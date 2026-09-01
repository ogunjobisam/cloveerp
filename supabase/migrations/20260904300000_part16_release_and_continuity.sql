-- =============================================================================
-- Part 16 — the environment ladder, and a restore proved by drill
--
-- Most of Part 16 this repository already does, and does properly. §16.2's
-- migration-first, forward-only rule is how every change here lands;
-- supabase/ci/migrations_immutable.sh enforces "a migration is written once";
-- supabase/ci/00_host_bootstrap.sql is the explicit host contract §16.2 asks
-- for; and §16.1's "an organisation's own test environment is not a separate
-- deployment — it is a tenant-scoped environment inside the same instance" is
-- exactly what erp.environment holds.
--
-- Two things it did not do.
--
-- §16.2 "A migration that adds a callable function must register it and pass
-- the boundary assertion in the same migration, so an ungoverned entry point
-- cannot survive its own transaction." Twenty of the sixty-three migrations
-- that create a public door did not. Enforced from now on by
-- supabase/ci/boundary_in_migration.sh, with the twenty named in a
-- grandfathered list because a migration is written once and they cannot be
-- corrected in place.
--
-- §16.5 "Restore is proved by drill, not by log. A scheduled restore into an
-- isolated environment, verified by running the invariant assertions against
-- the restored data, on a stated cadence. A BACKUP THAT HAS NEVER BEEN RESTORED
-- IS A HOPE." Nothing recorded a drill, so the platform could not tell a proved
-- restore from an untested one — which is the same position as having no
-- backup, discovered at the worst moment.
--
-- The environment ladder becomes a register for the ordinary reason: §16.1
-- states what each tier guarantees, and a guarantee nobody wrote down is one
-- nobody can be held to. "If it cannot be rebuilt from nothing, it is not an
-- environment" is a property of a tier, not a sentence in a document.
-- =============================================================================

-- ── §16.1 the ladder ────────────────────────────────────────────────────────

create table if not exists erp_ref.environment_tier (
  code              text primary key,
  name              text not null,
  guarantee         text not null,
  rebuilt_from_empty boolean not null,
  is_long_lived     boolean not null,
  holds_real_data   boolean not null,
  seq               integer not null,
  registered_at     timestamptz not null default now()
);

comment on table erp_ref.environment_tier is
  'Specification v1.2 §16.1. Each tier and what it guarantees. '
  'rebuilt_from_empty is a column because §16.1 makes it the definition of an '
  'environment rather than a nicety: "If it cannot be rebuilt from nothing, it '
  'is not an environment."';

insert into erp_ref.environment_tier
  (code, name, guarantee, rebuilt_from_empty, is_long_lived, holds_real_data, seq) values
('development', 'Development',
 'Per engineer, disposable, built from an empty database by applying the host bootstrap and every migration in order.',
 true, false, false, 10),
('ci', 'Continuous integration',
 'Created and destroyed per build, from empty, running every structural assertion and adversarial suite. The only place where a green result means anything, because it is the only place with no accumulated state.',
 true, false, false, 20),
('test', 'Test',
 'Long-lived, one per deployment, carrying every organisation''s test environment and the starter packs. Where configuration is authored and change sets are validated.',
 true, true, false, 30),
('live', 'Live',
 'The operating service.',
 true, true, true, 40)
on conflict (code) do update set
  name = excluded.name, guarantee = excluded.guarantee,
  rebuilt_from_empty = excluded.rebuilt_from_empty,
  is_long_lived = excluded.is_long_lived,
  holds_real_data = excluded.holds_real_data, seq = excluded.seq;

-- ── §16.5 continuity commitments, and the drills that prove them ────────────

create table if not exists erp_meta.continuity_commitment (
  code                text primary key,
  title               text not null,
  commitment          text not null,
  drill_cadence_days  integer,
  derived_from        text not null,
  seq                 integer not null,
  registered_at       timestamptz not null default now(),
  constraint continuity_cadence_positive
    check (drill_cadence_days is null or drill_cadence_days > 0)
);

comment on table erp_meta.continuity_commitment is
  'Specification v1.2 §16.5 and §9.2. What the platform commits to on backup, '
  'restore and continuity, and how often each is to be proved. A commitment '
  'with a cadence and no drill is what §16.5 calls a hope.';

insert into erp_meta.continuity_commitment
  (code, title, commitment, drill_cadence_days, derived_from, seq) values
