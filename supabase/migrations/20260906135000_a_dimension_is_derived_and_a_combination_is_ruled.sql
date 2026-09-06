-- =============================================================================
-- 20260906135000  A dimension is derived, and a combination is ruled
-- -----------------------------------------------------------------------------
-- Specification v1.6 §5.7, analytical dimensions. The register said
-- 5.7.dimensions was partial: dimensions are declared on the journal line and
-- an account can require them, "but derivation from the source event and the
-- permitted-combination rules are configuration that nothing evaluates yet".
-- Reading the schema confirmed it and found two more things: the door that
-- writes a combination rule defaulted its effect to a value the table's
-- constraint refuses ('block'; the constraint allows permit and forbid), and
-- erp.dimension.is_mandatory_default was read by nothing.
--
-- What changes:
--
--   * Derivation. erp.dimension.derivation is a JsonLogic expression
--     (erp.jsonlogic, the evaluator the rule engine already has) over the
--     facts of a posting — document, account, line, entity — that returns a
--     value code. erp.derive_dimensions() stamps a journal line from three
--     sources in order of authority: the posting rule line's static
--     dimensions, then what the derivations say, then what the document
--     itself carries (attributes.dimensions), the later overriding the
--     earlier. Every value stamped from any source must be a value the
--     dimension has, active and valid on the posting date; the bridge
--     (erp.post_document_finance) is needled to call it.
--   * Combination rules. erp.dimension_combination_rule gains a scope (when
--     the rule applies; null is always) beside its condition; forbid refuses
--     when the condition holds, permit refuses when it does not. Evaluated
--     by erp.check_dimension_combination() from the journal-line trigger, so
--     manual journals and every bridge are ruled alike. A rule or a
--     derivation that names a fact the posting does not have is refused when
--     it is written, not discovered at month end.
--   * The trigger also honours is_mandatory_default: a dimension mandatory by
--     default is required on every line, whatever the account says, and a
--     value nobody defined is refused wherever it came from.
--   * Doors: erp_upsert_dimension, erp_upsert_dimension_value,
--     erp_dimension_values, erp_preview_dimensions (what a document would be
--     stamped with, line by line, and whether the rules let it through);
--     erp_upsert_dimension_rule re-created with the scope and a default the
--     table accepts.
--
-- A stock adjustment posted without a document (erp.post_adjustment_finance)
-- has no document facts and derives nothing; its lines carry the rule's
-- static dimensions as before. Logged, not widened.
--
-- Proof: erp_test.dimension_suite() (12 cases, wrapper pinned): the two lints,
-- derivation from the document, the document's own value winning, an unknown
-- value refused, a forbidden and an unpermitted combination refused at the
-- line, an out-of-scope permit rule silent, a mandatory dimension missing
-- refused, a purchase order sent carrying the derived dimensions on both
-- journal lines, the preview agreeing with the posting, the register flipped.
-- D4 gains the binding: the rule table and the derivation were configuration
-- nothing read.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Schema
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.dimension_combination_rule
  add column if not exists scope jsonb;

comment on column erp.dimension_combination_rule.scope is
  'JsonLogic over {account, dimensions, entity}: when the rule applies. Null '
  'applies always. The condition is then what must not hold (forbid) or must '
  'hold (permit) for the line to post.';
comment on column erp.dimension_combination_rule.condition is
  'JsonLogic over {account, dimensions, entity}. With effect forbid the line '
  'is refused when this holds; with effect permit it is refused when this '
  'does not hold. Evaluated by erp.check_dimension_combination() from the '
  'journal-line trigger, for every journal however it was raised.';
comment on column erp.dimension.derivation is
  'JsonLogic over {document, account, line, entity} returning a value code of '
  'this dimension, or null for no opinion. Evaluated by erp.derive_dimensions() '
  'when a document posts; the document''s own attributes.dimensions override it '
  'and the posting rule line''s static dimensions sit beneath it.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The facts, and the lint that keeps a rule honest
-- ═════════════════════════════════════════════════════════════════════════════

-- Every `var` path in an expression, so a rule can be checked against the
-- facts it will be given before it is stored.
create or replace function erp.rule_fact_paths(p_expr jsonb)
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_paths text[] := '{}';
  v_key   text;
  v_elem  jsonb;
  v_raw   jsonb;
