-- =============================================================================
-- ERPWare — B3 (part 2/2): the rule engine
-- Spec 3.5:
--   "Declarative rules: condition, evaluation order, outcome, and effect on
--    documents, postings or workflow"
--   "Rules are versioned and effective-dated; the version in force at a
--    transaction's date is the version applied, permanently"
--   "Every rule evaluation is traceable: given an outcome, the system can state
--    which rule, which version, which inputs"
--   "No business rule is expressed in application code where a tenant might
--    reasonably need it to differ"
--
-- The last clause is the demanding one. It is only satisfiable if there is a
-- place for a rule to live that is not code, and a way to evaluate it that does
-- not involve deploying anything. So:
--
--   * The PRODUCT declares decision points — the places where it will ask a
--     question — each with a schema for the facts it will supply and a schema
--     for the answer it expects back. That contract is product content.
--
--   * The TENANT supplies rule sets against those decision points. A rule is a
--     condition (a declarative expression over the supplied facts), an
--     evaluation order, and an outcome.
--
--   * Evaluation is a generic interpreter. Adding a rule requires no code, and
--     two tenants with contradictory rules run the same binary.
--
-- Determinism is what makes the second clause achievable. Rule set versions are
-- effective-dated and non-overlapping, conditions are pure, and the interpreter
-- has no access to the clock, the session or any table. So recording which
-- version answered, together with the inputs, is enough to reproduce any past
-- outcome exactly — which is what "traceable" has to mean for a posting made
-- three years ago.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Decision points (product content)
-- -----------------------------------------------------------------------------

create table erp_ref.decision_point (
  code            text primary key
                    check (code ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  module_code     text references erp_ref.module(code),
  name_key        text not null,
  description     text,
  -- The facts the product promises to supply when it asks.
  input_schema    jsonb not null default '{"type":"object"}'::jsonb,
  -- The shape of answer it will act on.
  outcome_schema  jsonb not null default '{"type":"object"}'::jsonb,
  -- Used when no rule matches. Neutral, from standards or common practice.
  default_outcome jsonb,
  -- Where no rule matching is a problem rather than a default, the product says
  -- so here and evaluation raises instead of returning nothing.
  requires_match  boolean not null default false
);

comment on table erp_ref.decision_point is
  'Product content. Every place the product will ask a configured question, '
  'with the schema of the facts it supplies and the answer it expects. This is '
  'the contract that lets a rule live outside the code.';

-- -----------------------------------------------------------------------------
-- Rule sets (tenant content), versioned and effective-dated
-- -----------------------------------------------------------------------------

create table erp.rule_set (
  id                   uuid not null default gen_random_uuid(),
  tenant_id            uuid not null references erp.tenant(id) on delete cascade,
  decision_point_code  text not null references erp_ref.decision_point(code),
  code                 text not null,
  name                 text,
  description          text,
  entity_id            uuid,
  site_id              uuid,
  status               erp.record_status not null default 'active',
  created_at           timestamptz not null default now(),
  created_by           uuid,
  updated_at           timestamptz not null default now(),
  updated_by           uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, decision_point_code, code),
  foreign key (tenant_id, entity_id)
    references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id)
    references erp.site (tenant_id, id) on delete cascade,
  constraint rule_set_site_needs_entity
    check (site_id is null or entity_id is not null)
);

create index on erp.rule_set (tenant_id, decision_point_code) where status = 'active';

create table erp.rule_set_version (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  rule_set_id    uuid not null,
  version        integer not null check (version >= 1),
  status         erp.config_version_status not null default 'draft',
  effective_from date not null default current_date,
  effective_to   date,
  note           text,
  change_set_id  uuid,
  approved_by    uuid,
  approved_at    timestamptz,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, rule_set_id, version),
  foreign key (tenant_id, rule_set_id)
    references erp.rule_set (tenant_id, id) on delete cascade,
  constraint rule_set_version_range
    check (effective_to is null or effective_to > effective_from),
  -- The same guarantee the configuration engine makes: exactly one answer to
  -- "which rules were in force on that date".
  constraint rule_set_version_no_overlap
    exclude using gist (
      tenant_id with =,
      rule_set_id with =,
      daterange(effective_from, effective_to, '[)') with &&
    ) where (status = 'active')
);

