-- =============================================================================
-- ERPWare — B10: configuration intelligence
-- Spec 3.12, Part 7 ("No artificial intelligence in the transaction path, and
-- no configuration applied without human approval")
--
--   "Assists authoring, explanation, impact analysis, test generation,
--    onboarding interviews and migration mapping.
--    Proposes, never applies: every suggestion is a diff requiring named human
--    approval, validated in a test environment first.
--    Never in the transaction path: postings, allocations, tax determination
--    and stock movements are executed by deterministic rules only.
--    Operates strictly within tenant scope; no cross-tenant learning, no
--    cross-tenant examples, no model artefacts trained on one tenant's data
--    being used to serve another."
--
-- Three promises, and in most systems all three are policy: a paragraph in a
-- design document, upheld by everyone remembering. Each of them can be made
-- structural here, and that is what this migration is.
--
-- Note what is NOT here: anything that generates a suggestion. Whatever does
-- that lives outside the database, like the dispatch worker, and for the same
-- reason — its only way in is to create a proposal, and a proposal cannot
-- apply itself. The generator being absent is the design working, not a gap.
--
--   1. Proposes, never applies.
--      A proposal carries a B6 change set and cannot promote it. Promotion
--      requires an approver who is a PERSON: erp.app_user.kind = 'person'.
--      Service principals exist now (B1, completed during B8), so "named human
--      approval" is checkable rather than hoped for — the machine that wrote
--      the proposal is exactly the kind of principal that cannot approve it.
--
--   2. Validated in a test environment first.
--      Promotion to a production environment is refused unless the proposal
--      records a successful validation in a non-production one. B6 already
--      knows which environments are production.
--
--   3. Never in the transaction path.
--      Everything intelligent lives in its own schema, erp_ai, so the boundary
--      is a name rather than a convention. erp.assert_intelligence_boundary()
--      then walks the call graph TRANSITIVELY from every registered
--      transaction-path function and fails if any of them can reach erp_ai at
--      any depth. A direct-reference check would be trivially defeated by one
--      helper in between.
--
--   4. Strictly tenant scope.
--      Every erp_ai table is tenant-scoped and gets the same generated row
--      security as everything else, and a proposal's evidence must come from
--      the proposal's own tenant — enforced by composite key, so cross-tenant
--      evidence is not merely forbidden but unrepresentable.
-- =============================================================================

create schema if not exists erp_ai;

comment on schema erp_ai is
  'Everything that assists rather than decides. Separated by schema so spec '
  '3.12''s "never in the transaction path" is a checkable property of the call '
  'graph rather than a convention.';

revoke all on schema erp_ai from public;
grant usage on schema erp_ai to authenticated;

-- -----------------------------------------------------------------------------
-- What the transaction path IS
--
-- Named explicitly, because a boundary you cannot enumerate is a boundary you
-- cannot check. Spec 3.12 lists the four: postings, allocations, tax
-- determination and stock movements.
-- -----------------------------------------------------------------------------

create table erp_meta.transaction_path_function (
  schema_name  text not null,
  function_name text not null,
  rationale    text not null check (length(trim(rationale)) >= 10),
  registered_at timestamptz not null default now(),
  primary key (schema_name, function_name)
);

comment on table erp_meta.transaction_path_function is
  'The functions spec 3.12 says must be deterministic: postings, allocations, '
  'tax determination, stock movements. Registered by name so the boundary can '
  'be checked rather than asserted in prose.';

insert into erp_meta.transaction_path_function (schema_name, function_name, rationale) values
  ('erp', 'apply_stock_movement',
   'Stock movements. Spec 3.12 names them explicitly as deterministic-only.'),
  ('erp', 'reverse_stock_movement',
   'A correction is a stock movement and is held to the same rule.'),
  ('erp', 'move_container',
   'Moves the stock inside a container; a stock movement by another name.'),
  ('erp', 'check_journal_balances',
   'Postings. The deferred constraint that decides whether a journal may commit.'),
  ('erp', 'check_journal_line_posting',
   'Postings. Decides whether a line may exist and what it must trace to.'),
  ('erp', 'check_period_open',
   'Postings. Decides whether a period will accept a posting at all.'),
  ('erp', 'evaluate_legislation_rules',
   'Tax determination runs through the legislation rule evaluator.'),
  ('erp', 'jsonlogic',
   'The rule interpreter every deterministic decision is expressed in.'),
  ('erp', 'evaluate_rules',
   'Rule evaluation. The decision layer beneath allocation and determination.'),
  ('erp', 'perform_transition',
   'State transitions gate postings and movements; a suggestion must not move one.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- Proposals
-- -----------------------------------------------------------------------------

create type erp_ai.proposal_kind as enum (
  'authoring', 'explanation', 'impact_analysis', 'test_generation',
  'onboarding_interview', 'migration_mapping'
);

create type erp_ai.proposal_status as enum (
  'draft',      -- being assembled
  'proposed',   -- put to a human
  'validated',  -- applied and checked in a non-production environment
  'approved',   -- a named person said yes
  'rejected',
  'applied',    -- its change set was promoted
  'withdrawn'
);

create table erp_ai.proposal (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  kind            erp_ai.proposal_kind not null,
  title           text not null,
  -- Why this is being suggested, in words a reviewer can weigh. A proposal
  -- nobody can evaluate is a proposal that gets approved on trust, which is
  -- the failure spec 3.12 is written against.
  rationale       text not null check (length(trim(rationale)) >= 20),
  -- The diff. Spec 3.12: "every suggestion is a diff" — so it is a B6 change
  -- set, reviewed and promoted by exactly the same machinery as a human's
  -- change, with no separate path that could have weaker gates.
  change_set_id   uuid,
  status          erp_ai.proposal_status not null default 'draft',

  -- Promise 2. Which non-production environment it was proved in, and when.
  validated_in_environment_id uuid,
  validated_at    timestamptz,
  validation_summary jsonb,

  -- Promise 1. The person who approved it. Constrained to a person below.
  reviewed_by     uuid,
  reviewed_at     timestamptz,
  review_note     text,

  -- What produced it. Recorded plainly so a reviewer knows they are reading a
  -- machine's suggestion rather than a colleague's.
  produced_by     uuid,
  producer_label  text,

  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,

  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, change_set_id)
    references erp.change_set (tenant_id, id) on delete set null,
  foreign key (tenant_id, validated_in_environment_id)
    references erp.environment (tenant_id, id) on delete restrict,
  foreign key (tenant_id, reviewed_by)
    references erp.app_user (tenant_id, id) on delete restrict,
  foreign key (tenant_id, produced_by)
    references erp.app_user (tenant_id, id) on delete restrict,

  constraint proposal_decided_has_reviewer check (
    status not in ('approved', 'rejected', 'applied')
    or (reviewed_by is not null and reviewed_at is not null)),
  constraint proposal_validated_has_environment check (
    status not in ('validated', 'approved', 'applied')
    or (validated_in_environment_id is not null and validated_at is not null)),
  -- A proposal that changes something must carry the diff that says what.
  constraint proposal_authoring_has_change_set check (
    kind <> 'authoring' or status = 'draft' or change_set_id is not null)
);

comment on table erp_ai.proposal is
  'Spec 3.12: proposes, never applies. Carries a B6 change set and cannot '
  'promote it — promotion needs a named person, and the machine that wrote the '
  'proposal is precisely the kind of principal that cannot be one.';

create index on erp_ai.proposal (tenant_id, status);
create index on erp_ai.proposal (tenant_id, change_set_id) where change_set_id is not null;

-- Promise 1, enforced. "Named human approval" means a person: a service
-- principal cannot approve, which matters because a service principal is
-- exactly what produced the proposal.
create or replace function erp_ai.check_proposal_reviewer()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_kind erp.principal_kind;
  v_env  erp.environment%rowtype;
begin
  if new.reviewed_by is not null then
    select kind into v_kind from erp.app_user
     where tenant_id = new.tenant_id and id = new.reviewed_by;

    if v_kind <> 'person' then
      raise exception
        'ERPWARE_PROPOSAL_NEEDS_HUMAN_APPROVAL: % is a %; spec 3.12 requires '
        'named human approval, and a service principal is not one',
        new.reviewed_by, v_kind
        using errcode = '42501';
    end if;

    -- A machine cannot approve its own suggestion by being recorded as both
    -- producer and reviewer.
    if new.produced_by is not null and new.produced_by = new.reviewed_by then
      raise exception
        'ERPWARE_PROPOSAL_SELF_APPROVED: the producer of a proposal cannot be '
        'its reviewer'
        using errcode = '42501';
    end if;
  end if;

  -- Promise 2, enforced. Validation must have happened somewhere that is not
  -- production; "we tested it in production" is not a test.
  if new.validated_in_environment_id is not null then
    select * into v_env from erp.environment
     where tenant_id = new.tenant_id and id = new.validated_in_environment_id;

    if v_env.kind = 'production' then
      raise exception
        'ERPWARE_VALIDATED_IN_PRODUCTION: environment % is production; spec '
        '3.12 requires validation in a test environment first', v_env.code
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

create trigger t_proposal_reviewer
  before insert or update on erp_ai.proposal
  for each row execute function erp_ai.check_proposal_reviewer();

-- -----------------------------------------------------------------------------
-- Evidence
--
-- Promise 4. What the suggestion was derived from, always within the tenant.
-- The composite foreign key makes cross-tenant evidence unrepresentable rather
-- than merely forbidden.
-- -----------------------------------------------------------------------------

create table erp_ai.proposal_evidence (
  id              bigint generated always as identity primary key,
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  proposal_id     uuid not null,
  -- What was looked at: a table, a config object, a rule set, a report.
  source_kind     text not null check (source_kind ~ '^[a-z][a-z0-9_]*$'),
  source_ref      text not null,
  observation     text not null,
  observed_at     timestamptz not null default now(),
  unique (tenant_id, proposal_id, source_kind, source_ref),
  foreign key (tenant_id, proposal_id)
    references erp_ai.proposal (tenant_id, id) on delete cascade
);

comment on table erp_ai.proposal_evidence is
  'Spec 3.12: strictly tenant scope. The composite key onto the proposal means '
  'evidence from another tenant cannot be written down, rather than being '
  'forbidden by a rule somebody has to apply.';

-- -----------------------------------------------------------------------------
-- The boundary check
-- -----------------------------------------------------------------------------

-- Transitive, not direct. A transaction-path function calling a helper that
-- calls erp_ai is exactly the case a one-hop check misses, and exactly the case
-- that would happen in practice.
--
-- The edges come from scanning function bodies for schema-qualified calls,
-- which is reliable in this codebase specifically because every function is
-- defined with `set search_path = ''` and therefore must qualify every name it
-- calls. That is not a general technique; it works here because of a rule the
-- rest of the build already enforces.
create or replace function erp.intelligence_boundary_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- RECURSIVE because `reach` refers to itself; it applies to the whole WITH
  -- clause, so the non-recursive terms above it are unaffected.
  with recursive fn as (
    select p.oid,
           p.pronamespace::regnamespace::text as ns,
           p.proname,
           p.prosrc
      from pg_catalog.pg_proc p
     where p.pronamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_ai', 'erp_meta')
  ),
  edge as (
    select caller.oid as caller, callee.oid as callee
      from fn caller
      join fn callee
        on caller.oid <> callee.oid
       and position(callee.ns || '.' || callee.proname || '(' in caller.prosrc) > 0
  ),
  root as (
    select f.oid, f.ns, f.proname
      from erp_meta.transaction_path_function t
      join fn f on f.ns = t.schema_name and f.proname = t.function_name
  ),
  reach as (
    select r.oid as root_oid, r.ns as root_ns, r.proname as root_name,
           e.callee, 1 as depth
      from root r join edge e on e.caller = r.oid
    union
    select x.root_oid, x.root_ns, x.root_name, e.callee, x.depth + 1
      from reach x join edge e on e.caller = x.callee
     where x.depth < 12
  )
  -- Promise 3: nothing in the transaction path may reach the intelligence layer.
  select 'a transaction-path function can reach the intelligence layer',
         format('%s.%s', x.root_ns, x.root_name),
         format('reaches %s.%s at depth %s', c.ns, c.proname, x.depth)
    from reach x
    join fn c on c.oid = x.callee
   where c.ns = 'erp_ai'
  union all
  -- A registered transaction-path function that does not exist is a boundary
  -- with a hole in it: nothing is being checked and nothing says so.
  select 'a registered transaction-path function does not exist',
         format('%s.%s', t.schema_name, t.function_name),
         'the boundary check silently covers nothing for this entry'
    from erp_meta.transaction_path_function t
   where not exists (
     select 1 from pg_catalog.pg_proc p
      where p.pronamespace::regnamespace::text = t.schema_name
        and p.proname = t.function_name)
  union all
  -- Promise 4, structurally: an intelligence table without a tenant column
  -- could hold something that belongs to everyone.
  select 'an erp_ai table is not tenant-scoped',
         format('erp_ai.%s', c.relname),
         'it has no tenant_id, so nothing confines it to one tenant'
    from pg_catalog.pg_class c
   where c.relnamespace = 'erp_ai'::regnamespace
     and c.relkind = 'r'
     and not exists (
       select 1 from pg_catalog.pg_attribute a
        where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
          and a.attname = 'tenant_id')
  union all
  -- Promise 1, as data: anything decided must have been decided by a person.
  select 'a proposal was decided without a named human',
         p.id::text,
         format('status %s with reviewer %s', p.status,
                coalesce(p.reviewed_by::text, 'none'))
    from erp_ai.proposal p
   where p.status in ('approved', 'rejected', 'applied')
     and not exists (
       select 1 from erp.app_user u
        where u.tenant_id = p.tenant_id and u.id = p.reviewed_by
          and u.kind = 'person')
  union all
  -- Promise 2, as data.
  select 'a proposal was applied without validation outside production',
         p.id::text,
         'spec 3.12 requires a test environment first'
    from erp_ai.proposal p
   where p.status = 'applied'
     and not exists (
       select 1 from erp.environment e
        where e.tenant_id = p.tenant_id
          and e.id = p.validated_in_environment_id
          and e.kind <> 'production')
$$;

comment on function erp.intelligence_boundary_report() is
  'Spec 3.12 and Part 7. Walks the call graph transitively from every '
  'registered transaction-path function: a one-hop check would be defeated by '
  'a single helper in between, which is how it would actually happen.';

create or replace function erp.assert_intelligence_boundary()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.intelligence_boundary_report();

  if v_count > 0 then
    raise exception 'ERPWARE_INTELLIGENCE_BOUNDARY: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  return '';
end;
$$;

-- -----------------------------------------------------------------------------
-- Promotion, gated
-- -----------------------------------------------------------------------------

-- The only route from a proposal to an applied change. Deliberately a thin
-- wrapper over B6's erp.promote_change_set(): the gates below are additional to
-- the ones a human's change already passes, never a substitute for them, so a
-- proposal can never take a softer path than a person's edit.
create or replace function erp_ai.apply_proposal(
  p_proposal_id  uuid,
  p_review_note  text default null,
  p_scope_kinds  text[] default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor  uuid := erp.current_principal_id();
  v_kind   erp.principal_kind;
  p        erp_ai.proposal%rowtype;
  v_here   erp.environment%rowtype;
begin
  select kind into v_kind from erp.app_user
   where tenant_id = v_tenant and id = v_actor;

  if v_kind is distinct from 'person' then
    raise exception
      'ERPWARE_PROPOSAL_NEEDS_HUMAN_APPROVAL: applying a proposal requires a '
      'named person; the acting principal is %', coalesce(v_kind::text, 'unknown')
      using errcode = '42501';
  end if;

  select * into p from erp_ai.proposal
   where tenant_id = v_tenant and id = p_proposal_id for update;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_PROPOSAL: %', p_proposal_id using errcode = '23503';
  end if;

  if p.status <> 'validated' then
    raise exception
      'ERPWARE_PROPOSAL_NOT_VALIDATED: % is %; it must be validated in a test '
      'environment before it can be applied', p_proposal_id, p.status
      using errcode = '23514';
  end if;

  if p.change_set_id is null then
    raise exception
      'ERPWARE_PROPOSAL_HAS_NO_DIFF: spec 3.12 requires every suggestion to be '
      'a diff'
      using errcode = '23514';
  end if;

  if p.produced_by = v_actor then
    raise exception
      'ERPWARE_PROPOSAL_SELF_APPROVED: the producer of a proposal cannot apply it'
      using errcode = '42501';
  end if;

  -- B6 promotes into THIS database — the environment marked is_self — rather
  -- than taking a target. So the meaningful check is not where it is going but
  -- where it was proved: the trigger above already refuses a production
  -- validation environment, and 'validated' status requires one to be recorded,
  -- so reaching here means it was proved somewhere that is not production.
  select * into v_here from erp.environment
   where tenant_id = v_tenant and is_self;

  if v_here.id = p.validated_in_environment_id then
    raise exception
      'ERPWARE_VALIDATED_HERE: % was validated in this same environment; spec '
      '3.12 asks for a test environment first, not a rehearsal in place',
      p_proposal_id
      using errcode = '42501';
  end if;

  update erp_ai.proposal
     set status = 'approved', reviewed_by = v_actor, reviewed_at = now(),
         review_note = p_review_note
   where id = p_proposal_id;

  -- B6 does the actual work, with all of its own gates intact. Its second
  -- argument is the scope of config kinds to promote, not a destination.
  perform erp.promote_change_set(p.change_set_id, p_scope_kinds);

  update erp_ai.proposal set status = 'applied' where id = p_proposal_id;

  return p.change_set_id;
end;
$$;

comment on function erp_ai.apply_proposal is
  'The only route from a suggestion to an applied change. A thin wrapper over '
  'B6 promotion: these gates are additional to a human change''s, never a '
  'substitute, so a proposal cannot take a softer path than a person''s edit.';

select erp_meta.register_table('erp_meta', 'transaction_path_function', 'platform_internal',
  'The functions that must stay deterministic, named so the boundary is checkable.');
select erp_meta.register_table('erp_ai', 'proposal', 'tenant_scoped',
  'Spec 3.12: proposes, never applies.');
select erp_meta.register_table('erp_ai', 'proposal_evidence', 'tenant_scoped_append_only',
  'What a suggestion was derived from, always within the tenant.');

insert into erp_meta.audit_exemption (schema_name, table_name, rationale) values
  ('erp_ai', 'proposal_evidence',
   'Append-only observations carrying their own observed_at, written once when '
   'the proposal is assembled and never revised.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

select erp.assert_intelligence_boundary();

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_isolation();