('pitr', 'Point-in-time recovery',
 'Continuous backup with point-in-time recovery to the granularity stated in §9.2.',
 90, 'v1.2 §16.5, §9.2', 10),
('restore_drill', 'Restore proved by drill',
 'A scheduled restore into an isolated environment, verified by running the invariant assertions against the restored data.',
 90, 'v1.2 §16.5', 20),
('per_tenant_restore', 'Per-tenant restore',
 'One organisation can be restored without affecting another, because a shared-instance restore that requires downtime for everyone is not a usable remedy for one organisation''s mistake.',
 180, 'v1.2 §16.5', 30),
('host_portability', 'Host portability',
 'A single bootstrap script states everything the platform expects of its host — extensions, roles, the identity function — so the database is portable rather than bound to one provider by accident.',
 null, 'v1.2 §16.2, §16.5', 40)
on conflict (code) do update set
  title = excluded.title, commitment = excluded.commitment,
  drill_cadence_days = excluded.drill_cadence_days,
  derived_from = excluded.derived_from, seq = excluded.seq;

create table if not exists erp_meta.restore_drill (
  id                    uuid primary key default gen_random_uuid(),
  commitment_code       text not null references erp_meta.continuity_commitment(code),
  started_at            timestamptz not null default now(),
  finished_at           timestamptz,
  restored_from         text not null,
  restored_to           text not null,
  -- §16.5: "verified by running the invariant assertions against the restored
  -- data". A drill that restored bytes and checked nothing proves the backup
  -- was readable, which is not the claim being made.
  assertions_run        text[] not null default '{}',
  assertions_passed     integer,
  assertions_failed     integer,
  outcome               text not null,
  tenant_scope          text,
  note                  text,
  constraint restore_drill_outcome_known
    check (outcome in ('in_progress','passed','failed')),
  constraint restore_drill_passed_ran_assertions
    check (outcome <> 'passed'
           or (cardinality(assertions_run) > 0
               and coalesce(assertions_failed, 0) = 0
               and finished_at is not null)),
  constraint restore_drill_failed_says_so
    check (outcome <> 'failed' or coalesce(btrim(note), '') <> ''),
  constraint restore_drill_finished_after_start
    check (finished_at is null or finished_at >= started_at)
);

create index if not exists restore_drill_by_commitment
  on erp_meta.restore_drill (commitment_code, started_at desc);

comment on table erp_meta.restore_drill is
  'Specification v1.2 §16.5: "Restore is proved by drill, not by log ... A '
  'backup that has never been restored is a hope." A drill may only be recorded '
  'as passed if it ran assertions against the restored data and none failed.';

comment on constraint restore_drill_passed_ran_assertions on erp_meta.restore_drill is
  '§16.5 verifies a restore "by running the invariant assertions against the '
  'restored data". A drill that restored bytes and checked nothing proves the '
  'backup was readable, which is a smaller claim than the one being made.';

-- ── Reading the position ────────────────────────────────────────────────────

create or replace function erp.continuity_report()
returns table(commitment_code text, title text, cadence_days integer,
              last_drill timestamptz, days_since integer, state text)
language sql
stable
security definer
set search_path = ''
as $$
  select c.code, c.title, c.drill_cadence_days,
         d.started_at,
         case when d.started_at is null then null
              else extract(day from now() - d.started_at)::integer end,
         case
           when c.drill_cadence_days is null then 'no drill required'
           when d.started_at is null then 'never drilled'
           when extract(day from now() - d.started_at) > c.drill_cadence_days
             then 'overdue'
           else 'proved'
         end
    from erp_meta.continuity_commitment c
    left join lateral (
      select r.started_at from erp_meta.restore_drill r
       where r.commitment_code = c.code and r.outcome = 'passed'
       order by r.started_at desc limit 1) d on true
   order by c.seq
$$;

comment on function erp.continuity_report is
  'Specification v1.2 §16.5. What is proved, what is overdue, and what has never '
  'been drilled at all — the last being the state §16.5 calls a hope. A report '
  'rather than an assertion, because a build from empty has no drills by '
  'construction and a check that always failed would be turned off within a '
  'week.';

-- ── The assertion ───────────────────────────────────────────────────────────