create index on erp.rule_set_version (tenant_id, rule_set_id, version desc);

create table erp.rule (
  id                   uuid not null default gen_random_uuid(),
  tenant_id            uuid not null references erp.tenant(id) on delete cascade,
  rule_set_version_id  uuid not null,
  -- Evaluation order. Explicit, because "first match wins" is meaningless
  -- without a defined first.
  seq                  integer not null,
  code                 text not null,
  name                 text,
  description          text,
  -- A declarative expression over the decision point's inputs.
  condition            jsonb not null default 'true'::jsonb,
  -- Literal data, handed back to the caller. Deliberately not evaluated: an
  -- outcome is an answer, not a further computation, and keeping it literal
  -- means a typo in an outcome cannot be mistaken for an operator.
  outcome              jsonb not null default '{}'::jsonb,
  -- Whether matching this rule ends evaluation. First-match-wins by default;
  -- set false to accumulate several outcomes.
  stop_on_match        boolean not null default true,
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  created_by           uuid,
  updated_at           timestamptz not null default now(),
  updated_by           uuid,
  primary key (id),
  unique (tenant_id, rule_set_version_id, seq),
  unique (tenant_id, rule_set_version_id, code),
  foreign key (tenant_id, rule_set_version_id)
    references erp.rule_set_version (tenant_id, id) on delete cascade
);

create index on erp.rule (tenant_id, rule_set_version_id, seq) where is_active;

-- A rule that belongs to a version already in force is history. Editing it
-- would silently change what the system did to past transactions.
create or replace function erp.protect_active_rule()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status erp.config_version_status;
begin
  select rsv.status into v_status
    from erp.rule_set_version rsv
   where rsv.id = coalesce(new.rule_set_version_id, old.rule_set_version_id);

  if v_status in ('active', 'superseded') then
    raise exception
      'ERPWARE_RULE_VERSION_IN_FORCE: this rule set version has been in force and cannot be changed; create a new version'
      using errcode = '42501';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger t_rule_protect
  before insert or update or delete on erp.rule
  for each row execute function erp.protect_active_rule();

-- =============================================================================
-- The interpreter
--
-- A small declarative expression language, in the shape of JsonLogic. It is
-- deliberately incapable: no loops, no table access, no clock, no session. A
-- condition is a pure function of the facts it is handed, which is what makes
-- a recorded (version, inputs) pair enough to reproduce an outcome for ever.
-- =============================================================================

