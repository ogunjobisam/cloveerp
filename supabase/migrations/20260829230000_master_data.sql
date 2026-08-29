-- =============================================================================
-- ERPWare — Part 5.1: master data management
--
-- Spec 5.1 asks for seven things. B7 built the records themselves — item, party,
-- product structures, multilingual descriptions — and left every one of the
-- disciplines that keeps those records worth having:
--
--   completeness and validity scoring          nothing scores anything
--   duplicate detection and merge              erp.party.merged_into_id exists
--                                              and no code sets it
--   change-request workflow with field-level
--     approval rules                           nothing exists
--   controlled import with validation,
--     preview, staged load and rollback        nothing exists
--   rule-based mass maintenance with preview
--     and reversal                             nothing exists
--
-- The through-line is the same one this product keeps discovering: a record
-- store is not master data management. What makes master data *managed* is
-- that changing it is harder than changing anything else — reviewed, previewed,
-- scored and reversible — and none of that was here.
--
-- Two decisions worth stating up front.
--
-- **The rule language is the one that already exists.** Quality rules, mass-
-- change selectors and field-level approval conditions are all JsonLogic
-- evaluated by erp.jsonlogic_bool(), the same interpreter procurement's value
-- band and sales' credit check use. What they do NOT use is B3's decision-point
-- machinery, and that is deliberate rather than lazy: erp.evaluate_rules() is
-- built to pick one outcome and stop, while scoring a record means collecting
-- every finding. Reusing the language is the part that matters; reusing a
-- control flow built for a different question would have made both worse.
--
-- **Nothing writes a column this product has not agreed can be written that
-- way.** Mass maintenance and change requests both set fields by name, which is
-- dynamic SQL over user-supplied keys. Rather than escape carefully and hope,
-- erp_meta.maintainable_field enumerates exactly which columns of which tables
-- may be reached, with a rationale, in the same style as the two allow-lists
-- B1 and the public API already keep. A key not on that list is refused, so
-- tenant_id and id are not reachable by construction rather than by care.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Which fields may be maintained, and by what
-- -----------------------------------------------------------------------------

create table if not exists erp_meta.maintainable_field (
  object_type   text not null,
  table_name    text not null,
  column_name   text not null,
  data_kind     text not null
                  check (data_kind in ('text','integer','numeric','boolean','jsonb','uuid','enum')),
  rationale     text not null check (length(trim(rationale)) >= 20),
  primary key (object_type, column_name)
);

comment on table erp_meta.maintainable_field is
  'The complete list of columns that change requests and mass maintenance may '
  'write. Enumerated rather than escaped: a field not on this list cannot be '
  'reached by a caller-supplied key, so identity and tenancy columns are '
  'out of reach by construction.';

insert into erp_meta.maintainable_field
  (object_type, table_name, column_name, data_kind, rationale) values
  ('item', 'item', 'name',        'text',    'The description everyone reads. Routinely corrected in bulk after a catalogue import.'),
  ('item', 'item', 'item_class',  'text',    'Classification drives reporting and planning policy; reclassification is a normal mass change.'),
  ('item', 'item', 'item_group',  'text',    'Grouping for analysis. Changed together with class often enough to matter.'),
  ('item', 'item', 'lifecycle',   'enum',    'Draft to active to discontinued is the item''s own state, and is changed in bulk at range review.'),
  ('item', 'item', 'shelf_life_days', 'integer', 'A regulatory attribute that changes on supplier specification updates.'),
  ('item', 'item', 'min_remaining_shelf_life_days', 'integer', 'Customer acceptance rules change per contract and apply across a range.'),
  ('item', 'item', 'attributes',  'jsonb',   'Tenant-defined fields, which is precisely what level 2 of the extension ladder puts here.'),
  ('item', 'item', 'status',      'enum',    'Active to inactive is how a record is withdrawn without being deleted.'),
  ('party','party','name',        'text',    'The name shown on every document. Corrected after a merge or a rebrand.'),
  ('party','party','legal_name',  'text',    'The registered name, which differs from the trading name and changes on incorporation events.'),
  ('party','party','tax_identifier','text',  'Changes on registration, and a wrong one is a rejected statutory filing.'),
  ('party','party','registration_number','text','Company registration, updated when a counterparty restructures.'),
  ('party','party','country_code','text',    'Drives tax determination and legislation binding, so it is maintained rather than assumed.'),
  ('party','party','status',      'enum',    'Active to inactive is how a counterparty is withdrawn without being deleted.')
on conflict (object_type, column_name) do update
  set data_kind = excluded.data_kind, rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- Turning a record into facts
--
-- Every discipline below asks a question of a record: is it complete, does it
-- match this selector, has this field changed. All three want the record as
-- jsonb, so there is one function that produces it and nothing else reads the
-- tables directly.
-- -----------------------------------------------------------------------------

create or replace function erp.master_record(p_object_type text, p_object_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_row    jsonb;
  v_table  text;
begin
  select distinct m.table_name into v_table
    from erp_meta.maintainable_field m where m.object_type = p_object_type;

  if v_table is null then
    raise exception 'ERPWARE_UNKNOWN_OBJECT_TYPE: % is not maintainable', p_object_type
      using errcode = '23503',
      hint = 'erp_meta.maintainable_field is the list; adding a type means '
             'adding its fields with a rationale.';
  end if;

  -- The table name comes from the registry, never from the caller, so this
  -- format() cannot be steered by an argument.
  execute format('select to_jsonb(t) from erp.%I t where t.tenant_id = $1 and t.id = $2',
                 v_table)
    into v_row using v_tenant, p_object_id;

  return v_row;
end;
$$;

comment on function erp.master_record(text, uuid) is
  'A master record as facts, for the rule interpreter. The table is resolved '
  'through erp_meta.maintainable_field rather than from the argument, so the '
  'dynamic statement has no caller-supplied identifier in it.';

-- -----------------------------------------------------------------------------
-- Completeness and validity scoring
--
-- A rule states what a good record looks like, as a condition that is true when
-- the record satisfies it. Two kinds, because the specification names two and
-- they answer different questions: completeness is "is anything missing", and
-- validity is "is what is there believable".
-- -----------------------------------------------------------------------------

create table if not exists erp.data_quality_rule (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  object_type  text not null,
  code         text not null,
  name         text not null,
  kind         text not null check (kind in ('completeness', 'validity')),
  -- JsonLogic over erp.master_record(). True means the record is fine.
  condition    jsonb not null default 'true'::jsonb,
  -- Weight, so that a missing tax identifier can matter more than a missing
  -- item group without inventing a second severity scale.
  weight       integer not null default 1 check (weight > 0),
  severity     text not null default 'warning'
                 check (severity in ('info', 'warning', 'error')),
  message      text not null,
  entity_id    uuid,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, object_type, code),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade
);

comment on table erp.data_quality_rule is
  'Spec 5.1: completeness and validity scoring. What a good record looks like, '
  'as configuration — so two tenants can disagree about it without a branch.';

create index if not exists data_quality_rule_lookup
  on erp.data_quality_rule (tenant_id, object_type) where status = 'active';

create or replace function erp.score_master_record(
  p_object_type text,
  p_object_id   uuid
) returns table (
  code text, kind text, severity text, satisfied boolean,
  weight integer, message text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_facts  jsonb := erp.master_record(p_object_type, p_object_id);
  r        record;
begin
  if v_facts is null then
    raise exception 'ERPWARE_UNKNOWN_RECORD: no % with id %', p_object_type, p_object_id
      using errcode = '23503';
  end if;

  for r in
    select q.code, q.kind, q.severity, q.condition, q.weight, q.message
      from erp.data_quality_rule q
     where q.tenant_id = v_tenant
       and q.object_type = p_object_type
       and q.status = 'active'
     order by q.code
  loop
    code := r.code; kind := r.kind; severity := r.severity;
    weight := r.weight; message := r.message;
    -- A rule that cannot be evaluated is a failed rule, not a passed one. The
    -- opposite default would let a typo in a condition read as a clean record.
    begin
      satisfied := erp.jsonlogic_bool(r.condition, v_facts);
    exception when others then
      satisfied := false;
      message := format('%s (rule could not be evaluated: %s)', r.message, sqlerrm);
    end;
    return next;
  end loop;
end;
$$;

comment on function erp.score_master_record(text, uuid) is
  'Every quality finding for one record. A rule that cannot be evaluated counts '
  'as failed: the opposite default lets a typo in a condition read as a clean '
  'record, which is the worst answer available.';

create or replace function erp.data_quality_score(
  p_object_type text,
  p_object_id   uuid
) returns integer
language sql
stable
security invoker
set search_path = ''
as $$
  -- Weighted percentage, and 100 when no rule applies — a tenant that has
  -- configured no expectations has not thereby made its data bad.
  select case when coalesce(sum(s.weight), 0) = 0 then 100
              else round(100.0 * sum(s.weight) filter (where s.satisfied)
                               / sum(s.weight))::integer end
    from erp.score_master_record(p_object_type, p_object_id) s
$$;

create or replace function erp.data_quality_report(p_object_type text)
returns table (object_id uuid, code text, name text, score integer,
               errors integer, warnings integer)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_table  text;
begin
  select distinct m.table_name into v_table
    from erp_meta.maintainable_field m where m.object_type = p_object_type;

  if v_table is null then
    raise exception 'ERPWARE_UNKNOWN_OBJECT_TYPE: % is not maintainable', p_object_type
      using errcode = '23503';
  end if;

  return query execute format($q$
    select t.id, t.code, t.name,
           erp.data_quality_score(%L, t.id),
           (select count(*)::integer from erp.score_master_record(%L, t.id) s
             where not s.satisfied and s.severity = 'error'),
           (select count(*)::integer from erp.score_master_record(%L, t.id) s
             where not s.satisfied and s.severity = 'warning')
      from erp.%I t
     where t.tenant_id = $1 and t.status <> 'archived'
     order by 4, t.code
  $q$, p_object_type, p_object_type, p_object_type, v_table) using v_tenant;
end;
$$;

comment on function erp.data_quality_report(text) is
  'Spec 5.1: completeness and validity scoring, as a worklist — worst first, '
  'because a score nobody can act on is a number on a dashboard.';

-- -----------------------------------------------------------------------------
-- Duplicate detection and merge
--
-- erp.party has carried merged_into_id since B7, with a comment saying it is
-- there so old references still resolve, and no code has ever set it. The
-- column was right and the discipline was missing.
--
-- Merging does not delete and does not repoint. Every document that named the
-- duplicate still names it, and the duplicate now says who it became — which
-- is the only version of this that survives an audit, because rewriting a
-- despatch note from three years ago to name a different customer is falsifying
-- a record, whatever the reason.
-- -----------------------------------------------------------------------------

alter table erp.item
  add column if not exists merged_into_id uuid;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'item_merged_into_fk') then
    alter table erp.item
      add constraint item_merged_into_fk
      foreign key (tenant_id, merged_into_id)
        references erp.item (tenant_id, id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'item_not_merged_into_self') then
    alter table erp.item
      add constraint item_not_merged_into_self check (merged_into_id is distinct from id);
  end if;
