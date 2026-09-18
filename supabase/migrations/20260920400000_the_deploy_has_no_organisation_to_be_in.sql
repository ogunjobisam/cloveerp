set lock_timeout = '30s';

-- =============================================================================
-- 20260920400000  The deploy has no organisation to be in
-- -----------------------------------------------------------------------------
-- The deploy went green and the demonstration did not move. The step that
-- brings it up to date failed, and only the log said so — it is deliberately
-- non-fatal, which is why the deploy passed and why anyone could read what
-- happened:
--
--   CONTEXT:  PL/pgSQL function erp.require_tenant_id() line 7 at RAISE
--     PL/pgSQL function erp.allocate_number(...) line 4
--     SQL statement "select * from erp.allocate_number('ledger:' || l.id::text, …)"
--     PL/pgSQL function erp.journal_number_for(uuid,date) line 11
--     SQL statement "update erp.journal set journal_number = …"
--     PL/pgSQL function erp.number_journal_on_commit() line 11
--
-- ── WHAT ACTUALLY HAPPENED ───────────────────────────────────────────────────
--
-- erp.journal carries three constraint triggers that are INITIALLY DEFERRED —
-- the journal number, the journal balance and the journal-line balance — so
-- they do not fire when a row is written. They fire at COMMIT. Numbering a
-- journal reads the organisation's numbering rule, which needs
-- erp.require_tenant_id().
--
-- erp.catch_up_demonstrations() ended with
--
--   perform set_config('request.jwt.claims', '', true);
--
-- one statement before it returned: tidy, and exactly wrong. It put the context
-- back before the deferred triggers had fired, so when the transaction went to
-- commit, thousands of journal rows asked which organisation they belonged to
-- and the session had stopped being able to answer. On a live database the
-- catching up is thousands of journals; on an empty build it is none, so
-- nothing was queued and the commit had nothing to ask.
--
-- ── THE FOURTH TIME, AND THE SAME SENTENCE ───────────────────────────────────
--
-- The build's green is evidence about the build, not about production, whenever
-- the two push different amounts of work through one statement. This is that
-- shape again, with a new face: the suite that proves the routine establishes
-- its own session and keeps it for the whole fixture, so the routine has never
-- once been asked to work on a connection that arrived with nothing set. The
-- deploy's connection is exactly that. It is also the shape this repository
-- already learned from Edge Function calls, which arrive with no organisation
-- context and made a coalesce(p, require_tenant_id()) fallback evaluate anyway:
-- TEST FROM A BARE CONNECTION, BECAUSE THAT IS WHAT THE DEPLOY IS.
--
-- So this migration is half of the fix and supabase/ci/demonstration_catch_up.sh
-- is the other half: it builds a demonstration, opens A NEW CONNECTION with
-- nothing set on it, and calls the routine there, which is precisely what
-- deploy.yml does and precisely what nothing in the build did before.
--
-- ── WHAT THE CONTEXT ACTUALLY IS ─────────────────────────────────────────────
--
-- Stated explicitly rather than left to impersonation, because "it worked when
-- I signed in as somebody" is what made this invisible. erp.require_tenant_id()
-- calls erp.current_tenant_id(), which answers from the first of:
--
--   1. erp.principal_context() — the person the JWT subject resolves to, and
--      the organisation on their record. This is what impersonation sets, and
--      it is what the loop below still sets, because the work itself must be
--      done BY somebody: erp.authorise() needs a principal, not a tenant.
--   2. erp.job_tenant_id, but only when erp.session_is_trusted() — that is,
--      when the connected role has rolbypassrls. The deploy connects as
--      postgres, which does; the application's role does not. So on the
--      deploy's connection, and only there, this is a second answer to the
--      same question.
--
-- Both are set now, together, for each organisation in turn. Neither is cleared
-- until the deferred queue is provably empty.
--
-- ── AND THE QUEUE IS DRAINED WHERE THE ANSWER STILL EXISTS ───────────────────
--
-- set constraints all immediate, inside the loop, after each organisation's
-- work and while that organisation's context is still the one in force. That is
-- the real repair: it makes the numbering happen under the organisation whose
-- journals are being numbered, rather than under whatever happened to be set at
-- commit — which matters the moment there is more than one demonstration, and
-- would have been a silent mis-numbering rather than a loud refusal. A second
-- drain follows the loop, so that the invariant the old code broke is stated in
-- the code: nothing is left to fire when the context goes.
--
-- It is also what the suite has always done after seeding (20260918100000 and
-- every demonstration suite since). The suite was right and the routine was
-- not.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- erp.demonstration_catch_up() is untouched: the fault was never in what it
-- does, only in the session it was asked to do it in. Its twelve-case suite is
-- untouched and still runs from the catalogue on every build.
--
-- Cost on a real database: this file replaces one routine and asserts the
-- schema. Timed on live inside a rolled-back transaction, the four assertions
-- and the reconciliation below came to 4.6 s against three organisations and a
-- year of trading, of which the reconciliation was 1.7 s. No suite is run from
-- here (20260920310000).
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The caller, told what organisation it is in and asked to finish saying so
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.catch_up_demonstrations(p_code text default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  -- What erp.demonstration_catch_up() needs of the person it acts as. An
  -- organisation whose administrator does not hold all of these is left alone
  -- rather than acted on by the deploy's own role, which holds nothing and
  -- would prove nothing.
  v_needs  constant text[] := array[
    'master_data.write', 'administration.configure', 'administration.promote',
    'finance.post', 'finance.close_period', 'procurement.match'];
  t        record;
  v_admin  uuid;
  v_out    jsonb := '[]'::jsonb;
begin
  for t in select tn.id, tn.code from erp.tenant tn
            where tn.code like 'demo-%'
              and tn.status = 'active'::erp.tenant_status
              and (p_code is null or tn.code = p_code)
            order by tn.code
  loop
    begin
      v_admin := null;

      select u.auth_user_id into v_admin
        from erp.app_user u
       where u.tenant_id = t.id
         and u.kind = 'person'::erp.principal_kind
         and u.status = 'active'::erp.principal_status
         and u.auth_user_id is not null
         and (select count(distinct rp.permission_code)
                from erp.user_role ur
                join erp.role r
                  on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                 and r.status = 'active'::erp.record_status
                join erp.role_permission rp
                  on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
               where ur.tenant_id = u.tenant_id
                 and ur.app_user_id = u.id
                 and (ur.valid_from is null or ur.valid_from <= current_date)
                 and (ur.valid_to is null or ur.valid_to >= current_date)
                 and rp.permission_code = any (v_needs)) = array_length(v_needs, 1)
       order by u.created_at, u.id
       limit 1;

      if v_admin is null then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'organisation', t.code,
          'notes', jsonb_build_array(format(
            'Nobody signed in there holds all of %s, so it was left as it was.',
            array_to_string(v_needs, ', ')))));
        continue;
      end if;

      -- The person, because the work is authorised to somebody and
      -- erp.authorise() reads a principal. Transaction-local, the way
      -- supabase/ci/close_month.sh and supabase/ci/seed_demo.sql do it.
      perform set_config('request.jwt.claims',
                         json_build_object('sub', v_admin)::text, true);

      -- And the organisation, said outright. On a connection whose role has
      -- rolbypassrls — which the deploy's has and the application's has not —
      -- this answers erp.current_tenant_id() by itself, so a trigger that
      -- reaches for an organisation still finds one even where no person is
      -- resolvable.
      perform set_config('erp.job_tenant_id', t.id::text, true);

      -- The context that administrator actually resolves to is the one this
      -- writes in. Somebody who belongs to two organisations would otherwise
      -- carry this work into whichever one the database picked, and a
      -- demonstration repair has no business anywhere it was not aimed.
      if erp.current_tenant_id() is distinct from t.id then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'organisation', t.code,
          'notes', jsonb_build_array(
            'Signing in as its administrator resolves to another organisation, so nothing was done there.')));
        continue;
      end if;

      v_out := v_out || jsonb_build_array(erp.demonstration_catch_up());

      -- Here, and not at commit. erp.journal's number and both balance checks
      -- are constraint triggers that are initially deferred, so a journal
      -- written above is numbered at the end of the transaction — by which time
      -- this loop has moved on and, on the old code, had put the context back.
      -- Draining the queue while this organisation's context is still in force
      -- numbers its journals under it, which is the answer whether there is one
      -- demonstration or four.
      set constraints all immediate;

    exception when others then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'organisation', t.code,
        'notes', jsonb_build_array(format(
          'It was left as it was, because bringing it up to date refused. %s', sqlerrm))));
    end;
  end loop;

  -- The invariant the first version broke, written down: nothing may be left to
  -- fire when the context goes. Cheap when the loop has already drained, and
  -- the only thing standing between a future caller and the same failure.
  set constraints all immediate;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  return v_out;
end;
$$;

comment on function erp.catch_up_demonstrations(text) is
  'Brings every demonstration organisation up to today, as an administrator of '
  'each and in that organisation''s own context, and answers with what each one '
  'did. Drains the deferred constraint queue before it gives the context back, '
  'because erp.journal is numbered at commit. Raises nothing: an organisation '
  'that refuses is reported and the next one is tried. The deploy calls it with '
  'no argument, over a connection that arrives with nothing set.';

revoke all on function erp.catch_up_demonstrations(text) from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- ── Proved ───────────────────────────────────────────────────────────────────
--
-- Not here. What this file changes cannot be proved by a statement in it: the
-- claim is about a session that arrives with nothing set, and this file is
-- running in one that has. supabase/ci/demonstration_catch_up.sh is the proof,
-- and it is a build step rather than an assertion for exactly that reason —
-- it needs a second connection, and a migration has only the one it is in.
--
-- What is below is the ordinary schema proof, and it is all that belongs here.

select erp.assert_whole_database_reconciles();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
