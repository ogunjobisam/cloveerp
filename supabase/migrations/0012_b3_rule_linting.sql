-- =============================================================================
-- ERPWare — B3: linting rule conditions against the facts they will be given
--
-- The rule interpreter raises on an unknown OPERATOR, because a typo there
-- would make a rule silently never match. It does not raise on an unknown
-- PATH, and it must not: a decision point's input schema has optional
-- properties, and a condition that asks about one absent from these particular
-- facts should evaluate to null and move on, not abort a posting run.
--
-- That leaves a real gap, found by writing a rule with a mistyped path in it:
--
--     {"==": [{"var": "supplier_supplier_approved"}, false]}
--
-- Every part of that is well-formed. It reads correctly. It never matches
-- anything, ever, and nothing complains — the rule simply sits in the set
-- doing nothing while its author believes it is protecting them.
--
-- Rules decide money, stock and approvals, so this cannot be left to
-- discipline. A path that the decision point can never supply is a defect at
-- AUTHORING time even though it is legitimate at EVALUATION time — so it is
-- caught here, against the declared input schema, before the rule set is ever
-- put in force.
-- =============================================================================

-- Every `var` path mentioned anywhere in an expression.
create or replace function erp.rule_var_paths(p_expr jsonb)
returns setof text
language plpgsql
immutable
set search_path = ''
as $$
declare
  rec  record;
  v_op text;
  v_keys integer;