-- Truthiness, defined once and explicitly, because the alternative is every
-- rule author guessing.
create or replace function erp.jsonlogic_truthy(p_value jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null then false
    when jsonb_typeof(p_value) = 'null' then false
    when jsonb_typeof(p_value) = 'boolean' then (p_value)::text::boolean
    when jsonb_typeof(p_value) = 'number' then (p_value #>> '{}')::numeric <> 0
    when jsonb_typeof(p_value) = 'string' then (p_value #>> '{}') <> ''
    when jsonb_typeof(p_value) = 'array' then jsonb_array_length(p_value) > 0
    else true
  end
$$;

-- Ordering. Numbers compare numerically; everything else compares as text.
-- Returns null when the two are not comparable, which makes >/< false rather
-- than throwing — a missing fact should not abort a posting run.
create or replace function erp.jsonlogic_compare(p_a jsonb, p_b jsonb)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case
    when p_a is null or p_b is null then null
    when jsonb_typeof(p_a) = 'null' or jsonb_typeof(p_b) = 'null' then null
    when jsonb_typeof(p_a) = 'number' and jsonb_typeof(p_b) = 'number' then
      sign((p_a #>> '{}')::numeric - (p_b #>> '{}')::numeric)::integer
    else
      case when (p_a #>> '{}') < (p_b #>> '{}') then -1
           when (p_a #>> '{}') > (p_b #>> '{}') then 1
           else 0 end
  end
$$;

create or replace function erp.jsonlogic(p_expr jsonb, p_data jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_op    text;
  v_raw   jsonb;
  v_args  jsonb := '[]'::jsonb;
  v_keys  integer;
  v_elem  jsonb;
  v_path  text;
  v_cmp   integer;
  v_acc   numeric;
  v_i     integer;
  v_found boolean;
begin
  if p_expr is null then
    return 'null'::jsonb;
  end if;

  -- An array is a list of expressions, each evaluated.
  if jsonb_typeof(p_expr) = 'array' then
    for v_elem in select e.value from jsonb_array_elements(p_expr) e loop
      v_args := v_args || jsonb_build_array(erp.jsonlogic(v_elem, p_data));
    end loop;
    return v_args;
  end if;

  -- Anything that is not a single-key object is a literal.
  if jsonb_typeof(p_expr) <> 'object' then
    return p_expr;
  end if;

  select count(*) into v_keys from jsonb_object_keys(p_expr);
  if v_keys <> 1 then
    return p_expr;
  end if;

  select k into v_op from jsonb_object_keys(p_expr) k limit 1;
  v_raw := p_expr -> v_op;

  -- `var` reads a dotted path out of the supplied facts. Evaluated before the
  -- argument list, because its argument is a path rather than an expression.
  if v_op = 'var' then
    if jsonb_typeof(v_raw) = 'string' then
      v_path := v_raw #>> '{}';
      return coalesce(p_data #> string_to_array(v_path, '.'), 'null'::jsonb);
    elsif jsonb_typeof(v_raw) = 'array' then
      v_path := (v_raw -> 0) #>> '{}';
      return coalesce(p_data #> string_to_array(v_path, '.'),
                      erp.jsonlogic(v_raw -> 1, p_data),
                      'null'::jsonb);
    else
      raise exception 'ERPWARE_RULE_BAD_VAR: var takes a path, got %', v_raw
        using errcode = '22023';
    end if;
  end if;

  -- Everything else takes a list of evaluated arguments.
  if jsonb_typeof(v_raw) = 'array' then
    for v_elem in select e.value from jsonb_array_elements(v_raw) e loop
      v_args := v_args || jsonb_build_array(erp.jsonlogic(v_elem, p_data));
    end loop;
  else
    v_args := jsonb_build_array(erp.jsonlogic(v_raw, p_data));
  end if;

  case v_op
    when '==' then
      return to_jsonb((v_args -> 0) = (v_args -> 1));
    when '!=' then
      return to_jsonb((v_args -> 0) <> (v_args -> 1));

    when '>' then
      v_cmp := erp.jsonlogic_compare(v_args -> 0, v_args -> 1);
      return to_jsonb(coalesce(v_cmp, -99) = 1);
    when '>=' then
      v_cmp := erp.jsonlogic_compare(v_args -> 0, v_args -> 1);
      return to_jsonb(coalesce(v_cmp, -99) >= 0);
    when '<' then
      v_cmp := erp.jsonlogic_compare(v_args -> 0, v_args -> 1);
      return to_jsonb(coalesce(v_cmp, 99) = -1);
    when '<=' then
      v_cmp := erp.jsonlogic_compare(v_args -> 0, v_args -> 1);
      return to_jsonb(coalesce(v_cmp, 99) <= 0);

    when 'between' then
      -- Inclusive lower, exclusive upper: the convention used everywhere else
      -- in the product for ranges and bands.
      return to_jsonb(
        coalesce(erp.jsonlogic_compare(v_args -> 0, v_args -> 1), -99) >= 0
        and coalesce(erp.jsonlogic_compare(v_args -> 0, v_args -> 2), 99) = -1);

    when 'and' then
      for v_elem in select e.value from jsonb_array_elements(v_args) e loop
        if not erp.jsonlogic_truthy(v_elem) then return to_jsonb(false); end if;
      end loop;
      return to_jsonb(true);

    when 'or' then
      for v_elem in select e.value from jsonb_array_elements(v_args) e loop
        if erp.jsonlogic_truthy(v_elem) then return to_jsonb(true); end if;
      end loop;
      return to_jsonb(false);

    when 'not' then
      return to_jsonb(not erp.jsonlogic_truthy(v_args -> 0));

    when 'in' then
      if jsonb_typeof(v_args -> 1) = 'array' then
        select bool_or(e.value = (v_args -> 0)) into v_found
          from jsonb_array_elements(v_args -> 1) e;
        return to_jsonb(coalesce(v_found, false));
      elsif jsonb_typeof(v_args -> 1) = 'string' then
        return to_jsonb(position((v_args -> 0) #>> '{}' in (v_args -> 1) #>> '{}') > 0);
      else
        return to_jsonb(false);
      end if;

    when 'matches' then
      if jsonb_typeof(v_args -> 0) <> 'string' then return to_jsonb(false); end if;
      return to_jsonb((v_args -> 0) #>> '{}' ~ (v_args -> 1) #>> '{}');

    when 'is_null' then
      return to_jsonb((v_args -> 0) is null or jsonb_typeof(v_args -> 0) = 'null');

    when 'coalesce' then
      for v_elem in select e.value from jsonb_array_elements(v_args) e loop
        if v_elem is not null and jsonb_typeof(v_elem) <> 'null' then
          return v_elem;
        end if;
      end loop;
      return 'null'::jsonb;

    when 'if' then
      -- if/elseif/else chains: [cond, then, cond, then, ..., else]
      v_i := 0;
      while v_i + 1 < jsonb_array_length(v_args) loop
        if erp.jsonlogic_truthy(v_args -> v_i) then
          return v_args -> (v_i + 1);
        end if;
        v_i := v_i + 2;
      end loop;
      if v_i < jsonb_array_length(v_args) then
        return v_args -> v_i;
      end if;
      return 'null'::jsonb;

    when '+' then
      select sum((e.value #>> '{}')::numeric) into v_acc
        from jsonb_array_elements(v_args) e
       where jsonb_typeof(e.value) = 'number';
      return to_jsonb(coalesce(v_acc, 0));

    when '-' then
      return to_jsonb(((v_args -> 0) #>> '{}')::numeric - ((v_args -> 1) #>> '{}')::numeric);

    when '*' then
      v_acc := 1;
      for v_elem in select e.value from jsonb_array_elements(v_args) e loop
        v_acc := v_acc * (v_elem #>> '{}')::numeric;
      end loop;
      return to_jsonb(v_acc);

    when '/' then
      -- Division by zero returns null rather than raising: a rule set should
      -- not be able to abort a posting run through a divisor that happened to
      -- be zero for one line.
      if ((v_args -> 1) #>> '{}')::numeric = 0 then return 'null'::jsonb; end if;
      return to_jsonb(((v_args -> 0) #>> '{}')::numeric / ((v_args -> 1) #>> '{}')::numeric);

    else
      -- An unrecognised operator is a typo, and a typo that evaluates to a
      -- literal would silently make a rule never match. Rules decide money and
      -- stock; they fail loudly instead.
      raise exception 'ERPWARE_RULE_UNKNOWN_OPERATOR: %', v_op
        using errcode = '22023',
              hint = 'Supported: var == != > >= < <= between and or not in matches is_null coalesce if + - * /';
  end case;
end;
$$;

comment on function erp.jsonlogic(jsonb, jsonb) is
  'The rule condition interpreter. Pure by construction — no clock, no session, '
  'no table access — so the same version and the same inputs always give the '
  'same answer, which is what makes a posting from three years ago explainable.';

create or replace function erp.jsonlogic_bool(p_expr jsonb, p_data jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select erp.jsonlogic_truthy(erp.jsonlogic(p_expr, p_data))
$$;

-- =============================================================================
-- Evaluation
-- =============================================================================

create or replace function erp.evaluate_rules(
  p_decision_point text,
  p_data           jsonb default '{}'::jsonb,
  p_on             date default null,
  p_entity_id      uuid default null,
  p_site_id        uuid default null
) returns table (
  matched             boolean,
  outcome             jsonb,
  rule_id             uuid,
  rule_code           text,
  rule_set_id         uuid,
  rule_set_version_id uuid,
  rule_set_version    integer,
  trace               jsonb
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_on      date := coalesce(p_on, current_date);
  v_dp      erp_ref.decision_point%rowtype;
  v_set     record;
  r         record;
  v_hit     boolean;
  v_trace   jsonb := '[]'::jsonb;
  v_outcome jsonb := null;
  v_stopped boolean := false;
begin
  select * into v_dp from erp_ref.decision_point where code = p_decision_point;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DECISION_POINT: %', p_decision_point
      using errcode = '23503';
  end if;

  if not extensions.jsonb_matches_schema(v_dp.input_schema::json, p_data) then
    raise exception 'ERPWARE_RULE_INPUT_INVALID: facts supplied to % do not match its input schema',
      p_decision_point using errcode = '23514', detail = p_data::text;
  end if;

  -- Most specific scope wins, exactly as configuration resolves.
  select rs.id, rsv.id as version_id, rsv.version
    into v_set
    from erp.rule_set rs
    join erp.rule_set_version rsv
      on rsv.tenant_id = rs.tenant_id
     and rsv.rule_set_id = rs.id
     and rsv.status = 'active'
     and daterange(rsv.effective_from, rsv.effective_to, '[)') @> v_on
   where rs.tenant_id = v_tenant
     and rs.decision_point_code = p_decision_point
     and rs.status = 'active'
     and (rs.site_id   is null or rs.site_id   = p_site_id)
     and (rs.entity_id is null or rs.entity_id = p_entity_id)
   order by (rs.site_id is not null) desc, (rs.entity_id is not null) desc
   limit 1;

  if found then
    for r in
      select ru.id, ru.seq, ru.code, ru.condition, ru.outcome, ru.stop_on_match
        from erp.rule ru
       where ru.tenant_id = v_tenant
         and ru.rule_set_version_id = v_set.version_id
         and ru.is_active
       order by ru.seq
    loop
      if v_stopped then
        -- Rules after the stop are recorded as not reached, so the trace shows
        -- what was skipped and why, rather than simply omitting them.
        v_trace := v_trace || jsonb_build_array(jsonb_build_object(
          'seq', r.seq, 'rule_code', r.code, 'result', 'not_reached'));
        continue;
      end if;

      v_hit := erp.jsonlogic_bool(r.condition, p_data);

      v_trace := v_trace || jsonb_build_array(jsonb_build_object(
        'seq', r.seq,
        'rule_code', r.code,
        'result', case when v_hit then 'matched' else 'no_match' end,
        'condition', r.condition));

      if v_hit then
        v_outcome := case
          when v_outcome is null then r.outcome
          else v_outcome || r.outcome
        end;
        rule_id   := r.id;
        rule_code := r.code;
        if r.stop_on_match then
          v_stopped := true;
        end if;
      end if;
    end loop;
  end if;

  if v_outcome is null then
    if v_dp.requires_match then
      raise exception 'ERPWARE_RULE_NO_MATCH: no rule matched at % and it requires one',
        p_decision_point
        using errcode = '23514', detail = p_data::text;
    end if;
    v_outcome := v_dp.default_outcome;
    rule_code := coalesce(rule_code, '(default)');
  end if;

  matched             := (rule_id is not null);
  outcome             := v_outcome;
  rule_set_id         := v_set.id;
  rule_set_version_id := v_set.version_id;
  rule_set_version    := v_set.version;
  trace               := v_trace;
  return next;
end;
$$;

comment on function erp.evaluate_rules is
  'Evaluates the rule set in force at a date for a decision point, in sequence, '
  'and returns the outcome together with a trace of every rule considered — '
  'including the ones after a stop, marked as not reached.';

-- -----------------------------------------------------------------------------
-- Recorded evaluations
--
-- Where the caller persists the outcome anyway (a posting line records its rule
-- and version; spec 4.7), that reference plus determinism is enough to explain
-- it later. This table is for decisions whose inputs are not otherwise kept.
-- -----------------------------------------------------------------------------

create table erp.rule_evaluation (
  id                  bigint generated always as identity primary key,
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  occurred_at         timestamptz not null default clock_timestamp(),
  decision_point_code text not null,
  entity_id           uuid,
  site_id             uuid,
  effective_date      date not null,
  rule_set_id         uuid,
  rule_set_version_id uuid,
  rule_set_version    integer,
  matched_rule_id     uuid,
  matched_rule_code   text,
  inputs              jsonb not null,
  outcome             jsonb,
  trace               jsonb not null default '[]'::jsonb,
  object_type         text,
  object_id           uuid,
  actor_id            uuid,
  correlation_id      uuid
);

create index on erp.rule_evaluation (tenant_id, decision_point_code, occurred_at desc);
create index on erp.rule_evaluation (tenant_id, object_type, object_id);
create index on erp.rule_evaluation (tenant_id, correlation_id) where correlation_id is not null;

create or replace function erp.evaluate_and_record(
  p_decision_point text,
  p_data           jsonb default '{}'::jsonb,
  p_on             date default null,
  p_entity_id      uuid default null,
  p_site_id        uuid default null,
  p_object_type    text default null,
  p_object_id      uuid default null
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v        record;
begin
  select * into v
    from erp.evaluate_rules(p_decision_point, p_data, p_on, p_entity_id, p_site_id);

  insert into erp.rule_evaluation (
    tenant_id, decision_point_code, entity_id, site_id, effective_date,
    rule_set_id, rule_set_version_id, rule_set_version,
    matched_rule_id, matched_rule_code, inputs, outcome, trace,
    object_type, object_id, actor_id, correlation_id)
  values (
    v_tenant, p_decision_point, p_entity_id, p_site_id, coalesce(p_on, current_date),
    v.rule_set_id, v.rule_set_version_id, v.rule_set_version,
    v.rule_id, v.rule_code, p_data, v.outcome, v.trace,
    p_object_type, p_object_id, erp.current_principal_id(),
    erp.current_correlation_id());

  return v.outcome;
end;
$$;

-- -----------------------------------------------------------------------------
-- Explanation
--
-- Spec 3.5: "given an outcome, the system can state which rule, which version,
-- which inputs". Re-running is safe because the interpreter is pure and the
-- version that was in force is still there.
-- -----------------------------------------------------------------------------

create or replace function erp.explain_rule_outcome(p_evaluation_id bigint)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'decision_point', re.decision_point_code,
    'evaluated_at', re.occurred_at,
    'effective_date', re.effective_date,
    'rule_set', rs.code,
    'rule_set_version', re.rule_set_version,
    'matched_rule', re.matched_rule_code,
    'inputs', re.inputs,
    'outcome', re.outcome,
    'trace', re.trace,
    'reproduced_now', (
      select r.outcome
        from erp.evaluate_rules(re.decision_point_code, re.inputs,
                                re.effective_date, re.entity_id, re.site_id) r),
    'actor', re.actor_id)
    from erp.rule_evaluation re
    left join erp.rule_set rs on rs.id = re.rule_set_id
   where re.tenant_id = erp.require_tenant_id()
     and re.id = p_evaluation_id
$$;

comment on function erp.explain_rule_outcome(bigint) is
  'Restates a recorded decision and re-derives it from the version that was in '
  'force. If reproduced_now differs from outcome, something that was supposed '
  'to be immutable was not.';

select erp_meta.register_table('erp', 'rule_evaluation', 'tenant_scoped_append_only',
  'A record of what the system decided and why. Evidence, not working state.');

insert into erp_meta.audit_exemption (schema_name, table_name, rationale) values
  ('erp', 'rule_evaluation',
   'Append-only evidence already carrying actor, inputs, outcome and trace.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