create or replace function erp.release_integrity_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- §16.1: every tier states what it guarantees.
  select 'an environment tier states no guarantee', t.code, t.name
    from erp_ref.environment_tier t
   where coalesce(btrim(t.guarantee), '') = ''

  union all

  -- §16.1: "If it cannot be rebuilt from nothing, it is not an environment."
  select 'an environment tier cannot be rebuilt from nothing', t.code,
         'then by §16.1 it is not an environment'
    from erp_ref.environment_tier t
   where not t.rebuilt_from_empty

  union all

  -- §16.5: a commitment with a cadence is one somebody has to prove; a
  -- commitment with neither cadence nor a reason to lack one is a sentence.
  select 'a continuity commitment names no source clause', c.code, c.title
    from erp_meta.continuity_commitment c
   where coalesce(btrim(c.derived_from), '') = ''

  union all

  -- §16.5: a drill claiming to have passed without running assertions. Also a
  -- constraint; checked here because a row predating the constraint would
  -- still be here, and because this is the finding worth reading.
  select 'a restore drill passed without running assertions', d.id::text,
         d.restored_from || ' → ' || d.restored_to
    from erp_meta.restore_drill d
   where d.outcome = 'passed'
     and (cardinality(d.assertions_run) = 0 or coalesce(d.assertions_failed, 0) > 0)

  union all

  -- A drill naming a commitment that has gone.
  select 'a restore drill names a commitment that does not exist',
         d.id::text, d.commitment_code
    from erp_meta.restore_drill d
   where not exists (select 1 from erp_meta.continuity_commitment c
                      where c.code = d.commitment_code)

  order by 1, 2
$$;

comment on function erp.release_integrity_report is
  'Specification v1.2 Part 16. Read by erp.assert_release_integrity().';

create or replace function erp.assert_release_integrity()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text; v_tiers integer; v_commitments integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.release_integrity_report();

  if v_count > 0 then
    raise exception 'ERPWARE_RELEASE_INTEGRITY: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  select count(*) into v_tiers from erp_ref.environment_tier;
  select count(*) into v_commitments from erp_meta.continuity_commitment;
  return format('release: %s tier(s) rebuildable from nothing, %s continuity commitment(s)',
                v_tiers, v_commitments);
end;
$$;

comment on function erp.assert_release_integrity is
  'Fails where a tier states no guarantee or cannot be rebuilt from nothing, '
  'where a continuity commitment names no source clause, or where a restore '
  'drill claims to have passed without running assertions against the restored '
  'data.';

-- ── Registration ────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_ref','environment_tier','product_content',
   'Part 16 §16.1. The environment ladder and what each tier guarantees.'),
  ('erp_meta','continuity_commitment','platform_internal',
   'Part 16 §16.5. What the platform commits to on backup, restore and continuity.'),
  ('erp_meta','restore_drill','platform_internal',
   'Part 16 §16.5. The proof that a backup restores, which a log cannot give.')
on conflict (schema_name, table_name) do nothing;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
('erp','continuity_report','Reads erp_meta.continuity_commitment and erp_meta.restore_drill, which are platform_internal and unreachable from a session role. Returns platform-wide continuity state, which belongs to no tenant and names no tenant data.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('release_integrity', 'Release and continuity sound', 'assertion', 'platform',
   'erp', 'assert_release_integrity', '',
   'release_integrity_report', '',
   'Part 16''s ladder and continuity commitments: every tier rebuildable from '
   'nothing, every commitment traced to the clause it comes from, and no '
   'restore drill claiming to have passed without running the assertions §16.5 '
   'requires against the restored data.',
   true, 58),
  -- detail_function is NULL, not '': erp.assert_diagnostics_registered() reads
  -- an empty string as a promise of a detail view and then cannot find
  -- "erp." — which it said so, on the first rebuild from empty. A report IS
  -- its own detail.
  ('continuity', 'Continuity drills', 'report', 'platform',
   'erp', 'continuity_report', '', null, '',
   'What has been proved by drill, what is overdue, and what has never been '
   'restored at all — which §16.5 calls a hope rather than a backup.',
   false, 59)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

insert into erp_ref.resource (key, locale, value, description) values
('continuity.never_drilled', 'en', 'Never restored',
 '§16.5: a backup that has never been restored is a hope.'),
('continuity.overdue', 'en', 'Restore drill overdue',
 '§16.5: proved by drill on a stated cadence, not by the existence of a backup.')
on conflict (key, locale) do update set value = excluded.value;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_release_integrity();