begin
  if p_expr is null then
    return v_paths;
  end if;
  if jsonb_typeof(p_expr) = 'array' then
    for v_elem in select e.value from jsonb_array_elements(p_expr) e loop
      v_paths := v_paths || erp.rule_fact_paths(v_elem);
    end loop;
    return v_paths;
  end if;
  if jsonb_typeof(p_expr) <> 'object' then
    return v_paths;
  end if;
  if p_expr ? 'var' and (select count(*) from jsonb_object_keys(p_expr)) = 1 then
    v_raw := p_expr -> 'var';
    if jsonb_typeof(v_raw) = 'string' then
      return array[v_raw #>> '{}'];
    elsif jsonb_typeof(v_raw) = 'array' then
      return array[(v_raw -> 0) #>> '{}'] || erp.rule_fact_paths(v_raw -> 1);
    end if;
    return v_paths;
  end if;
  for v_key in select k from jsonb_object_keys(p_expr) k loop
    v_paths := v_paths || erp.rule_fact_paths(p_expr -> v_key);
  end loop;
  return v_paths;
end;
$$;
revoke all on function erp.rule_fact_paths(jsonb) from public, anon, authenticated;

create or replace function erp.lint_rule_facts(p_expr jsonb, p_roots text[], p_what text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_path text;
begin
  if p_expr is null then
    return;
  end if;
  foreach v_path in array erp.rule_fact_paths(p_expr) loop
    if not (split_part(v_path, '.', 1) = any (p_roots)) then
      raise exception 'CLOVEERP_RULE_UNKNOWN_FACT: % reads %, which a posting does not have',
        p_what, v_path
        using errcode = '22023',
              hint = format('The facts are %s; write the path as root.field, for example %s.code.',
                            array_to_string(p_roots, ', '), p_roots[1]);
    end if;
  end loop;
  -- A malformed expression fails here rather than on the first posting.
  perform erp.jsonlogic(p_expr, '{}'::jsonb);
end;
$$;
revoke all on function erp.lint_rule_facts(jsonb, text[], text) from public, anon, authenticated;

-- What a derivation sees.
create or replace function erp.dimension_facts(p_document_id uuid, p_account_code text, p_line jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
           'document', jsonb_build_object(
             'id', d.id, 'document_number', d.document_number,
             'document_type', dt.code, 'base_type', dt.base_type_code,
             'entity_code', e.code, 'site_code', s.code,
             'party_code', p.code, 'party_name', p.name,
             'currency', d.currency, 'document_date', d.document_date,
             'posting_date', coalesce(d.posting_date, d.document_date),
             'our_reference', d.our_reference, 'their_reference', d.their_reference,
             'order_behaviour', d.order_behaviour_code,
             'attributes', coalesce(d.attributes, '{}'::jsonb)),
           'account', coalesce((select jsonb_build_object('code', a.code, 'name', a.name,
                                                          'account_type', a.account_type,
                                                          'group_code', a.group_code)
                                  from erp.account a
                                 where a.tenant_id = d.tenant_id and a.entity_id = d.entity_id
                                   and a.code = p_account_code
                                 limit 1),
                               jsonb_build_object('code', p_account_code)),
           'line', coalesce(p_line, '{}'::jsonb),
           'entity', jsonb_build_object('code', e.code, 'name', e.name))
    from erp.document d
    join erp.document_type dt on dt.id = d.document_type_id
    join erp.entity e on e.id = d.entity_id
    left join erp.site s on s.id = d.site_id
    left join erp.party p on p.id = d.party_id
   where d.tenant_id = erp.current_tenant_id()
     and d.id = p_document_id
$$;
revoke all on function erp.dimension_facts(uuid, text, jsonb) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Values are validated, dimensions are derived
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.validate_dimensions(p_dimensions jsonb, p_on date default current_date)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  r record;
  v_dim uuid;
begin
  if p_dimensions is null or p_dimensions = '{}'::jsonb then
    return;
  end if;
  if jsonb_typeof(p_dimensions) <> 'object' then
    raise exception 'CLOVEERP_DIMENSIONS_NOT_AN_OBJECT: dimensions are an object of code to value code'
      using errcode = '22023',
            hint = 'Write {"CC": "SALES"}: the dimension code, then the value code.';
  end if;
  for r in select k, v from jsonb_each_text(p_dimensions) e(k, v) loop
    select d.id into v_dim from erp.dimension d
     where d.tenant_id = v_tenant and d.code = r.k and d.status = 'active';
    if v_dim is null then
      raise exception 'CLOVEERP_UNKNOWN_DIMENSION: % is not a dimension this organisation has', r.k
        using errcode = '23503',
              hint = 'erp_dimensions() lists them; erp_upsert_dimension() adds one.';
    end if;
    if r.v is null then
      continue;
    end if;
    if not exists (select 1 from erp.dimension_value dv
                    where dv.tenant_id = v_tenant and dv.dimension_id = v_dim
                      and dv.code = r.v and dv.status = 'active'
                      and (dv.valid_from is null or dv.valid_from <= p_on)
                      and (dv.valid_to is null or dv.valid_to >= p_on)) then
      raise exception 'CLOVEERP_DIMENSION_VALUE_UNKNOWN: % has no value % in force on %', r.k, r.v, p_on
        using errcode = '23503',
              hint = 'erp_dimension_values(dimension) lists the values; erp_upsert_dimension_value() adds one.';
    end if;
  end loop;
end;
$$;
revoke all on function erp.validate_dimensions(jsonb, date) from public, anon, authenticated;

create or replace function erp.derive_dimensions(p_document_id uuid, p_account_code text, p_line jsonb,
                                                 p_on date default current_date)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.current_tenant_id();
  v_facts    jsonb;
  v_static   jsonb := coalesce(p_line -> 'dimensions', '{}'::jsonb);
  v_derived  jsonb := '{}'::jsonb;
  v_explicit jsonb;
  v_out      jsonb;
  dim        record;
  v_value    jsonb;
begin
  v_facts := erp.dimension_facts(p_document_id, p_account_code, p_line);
  if v_facts is null then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  v_explicit := coalesce(v_facts -> 'document' -> 'attributes' -> 'dimensions', '{}'::jsonb);
  if jsonb_typeof(v_explicit) <> 'object' then
    raise exception 'CLOVEERP_DIMENSIONS_NOT_AN_OBJECT: the document''s attributes.dimensions is not an object'
      using errcode = '22023',
            hint = 'Write {"CC": "SALES"} under attributes.dimensions: the dimension code, then the value code.';
  end if;

  for dim in
    select d.code, d.derivation from erp.dimension d
     where d.tenant_id = v_tenant and d.status = 'active' and d.derivation is not null
     order by d.code
  loop
    begin
      v_value := erp.jsonlogic(dim.derivation, v_facts);
    exception when others then
      -- A derivation the rule engine cannot read is a derivation nobody
      -- tested; the posting says so rather than analysing the line as nothing.
      raise exception 'CLOVEERP_DERIVATION_INVALID: the derivation of % is not an expression the rule engine reads (%)',
        dim.code, left(sqlerrm, 80)
        using errcode = '22023',
              hint = 'Rewrite it through erp_upsert_dimension(), which checks the expression against the posting''s facts.';
    end;
    if v_value is not null and jsonb_typeof(v_value) = 'string' then
      v_derived := v_derived || jsonb_build_object(dim.code, v_value);
    end if;
  end loop;

  -- The later source overrides the earlier: the rule's static value is the
  -- floor, the derivation the default, the document's own word the last.
  v_out := v_static || v_derived || v_explicit;
  perform erp.validate_dimensions(v_out, p_on);
  return v_out;
end;
$$;
revoke all on function erp.derive_dimensions(uuid, text, jsonb, date) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The permitted combinations
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.check_dimension_combination(p_entity_id uuid, p_account_id uuid, p_dimensions jsonb)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_facts  jsonb;
  rule     record;
  v_holds  boolean;
begin
  select jsonb_build_object(
           'account', jsonb_build_object('code', a.code, 'name', a.name,
                                         'account_type', a.account_type, 'group_code', a.group_code),
           'dimensions', coalesce(p_dimensions, '{}'::jsonb),
           'entity', jsonb_build_object('code', e.code, 'name', e.name))
    into v_facts
    from erp.account a
    join erp.entity e on e.id = a.entity_id
   where a.tenant_id = v_tenant and a.id = p_account_id;

  if v_facts is null then
    return;
  end if;

  for rule in
    select r.code, r.name, r.scope, r.condition, r.effect, r.message
      from erp.dimension_combination_rule r
     where r.tenant_id = v_tenant and r.status = 'active'
       and (r.entity_id is null or r.entity_id = p_entity_id)
     order by r.code
  loop
    if rule.scope is not null
       and not erp.jsonlogic_truthy(erp.jsonlogic(rule.scope, v_facts)) then
      continue;
    end if;
    v_holds := erp.jsonlogic_truthy(erp.jsonlogic(rule.condition, v_facts));
    if rule.effect = 'forbid' and v_holds then
      raise exception 'CLOVEERP_DIMENSION_COMBINATION_FORBIDDEN: % — %',
        rule.code, coalesce(rule.message, rule.name, 'this combination is forbidden')
        using errcode = '23514',
              hint = 'erp_dimension_rules() shows the rule; change the dimensions on the line, or the rule.';
    end if;
    if rule.effect = 'permit' and not v_holds then
      raise exception 'CLOVEERP_DIMENSION_COMBINATION_NOT_PERMITTED: % — %',
        rule.code, coalesce(rule.message, rule.name, 'this combination is not permitted')
        using errcode = '23514',
              hint = 'erp_dimension_rules() shows what the rule permits; change the dimensions on the line, or the rule.';
    end if;
  end loop;
end;
$$;
revoke all on function erp.check_dimension_combination(uuid, uuid, jsonb) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Writers
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.upsert_dimension(p_code text, p_name text, p_derivation jsonb default null,
                                                p_is_mandatory_default boolean default false,
                                                p_status text default 'active')
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_code   text := upper(btrim(p_code));
begin
  perform erp.authorise('finance.configure', null, null, null, 'dimension', null);

  if v_code !~ '^[A-Z0-9_]{1,30}$' then
    raise exception 'CLOVEERP_DIMENSION_CODE_INVALID: % is not a code (letters, digits and underscores, up to 30)', p_code
      using errcode = '22023', hint = 'Write CC, DEPT or COST_CENTRE.';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'CLOVEERP_DIMENSION_NEEDS_A_NAME: % needs a name people will read on a report', v_code
      using errcode = '22023', hint = 'Give the dimension the name it has in the finance team''s own words.';
  end if;
  if p_status not in ('active', 'inactive') then
    raise exception 'CLOVEERP_UNKNOWN_STATUS: % is not active or inactive', p_status
      using errcode = '22023', hint = 'A dimension is active or inactive.';
  end if;

  perform erp.lint_rule_facts(p_derivation, array['document', 'account', 'line', 'entity'],
                              format('the derivation of %s', v_code));

  select d.id into v_id from erp.dimension d where d.tenant_id = v_tenant and d.code = v_code;
  if v_id is null then
    insert into erp.dimension (tenant_id, code, name, derivation, is_mandatory_default, status)
    values (v_tenant, v_code, btrim(p_name), p_derivation, coalesce(p_is_mandatory_default, false),
            p_status::erp.record_status)
    returning id into v_id;
  else
    update erp.dimension
       set name = btrim(p_name), derivation = p_derivation,
           is_mandatory_default = coalesce(p_is_mandatory_default, false),
           status = p_status::erp.record_status, updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;
  return v_id;
end;
$$;
revoke all on function erp.upsert_dimension(text, text, jsonb, boolean, text) from public, anon, authenticated;

create or replace function erp.upsert_dimension_value(p_dimension_code text, p_code text, p_name text,
                                                      p_parent_code text default null,
                                                      p_valid_from date default null, p_valid_to date default null,
                                                      p_status text default 'active')
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_dim    uuid;
  v_id     uuid;
  v_parent uuid;
  v_code   text := upper(btrim(p_code));
begin
  perform erp.authorise('finance.configure', null, null, null, 'dimension', null);

  select d.id into v_dim from erp.dimension d
   where d.tenant_id = v_tenant and d.code = upper(btrim(p_dimension_code));
  if v_dim is null then
    raise exception 'CLOVEERP_UNKNOWN_DIMENSION: % is not a dimension this organisation has', p_dimension_code
      using errcode = '23503', hint = 'erp_dimensions() lists them; erp_upsert_dimension() adds one.';
  end if;
  if v_code !~ '^[A-Za-z0-9_.-]{1,40}$' then
    raise exception 'CLOVEERP_DIMENSION_VALUE_CODE_INVALID: % is not a value code', p_code
      using errcode = '22023', hint = 'Letters, digits, underscore, dot and hyphen, up to 40.';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'CLOVEERP_DIMENSION_VALUE_NEEDS_A_NAME: % needs a name', v_code
      using errcode = '22023', hint = 'Give the value the name it has on the organisation chart.';
  end if;
  if p_valid_to is not null and p_valid_from is not null and p_valid_to < p_valid_from then
    raise exception 'CLOVEERP_DIMENSION_VALUE_WINDOW_INVERTED: % ends before it starts', v_code
      using errcode = '22023', hint = 'valid_to must not be before valid_from.';
  end if;
  if p_status not in ('active', 'inactive') then
    raise exception 'CLOVEERP_UNKNOWN_STATUS: % is not active or inactive', p_status
      using errcode = '22023', hint = 'A value is active or inactive.';
  end if;
  if p_parent_code is not null then
    select dv.id into v_parent from erp.dimension_value dv
     where dv.tenant_id = v_tenant and dv.dimension_id = v_dim and dv.code = upper(btrim(p_parent_code));
    if v_parent is null then
      raise exception 'CLOVEERP_DIMENSION_VALUE_UNKNOWN: % has no value % to be the parent of %',
        upper(btrim(p_dimension_code)), p_parent_code, v_code
        using errcode = '23503', hint = 'Add the parent value first.';
    end if;
  end if;

  select dv.id into v_id from erp.dimension_value dv
   where dv.tenant_id = v_tenant and dv.dimension_id = v_dim and dv.code = v_code;
  if v_id is null then
    insert into erp.dimension_value (tenant_id, dimension_id, code, name, parent_value_id,
                                     valid_from, valid_to, status)
    values (v_tenant, v_dim, v_code, btrim(p_name), v_parent, p_valid_from, p_valid_to,
            p_status::erp.record_status)
    returning id into v_id;
  else
    if v_parent = v_id then
      raise exception 'CLOVEERP_DIMENSION_VALUE_OWN_PARENT: % cannot be its own parent', v_code
        using errcode = '22023', hint = 'Name a different value, or none.';
    end if;
    update erp.dimension_value
       set name = btrim(p_name), parent_value_id = v_parent, valid_from = p_valid_from,
           valid_to = p_valid_to, status = p_status::erp.record_status, updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;
  return v_id;
end;
$$;
revoke all on function erp.upsert_dimension_value(text, text, text, text, date, date, text) from public, anon, authenticated;

create or replace function erp.upsert_dimension_rule(p_code text, p_name text, p_condition jsonb,
                                                     p_effect text default 'forbid', p_message text default null,
                                                     p_entity_id uuid default null, p_scope jsonb default null,
                                                     p_status text default 'active')
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_code   text := upper(btrim(p_code));
begin
  perform erp.authorise('finance.configure', p_entity_id, null, null, 'dimension_combination_rule', null);

  if p_effect not in ('permit', 'forbid') then
    raise exception 'CLOVEERP_RULE_EFFECT_UNKNOWN: % is not permit or forbid', p_effect
      using errcode = '22023',
            hint = 'forbid refuses the line when the condition holds; permit refuses it when the condition does not.';
  end if;
  if p_condition is null then
    raise exception 'CLOVEERP_RULE_NEEDS_A_CONDITION: % says nothing', v_code
      using errcode = '22023',
            hint = 'Write the condition as JsonLogic over account, dimensions and entity.';
  end if;
  if p_status not in ('active', 'inactive') then
    raise exception 'CLOVEERP_UNKNOWN_STATUS: % is not active or inactive', p_status
      using errcode = '22023', hint = 'A rule is active or inactive.';
  end if;
  if p_entity_id is not null and not exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.id = p_entity_id) then
    raise exception 'CLOVEERP_UNKNOWN_ENTITY: %', p_entity_id
      using errcode = '23503', hint = 'erp_entities() lists the companies.';
  end if;

  perform erp.lint_rule_facts(p_condition, array['account', 'dimensions', 'entity'], format('the condition of %s', v_code));
  perform erp.lint_rule_facts(p_scope, array['account', 'dimensions', 'entity'], format('the scope of %s', v_code));

  select r.id into v_id from erp.dimension_combination_rule r
   where r.tenant_id = v_tenant and r.code = v_code;
  if v_id is null then
    insert into erp.dimension_combination_rule (
      tenant_id, entity_id, code, name, condition, effect, message, scope, status)
    values (v_tenant, p_entity_id, v_code, p_name, p_condition, p_effect, p_message, p_scope,
            p_status::erp.record_status)
    returning id into v_id;
  else
    update erp.dimension_combination_rule
       set name = p_name, condition = p_condition, effect = p_effect, message = p_message,
           entity_id = p_entity_id, scope = p_scope, status = p_status::erp.record_status,
           updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;
  return v_id;
end;
$$;
revoke all on function erp.upsert_dimension_rule(text, text, jsonb, text, text, uuid, jsonb, text) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5b. The one derivation that already existed was a note, not an expression
-- ═════════════════════════════════════════════════════════════════════════════

-- erp.ensure_department_dimension() wrote {"from": "requester_primary_department"}
-- into a column nothing read. Now that the column is evaluated, that shape
-- would refuse every posting in an organisation with a department. The
-- department a document carries under attributes.department is what the
-- derivation reads; a document that carries none gets no opinion, and the
-- department's value is stamped only where somebody said which.
do $$
declare v_src text := pg_get_functiondef('erp.ensure_department_dimension()'::regprocedure);
begin
  if position('jsonb_build_object(''from'', ''requester_primary_department'')' in v_src) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.ensure_department_dimension is not the 20260830130124 body';
  end if;
  execute replace(v_src, 'jsonb_build_object(''from'', ''requester_primary_department'')',
                         'jsonb_build_object(''var'', ''document.attributes.department'')');
end $$;

update erp.dimension
   set derivation = jsonb_build_object('var', 'document.attributes.department'), updated_at = now()
 where code = 'DEPARTMENT' and derivation ? 'from';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The bridge derives; the trigger rules
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare
  v_src    text := pg_get_functiondef('erp.post_document_finance(uuid)'::regprocedure);
  v_needle text := E'      coalesce(v_line -> ''dimensions'', ''{}''::jsonb),\n      pr.id, pr.version, v_event,';
  v_new    text;
begin
  if position(v_needle in v_src) = 0 or position('derive_dimensions' in v_src) > 0
     or (length(v_src) - length(replace(v_src, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.post_document_finance does not carry the journal-line insert once';
  end if;
  v_new := replace(v_src, v_needle,
    E'      erp.derive_dimensions(p_document_id, acc.code, v_line,\n'
    || E'                            coalesce(d.posting_date, d.document_date, current_date)),\n'
    || E'      pr.id, pr.version, v_event,');
  execute v_new;
end $$;

do $$
declare v_src text := pg_get_functiondef('erp.check_journal_line_posting()'::regprocedure);
begin
  if position('foreach d in array v_account.requires_dimensions loop' in v_src) = 0
     or position('check_dimension_combination' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.check_journal_line_posting is not the 20260829220000 body';
  end if;
end $$;

create or replace function erp.check_journal_line_posting()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_source   text;
  v_account  erp.account%rowtype;
  v_missing  text[];
  v_required text[];
  v_on       date;
  d          text;
begin
  select j.source_code, j.posting_date into v_source, v_on from erp.journal j where j.id = new.journal_id;

  -- Spec 4.7: every posting traces to an operational event and the rule
  -- version that produced it. Manual journals are the stated exception and
  -- carry a reason on the journal instead.
  if v_source <> 'manual'
     and (new.posting_rule_id is null or new.source_event_id is null) then
    raise exception
      'CLOVEERP_POSTING_NOT_TRACEABLE: a machine-generated line must name its source event and posting rule'
      using errcode = '23514',
            hint = 'Only a manual journal may post without a rule, and it must carry a reason.';
  end if;

  select * into v_account from erp.account a where a.id = new.account_id;

  if not v_account.is_postable then
    raise exception 'CLOVEERP_ACCOUNT_NOT_POSTABLE: % is a summary or control account',
      v_account.code using errcode = '23514',
      hint = 'Post to a postable account beneath it.';
  end if;

  -- Every value the line carries is one the dimension has, whatever wrote it.
  perform erp.validate_dimensions(coalesce(new.dimensions, '{}'::jsonb), coalesce(v_on, current_date));

  -- Dimensions the account insists on, and the ones mandatory by default.
  select coalesce(v_account.requires_dimensions, '{}')
         || coalesce(array_agg(dm.code) filter (where dm.code is not null), '{}')
    into v_required
    from erp.dimension dm
   where dm.tenant_id = new.tenant_id and dm.status = 'active' and dm.is_mandatory_default
     and not (dm.code = any (coalesce(v_account.requires_dimensions, '{}')));

  v_missing := '{}';
  foreach d in array v_required loop
    if not (coalesce(new.dimensions, '{}'::jsonb) ? d) then
      v_missing := v_missing || d;
    end if;
  end loop;

  if cardinality(v_missing) > 0 then
    raise exception 'CLOVEERP_DIMENSION_REQUIRED: % requires %',
      v_account.code, array_to_string(v_missing, ', ') using errcode = '23514',
      hint = 'Give the line the dimension, or give the dimension a derivation so the posting can.';
  end if;

  -- The permitted combinations, for every journal however it was raised.
  perform erp.check_dimension_combination(v_account.entity_id, v_account.id,
                                          coalesce(new.dimensions, '{}'::jsonb));

  return new;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_upsert_dimension(p_code text, p_name text, p_derivation jsonb default null,
                                                       p_is_mandatory_default boolean default false,
                                                       p_status text default 'active')
returns jsonb
language sql
set search_path = ''
as $$
  select jsonb_build_object('dimension_id',
           erp.upsert_dimension(p_code, p_name, p_derivation, p_is_mandatory_default, p_status),
         'code', upper(btrim(p_code)))
$$;

create or replace function public.erp_upsert_dimension_value(p_dimension_code text, p_code text, p_name text,
                                                             p_parent_code text default null,
                                                             p_valid_from date default null, p_valid_to date default null,
                                                             p_status text default 'active')
returns jsonb
language sql
set search_path = ''
as $$
  select jsonb_build_object('value_id',
           erp.upsert_dimension_value(p_dimension_code, p_code, p_name, p_parent_code, p_valid_from, p_valid_to, p_status),
         'dimension', upper(btrim(p_dimension_code)), 'code', upper(btrim(p_code)))
$$;

create or replace function public.erp_dimension_values(p_dimension_code text default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'value_id', dv.id, 'dimension', d.code, 'code', dv.code, 'name', dv.name,
           'parent_code', (select p.code from erp.dimension_value p where p.id = dv.parent_value_id),
           'valid_from', dv.valid_from, 'valid_to', dv.valid_to, 'status', dv.status)
         order by d.code, dv.code), '[]'::jsonb)
    from erp.dimension_value dv
    join erp.dimension d on d.id = dv.dimension_id
   where dv.tenant_id = erp.current_tenant_id()
     and (p_dimension_code is null or d.code = upper(btrim(p_dimension_code)))
$$;

-- The door that wrote a rule defaulted to an effect the table refuses; it is
-- re-created with the scope and a default the constraint accepts. Same name,
-- one signature.
drop function if exists public.erp_upsert_dimension_rule(text, text, jsonb, text, text, uuid);
create function public.erp_upsert_dimension_rule(p_code text, p_name text, p_condition jsonb,
                                                 p_effect text default 'forbid', p_message text default null,
                                                 p_entity_id uuid default null, p_scope jsonb default null,
                                                 p_status text default 'active')
returns jsonb
language sql
set search_path = ''
as $$
  select jsonb_build_object('rule_id',
           erp.upsert_dimension_rule(p_code, p_name, p_condition, p_effect, p_message, p_entity_id, p_scope, p_status),
         'code', upper(btrim(p_code)))
$$;

-- The rule listing shows the scope too.
create or replace function public.erp_dimension_rules()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.read');
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'rule_id', r.id, 'code', r.code, 'name', r.name,
      'scope', r.scope, 'condition', r.condition, 'effect', r.effect, 'message', r.message,
      'entity_id', r.entity_id, 'status', r.status) as x
      from erp.dimension_combination_rule r
     where r.tenant_id = erp.current_tenant_id()
  ) s;
  return v_out;
end;
$$;

-- What a document would be stamped with, line by line, before it posts.
create or replace function public.erp_preview_dimensions(p_document_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  pr       erp.posting_rule%rowtype;
  v_line   jsonb;
  v_dims   jsonb;
  v_acc    erp.account%rowtype;
  v_out    jsonb := '[]'::jsonb;
  v_on     date;
  v_verdict text;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;
  perform erp.authorise('finance.read', d.entity_id, d.site_id, null, 'document', p_document_id);

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  v_on := coalesce(d.posting_date, d.document_date, current_date);

  select * into pr from erp.posting_rule r
   where r.tenant_id = v_tenant and r.code = dt.posting_rule_code and r.status = 'active'
     and (r.entity_id is null or r.entity_id = d.entity_id)
     and r.effective_from <= v_on and (r.effective_to is null or r.effective_to > v_on)
   order by (r.entity_id is not null) desc, r.version desc limit 1;

  if pr.id is null then
    return jsonb_build_object('document_id', p_document_id, 'posting_rule', null, 'lines', '[]'::jsonb,
                              'note', 'this document type reaches no ledger, or no rule is in force');
  end if;

  for v_line in select l.value from jsonb_array_elements(pr.posting_lines) l loop
    v_acc := null;
    select * into v_acc from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = d.entity_id
       and a.code = erp.posting_line_account_code(v_line, p_document_id, pr.ledger_id)
       and a.status = 'active';
    begin
      v_dims := erp.derive_dimensions(p_document_id, coalesce(v_acc.code, v_line ->> 'account'), v_line, v_on);
      if v_acc.id is not null then
        perform erp.check_dimension_combination(d.entity_id, v_acc.id, v_dims);
      end if;
      v_verdict := 'ok';
    exception when others then
      v_verdict := left(sqlerrm, 300);
    end;
    v_out := v_out || jsonb_build_object(
      'account', coalesce(v_acc.code, v_line ->> 'account'), 'account_name', v_acc.name,
      'side', v_line ->> 'side', 'dimensions', v_dims, 'verdict', v_verdict);
  end loop;

  return jsonb_build_object('document_id', p_document_id, 'posting_rule', pr.code,
                            'posting_date', v_on, 'lines', v_out);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_upsert_dimension(text, text, jsonb, boolean, text)',
    'erp_upsert_dimension_value(text, text, text, text, date, date, text)',
    'erp_dimension_values(text)',
    'erp_upsert_dimension_rule(text, text, jsonb, text, text, uuid, jsonb, text)',
    'erp_dimension_rules()',
    'erp_preview_dimensions(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_upsert_dimension', 'erp.upsert_dimension',
   'Declares or changes an analytical dimension and its derivation; authorises finance.configure and lints the derivation''s facts.'),
  ('erp_upsert_dimension_value', 'erp.upsert_dimension_value',
   'Adds or changes a value of a dimension with its validity window; authorises finance.configure.'),
  ('erp_upsert_dimension_rule', 'erp.upsert_dimension_rule',
   'Writes a permitted-combination rule with its scope and condition; authorises finance.configure and lints both expressions.'),
  ('erp_preview_dimensions', 'erp.authorise',
   'Shows what a document would be stamped with and whether the rules let it post; authorises finance.read on the document, so it cannot be STABLE.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The register and the decision
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.part5_capability
   set status = 'built',
       gap = null,
       artefacts = array['erp.dimension',
                         'erp.dimension_value',
                         'erp.dimension_combination_rule',
                         'erp.derive_dimensions(uuid,text,jsonb,date)',
                         'erp.dimension_facts(uuid,text,jsonb)',
                         'erp.validate_dimensions(jsonb,date)',
                         'erp.check_dimension_combination(uuid,uuid,jsonb)',
                         'erp.lint_rule_facts(jsonb,text[],text)',
                         'erp.check_journal_line_posting()',
                         'erp.upsert_dimension(text,text,jsonb,boolean,text)',
                         'erp.upsert_dimension_value(text,text,text,text,date,date,text)',
                         'erp.upsert_dimension_rule(text,text,jsonb,text,text,uuid,jsonb,text)']
 where code = '5.7.dimensions';

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D4', 'erp_test', 'assert_dimension_suite',
   'The dimension derivation and the permitted-combination rule were configuration that nothing evaluated — the other half of D4, that configuration nobody reads is not configuration. The suite proves both are read at posting, from the bridge and from a manual journal.')
on conflict do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.dimension_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth uuid := gen_random_uuid();
  v_entity uuid; v_site uuid; v_site_code text; v_sup uuid; v_item uuid; v_ledger uuid;
  v_acc uuid; v_acc_code text; v_po uuid; v_po2 uuid; v_j uuid; v_dims jsonb; v_x jsonb;
  t record; v_ok boolean; v_msg text; v_n integer;
begin
  begin
    select x.tenant_id, x.admin_user_id, x.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzdim', 'Dimension Suite', 'admin@zzdim.test', 'Dim Admin') x;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (v_auth, 'admin@zzdim.test');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    select s.id, s.code into v_site, v_site_code from erp.site s where s.tenant_id = v_tenant and s.entity_id = v_entity order by s.code limit 1;
    select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.status = 'active' order by i.code limit 1;
    select pr.party_id into v_sup from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;
    select l.id into v_ledger from erp.ledger l where l.tenant_id = v_tenant and l.entity_id = v_entity and l.status = 'active' order by l.code limit 1;
    select a.id, a.code into v_acc, v_acc_code from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = '8100' and a.is_postable;

    -- 1. A derivation that reads a fact the posting does not have.
    begin
      perform erp.upsert_dimension('CC', 'Cost centre', '{"var": "invoice.region"}'::jsonb);
      v_ok := false; v_msg := 'accepted a derivation over a fact that does not exist';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_RULE_UNKNOWN_FACT:%invoice.region%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a derivation that names a fact the posting does not have is refused when written', v_ok, v_msg;

    -- 2. A value for a dimension nobody declared.
    begin
      perform erp.upsert_dimension_value('CC', 'PURCH', 'Purchasing');
      v_ok := false; v_msg := 'accepted a value for an unknown dimension';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_UNKNOWN_DIMENSION:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a value for a dimension nobody declared is refused', v_ok, v_msg;

    -- The dimensions: a cost centre derived from the document type, a region
    -- derived from the site.
    perform erp.upsert_dimension('CC', 'Cost centre',
      '{"if": [{"==": [{"var": "document.base_type"}, "purchase_order"]}, "PURCH", "GEN"]}'::jsonb);
    perform erp.upsert_dimension_value('CC', 'PURCH', 'Purchasing');
    perform erp.upsert_dimension_value('CC', 'GEN', 'General');
    perform erp.upsert_dimension_value('CC', 'OLD', 'Closed centre', null, null, current_date - 1);
    perform erp.upsert_dimension('REGION', 'Region', '{"var": "document.site_code"}'::jsonb);
    perform erp.upsert_dimension_value('REGION', v_site_code, 'The main site');

    -- 3. Derived from the document.
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_po, v_item, 2, 500, 'for the cost centre');
    v_dims := erp.derive_dimensions(v_po, v_acc_code, '{"account": "8100", "side": "debit"}'::jsonb);
    return query select 'a document''s dimensions are derived from its facts',
      v_dims ->> 'CC' = 'PURCH' and v_dims ->> 'REGION' = v_site_code,
      format('CC %s, REGION %s', v_dims ->> 'CC', v_dims ->> 'REGION');

    -- 4. The document's own word wins over the derivation.
    update erp.document set attributes = coalesce(attributes, '{}'::jsonb) || '{"dimensions": {"CC": "GEN"}}'::jsonb
     where id = v_po;
    v_dims := erp.derive_dimensions(v_po, v_acc_code, '{"account": "8100", "side": "debit", "dimensions": {"CC": "PURCH"}}'::jsonb);
    return query select 'what the document carries overrides the derivation and the rule''s static value',
      v_dims ->> 'CC' = 'GEN' and v_dims ->> 'REGION' = v_site_code,
      'the document said GEN; the derivation and the rule said PURCH';

    -- 5. A value nobody defined, or one no longer in force.
    update erp.document set attributes = attributes || '{"dimensions": {"CC": "OLD"}}'::jsonb where id = v_po;
    begin
      v_dims := erp.derive_dimensions(v_po, v_acc_code, '{}'::jsonb);
      v_ok := false; v_msg := 'a closed value was stamped';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_DIMENSION_VALUE_UNKNOWN: CC has no value OLD%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a value not in force on the posting date is refused wherever it came from', v_ok, v_msg;
    update erp.document set attributes = attributes - 'dimensions' where id = v_po;

    -- 6. A forbidden combination, refused at the line by the trigger.
    perform erp.upsert_dimension_rule('NO_GEN_ON_COMMITMENTS', 'No general cost centre on commitments',
      '{"==": [{"var": "dimensions.CC"}, "GEN"]}'::jsonb, 'forbid',
      'a commitment must name the buying cost centre', null,
      '{"==": [{"var": "account.code"}, "8100"]}'::jsonb);
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date, description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'dimension suite', 'draft', 'the suite is proving the rules')
    returning id into v_j;
    begin
      insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                    base_debit_minor, base_credit_minor, exchange_rate, dimensions)
      values (v_tenant, v_j, 1, v_acc, 100, 0, 'GBP', 100, 0, 1, '{"CC": "GEN"}'::jsonb);
      v_ok := false; v_msg := 'a forbidden combination posted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_DIMENSION_COMBINATION_FORBIDDEN: NO_GEN_ON_COMMITMENTS%'; v_msg := left(sqlerrm, 100);
    end;
    return query select 'a forbidden combination is refused at the line, for a manual journal too', v_ok, v_msg;

    -- 7. A permit rule: in scope it refuses what it does not permit; out of
    --    scope it says nothing.
    perform erp.upsert_dimension_rule('REGION_ON_8100', 'Commitments are regional',
      jsonb_build_object('in', jsonb_build_array(jsonb_build_object('var', 'dimensions.REGION'),
                                                 jsonb_build_array(v_site_code))), 'permit',
      'a commitment is booked to the main site''s region', null,
      '{"==": [{"var": "account.code"}, "8100"]}'::jsonb);
    begin
      insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                    base_debit_minor, base_credit_minor, exchange_rate, dimensions)
      values (v_tenant, v_j, 2, v_acc, 100, 0, 'GBP', 100, 0, 1, '{"CC": "PURCH"}'::jsonb);
      v_ok := false; v_msg := 'a line outside what the rule permits posted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_DIMENSION_COMBINATION_NOT_PERMITTED: REGION_ON_8100%'; v_msg := left(sqlerrm, 100);
    end;
    -- The same dimensions on the offset account are outside the rule's scope.
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate, dimensions)
    select v_tenant, v_j, 3, a.id, 0, 100, 'GBP', 0, 100, 1, '{"CC": "PURCH"}'::jsonb
      from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = '8900';
    return query select 'a permit rule refuses what it does not permit in scope, and is silent out of scope',
      v_ok and (select count(*) from erp.journal_line jl where jl.journal_id = v_j) = 1,
      v_msg;

    -- 8. Mandatory by default.
    perform erp.upsert_dimension('PROJECT', 'Project', null, true);
    perform erp.upsert_dimension_value('PROJECT', 'P1', 'The first project');
    begin
      insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                    base_debit_minor, base_credit_minor, exchange_rate, dimensions)
      select v_tenant, v_j, 4, a.id, 0, 100, 'GBP', 0, 100, 1, '{"CC": "PURCH"}'::jsonb
        from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = '8900';
      v_ok := false; v_msg := 'a line without the mandatory dimension posted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_DIMENSION_REQUIRED: 8900 requires PROJECT%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a dimension mandatory by default is required on every line', v_ok, v_msg;
    perform erp.upsert_dimension('PROJECT', 'Project', null, false, 'inactive');

    -- 9. The bridge: a purchase order sent carries the derived dimensions on
    --    both lines, and the preview said so first.
    v_po2 := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_po2, v_item, 1, 500, 'to be committed');
    v_x := public.erp_preview_dimensions(v_po2);
    perform erp.transition_document(v_po2, 'submit');
    for t in select tk.id from erp.approval_task tk join erp.approval_request q on q.id = tk.approval_request_id
              where q.object_id = v_po2 and tk.status = 'pending' and tk.assignee_user_id = erp.current_principal_id()
    loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;
    perform erp.transition_document(v_po2, 'approve');
    perform erp.transition_document(v_po2, 'send');
    select count(*) into v_n from erp.journal j join erp.journal_line jl on jl.journal_id = j.id
     where j.tenant_id = v_tenant and j.document_id = v_po2
       and jl.dimensions ->> 'CC' = 'PURCH' and jl.dimensions ->> 'REGION' = v_site_code;
    return query select 'a purchase order sent carries the derived dimensions on every journal line',
      v_n = 2 and v_n = (select count(*) from erp.journal j join erp.journal_line jl on jl.journal_id = j.id
                          where j.tenant_id = v_tenant and j.document_id = v_po2),
      format('%s line(s) stamped CC PURCH, REGION %s', v_n, v_site_code);

    return query select 'the preview showed the same dimensions and let the lines through',
      jsonb_array_length(v_x -> 'lines') = 2
      and (select bool_and(l ->> 'verdict' = 'ok' and l -> 'dimensions' ->> 'CC' = 'PURCH')
             from jsonb_array_elements(v_x -> 'lines') l),
      v_x ->> 'posting_rule';

    return query select 'the register says dimensions are built, and the artefacts exist',
      (select c.status from erp_ref.part5_capability c where c.code = '5.7.dimensions') = 'built'
      and not exists (select 1 from erp.part5_coverage_report() f where f.reference = '5.7.dimensions')
      and exists (select 1 from erp_ref.product_decision_check c
                   where c.decision_code = 'D4' and c.routine_name = 'assert_dimension_suite'),
      '5.7.dimensions; D4 bound';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzdim');
  detail := 'the organisation, its dimensions and its journals rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_dimension_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 12;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _dimension_suite on commit drop as
    select * from erp_test.dimension_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _dimension_suite;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DIMENSION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_DIMENSION_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('dimensions: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_dimension_suite() from public, anon, authenticated;
revoke all on function erp_test.dimension_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_dimension_suite();
select erp_test.assert_finance_suite();
select erp_test.assert_order_behaviour_suite();
select erp_test.assert_costing_suite();
select erp.assert_part5_coverage();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_no_dead_configuration();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