begin
  if p_expr is null then return; end if;

  if jsonb_typeof(p_expr) = 'array' then
    for rec in select e.value as v from jsonb_array_elements(p_expr) e loop
      return query select erp.rule_var_paths(rec.v);
    end loop;
    return;
  end if;

  if jsonb_typeof(p_expr) <> 'object' then return; end if;

  select count(*) into v_keys from jsonb_object_keys(p_expr);
  if v_keys = 1 then
    select k into v_op from jsonb_object_keys(p_expr) k limit 1;
    if v_op = 'var' then
      if jsonb_typeof(p_expr -> 'var') = 'string' then
        return next (p_expr -> 'var') #>> '{}';
      elsif jsonb_typeof(p_expr -> 'var') = 'array' then
        return next (p_expr #> '{var,0}') #>> '{}';
        -- The default branch of a two-argument var may itself contain vars.
        return query select erp.rule_var_paths(p_expr #> '{var,1}');
      end if;
      return;
    end if;
  end if;

  for rec in select e.value as v from jsonb_each(p_expr) e loop
    return query select erp.rule_var_paths(rec.v);
  end loop;
end;
$$;

-- Every dotted path a JSON Schema declares. Objects recurse; anything else is
-- a leaf. A schema that permits additional properties declares nothing useful,
-- which the linter accounts for below.
create or replace function erp.schema_paths(p_schema jsonb, p_prefix text default '')
returns setof text
language plpgsql
immutable
set search_path = ''
as $$
declare
  rec     record;
  v_child text;
begin
  if p_schema is null or jsonb_typeof(p_schema) <> 'object' then return; end if;
  if p_schema -> 'properties' is null then return; end if;

  for rec in
    select e.key as k, e.value as v from jsonb_each(p_schema -> 'properties') e
  loop
    v_child := case when p_prefix = '' then rec.k else p_prefix || '.' || rec.k end;
    return next v_child;
    return query select erp.schema_paths(rec.v, v_child);
  end loop;
end;
$$;

create or replace function erp.lint_rule_set_version(p_rule_set_version_id uuid)
returns table (
  severity   text,
  rule_code  text,
  finding    text,
  detail     text
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_dp      erp_ref.decision_point%rowtype;
  v_open    boolean;
  r         record;
  v_path    text;
  v_probe   jsonb;
begin
  select dp.* into v_dp
    from erp.rule_set_version rsv
    join erp.rule_set rs
      on rs.tenant_id = rsv.tenant_id and rs.id = rsv.rule_set_id
    join erp_ref.decision_point dp on dp.code = rs.decision_point_code
   where rsv.tenant_id = v_tenant and rsv.id = p_rule_set_version_id;

  if not found then
    raise exception 'ERPWARE_RULE_SET_VERSION_NOT_FOUND: %', p_rule_set_version_id
      using errcode = '23503';
  end if;

  -- If the decision point permits properties it has not declared, an unknown
  -- path may be legitimate and the check would be noise.
  v_open := coalesce((v_dp.input_schema ->> 'additionalProperties')::boolean, true);

  for r in
    select ru.code, ru.condition, ru.outcome, ru.seq, ru.stop_on_match
      from erp.rule ru
     where ru.tenant_id = v_tenant
       and ru.rule_set_version_id = p_rule_set_version_id
     order by ru.seq
  loop
    -- 1. Paths the decision point can never supply.
    if not v_open then
      for v_path in select erp.rule_var_paths(r.condition) loop
        if not exists (select 1 from erp.schema_paths(v_dp.input_schema) sp
                        where sp = v_path) then
          severity  := 'error';
          rule_code := r.code;
          finding   := 'condition reads a fact the decision point never supplies';
          detail    := format('"%s" is not declared by %s, so this rule can never match',
                              v_path, v_dp.code);
          return next;
        end if;
      end loop;
    end if;

    -- 2. Conditions that do not evaluate at all: an unknown operator, a
    --    malformed var. Probed against an empty fact set, since the
    --    interpreter is pure and structural errors do not depend on the data.
    begin
      v_probe := erp.jsonlogic(r.condition, '{}'::jsonb);
    exception when others then
      severity  := 'error';
      rule_code := r.code;
      finding   := 'condition cannot be evaluated';
      detail    := sqlerrm;
      return next;
    end;

    -- 3. Outcomes that do not match the shape the product will act on.
    if not extensions.jsonb_matches_schema(v_dp.outcome_schema::json, r.outcome) then
      severity  := 'error';
      rule_code := r.code;
      finding   := 'outcome does not satisfy the decision point''s outcome schema';
      detail    := r.outcome::text;
      return next;
    end if;

    -- 4. A rule that always matches, followed by others: everything after it
    --    is unreachable. Worth saying out loud rather than leaving to be
    --    discovered when a rule that should have fired did not.
    if r.stop_on_match
       and r.condition = 'true'::jsonb
       and exists (select 1 from erp.rule later
                    where later.tenant_id = v_tenant
                      and later.rule_set_version_id = p_rule_set_version_id
                      and later.seq > r.seq
                      and later.is_active)
    then
      severity  := 'warning';
      rule_code := r.code;
      finding   := 'rule always matches and stops, making later rules unreachable';
      detail    := format('rules after seq %s never evaluate', r.seq);
      return next;
    end if;
  end loop;

  return;
end;
$$;

comment on function erp.lint_rule_set_version(uuid) is
  'Checks a draft rule set against the contract of its decision point: paths '
  'that can never be supplied, conditions that cannot evaluate, outcomes of '
  'the wrong shape, and rules made unreachable by an earlier catch-all.';

-- A rule set version may not be put in force with errors outstanding. The
-- linter is only worth having if it is on the path.
create or replace function erp.activate_rule_set_version(
  p_rule_set_version_id uuid,
  p_effective_from      date default null
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_errors   text;
  v_count    integer;
  v_set      uuid;
  v_from     date := coalesce(p_effective_from, current_date);
begin
  select rsv.rule_set_id into v_set
    from erp.rule_set_version rsv
   where rsv.tenant_id = v_tenant and rsv.id = p_rule_set_version_id
     and rsv.status = 'draft';

  if not found then
    raise exception 'ERPWARE_RULE_SET_VERSION_NOT_DRAFT: % is not a draft version',
      p_rule_set_version_id using errcode = '23514';
  end if;

  select count(*), string_agg(format('  [%s] %s: %s — %s', l.severity, l.rule_code,
                                     l.finding, l.detail), E'\n')
    into v_count, v_errors
    from erp.lint_rule_set_version(p_rule_set_version_id) l
   where l.severity = 'error';

  if v_count > 0 then
    raise exception E'ERPWARE_RULE_SET_INVALID: % error(s)\n%', v_count, v_errors
      using errcode = '23514';
  end if;

  -- Close whatever is in force at the new start date, exactly as configuration
  -- versions are closed: history stays answerable.
  update erp.rule_set_version rsv
     set effective_to = v_from,
         status = case when rsv.effective_from >= v_from then 'superseded' else rsv.status end,
         updated_at = now()
   where rsv.tenant_id = v_tenant
     and rsv.rule_set_id = v_set
     and rsv.status = 'active'
     and (rsv.effective_to is null or rsv.effective_to > v_from);

  update erp.rule_set_version rsv
     set status = 'superseded', updated_at = now()
   where rsv.tenant_id = v_tenant
     and rsv.rule_set_id = v_set
     and rsv.status = 'active'
     and rsv.effective_to is not null
     and rsv.effective_to <= rsv.effective_from;

  update erp.rule_set_version
     set status = 'active', effective_from = v_from, updated_at = now()
   where tenant_id = v_tenant and id = p_rule_set_version_id;
end;
$$;

comment on function erp.activate_rule_set_version(uuid, date) is
  'The supported way to put rules in force. Refuses on any lint error, so a '
  'rule that can never match cannot reach production by being switched on '
  'directly.';