end;
$$;

comment on column erp.item.merged_into_id is
  'Where this record was merged into another, the survivor. Old references are '
  'left pointing here and resolve through this column; repointing them would '
  'be rewriting history that somebody signed.';

-- The comparison key. Deliberately crude and deliberately documented: this
-- catches "Acme Ltd." against "ACME LTD", which is the overwhelming majority of
-- real duplicates, and does not pretend to catch "Acme" against "Acme Holdings".
-- A fuzzy matcher that is right eighty per cent of the time produces a review
-- queue nobody trusts, which is worse than a short list everybody does.
create or replace function erp.match_key(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(regexp_replace(lower(coalesce(p_value, '')), '[^a-z0-9]+', '', 'g'), '')
$$;

comment on function erp.match_key(text) is
  'Case, punctuation and spacing removed. Catches the duplicates that actually '
  'occur; makes no claim about the ones that need judgement.';

create or replace function erp.duplicate_candidates(p_object_type text)
returns table (left_id uuid, left_code text, right_id uuid, right_code text,
               matched_on text, value text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  if p_object_type = 'party' then
    return query
      -- Name, and the two identifiers that are supposed to be unique in the
      -- outside world. A shared tax identifier is not a candidate duplicate,
      -- it is a certain one.
      select a.id, a.code, b.id, b.code, m.field, m.val
        from erp.party a
        join lateral (values
              ('name', erp.match_key(a.name)),
              ('tax_identifier', erp.match_key(a.tax_identifier)),
              ('registration_number', erp.match_key(a.registration_number))
             ) as m(field, val) on m.val is not null
        join erp.party b
          on b.tenant_id = a.tenant_id and b.id > a.id
         and b.merged_into_id is null
         and erp.match_key(case m.field
                             when 'name' then b.name
                             when 'tax_identifier' then b.tax_identifier
                             else b.registration_number end) = m.val
       where a.tenant_id = v_tenant
         and a.merged_into_id is null;

  elsif p_object_type = 'item' then
    return query
      select a.id, a.code, b.id, b.code, 'name'::text, erp.match_key(a.name)
        from erp.item a
        join erp.item b
          on b.tenant_id = a.tenant_id and b.id > a.id
         and b.merged_into_id is null
         and erp.match_key(b.name) = erp.match_key(a.name)
       where a.tenant_id = v_tenant
         and a.merged_into_id is null
         and erp.match_key(a.name) is not null;

  else
    raise exception 'ERPWARE_NO_DUPLICATE_RULE: % has no comparison defined',
      p_object_type using errcode = '23503';
  end if;
end;
$$;

create or replace function erp.merge_master_record(
  p_object_type text,
  p_survivor_id uuid,
  p_duplicate_id uuid,
  p_reason      text
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_table  text;
  v_merged uuid;
begin
  select distinct m.table_name into v_table
    from erp_meta.maintainable_field m where m.object_type = p_object_type;

  if v_table is null then
    raise exception 'ERPWARE_UNKNOWN_OBJECT_TYPE: % is not maintainable', p_object_type
      using errcode = '23503';
  end if;

  if coalesce(p_reason, '') = '' then
    raise exception 'ERPWARE_MERGE_NEEDS_REASON: a merge is not undone, so it is not done silently'
      using errcode = '23514';
  end if;

  if p_survivor_id = p_duplicate_id then
    raise exception 'ERPWARE_MERGE_INTO_SELF: a record cannot be its own survivor'
      using errcode = '23514';
  end if;

  perform erp.authorise('master_data.approve', null, null, null,
                        p_object_type, p_duplicate_id);

  -- A survivor that has itself been merged would make the chain two hops long,
  -- and a chain nobody bounded eventually contains a cycle.
  execute format('select t.merged_into_id from erp.%I t
                   where t.tenant_id = $1 and t.id = $2', v_table)
    into v_merged using v_tenant, p_survivor_id;

  if v_merged is not null then
    raise exception
      'ERPWARE_MERGE_CHAIN: the survivor has itself been merged into %; merge '
      'into that record instead', v_merged
      using errcode = '23514';
  end if;

  execute format('update erp.%I t set merged_into_id = $2, status = ''inactive'',
                                      updated_at = now()
                   where t.tenant_id = $1 and t.id = $3
                     and t.merged_into_id is null', v_table)
    using v_tenant, p_survivor_id, p_duplicate_id;

  if not found then
    raise exception 'ERPWARE_ALREADY_MERGED_OR_MISSING: % % cannot be merged',
      p_object_type, p_duplicate_id using errcode = '23505';
  end if;

  -- Spec 4.10 and the audit stream: a merge is a fact about the record, and a
  -- fact belongs in the event store rather than in a status column alone.
  perform erp.append_event(
    -- The aggregate is 'master_record', not the object type: an event type is
    -- declared against one aggregate, and item and party merges are the same
    -- fact about the same kind of thing.
    'master_record.merged', 'master_record', p_duplicate_id,
    jsonb_build_object(
      'object_type', p_object_type,
      'survivor_id', p_survivor_id,
      'duplicate_id', p_duplicate_id,
      'reason', p_reason));
end;
$$;

comment on function erp.merge_master_record(text, uuid, uuid, text) is
  'Spec 5.1: duplicate detection and merge. The duplicate records who it '
  'became; no existing document is rewritten, because rewriting a signed record '
  'to name a different party is falsifying it whatever the reason.';

insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description, payload_schema)
values
  ('master_record.merged', 1, 'master_record', 'master_data', 'event.master_record.merged',
   'A master record was merged into another; old references resolve through it.',
   jsonb_build_object(
     'type','object',
     'required', jsonb_build_array('object_type','survivor_id','duplicate_id','reason'),
     'properties', jsonb_build_object(
       'object_type',  jsonb_build_object('type','string'),
       'survivor_id',  jsonb_build_object('type','string'),
       'duplicate_id', jsonb_build_object('type','string'),
       'reason',       jsonb_build_object('type','string'))))
on conflict (code, version) do update set payload_schema = excluded.payload_schema;

insert into erp_ref.resource (key, locale, value) values
  ('event.master_record.merged', 'en', 'Master record merged')
on conflict (key, locale) do nothing;

-- -----------------------------------------------------------------------------
-- Change requests, with field-level approval rules
--
-- Spec 5.1 asks for approval rules "at field level", which is the whole point:
-- correcting a spelling and changing a tax identifier are not the same event,
-- and a workflow that treats them alike gets switched off within a month.
--
-- So a rule names a field and a chain, and submitting a request routes it
-- through the chain of the most sensitive field it touches. A request for
-- fields that no rule covers needs no approval and says so, rather than
-- inventing an approver.
-- -----------------------------------------------------------------------------

create type erp.change_request_status as enum
  ('draft', 'pending', 'approved', 'rejected', 'applied', 'withdrawn');

create table if not exists erp.field_approval_rule (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  object_type  text not null,
  field_name   text not null,
  -- JsonLogic over {before, after, field}. A change of any size may need
  -- review; a change past a threshold may need a different one.
  condition    jsonb not null default 'true'::jsonb,
  approval_chain_code text,
  -- The higher number wins when a request touches several governed fields.
  sensitivity  integer not null default 100,
  reason_required boolean not null default false,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, object_type, field_name)
);

comment on table erp.field_approval_rule is
  'Spec 5.1: field-level approval rules. Correcting a spelling and changing a '
  'tax identifier are not the same event, and a workflow that treats them alike '
  'is switched off within a month.';

create table if not exists erp.change_request (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  object_type  text not null,
  object_id    uuid not null,
  -- The fields being changed, and the record as it stood when they were
  -- proposed. Keeping the before means the request can tell whether the world
  -- moved underneath it before it was approved.
  proposed     jsonb not null,
  before_snapshot jsonb not null,
  reason       text,
  status       erp.change_request_status not null default 'draft',
  approval_request_id uuid,
  applied_at   timestamptz,
  applied_by   uuid,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id)
);

create index if not exists change_request_open
  on erp.change_request (tenant_id, object_type, object_id)
  where status in ('draft', 'pending', 'approved');

-- Which rule governs this request: the most sensitive field it touches whose
-- condition holds. Returned rather than applied, so the caller and the screen
-- can both say why before anybody commits to it.
create or replace function erp.change_request_governance(p_request_id uuid)
returns table (field_name text, approval_chain_code text, sensitivity integer,
               reason_required boolean)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  cr       erp.change_request%rowtype;
  r        record;
  v_facts  jsonb;
begin
  select * into cr from erp.change_request
   where tenant_id = v_tenant and id = p_request_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_CHANGE_REQUEST: %', p_request_id using errcode = '23503';
  end if;

  for r in
    select f.field_name, f.approval_chain_code, f.condition,
           f.sensitivity, f.reason_required
      from erp.field_approval_rule f
     where f.tenant_id = v_tenant
       and f.object_type = cr.object_type
       and f.status = 'active'
       and cr.proposed ? f.field_name
     order by f.sensitivity desc, f.field_name
  loop
    v_facts := jsonb_build_object(
      'field',  r.field_name,
      'before', cr.before_snapshot -> r.field_name,
      'after',  cr.proposed -> r.field_name,
      'record', cr.before_snapshot);

    if erp.jsonlogic_bool(r.condition, v_facts) then
      field_name := r.field_name;
      approval_chain_code := r.approval_chain_code;
      sensitivity := r.sensitivity;
      reason_required := r.reason_required;
      return next;
    end if;
  end loop;
end;
$$;

create or replace function erp.open_change_request(
  p_object_type text,
  p_object_id   uuid,
  p_proposed    jsonb,
  p_reason      text default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_before jsonb;
  v_bad    text;
  v_id     uuid;
begin
  perform erp.authorise('master_data.write', null, null, null,
                        p_object_type, p_object_id);

  v_before := erp.master_record(p_object_type, p_object_id);
  if v_before is null then
    raise exception 'ERPWARE_UNKNOWN_RECORD: no % with id %', p_object_type, p_object_id
      using errcode = '23503';
  end if;

  if p_proposed is null or jsonb_typeof(p_proposed) <> 'object'
     or p_proposed = '{}'::jsonb then
    raise exception 'ERPWARE_EMPTY_CHANGE_REQUEST: a request that changes nothing'
      using errcode = '23514';
  end if;

  -- The allow-list, checked at the door. Everything downstream can then assume
  -- every key names a column this product agreed may be maintained.
  select string_agg(k, ', ') into v_bad
    from jsonb_object_keys(p_proposed) k
   where not exists (
     select 1 from erp_meta.maintainable_field m
      where m.object_type = p_object_type and m.column_name = k);

  if v_bad is not null then
    raise exception 'ERPWARE_FIELD_NOT_MAINTAINABLE: % on %', v_bad, p_object_type
      using errcode = '42501',
      hint = 'erp_meta.maintainable_field enumerates what may be changed this '
             'way, each with a rationale.';
  end if;

  insert into erp.change_request (
    tenant_id, object_type, object_id, proposed, before_snapshot, reason, status)
  values (v_tenant, p_object_type, p_object_id, p_proposed, v_before, p_reason, 'draft')
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function erp.submit_change_request(p_request_id uuid)
returns erp.change_request_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  cr       erp.change_request%rowtype;
  g        record;
  v_req    uuid;
  v_status erp.change_request_status;
begin
  select * into cr from erp.change_request
   where tenant_id = v_tenant and id = p_request_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_CHANGE_REQUEST: %', p_request_id using errcode = '23503';
  end if;

  if cr.status <> 'draft' then
    raise exception 'ERPWARE_CHANGE_REQUEST_NOT_DRAFT: % is %', p_request_id, cr.status
      using errcode = '23514';
  end if;

  select * into g from erp.change_request_governance(p_request_id) limit 1;

  if g.field_name is null then
    -- No rule covers any field in this request. Approved on submission, and
    -- recorded as such: "nobody had to approve this" is a different fact from
    -- "somebody approved this", and conflating them is how an audit finds a
    -- change with an approver who never saw it.
    v_status := 'approved';
  else
    if g.reason_required and coalesce(cr.reason, '') = '' then
      raise exception
        'ERPWARE_CHANGE_REQUEST_NEEDS_REASON: % requires one on this object',
        g.field_name using errcode = '23514';
    end if;

    if g.approval_chain_code is not null then
      v_req := erp.request_approval(
        'change_request', p_request_id,
        jsonb_build_object(
          'object_type', cr.object_type,
          'field', g.field_name,
          'sensitivity', g.sensitivity,
          'before', cr.before_snapshot -> g.field_name,
          'after', cr.proposed -> g.field_name),
        1, null, null);
    end if;
    v_status := 'pending';
  end if;

  update erp.change_request
     set status = v_status, approval_request_id = v_req, updated_at = now()
   where id = p_request_id;

  return v_status;
end;
$$;

-- Two sources of truth for "is this approved" is one too many. The request's
-- own status column caches the answer for listing screens; this derives it from
-- the approval engine, and everything that acts on the answer reads this.
create or replace function erp.change_request_effective_status(p_request_id uuid)
returns erp.change_request_status
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  cr       erp.change_request%rowtype;
  v_appr   erp.approval_status;
begin
  select * into cr from erp.change_request
   where tenant_id = v_tenant and id = p_request_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_CHANGE_REQUEST: %', p_request_id using errcode = '23503';
  end if;

  if cr.status <> 'pending' or cr.approval_request_id is null then
    return cr.status;
  end if;

  select ar.status into v_appr
    from erp.approval_request ar where ar.id = cr.approval_request_id;

  return case v_appr
           when 'approved' then 'approved'::erp.change_request_status
           when 'rejected' then 'rejected'::erp.change_request_status
           else 'pending'::erp.change_request_status
         end;
end;
$$;

create or replace function erp.apply_change_request(p_request_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  cr       erp.change_request%rowtype;
  v_now    jsonb;
  v_table  text;
  v_sets   text := '';
  v_key    text;
  v_kind   text;
  v_count  integer := 0;
  v_drift  text;
begin
  select * into cr from erp.change_request
   where tenant_id = v_tenant and id = p_request_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_CHANGE_REQUEST: %', p_request_id using errcode = '23503';
  end if;

  if erp.change_request_effective_status(p_request_id) <> 'approved' then
    raise exception
      'ERPWARE_CHANGE_REQUEST_NOT_APPROVED: % is %, and only an approved '
      'request may be applied',
      p_request_id, erp.change_request_effective_status(p_request_id)
      using errcode = '42501';
  end if;

  v_now := erp.master_record(cr.object_type, cr.object_id);

  -- The world may have moved while this waited. Applying anyway would silently
  -- undo whoever changed it in the meantime, which is the failure mode that
  -- makes people stop trusting a review queue.
  select string_agg(k, ', ') into v_drift
    from jsonb_object_keys(cr.proposed) k
   where (v_now -> k) is distinct from (cr.before_snapshot -> k);

  if v_drift is not null then
    raise exception
      'ERPWARE_CHANGE_REQUEST_STALE: % changed since this was proposed', v_drift
      using errcode = '40001',
      hint = 'Open a new request against the record as it now stands.';
  end if;

  select distinct m.table_name into v_table
    from erp_meta.maintainable_field m where m.object_type = cr.object_type;

  for v_key in select k from jsonb_object_keys(cr.proposed) k order by k
  loop
    select m.data_kind into v_kind
      from erp_meta.maintainable_field m
     where m.object_type = cr.object_type and m.column_name = v_key;

    if v_kind is null then
      raise exception 'ERPWARE_FIELD_NOT_MAINTAINABLE: %', v_key using errcode = '42501';
    end if;

    -- The identifier comes from the registry row, not from the key, and the
    -- value goes in as a parameterised jsonb extraction rather than as text
    -- spliced into the statement.
    v_sets := v_sets || case when v_sets = '' then '' else ', ' end
              || format('%I = ($2 ->> %L)%s', v_key, v_key,
                        case v_kind
                          when 'jsonb'   then '::jsonb'
                          when 'integer' then '::integer'
                          when 'numeric' then '::numeric'
                          when 'boolean' then '::boolean'
                          when 'uuid'    then '::uuid'
                          else '' end);
    v_count := v_count + 1;
  end loop;

  -- An enum column takes the text form, which Postgres coerces on assignment;
  -- an invalid label raises rather than being stored, which is the behaviour
  -- wanted here.
  execute format('update erp.%I set %s, updated_at = now(), updated_by = $3
                   where tenant_id = $1 and id = $4', v_table, v_sets)
    using v_tenant, cr.proposed, erp.current_principal_id(), cr.object_id;

  update erp.change_request
     set status = 'applied', applied_at = now(),
         applied_by = erp.current_principal_id(), updated_at = now()
   where id = p_request_id;

  return v_count;
end;
$$;

comment on function erp.apply_change_request(uuid) is
  'Applies an approved request, refusing if the record moved underneath it. '
  'Column names come from erp_meta.maintainable_field and values are '
  'parameterised, so no part of the statement is caller-supplied text.';

-- -----------------------------------------------------------------------------
-- Controlled import: validate, preview, staged load, rollback
--
-- Spec 5.1 names four stages and they are four stages for a reason. An import
-- that validates and loads in one step gives whoever ran it no moment at which
-- to look at what is about to happen — and an import with no rollback makes the
-- first bad file somebody else's afternoon.
--
-- Rollback is real here rather than nominal: every loaded row records what the
-- record looked like beforehand, so reversing an update restores it and
-- reversing an insert removes it. A row that has been referenced since cannot
-- be removed, and the rollback says so rather than cascading.
-- -----------------------------------------------------------------------------

create type erp.import_status as enum
  ('received', 'validated', 'previewed', 'loaded', 'rolled_back', 'rejected');

create table if not exists erp.import_batch (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  object_type  text not null,
  source       text not null default 'manual',
  status       erp.import_status not null default 'received',
  row_count    integer not null default 0,
  error_count  integer not null default 0,
  loaded_at    timestamptz,
  rolled_back_at timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code)
);

create table if not exists erp.import_row (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  import_batch_id uuid not null,
  row_no       integer not null,
  raw          jsonb not null,
  -- What validation decided should happen to this row.
  action       text check (action in ('insert', 'update', 'skip', 'reject')),
  findings     jsonb not null default '[]'::jsonb,
  target_id    uuid,
  -- The record as it stood before this row touched it. Null for an insert,
  -- which is how rollback tells the two apart.
  before_snapshot jsonb,
  loaded       boolean not null default false,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, import_batch_id, row_no),
  foreign key (tenant_id, import_batch_id)
    references erp.import_batch (tenant_id, id) on delete cascade
);

create index if not exists import_row_batch on erp.import_row (tenant_id, import_batch_id, row_no);

create or replace function erp.stage_import(
  p_object_type text,
  p_rows        jsonb,
  p_code        text default null,
  p_source      text default 'manual'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_code   text := coalesce(p_code, 'IMP-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'));
begin
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', null);

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'ERPWARE_EMPTY_IMPORT: an import of no rows' using errcode = '23514';
  end if;

  if not exists (select 1 from erp_meta.maintainable_field m
                  where m.object_type = p_object_type) then
    raise exception 'ERPWARE_UNKNOWN_OBJECT_TYPE: % is not maintainable', p_object_type
      using errcode = '23503';
  end if;

  insert into erp.import_batch (tenant_id, code, object_type, source, row_count)
  values (v_tenant, v_code, p_object_type, p_source, jsonb_array_length(p_rows))
  returning id into v_id;

  insert into erp.import_row (tenant_id, import_batch_id, row_no, raw)
  select v_tenant, v_id, (e.ordinality)::integer, e.value
    from jsonb_array_elements(p_rows) with ordinality e(value, ordinality);

  return v_id;
end;
$$;

create or replace function erp.validate_import(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  v_table  text;
  r        record;
  v_find   jsonb;
  v_target uuid;
  v_bad    text;
  v_errors integer := 0;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  if b.status not in ('received', 'validated', 'previewed') then
    raise exception 'ERPWARE_IMPORT_NOT_VALIDATABLE: % is %', b.code, b.status
      using errcode = '23514';
  end if;

  select distinct m.table_name into v_table
    from erp_meta.maintainable_field m where m.object_type = b.object_type;

  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id
            order by row_no
  loop
    v_find := '[]'::jsonb;
    v_target := null;

    -- Every row must name the record it is about.
    if coalesce(r.raw ->> 'code', '') = '' then
      v_find := v_find || jsonb_build_object(
        'severity','error','message','no code, so this row names no record');
    else
      execute format('select t.id from erp.%I t where t.tenant_id = $1 and t.code = $2',
                     v_table)
        into v_target using v_tenant, r.raw ->> 'code';
    end if;

    -- Every other key must be a field this product agreed may be written.
    select string_agg(k, ', ') into v_bad
      from jsonb_object_keys(r.raw) k
     where k <> 'code'
       and not exists (select 1 from erp_meta.maintainable_field m
                        where m.object_type = b.object_type and m.column_name = k);

    if v_bad is not null then
      v_find := v_find || jsonb_build_object(
        'severity','error','message', format('unknown or protected field(s): %s', v_bad));
    end if;

    update erp.import_row
       set findings = v_find,
           target_id = v_target,
           action = case
                      when jsonb_array_length(v_find) > 0 then 'reject'
                      when v_target is not null then 'update'
                      else 'insert' end,
           updated_at = now()
     where id = r.id;

    if jsonb_array_length(v_find) > 0 then v_errors := v_errors + 1; end if;
  end loop;

  update erp.import_batch
     set status = 'validated', error_count = v_errors, updated_at = now()
   where id = p_batch_id;

  return v_errors;
end;
$$;

-- The moment somebody gets to look. Deliberately a separate call that changes
-- nothing but the status: "I previewed this" is a fact worth recording, and an
-- import that reaches load without it should be visibly different.
create or replace function erp.preview_import(p_batch_id uuid)
returns table (row_no integer, action text, code text, target_id uuid,
               changes jsonb, findings jsonb)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  if b.status = 'received' then
    raise exception 'ERPWARE_IMPORT_NOT_VALIDATED: validate % before previewing it', b.code
      using errcode = '23514';
  end if;

  update erp.import_batch set status = 'previewed', updated_at = now()
   where id = p_batch_id and status = 'validated';

  return query
    select r.row_no, r.action, r.raw ->> 'code', r.target_id,
           case when r.target_id is null then r.raw
                else (select jsonb_object_agg(k.key, jsonb_build_object(
                               'from', erp.master_record(b.object_type, r.target_id) -> k.key,
                               'to',   k.value))
                        from jsonb_each(r.raw - 'code') k
                       where erp.master_record(b.object_type, r.target_id) -> k.key
                             is distinct from k.value)
           end,
           r.findings
      from erp.import_row r
     where r.tenant_id = v_tenant and r.import_batch_id = p_batch_id
     order by r.row_no;
end;
$$;

comment on function erp.preview_import(uuid) is
  'Spec 5.1: preview before staged load. Shows each row as before-and-after '
  'rather than as input, because a list of what was in the file is not a '
  'preview of what it will do.';

-- The one function that writes a maintainable record from jsonb, used by the
-- import loader and by mass maintenance. Extracted rather than written twice,
-- because two implementations of "which columns may be written" is one more
-- than the number that can be kept correct.
create or replace function erp.write_master_fields(
  p_object_type text,
  p_object_id   uuid,
  p_values      jsonb
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_table  text;
  v_sets   text := '';
  v_key    text;
  v_kind   text;
begin
  select distinct m.table_name into v_table
    from erp_meta.maintainable_field m where m.object_type = p_object_type;

  for v_key in select k from jsonb_object_keys(p_values) k order by k
  loop
    select m.data_kind into v_kind
      from erp_meta.maintainable_field m
     where m.object_type = p_object_type and m.column_name = v_key;

    if v_kind is null then
      raise exception 'ERPWARE_FIELD_NOT_MAINTAINABLE: % on %', v_key, p_object_type
        using errcode = '42501';
    end if;

    v_sets := v_sets || case when v_sets = '' then '' else ', ' end
              || format('%I = ($2 ->> %L)%s', v_key, v_key,
                        case v_kind
                          when 'jsonb'   then '::jsonb'
                          when 'integer' then '::integer'
                          when 'numeric' then '::numeric'
                          when 'boolean' then '::boolean'
                          when 'uuid'    then '::uuid'
                          else '' end);
  end loop;

  if v_sets = '' then return; end if;

  execute format('update erp.%I set %s, updated_at = now(), updated_by = $3
                   where tenant_id = $1 and id = $4', v_table, v_sets)
    using v_tenant, p_values, erp.current_principal_id(), p_object_id;
end;
$$;

create or replace function erp.load_import(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_new    uuid;
  v_loaded integer := 0;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'previewed' then
    raise exception
      'ERPWARE_IMPORT_NOT_PREVIEWED: % is %, and a staged load happens after '
      'somebody has looked at it', b.code, b.status
      using errcode = '23514',
      hint = 'Spec 5.1 asks for validation, preview, staged load and rollback '
             'in that order; the preview is the point at which a person is '
             'given a chance to stop.';
  end if;

  if b.error_count > 0 then
    raise exception
      'ERPWARE_IMPORT_HAS_ERRORS: % rows in % are rejected; fix the file rather '
      'than loading the good half', b.error_count, b.code
      using errcode = '23514';
  end if;

  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id
              and action in ('insert', 'update')
            order by row_no
  loop
    if r.action = 'update' then
      update erp.import_row
         set before_snapshot = erp.master_record(b.object_type, r.target_id)
       where id = r.id;
      perform erp.write_master_fields(b.object_type, r.target_id, r.raw - 'code');
      update erp.import_row set loaded = true, updated_at = now() where id = r.id;
    else
      -- Inserting needs the columns an object cannot exist without, which are
      -- object-specific and therefore named here rather than derived.
      if b.object_type = 'party' then
        insert into erp.party (tenant_id, code, name, status)
        values (v_tenant, r.raw ->> 'code',
                coalesce(r.raw ->> 'name', r.raw ->> 'code'), 'draft')
        returning id into v_new;
      elsif b.object_type = 'item' then
        insert into erp.item (tenant_id, code, name, stock_uom_id, lifecycle, status)
        values (v_tenant, r.raw ->> 'code',
                coalesce(r.raw ->> 'name', r.raw ->> 'code'),
                (select u.id from erp.uom u
                  where u.tenant_id = v_tenant and u.is_base
                  order by u.code limit 1),
                'draft', 'draft')
        returning id into v_new;
      else
        raise exception 'ERPWARE_NO_IMPORT_INSERT: % rows can be updated but not created',
          b.object_type using errcode = '23503';
      end if;

      perform erp.write_master_fields(b.object_type, v_new, r.raw - 'code' - 'name');
      update erp.import_row
         set target_id = v_new, loaded = true, before_snapshot = null, updated_at = now()
       where id = r.id;
    end if;

    v_loaded := v_loaded + 1;
  end loop;

  update erp.import_batch
     set status = 'loaded', loaded_at = now(), updated_at = now()
   where id = p_batch_id;

  return v_loaded;
end;
$$;

create or replace function erp.rollback_import(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  v_table  text;
  r        record;
  v_n      integer := 0;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'loaded' then
    raise exception 'ERPWARE_IMPORT_NOT_LOADED: % is %', b.code, b.status
      using errcode = '23514';
  end if;

  select distinct m.table_name into v_table
    from erp_meta.maintainable_field m where m.object_type = b.object_type;

  -- Reverse order, so that anything an earlier row depended on is still there
  -- while a later row is undone.
  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id and loaded
            order by row_no desc
  loop
    if r.before_snapshot is null then
      -- This row created the record, so undoing it removes the record. If
      -- something has referenced it since, the delete is refused and the
      -- rollback stops — cascading here would take real work with it.
      begin
        execute format('delete from erp.%I t where t.tenant_id = $1 and t.id = $2', v_table)
          using v_tenant, r.target_id;
      exception when foreign_key_violation then
        raise exception
          'ERPWARE_IMPORT_ROLLBACK_BLOCKED: % has been referenced since it was '
          'imported and cannot be removed', r.raw ->> 'code'
          using errcode = '23503',
          hint = 'Withdraw the record instead; deleting it would take whatever '
                 'now depends on it.';
      end;
    else
      perform erp.write_master_fields(
        b.object_type, r.target_id,
        (select jsonb_object_agg(k, r.before_snapshot -> k)
           from jsonb_object_keys(r.raw - 'code') k));
    end if;
    v_n := v_n + 1;
  end loop;

  update erp.import_batch
     set status = 'rolled_back', rolled_back_at = now(), updated_at = now()
   where id = p_batch_id;

  return v_n;
end;
$$;

comment on function erp.rollback_import(uuid) is
  'Spec 5.1: rollback. Real rather than nominal — every loaded row kept what '
  'the record looked like beforehand, so an update is restored and an insert is '
  'removed. A record referenced since is refused rather than cascaded.';

-- -----------------------------------------------------------------------------
-- Rule-based mass maintenance, with preview and reversal
--
-- The same discipline as import, applied to records that already exist: a
-- selector says which records, a change says what to do to them, and neither
-- happens until somebody has seen the list.
--
-- The selector is JsonLogic over the record — the same language as everything
-- else in this product. That matters more than it sounds: a second selector
-- language would mean a rule that is expressible in an approval chain and not
-- in a mass change, which is exactly the sort of seam that turns configuration
-- back into engineering.
-- -----------------------------------------------------------------------------

create type erp.mass_change_status as enum
  ('draft', 'previewed', 'applied', 'reversed');

create table if not exists erp.mass_change (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  object_type  text not null,
  selector     jsonb not null default 'true'::jsonb,
  changes      jsonb not null,
  reason       text,
  status       erp.mass_change_status not null default 'draft',
  affected     integer,
  applied_at   timestamptz,
  reversed_at  timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code)
);

create table if not exists erp.mass_change_row (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  mass_change_id uuid not null,
  object_id    uuid not null,
  before_snapshot jsonb not null,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, mass_change_id, object_id),
  foreign key (tenant_id, mass_change_id)
    references erp.mass_change (tenant_id, id) on delete cascade
);

create or replace function erp.open_mass_change(
  p_object_type text,
  p_selector    jsonb,
  p_changes     jsonb,
  p_reason      text default null,
  p_code        text default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_bad    text;
  v_id     uuid;
begin
  perform erp.authorise('master_data.write', null, null, null, 'mass_change', null);

  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    raise exception 'ERPWARE_EMPTY_MASS_CHANGE: a mass change that changes nothing'
      using errcode = '23514';
  end if;

  select string_agg(k, ', ') into v_bad
    from jsonb_object_keys(p_changes) k
   where not exists (select 1 from erp_meta.maintainable_field m
                      where m.object_type = p_object_type and m.column_name = k);

  if v_bad is not null then
    raise exception 'ERPWARE_FIELD_NOT_MAINTAINABLE: % on %', v_bad, p_object_type
      using errcode = '42501';
  end if;

  -- A selector of `true` would match every record of the type. That is a
  -- legitimate thing to want and a terrible thing to do by accident, so it has
  -- to be said in words.
  if p_selector = 'true'::jsonb and coalesce(p_reason, '') = '' then
    raise exception
      'ERPWARE_UNSELECTIVE_MASS_CHANGE: a change with no selector touches every '
      '% and needs a reason', p_object_type
      using errcode = '23514';
  end if;

  insert into erp.mass_change (tenant_id, code, object_type, selector, changes, reason)
  values (v_tenant,
          coalesce(p_code, 'MC-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS')),
          p_object_type, coalesce(p_selector, 'true'::jsonb), p_changes, p_reason)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function erp.preview_mass_change(p_mass_change_id uuid)
returns table (object_id uuid, code text, before_value jsonb, after_value jsonb)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  mc       erp.mass_change%rowtype;
  v_table  text;
  r        record;
  v_n      integer := 0;
begin
  select * into mc from erp.mass_change
   where tenant_id = v_tenant and id = p_mass_change_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_MASS_CHANGE: %', p_mass_change_id using errcode = '23503';
  end if;

  select distinct m.table_name into v_table
    from erp_meta.maintainable_field m where m.object_type = mc.object_type;

  for r in execute format(
    'select t.id, t.code, to_jsonb(t) as rec from erp.%I t
      where t.tenant_id = $1 and t.status <> ''archived'' order by t.code', v_table)
    using v_tenant
  loop
    if erp.jsonlogic_bool(mc.selector, r.rec) then
      object_id := r.id;
      code := r.code;
      before_value := (select jsonb_object_agg(k, r.rec -> k)
                         from jsonb_object_keys(mc.changes) k);
      after_value := mc.changes;
      v_n := v_n + 1;
      return next;
    end if;
  end loop;

  update erp.mass_change
     set status = case when status = 'draft' then 'previewed' else status end,
         affected = v_n, updated_at = now()
   where id = p_mass_change_id;
end;
$$;

create or replace function erp.apply_mass_change(p_mass_change_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  mc       erp.mass_change%rowtype;
  r        record;
  v_n      integer := 0;
begin
  select * into mc from erp.mass_change
   where tenant_id = v_tenant and id = p_mass_change_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_MASS_CHANGE: %', p_mass_change_id using errcode = '23503';
  end if;

  perform erp.authorise('master_data.write', null, null, null,
                        'mass_change', p_mass_change_id);

  if mc.status <> 'previewed' then
    raise exception
      'ERPWARE_MASS_CHANGE_NOT_PREVIEWED: % is %, and a mass change is applied '
      'after somebody has seen the list', mc.code, mc.status
      using errcode = '23514';
  end if;

  -- The preview is recomputed rather than trusted: between previewing and
  -- applying, a record may have started or stopped matching, and applying a
  -- stale list is how a mass change touches something nobody reviewed.
  for r in select * from erp.preview_mass_change(p_mass_change_id)
  loop
    insert into erp.mass_change_row (
      tenant_id, mass_change_id, object_id, before_snapshot)
    values (v_tenant, p_mass_change_id, r.object_id, r.before_value)
    on conflict (tenant_id, mass_change_id, object_id) do nothing;

    perform erp.write_master_fields(mc.object_type, r.object_id, mc.changes);
    v_n := v_n + 1;
  end loop;

  update erp.mass_change
     set status = 'applied', affected = v_n, applied_at = now(), updated_at = now()
   where id = p_mass_change_id;

  return v_n;
end;
$$;

create or replace function erp.reverse_mass_change(p_mass_change_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  mc       erp.mass_change%rowtype;
  r        record;
  v_n      integer := 0;
begin
  select * into mc from erp.mass_change
   where tenant_id = v_tenant and id = p_mass_change_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_MASS_CHANGE: %', p_mass_change_id using errcode = '23503';
  end if;

  perform erp.authorise('master_data.write', null, null, null,
                        'mass_change', p_mass_change_id);

  if mc.status <> 'applied' then
    raise exception 'ERPWARE_MASS_CHANGE_NOT_APPLIED: % is %', mc.code, mc.status
      using errcode = '23514';
  end if;

  for r in select * from erp.mass_change_row
            where tenant_id = v_tenant and mass_change_id = p_mass_change_id
  loop
    perform erp.write_master_fields(mc.object_type, r.object_id, r.before_snapshot);
    v_n := v_n + 1;
  end loop;

  update erp.mass_change
     set status = 'reversed', reversed_at = now(), updated_at = now()
   where id = p_mass_change_id;

  return v_n;
end;
$$;

comment on function erp.reverse_mass_change(uuid) is
  'Spec 5.1: reversal. Every touched record kept its prior values, so this puts '
  'them back — which is what makes the preview worth having rather than the '
  'only line of defence.';

-- -----------------------------------------------------------------------------
-- Master data, installed
--
-- Quality rules and field approval rules are policy, so they go through B6 like
-- everything else. B6 gains two more kinds; both are versionless replacements
-- rather than versioned supersessions, because unlike a posting rule nothing
-- records "the quality rule version that scored this record".
-- -----------------------------------------------------------------------------

create or replace function erp.configure_master_data(
  p_approver_role text default 'administrator'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  v_cs := erp.install_module_config(
    'master-data-governance', 'Master data governance',
    'What a good record looks like, and which fields cannot be changed without '
    'somebody agreeing.',
    jsonb_build_array(
      -- The chain a governed field routes through.
      jsonb_build_object('kind','approval_chain','key','master_data_change','payload',
        jsonb_build_object(
          'code','master_data_change','name','Master data change',
          'object_type','change_request',
          'applies_when', 'true'::jsonb,
          'priority', 100,
          'material_fields', jsonb_build_array('field','after'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','steward','name','Data steward',
              'approver_kind','role','role',p_approver_role,'min_approvals',1)))),

      -- Quality rules. Written as "true when the record is fine", so the
      -- condition reads as the standard rather than as the complaint.
      jsonb_build_object('kind','data_quality_rule','key','item.has_name','payload',
        jsonb_build_object(
          'object_type','item','code','has_name','name','Item has a description',
          'kind','completeness','weight',3,'severity','error',
          'message','An item with no description cannot be ordered by anyone who did not create it.',
          'condition', jsonb_build_object('!=', jsonb_build_array(
            jsonb_build_object('var','name'), null)))),

      jsonb_build_object('kind','data_quality_rule','key','item.classified','payload',
        jsonb_build_object(
          'object_type','item','code','classified','name','Item is classified',
          'kind','completeness','weight',2,'severity','warning',
          'message','Without a class this item is invisible to planning policy and to reporting.',
          'condition', jsonb_build_object('!=', jsonb_build_array(
            jsonb_build_object('var','item_class'), null)))),

      -- Validity rather than completeness: the field is there, and what it says
      -- is not believable.
      jsonb_build_object('kind','data_quality_rule','key','item.shelf_life_consistent','payload',
        jsonb_build_object(
          'object_type','item','code','shelf_life_consistent',
          'name','Shelf life allows the acceptance window',
          'kind','validity','weight',3,'severity','error',
          'message','Minimum remaining shelf life is not less than total shelf life, so every batch fails acceptance on the day it is made.',
          'condition', jsonb_build_object('or', jsonb_build_array(
            jsonb_build_object('==', jsonb_build_array(
              jsonb_build_object('var','shelf_life_days'), null)),
            jsonb_build_object('==', jsonb_build_array(
              jsonb_build_object('var','min_remaining_shelf_life_days'), null)),
            jsonb_build_object('<', jsonb_build_array(
              jsonb_build_object('var','min_remaining_shelf_life_days'),
              jsonb_build_object('var','shelf_life_days'))))))),

      jsonb_build_object('kind','data_quality_rule','key','party.has_country','payload',
        jsonb_build_object(
          'object_type','party','code','has_country','name','Party has a country',
          'kind','completeness','weight',3,'severity','error',
          'message','Country drives tax determination and legislation binding; without it neither can be answered.',
          'condition', jsonb_build_object('!=', jsonb_build_array(
            jsonb_build_object('var','country_code'), null)))),

      jsonb_build_object('kind','data_quality_rule','key','party.has_tax_id','payload',
        jsonb_build_object(
          'object_type','party','code','has_tax_id','name','Party has a tax identifier',
          'kind','completeness','weight',2,'severity','warning',
          'message','A missing tax identifier is a rejected statutory filing later.',
          'condition', jsonb_build_object('!=', jsonb_build_array(
            jsonb_build_object('var','tax_identifier'), null)))),

      -- Field-level approval. A tax identifier is reviewed; a description is
      -- not. That difference is the whole of spec 5.1's "field-level".
      jsonb_build_object('kind','field_approval_rule','key','party.tax_identifier','payload',
        jsonb_build_object(
          'object_type','party','field_name','tax_identifier',
          'approval_chain','master_data_change','sensitivity',900,
          'reason_required', true)),

      jsonb_build_object('kind','field_approval_rule','key','party.country_code','payload',
        jsonb_build_object(
          'object_type','party','field_name','country_code',
          'approval_chain','master_data_change','sensitivity',800,
          'reason_required', true)),

      -- Governed, but only past a threshold: reclassifying a draft item is
      -- housekeeping, reclassifying a live one moves numbers in a report.
      jsonb_build_object('kind','field_approval_rule','key','item.item_class','payload',
        jsonb_build_object(
          'object_type','item','field_name','item_class',
          'approval_chain','master_data_change','sensitivity',500,
          'condition', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','record.lifecycle'), 'active'))))));

  return v_cs;
end;
$$;

comment on function erp.configure_master_data(text) is
  'Spec 5.1 as configuration: what a good record looks like, and which fields '
  'need somebody to agree before they change.';

-- -----------------------------------------------------------------------------
-- B6 learns two more kinds
--
-- Regenerated from the live definition again, for the same reason as last time.
-- -----------------------------------------------------------------------------

create or replace function erp.apply_change_set_item(p_item_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant  uuid := erp.require_tenant_id();
  i         erp.change_set_item%rowtype;
  p         jsonb;
  v_entity  uuid;
  v_site    uuid;
  v_from    date;
  v_obj     uuid;
  v_ver     uuid;
  v_vnum    integer;
  r         record;
  v_state   uuid;
begin
  select * into i from erp.change_set_item where tenant_id = v_tenant and id = p_item_id;
  p := i.payload;

  -- Codes to local ids. A change set built elsewhere knows nothing of our keys.
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.code = (p ->> 'entity');
  select s.id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.code = (p ->> 'site');
  v_from := coalesce(i.effective_from, (p ->> 'effective_from')::date, current_date);

  if (p ? 'entity') and (p ->> 'entity') is not null and v_entity is null then
    raise exception 'ERPWARE_PROMOTION_UNKNOWN_ENTITY: this environment has no entity %',
      p ->> 'entity' using errcode = '23503';
  end if;

  case i.object_kind

    when 'config' then
      if i.operation = 'remove' then
        update erp.config_object co set status = 'inactive', updated_at = now()
         where co.tenant_id = v_tenant
           and co.config_type_code = (p ->> 'config_type')
           and co.code is not distinct from (p ->> 'code')
           and co.entity_id is not distinct from v_entity
           and co.site_id is not distinct from v_site;
      else
        perform erp.set_config_value(
          p ->> 'config_type', p -> 'value', p ->> 'code', v_from,
          v_entity, v_site, 'promoted');
      end if;

    when 'terminology' then
      if i.operation = 'remove' then
        update erp.resource_override ro set status = 'inactive', updated_at = now()
         where ro.tenant_id = v_tenant and ro.key = (p ->> 'key')
           and ro.locale = (p ->> 'locale') and ro.entity_id is not distinct from v_entity;
      else
        insert into erp.resource_override (tenant_id, key, locale, value, entity_id)
        values (v_tenant, p ->> 'key', p ->> 'locale', p ->> 'value', v_entity)
        on conflict (tenant_id, key, locale,
                     coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid))
          do update set value = excluded.value, status = 'active', updated_at = now();
      end if;

    when 'legislation_binding' then
      if i.operation = 'remove' then
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack');
      else
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack') and b.status = 'active';
        insert into erp.entity_legislation_binding (
          tenant_id, entity_id, pack_code, pack_version, effective_from, effective_to)
        values (v_tenant, v_entity, p ->> 'pack', (p ->> 'pack_version')::integer,
                v_from, (p ->> 'effective_to')::date);
      end if;

    when 'event_subscription' then
      if i.operation = 'remove' then
        update erp.event_subscription es set status = 'inactive', updated_at = now()
         where es.tenant_id = v_tenant and es.consumer_code = (p ->> 'consumer')
           and es.event_pattern = (p ->> 'pattern');
      else
        insert into erp.event_subscription (
          tenant_id, consumer_code, event_pattern, module_code, max_attempts)
        values (v_tenant, p ->> 'consumer', p ->> 'pattern', p ->> 'module',
                coalesce((p ->> 'max_attempts')::smallint, 8))
        on conflict (tenant_id, consumer_code, event_pattern) do update
          set module_code = excluded.module_code,
              max_attempts = excluded.max_attempts,
              status = 'active', updated_at = now();
      end if;

    when 'role' then
      if i.operation = 'remove' then
        update erp.role r set status = 'inactive', updated_at = now()
         where r.tenant_id = v_tenant and r.code = (p ->> 'code');
      else
        insert into erp.role (tenant_id, code, name, name_key, from_template)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'name_key', p ->> 'from_template')
        on conflict (tenant_id, code) do update
          set name = excluded.name, name_key = excluded.name_key,
              status = 'active', updated_at = now()
        returning id into v_obj;

        -- The grant set is replaced wholesale: a promoted role is the role the
        -- change set describes, not a merge with whatever was here before.
        delete from erp.role_permission rp
         where rp.tenant_id = v_tenant and rp.role_id = v_obj;

        insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
        select v_tenant, v_obj, e.value ->> 'permission',
               coalesce((select array_agg(dc #>> '{}')
                           from jsonb_array_elements(e.value -> 'data_classes') dc),
                        '{}'::text[])
          from jsonb_array_elements(coalesce(p -> 'permissions', '[]'::jsonb)) e;
      end if;

    when 'rule_set' then
      if i.operation = 'remove' then
        update erp.rule_set rs set status = 'inactive', updated_at = now()
         where rs.tenant_id = v_tenant
           and rs.decision_point_code = (p ->> 'decision_point')
           and rs.code = (p ->> 'code');
      else
        insert into erp.rule_set (tenant_id, decision_point_code, code, name, entity_id, site_id)
        values (v_tenant, p ->> 'decision_point', p ->> 'code', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, decision_point_code, code) do update
          set name = excluded.name, status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.rule_set_version v
         where v.tenant_id = v_tenant and v.rule_set_id = v_obj;

        insert into erp.rule_set_version (
          tenant_id, rule_set_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.rule (
          tenant_id, rule_set_version_id, seq, code, name, condition, outcome,
          stop_on_match, is_active)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', e.value -> 'condition', e.value -> 'outcome',
               coalesce((e.value ->> 'stop_on_match')::boolean, true),
               coalesce((e.value ->> 'is_active')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'rules', '[]'::jsonb)) e;

        -- Activation runs the linter, so a promotion cannot introduce a rule
        -- that can never match.
        perform erp.activate_rule_set_version(v_ver, v_from);
      end if;

    when 'state_machine' then
      if i.operation = 'remove' then
        update erp.state_machine sm set status = 'inactive', updated_at = now()
         where sm.tenant_id = v_tenant and sm.code = (p ->> 'code');
      else
        insert into erp.state_machine (tenant_id, code, object_type, name, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'object_type', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, code) do update
          set object_type = excluded.object_type, name = excluded.name,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.state_machine_version v
         where v.tenant_id = v_tenant and v.state_machine_id = v_obj;

        insert into erp.state_machine_version (
          tenant_id, state_machine_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.state (
          tenant_id, state_machine_version_id, code, name, is_initial, is_terminal,
          is_committed, sort_order, on_enter, on_exit)
        select v_tenant, v_ver, e.value ->> 'code', e.value ->> 'name',
               coalesce((e.value ->> 'is_initial')::boolean, false),
               coalesce((e.value ->> 'is_terminal')::boolean, false),
               coalesce((e.value ->> 'is_committed')::boolean, false),
               coalesce((e.value ->> 'sort_order')::integer, 100),
               coalesce(e.value -> 'on_enter', '[]'::jsonb),
               coalesce(e.value -> 'on_exit', '[]'::jsonb)
          from jsonb_array_elements(coalesce(p -> 'states', '[]'::jsonb)) e;

        -- Transitions come second because they reference states by code.
        for r in select e.value as tr
                   from jsonb_array_elements(coalesce(p -> 'transitions', '[]'::jsonb)) e
        loop
          insert into erp.transition (
            tenant_id, state_machine_version_id, code, name, from_state_id, to_state_id,
            guard, effects, required_permission, is_automatic, sort_order)
          select v_tenant, v_ver, r.tr ->> 'code', r.tr ->> 'name',
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'from'),
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'to'),
                 coalesce(r.tr -> 'guard', 'true'::jsonb),
                 coalesce(r.tr -> 'effects', '[]'::jsonb),
                 r.tr ->> 'required_permission',
                 coalesce((r.tr ->> 'is_automatic')::boolean, false),
                 coalesce((r.tr ->> 'sort_order')::integer, 100);
        end loop;

        -- Activation runs the graph validation, so a promotion cannot
        -- introduce a state a document could enter and never leave.
        perform erp.activate_state_machine_version(v_ver, v_from);
      end if;

    when 'approval_chain' then
      if i.operation = 'remove' then
        update erp.approval_chain ac set status = 'inactive', updated_at = now()
         where ac.tenant_id = v_tenant and ac.code = (p ->> 'code');
      else
        insert into erp.approval_chain (
          tenant_id, code, name, object_type, applies_when, priority, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'object_type',
                coalesce(p -> 'applies_when', 'true'::jsonb),
                coalesce((p ->> 'priority')::integer, 100), v_entity, v_site)
        on conflict (tenant_id, code) do update
          set name = excluded.name, object_type = excluded.object_type,
              applies_when = excluded.applies_when, priority = excluded.priority,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.approval_chain_version v
         where v.tenant_id = v_tenant and v.approval_chain_id = v_obj;

        insert into erp.approval_chain_version (
          tenant_id, approval_chain_id, version, status, effective_from,
          material_fields, value_field, tolerance_pct, tolerance_absolute, note)
        values (
          v_tenant, v_obj, v_vnum, 'draft', v_from,
          coalesce((select array_agg(f #>> '{}')
                      from jsonb_array_elements(coalesce(p -> 'material_fields', '[]'::jsonb)) f),
                   '{}'::text[]),
          p ->> 'value_field',
          (p ->> 'tolerance_pct')::numeric,
          (p ->> 'tolerance_absolute')::numeric,
          'promoted')
        returning id into v_ver;

        insert into erp.approval_step (
          tenant_id, approval_chain_version_id, seq, code, name, approver_kind,
          role_id, app_user_id, min_approvals, condition, escalate_after, allow_delegation)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', (e.value ->> 'approver_kind')::erp.approver_kind,
               (select ro.id from erp.role ro
                 where ro.tenant_id = v_tenant and ro.code = e.value ->> 'role'),
               (select u.id from erp.app_user u
                 where u.tenant_id = v_tenant and u.email = e.value ->> 'user'),
               coalesce((e.value ->> 'min_approvals')::smallint, 1),
               coalesce(e.value -> 'condition', 'true'::jsonb),
               (e.value ->> 'escalate_after')::interval,
               coalesce((e.value ->> 'allow_delegation')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'steps', '[]'::jsonb)) e;

        -- Activation refuses a chain with no steps, so a promotion cannot
        -- install one that approves everything unchecked.
        perform erp.activate_approval_chain_version(v_ver, v_from);
      end if;

    -- Spec 5.7: "declarative posting rules from operational events". Declarative
    -- means configuration, and configuration in this product is promoted rather
    -- than edited — otherwise the rule that decides which account a receipt
    -- lands in would be the one thing in finance nobody had to get approved.
    --
    -- Rules are versioned in place: a new version supersedes the last rather
    -- than replacing it, because a journal line records the rule version that
    -- produced it and that reference must stay resolvable for ever.
    when 'posting_rule' then
      if i.operation = 'remove' then
        update erp.posting_rule pr set status = 'withdrawn', updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code')
           and pr.status = 'active';
      else
        select coalesce(max(pr.version), 0) + 1 into v_vnum
          from erp.posting_rule pr
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code');

        -- Supersede the version in force. Closing it the day before the new
        -- one starts keeps "exactly one rule in force" true without a gap.
        update erp.posting_rule pr
           set status = 'superseded',
               effective_to = least(coalesce(pr.effective_to, v_from), v_from),
               updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code')
           and pr.status = 'active';

        insert into erp.posting_rule (
          tenant_id, code, name, entity_id, ledger_id, event_type, condition,
          posting_lines, version, status, effective_from, legislation_pack_code)
        values (
          v_tenant, p ->> 'code', p ->> 'name', v_entity,
          (select l.id from erp.ledger l
            where l.tenant_id = v_tenant and l.code = (p ->> 'ledger')
              and (v_entity is null or l.entity_id = v_entity)
            order by l.code limit 1),
          p ->> 'event_type',
          coalesce(p -> 'condition', 'true'::jsonb),
          coalesce(p -> 'posting_lines', '[]'::jsonb),
          v_vnum, 'active', v_from, p ->> 'legislation_pack');

        -- A rule that does not balance would raise a journal that cannot post,
        -- and it would do so at month end rather than here. Refusing at
        -- promotion is the whole point of promoting it.
        perform erp.assert_posting_rule_balances(p ->> 'code', v_vnum);
      end if;

    -- Spec 5.1: what a good record looks like is a tenant's opinion, and an
    -- opinion that decides whether a record is fit to trade on belongs in the
    -- same promotion pipeline as everything else. Replaced rather than
    -- versioned: nothing records "the quality rule version that scored this",
    -- so a superseded version would be a row nobody could ever read.
    when 'data_quality_rule' then
      if i.operation = 'remove' then
        update erp.data_quality_rule q set status = 'inactive', updated_at = now()
         where q.tenant_id = v_tenant
           and q.object_type = (p ->> 'object_type')
           and q.code = (p ->> 'code');
      else
        insert into erp.data_quality_rule (
          tenant_id, object_type, code, name, kind, condition, weight,
          severity, message, entity_id, status)
        values (v_tenant, p ->> 'object_type', p ->> 'code', p ->> 'name',
                coalesce(p ->> 'kind', 'completeness'),
                coalesce(p -> 'condition', 'true'::jsonb),
                coalesce((p ->> 'weight')::integer, 1),
                coalesce(p ->> 'severity', 'warning'),
                coalesce(p ->> 'message', p ->> 'name'),
                v_entity, 'active')
        on conflict (tenant_id, object_type, code) do update
          set name = excluded.name, kind = excluded.kind,
              condition = excluded.condition, weight = excluded.weight,
              severity = excluded.severity, message = excluded.message,
              status = 'active', updated_at = now();
      end if;

    -- Which fields cannot change without somebody agreeing. Promoted for the
    -- same reason the approval chains themselves are: a control that its own
    -- subject can switch off is not a control.
    when 'field_approval_rule' then
      if i.operation = 'remove' then
        update erp.field_approval_rule f set status = 'inactive', updated_at = now()
         where f.tenant_id = v_tenant
           and f.object_type = (p ->> 'object_type')
           and f.field_name = (p ->> 'field_name');
      else
        if not exists (select 1 from erp_meta.maintainable_field m
                        where m.object_type = (p ->> 'object_type')
                          and m.column_name = (p ->> 'field_name')) then
          raise exception
            'ERPWARE_PROMOTION_UNGOVERNABLE_FIELD: %.% is not a maintainable field',
            p ->> 'object_type', p ->> 'field_name'
            using errcode = '23503',
                  hint = 'A rule guarding a field nothing can change is a control '
                         'that will never fire.';
        end if;

        insert into erp.field_approval_rule (
          tenant_id, object_type, field_name, condition, approval_chain_code,
          sensitivity, reason_required, status)
        values (v_tenant, p ->> 'object_type', p ->> 'field_name',
                coalesce(p -> 'condition', 'true'::jsonb),
                p ->> 'approval_chain',
                coalesce((p ->> 'sensitivity')::integer, 100),
                coalesce((p ->> 'reason_required')::boolean, false),
                'active')
        on conflict (tenant_id, object_type, field_name) do update
          set condition = excluded.condition,
              approval_chain_code = excluded.approval_chain_code,
              sensitivity = excluded.sensitivity,
              reason_required = excluded.reason_required,
              status = 'active', updated_at = now();
      end if;

    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule, data_quality_rule, field_approval_rule';
  end case;
end;
$function$;

-- -----------------------------------------------------------------------------
-- The assertions
-- -----------------------------------------------------------------------------

create or replace function erp.master_data_configuration_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- A rule guarding a field nothing can write would never fire, and would read
  -- on a governance screen as a control that exists.
  select 'a field approval rule guards a field that cannot be maintained',
         format('%s.%s', f.object_type, f.field_name),
         'erp_meta.maintainable_field does not list it, so no change request '
         'or mass change can ever touch it'
    from erp.field_approval_rule f
   where f.status = 'active'
     and not exists (select 1 from erp_meta.maintainable_field m
                      where m.object_type = f.object_type
                        and m.column_name = f.field_name)
  union all
  -- A rule that names a chain nobody promoted would route an approval into
  -- nothing, and erp.submit_change_request() would mark it pending for ever.
  select 'a field approval rule names an approval chain that does not exist',
         format('%s.%s', f.object_type, f.field_name),
         format('approval_chain_code = %s', f.approval_chain_code)
    from erp.field_approval_rule f
   where f.status = 'active'
     and f.approval_chain_code is not null
     and not exists (select 1 from erp.approval_chain ac
                      where ac.tenant_id = f.tenant_id
                        and ac.code = f.approval_chain_code
                        and ac.status = 'active')
  union all
  -- A quality rule about an object type this product cannot describe as facts
  -- would score nothing.
  select 'a data quality rule scores an object type that has no fields',
         format('%s.%s', q.object_type, q.code),
         'erp_meta.maintainable_field has no rows for it, so erp.master_record() '
         'cannot produce the facts the condition reads'
    from erp.data_quality_rule q
   where q.status = 'active'
     and not exists (select 1 from erp_meta.maintainable_field m
                      where m.object_type = q.object_type)
$$;

create or replace function erp.assert_master_data_sane()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.master_data_configuration_report();

  if v_count > 0 then
    raise exception 'ERPWARE_MASTER_DATA_CONFIGURATION_DEAD: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  return 'master data: every rule can fire';
end;
$$;

-- -----------------------------------------------------------------------------
-- The public surface — all reads except the ones that were always writes
-- -----------------------------------------------------------------------------

create or replace function public.erp_data_quality(p_object_type text)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(q) order by q.score, q.code), '[]'::jsonb)
    from erp.data_quality_report(p_object_type) q
$$;

create or replace function public.erp_duplicate_candidates(p_object_type text)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb)
    from erp.duplicate_candidates(p_object_type) d
$$;

create or replace function public.erp_configure_master_data(
  p_approver_role text default 'administrator')
returns uuid
language sql
volatile
security invoker
set search_path = ''
as $$ select erp.configure_master_data(p_approver_role) $$;

create or replace function public.erp_open_change_request(
  p_object_type text, p_object_id uuid, p_proposed jsonb, p_reason text default null)
returns uuid
language sql
volatile
security invoker
set search_path = ''
as $$ select erp.open_change_request(p_object_type, p_object_id, p_proposed, p_reason) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_data_quality(text)',
    'public.erp_duplicate_candidates(text)',
    'public.erp_configure_master_data(text)',
    'public.erp_open_change_request(text, uuid, jsonb, text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_master_data', 'erp.configure_master_data',
   'Submits the quality and field-approval rules as a B6 change set the caller '
   'cannot approve; the installer authorises administration.configure.'),
  ('erp_open_change_request', 'erp.open_change_request',
   'Opens a draft change request. Authorises master_data.write, and refuses any '
   'field not enumerated in erp_meta.maintainable_field; applying it needs '
   'approval it cannot grant itself.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- The suite
-- -----------------------------------------------------------------------------

create or replace function erp_test.master_data_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  cs uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_item uuid; v_item2 uuid; v_p1 uuid; v_p2 uuid;
  v_cr uuid; v_imp uuid; v_mc uuid;
  v_score integer; v_n integer; v_status erp.change_request_status;
  v_ok boolean; v_msg text; v_task uuid;
begin
  select * into r from erp.provision_tenant('zzmdm','MDM Suite','a@zzmdm.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzmdm.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  cs := erp.configure_master_data();
  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(cs); perform erp.promote_change_set(cs);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'governance installs as configuration, not as code',
    (select count(*) from erp.data_quality_rule q
      where q.tenant_id = r.tenant_id and q.status='active') = 5
    and (select count(*) from erp.field_approval_rule f
          where f.tenant_id = r.tenant_id and f.status='active') = 3,
    'five quality rules and three governed fields, all promoted';

  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;

  -- ---------------------------------------------------------------------------
  -- Scoring: read the number, and read it changing.
  -- ---------------------------------------------------------------------------
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'BARE','Bare item',v_uom,'active') returning id into v_item;

  v_score := erp.data_quality_score('item', v_item);
  return query select 'an incomplete record scores below a complete one',
    v_score = 75,
    format('name (3) and shelf life (3) satisfied, class (2) not: %s of 8', v_score);

  update erp.item set item_class = 'AMBIENT' where id = v_item;
  return query select 'and completing it moves the score',
    erp.data_quality_score('item', v_item) = 100,
    format('%s to %s', v_score, erp.data_quality_score('item', v_item));

  -- Validity is a different question from completeness: both fields are here,
  -- and what they say together is impossible.
  update erp.item set shelf_life_days = 30, min_remaining_shelf_life_days = 60
   where id = v_item;
  return query select 'a record can be complete and still invalid',
    erp.data_quality_score('item', v_item) = 63
    and exists (select 1 from erp.score_master_record('item', v_item) s
                 where s.code = 'shelf_life_consistent' and not s.satisfied
                   and s.kind = 'validity'),
    'every field present, and the acceptance window longer than the shelf life';

  update erp.item set shelf_life_days = 90 where id = v_item;

  -- ---------------------------------------------------------------------------
  -- Duplicates and merge.
  -- ---------------------------------------------------------------------------
  insert into erp.party (tenant_id,code,name,country_code,tax_identifier,status)
  values (r.tenant_id,'ACME1','Acme Ltd.','GB','GB123','active') returning id into v_p1;
  insert into erp.party (tenant_id,code,name,country_code,status)
  values (r.tenant_id,'ACME2','ACME  LTD','GB','active') returning id into v_p2;

  return query select 'two spellings of one counterparty are found',
    exists (select 1 from erp.duplicate_candidates('party') d
             where d.matched_on = 'name'
               and ((d.left_id = v_p1 and d.right_id = v_p2)
                 or (d.left_id = v_p2 and d.right_id = v_p1))),
    'case, punctuation and spacing removed — the duplicates that occur';

  perform erp.merge_master_record('party', v_p1, v_p2, 'same company, two entries');

  return query select 'the duplicate records who it became, and is not deleted',
    (select p.merged_into_id from erp.party p where p.id = v_p2) = v_p1
    and (select p.status::text from erp.party p where p.id = v_p2) = 'inactive',
    'old references still resolve; no signed document was rewritten';

  return query select 'and a merged record stops being a candidate',
    not exists (select 1 from erp.duplicate_candidates('party') d
                 where d.left_id = v_p2 or d.right_id = v_p2),
    'a review queue that keeps offering the same pair is one nobody works';

  begin
    perform erp.merge_master_record('party', v_p2, v_p1, 'chain');
    v_ok := false; v_msg := 'a merge chain two hops long was allowed';
  exception when others then
    v_ok := (sqlerrm like '%MERGE_CHAIN%'); v_msg := left(sqlerrm,56);
  end;
  return query select 'merging into an already-merged record is refused', v_ok, v_msg;

  -- ---------------------------------------------------------------------------
  -- Change requests, and the field-level part of field-level.
  -- ---------------------------------------------------------------------------
  v_cr := erp.open_change_request('party', v_p1,
            jsonb_build_object('name','Acme Limited'), 'trading name tidy-up');
  v_status := erp.submit_change_request(v_cr);

  return query select 'an ungoverned field needs no approver, and says so',
    v_status = 'approved'
    and (select cr.approval_request_id is null from erp.change_request cr where cr.id = v_cr),
    '"nobody had to approve this" is a different fact from "somebody did"';

  perform erp.apply_change_request(v_cr);
  return query select 'and applying it writes the field',
    (select p.name from erp.party p where p.id = v_p1) = 'Acme Limited',
    'through the allow-list, never through a caller-supplied identifier';

  v_cr := erp.open_change_request('party', v_p1,
            jsonb_build_object('tax_identifier','GB999'), 'new registration');
  v_status := erp.submit_change_request(v_cr);

  return query select 'a governed field routes to an approver',
    v_status = 'pending'
    and (select cr.approval_request_id is not null from erp.change_request cr where cr.id = v_cr),
    'the same change, a different field, a different outcome';

  begin
    perform erp.apply_change_request(v_cr);
    v_ok := false; v_msg := 'an unapproved change was applied';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm,56); end;
  return query select 'and cannot be applied until it is approved', v_ok, v_msg;

  -- Approve it as somebody else, then apply.
  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  -- Both principals hold the approver role, so the chain raised a task for
  -- each. Taking whichever came first would decide somebody else's task and be
  -- refused — correctly, and confusingly.
  select t.id into v_task from erp.approval_task t
    join erp.approval_request ar on ar.id = t.approval_request_id
   where ar.object_type = 'change_request' and ar.object_id = v_cr
     and t.status = 'pending' and t.assignee_user_id = v_second
   limit 1;
  perform erp.decide_approval_task(v_task, true, 'seen the certificate');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  perform erp.apply_change_request(v_cr);
  return query select 'once approved it applies',
    (select p.tax_identifier from erp.party p where p.id = v_p1) = 'GB999',
    'approval read from the engine, not cached in a second status column';

  -- The world moving underneath a waiting request.
  v_cr := erp.open_change_request('party', v_p1,
            jsonb_build_object('name','Acme Holdings'), 'rebrand');
  perform erp.submit_change_request(v_cr);
  update erp.party set name = 'Acme Group' where id = v_p1;
  begin
    perform erp.apply_change_request(v_cr);
    v_ok := false; v_msg := 'a stale request silently undid somebody else';
  exception when sqlstate '40001' then v_ok := true; v_msg := left(sqlerrm,56); end;
  return query select 'a request whose record moved is refused, not applied', v_ok, v_msg;

  -- The allow-list, at the door.
  begin
    perform erp.open_change_request('party', v_p1, jsonb_build_object('tenant_id', gen_random_uuid()));
    v_ok := false; v_msg := 'a change request reached tenant_id';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm,56); end;
  return query select 'a field outside the allow-list cannot be reached', v_ok, v_msg;

  -- ---------------------------------------------------------------------------
  -- Import: four stages, in order, and a rollback that restores.
  -- ---------------------------------------------------------------------------
  v_imp := erp.stage_import('party', jsonb_build_array(
    jsonb_build_object('code','ACME1','name','Acme Group plc'),
    jsonb_build_object('code','NEWCO','name','Newco Ltd','country_code','IE')));

  -- Called first, into a variable, and only then observed. Doing both inside
  -- one boolean expression makes the case depend on the order Postgres chooses
  -- to evaluate the operands in, which is not defined — and which quietly gave
  -- the wrong answer here until it was written this way.
  v_n := erp.validate_import(v_imp);
  return query select 'validation decides insert or update per row',
    v_n = 0
    and (select count(*) from erp.import_row i
          where i.import_batch_id = v_imp and i.action = 'update') = 1
    and (select count(*) from erp.import_row i
          where i.import_batch_id = v_imp and i.action = 'insert') = 1,
    format('%s errors; one row names a record that exists, one does not', v_n);

  begin
    perform erp.load_import(v_imp);
    v_ok := false; v_msg := 'an import loaded without anybody looking at it';
  exception when others then
    v_ok := (sqlerrm like '%NOT_PREVIEWED%'); v_msg := left(sqlerrm,56);
  end;
  return query select 'a load before the preview is refused', v_ok, v_msg;

  return query select 'the preview shows before-and-after, not the file',
    (select p.changes -> 'name' ->> 'from' from erp.preview_import(v_imp) p
      where p.code = 'ACME1') = 'Acme Group',
    'a list of what was in the file is not a preview of what it will do';

  v_n := erp.load_import(v_imp);
  return query select 'a staged load inserts and updates',
    v_n = 2
    and (select p.name from erp.party p where p.code = 'ACME1') = 'Acme Group plc'
    and exists (select 1 from erp.party p
                 where p.tenant_id = r.tenant_id and p.code = 'NEWCO'
                   and p.country_code = 'IE'),
    'the update took, and the insert carried its other fields';

  v_n := erp.rollback_import(v_imp);
  return query select 'rollback restores the update and removes the insert',
    v_n = 2
    and (select p.name from erp.party p where p.code = 'ACME1') = 'Acme Group'
    and not exists (select 1 from erp.party p
                     where p.tenant_id = r.tenant_id and p.code = 'NEWCO'),
    'real rather than nominal: every row kept what was there before';

  -- ---------------------------------------------------------------------------
  -- Mass maintenance.
  -- ---------------------------------------------------------------------------
  insert into erp.item (tenant_id,code,name,item_class,stock_uom_id,status)
  values (r.tenant_id,'CHILL1','Chilled one','CHILLED',v_uom,'active') returning id into v_item2;
  insert into erp.item (tenant_id,code,name,item_class,stock_uom_id,status)
  values (r.tenant_id,'CHILL2','Chilled two','CHILLED',v_uom,'active');

  v_mc := erp.open_mass_change('item',
    jsonb_build_object('==', jsonb_build_array(jsonb_build_object('var','item_class'),'CHILLED')),
    jsonb_build_object('item_group','COLD_CHAIN'),
    'cold chain reporting group');

  return query select 'a selector picks the records it says it picks',
    (select count(*) from erp.preview_mass_change(v_mc)) = 2,
    'JsonLogic over the record — the same language as every other rule here';

  v_n := erp.apply_mass_change(v_mc);
  return query select 'applying it changes exactly those',
    v_n = 2
    and (select count(*) from erp.item i
          where i.tenant_id = r.tenant_id and i.item_group = 'COLD_CHAIN') = 2
    and (select i.item_group is null from erp.item i where i.id = v_item),
    'the ambient item was not selected and was not touched';

  v_n := erp.reverse_mass_change(v_mc);
  return query select 'and reversing it puts them back',
    v_n = 2
    and not exists (select 1 from erp.item i
                     where i.tenant_id = r.tenant_id and i.item_group = 'COLD_CHAIN'),
    'every touched record kept its prior values';

  begin
    perform erp.open_mass_change('item', 'true'::jsonb,
                                 jsonb_build_object('status','inactive'));
    v_ok := false; v_msg := 'a change with no selector was accepted silently';
  exception when others then
    v_ok := (sqlerrm like '%UNSELECTIVE%'); v_msg := left(sqlerrm,56);
  end;
  return query select 'a mass change with no selector must be said in words', v_ok, v_msg;

  -- ---------------------------------------------------------------------------
  -- The configuration assertion.
  -- ---------------------------------------------------------------------------
  return query select 'every promoted rule can actually fire',
    (select count(*) from erp.master_data_configuration_report()) = 0,
    'a control that guards an unwritable field is not a control';

  insert into erp.field_approval_rule (tenant_id, object_type, field_name, approval_chain_code)
  values (r.tenant_id, 'party', 'duns_or_gln', 'master_data_change');
  return query select 'a rule guarding a field nothing can write fails the build',
    (select count(*) from erp.master_data_configuration_report()
      where finding = 'a field approval rule guards a field that cannot be maintained') = 1,
    'it would read on a governance screen as a control that exists';
  delete from erp.field_approval_rule
   where tenant_id = r.tenant_id and field_name = 'duns_or_gln';

  set constraints all immediate;
  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_master_data_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 26;
begin
  create temporary table if not exists zz_mdm_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_mdm_result;
  insert into zz_mdm_result select * from erp_test.master_data_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_mdm_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_MASTER_DATA_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;

  if v_pass < v_total then
    raise exception E'ERPWARE_MASTER_DATA_SUITE_FAILED: %/%\n%', v_pass, v_total, v_detail
      using errcode = 'P0001';
  end if;

  return format('master data: %s/%s', v_pass, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_master_data_sane();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_isolation();
