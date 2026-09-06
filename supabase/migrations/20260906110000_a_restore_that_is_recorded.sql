-- A restore that is recorded.
--
-- D28 says a backup that has never been restored is a hope, and the product
-- has said so about itself since 20260904300000: erp.continuity_report() read
-- "never drilled" for every commitment, and restore_drill.yml — a working
-- quarterly drill that dumps live, restores it into an isolated PostgreSQL of
-- the live major version and runs the console and the whole-database
-- reconciliation against what came back — could not write its result, because
-- erp_meta.restore_drill had no writer outside its own test suite. The drill
-- ran; the register did not know.
--
-- This file gives the register its writers and the drill its second half.
--
-- The writer. erp.record_restore_drill() takes what a drill knows — the
-- commitment, when it started and finished, what was restored from and into,
-- the assertions it ran and how many passed — and refuses a hollow one by name
-- before the constraint would: a drill that passed without running anything,
-- an outcome the register does not have, a per-organisation drill that names
-- no organisation. Only a trusted session may call it (the drill workflow
-- records over the owner connection, as deploy.yml proves the live database);
-- a person records a drill done by hand through erp_platform_record_restore_drill,
-- which runs as definer behind the operator role and names who recorded it.
-- Every record lands in the platform audit trail.
--
-- The second half. §16.5's per-organisation restore had no mechanism: the
-- commitment (cadence 180 days) was a sentence. erp.isolate_tenant() turns a
-- restored copy of the whole platform into a validation environment holding
-- exactly one organisation, by purging every other one through the same
-- window the scheduled purge uses. It refuses unless the caller names the
-- database it is in, that database has been declared a restore target in the
-- same transaction, and the database is not called `postgres` — which is what
-- the live Supabase database is always called and a copy never is. The drill
-- then re-proves the lone organisation and records per_tenant_restore.
--
-- Two doors regated on the way. erp_platform_continuity() and
-- erp_platform_support_access() were STABLE SQL wrappers with no gate at all,
-- granted to every signed-in user; the continuity screen every organisation's
-- administrator reads calls them, so they authorise administration.read now,
-- which is what makes them volatile and puts them on the write allow-list.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The record
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_meta.restore_drill add column if not exists recorded_by text;
comment on column erp_meta.restore_drill.recorded_by is
  'Who or what recorded the drill: the workflow, or the platform staff member who recorded one done by hand.';

create or replace function erp.record_restore_drill(
  p_commitment_code   text,
  p_started_at        timestamptz,
  p_finished_at       timestamptz,
  p_restored_from     text,
  p_restored_to       text,
  p_assertions_run    text[],
  p_assertions_passed integer,
  p_assertions_failed integer,
  p_outcome           text,
  p_tenant_scope      text default null,
  p_note              text default null,
  p_recorded_by       text default 'workflow')
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not record a restore drill', current_user
      using errcode = '42501',
            hint = 'The drill workflow records over the owner connection; a person records a drill done by hand through erp_platform_record_restore_drill.';
  end if;

  if p_outcome is null or p_outcome not in ('passed', 'failed') then
    raise exception 'CLOVEERP_DRILL_OUTCOME_UNKNOWN: a drill is recorded as passed or failed, not %', coalesce(p_outcome, 'null')
      using errcode = '22023',
            hint = 'Record passed when every assertion passed, failed with a note saying what did not.';
  end if;

  if not exists (select 1 from erp_meta.continuity_commitment c where c.code = p_commitment_code) then
    raise exception 'CLOVEERP_UNKNOWN_COMMITMENT: % is not a continuity commitment', p_commitment_code
      using errcode = '23503',
            hint = 'The commitments are the rows of erp_meta.continuity_commitment: restore_drill, per_tenant_restore, pitr.';
  end if;

  if p_commitment_code = 'per_tenant_restore' and coalesce(btrim(p_tenant_scope), '') = '' then
    raise exception 'CLOVEERP_DRILL_NEEDS_SCOPE: a per-organisation restore names the organisation it restored'
      using errcode = '22023',
            hint = 'Pass the organisation code as p_tenant_scope.';
  end if;

  if p_outcome = 'passed'
     and (coalesce(cardinality(p_assertions_run), 0) = 0 or coalesce(p_assertions_failed, 0) > 0) then
    raise exception 'CLOVEERP_DRILL_PROVED_NOTHING: a drill passes by running assertions against the restored data, and every one of them passing'
      using errcode = '23514',
            hint = 'Record what ran and what failed; a drill that ran nothing is recorded as failed, with a note.';
  end if;

  if p_outcome = 'failed' and coalesce(btrim(p_note), '') = '' then
    raise exception 'CLOVEERP_DRILL_FAILED_SAYS_WHY: a failed drill carries a note saying what failed'
      using errcode = '23514',
            hint = 'Pass the failing assertion or the error as p_note.';
  end if;

  insert into erp_meta.restore_drill (
    commitment_code, started_at, finished_at, restored_from, restored_to,
    assertions_run, assertions_passed, assertions_failed, outcome, tenant_scope, note, recorded_by)
  values (
    p_commitment_code, coalesce(p_started_at, now()), coalesce(p_finished_at, now()),
    p_restored_from, p_restored_to,
    coalesce(p_assertions_run, '{}'::text[]), p_assertions_passed, p_assertions_failed,
    p_outcome, nullif(btrim(p_tenant_scope), ''), nullif(btrim(p_note), ''), p_recorded_by)
  returning id into v_id;

  -- The platform's own trail. A drill has no organisation and, from the
  -- workflow, no person; the purge sweep writes its rows the same way.
  insert into erp_meta.platform_audit (actor_email, actor_role, action, target, reason, detail)
  values ('system', 'platform', 'platform.restore_drill_recorded', v_id::text, nullif(btrim(p_note), ''),
          jsonb_build_object('commitment', p_commitment_code, 'outcome', p_outcome,
                             'tenant_scope', nullif(btrim(p_tenant_scope), ''), 'recorded_by', p_recorded_by,
                             'assertions', coalesce(cardinality(p_assertions_run), 0),
                             'restored_from', p_restored_from, 'restored_to', p_restored_to));

  return v_id;
end;
$$;
revoke all on function erp.record_restore_drill(text, timestamptz, timestamptz, text, text, text[], integer, integer, text, text, text, text)
  from public, anon, authenticated;
comment on function erp.record_restore_drill is
  'Records a restore drill in erp_meta.restore_drill from a trusted session; refuses a hollow one by name.';

-- A drill done by hand, recorded by the person who did it.
drop function if exists public.erp_platform_record_restore_drill(text, timestamptz, timestamptz, text, text, text[], integer, integer, text, text, text);
create function public.erp_platform_record_restore_drill(
  p_commitment_code   text,
  p_started_at        timestamptz,
  p_finished_at       timestamptz,
  p_restored_from     text,
  p_restored_to       text,
  p_assertions_run    text[],
  p_assertions_passed integer,
  p_assertions_failed integer,
  p_outcome           text,
  p_tenant_scope      text default null,
  p_note              text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v    erp_meta.platform_staff;
  v_id uuid;
begin
  v := erp_meta.require_platform('operator');
  v_id := erp.record_restore_drill(
    p_commitment_code, p_started_at, p_finished_at, p_restored_from, p_restored_to,
    p_assertions_run, p_assertions_passed, p_assertions_failed, p_outcome,
    p_tenant_scope, p_note, v.email);
  perform erp_meta.platform_log(v, 'platform.restore_drill_recorded_by_hand', null, v_id::text, p_note,
    jsonb_build_object('commitment', p_commitment_code, 'outcome', p_outcome));
  return jsonb_build_object(
    'drill_id', v_id,
    'commitment', p_commitment_code,
    'state', (select r.state from erp.continuity_report() r where r.commitment_code = p_commitment_code));
end;
$$;
revoke all on function public.erp_platform_record_restore_drill(text, timestamptz, timestamptz, text, text, text[], integer, integer, text, text, text) from public, anon;
grant execute on function public.erp_platform_record_restore_drill(text, timestamptz, timestamptz, text, text, text[], integer, integer, text, text, text) to authenticated, service_role;
insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_record_restore_drill',
   'Writes erp_meta.restore_drill, which is platform-internal and unreachable by any session; gated on erp_meta.require_platform(operator) and every record lands in erp_meta.platform_audit with the recorder''s email.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_record_restore_drill', 'erp_meta.require_platform',
   'Records a restore drill done by hand; platform operators only, audited.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- What the register holds, readable from the console.
create or replace function erp.restore_drill_report()
returns table(id uuid, commitment_code text, started_at timestamptz, finished_at timestamptz,
              outcome text, tenant_scope text, assertions integer, failed integer,
              recorded_by text, restored_from text, restored_to text, note text)
language sql
stable
security definer
set search_path = ''
as $$
  select d.id, d.commitment_code, d.started_at, d.finished_at, d.outcome, d.tenant_scope,
         cardinality(d.assertions_run), d.assertions_failed, d.recorded_by,
         d.restored_from, d.restored_to, d.note
    from erp_meta.restore_drill d
   order by d.started_at desc
   limit 200
$$;
revoke all on function erp.restore_drill_report() from public, anon, authenticated;
insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'restore_drill_report',
   'Reads erp_meta.restore_drill, which is platform-internal; the platform console runs it through erp_platform_run_check, which is gated on platform staff.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('restore_drills', 'Restore drills recorded', 'report', 'platform',
   'restore_drill_report', '', null, '',
   'Every restore drill the register holds: what was restored where, what ran against it, and who recorded it. A commitment reads proved only from a passed row here.',
   false, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, blurb = excluded.blurb;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. One organisation, restored alone
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.isolate_tenant(p_tenant_code text, p_confirm_database text)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_keep    erp.tenant%rowtype;
  t         record;
  v_removed text[] := '{}';
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not isolate an organisation', current_user
      using errcode = '42501',
            hint = 'The restore drill runs this over the owner connection of a restored copy; nothing else does.';
  end if;

  if p_confirm_database is distinct from current_database() then
    raise exception 'CLOVEERP_RESTORE_TARGET_NOT_CONFIRMED: this database is %, not %', current_database(), coalesce(p_confirm_database, 'null')
      using errcode = '22023',
            hint = 'Type the name of the database you are in, as the purge door makes you type the organisation code.';
  end if;

  if coalesce(current_setting('erp.restore_target', true), '') <> current_database() then
    raise exception 'CLOVEERP_NOT_A_RESTORE_TARGET: % has not been declared a restore target in this transaction', current_database()
      using errcode = '42501',
            hint = 'In the same transaction: select set_config(''erp.restore_target'', current_database(), true). The setting is transaction-local by construction.';
  end if;

  if current_database() = 'postgres' then
    raise exception 'CLOVEERP_RESTORE_TARGET_LOOKS_LIVE: a database called postgres is what the live project is called; a restored copy never is'
      using errcode = '42501',
            hint = 'Restore into a database with its own name before isolating an organisation in it.';
  end if;

  select * into v_keep from erp.tenant where code = p_tenant_code;
  if v_keep.id is null then
    raise exception 'CLOVEERP_UNKNOWN_TENANT: no organisation % in this database', p_tenant_code
      using errcode = '23503',
            hint = 'Name an organisation the restored copy holds: select code from erp.tenant.';
  end if;

  -- Every other organisation goes through the purge window, one at a time,
  -- which is the only route that takes an organisation's rows with it.
  for t in select tn.id, tn.code from erp.tenant tn where tn.id <> v_keep.id order by tn.code loop
    perform erp.begin_tenant_purge(t.id);
    delete from erp.tenant where id = t.id;
    perform erp.end_tenant_purge();
    v_removed := v_removed || t.code;
  end loop;

  insert into erp_meta.platform_audit (actor_email, actor_role, action, tenant_id, tenant_code, target, reason, detail)
  values ('system', 'platform', 'platform.tenant_isolated', v_keep.id, v_keep.code, current_database(),
          'per-organisation restore drill',
          jsonb_build_object('kept', v_keep.code, 'removed', to_jsonb(v_removed), 'database', current_database()));

  return jsonb_build_object('kept', v_keep.code, 'removed', to_jsonb(v_removed),
                            'organisations_remaining', (select count(*) from erp.tenant));
end;
$$;
revoke all on function erp.isolate_tenant(text, text) from public, anon, authenticated;
comment on function erp.isolate_tenant is
  'In a restored copy declared a restore target, purges every organisation but one, so the per-organisation restore commitment can be drilled. Refuses anywhere else.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Two doors that had no gate
-- ═════════════════════════════════════════════════════════════════════════════

do $doors$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.erp_platform_continuity()'::regprocedure);
  if position('from erp.continuity_report() r' in v_def) = 0 then
    raise exception 'CLOVEERP_DOOR_UNRECOGNISED: erp_platform_continuity is not the body this migration regates';
  end if;
  v_def := pg_get_functiondef('public.erp_platform_support_access()'::regprocedure);
  if position('from erp.support_access_report() r' in v_def) = 0 then
    raise exception 'CLOVEERP_DOOR_UNRECOGNISED: erp_platform_support_access is not the body this migration regates';
  end if;
end
$doors$;

create or replace function public.erp_platform_continuity()
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform erp.authorise('administration.read');
  return coalesce((select jsonb_agg(to_jsonb(r) order by r.commitment_code) from erp.continuity_report() r), '[]'::jsonb);
end;
$$;
revoke all on function public.erp_platform_continuity() from public, anon;
grant execute on function public.erp_platform_continuity() to authenticated, service_role;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_continuity', 'erp.authorise',
   'A read of the platform''s continuity state for an organisation''s administrator; volatile only for the access-log row erp.authorise() writes; carries no organisation data.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

create or replace function public.erp_platform_support_access()
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform erp.authorise('administration.read');
  return coalesce((select jsonb_agg(to_jsonb(r) order by r.granted_at desc) from erp.support_access_report() r), '[]'::jsonb);
end;
$$;
revoke all on function public.erp_platform_support_access() from public, anon;
grant execute on function public.erp_platform_support_access() to authenticated, service_role;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_support_access', 'erp.authorise',
   'The support-access grants an organisation''s administrator may see; erp.support_access_report() is scoped to the caller''s organisation; volatile only for the access-log row erp.authorise() writes.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. D28 bound to what it now has
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.product_decision_check
   set note = 'Recovery is recorded: restore_drill.yml writes erp_meta.restore_drill through erp.record_restore_drill() and erp.continuity_report() reads proved from it; a hollow record is a finding here.'
 where decision_code = 'D28' and schema_name = 'erp' and routine_name = 'assert_release_integrity';
insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note)
values ('D28', 'erp_test', 'assert_recovery_record_suite',
        'The writer refuses a drill that proved nothing, records who recorded it, and one organisation can be restored alone in a declared restore target.')
on conflict do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.recovery_record_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_id       uuid;
  v_id2      uuid;
  v_res      jsonb;
  v_ok       boolean;
  v_msg      text;
  v_state    text;
  v_support  uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
  v_left     integer;
  v_kept     text;
  v_skipped  boolean := false;
  v_iso      jsonb;
begin
  insert into erp_meta.continuity_commitment (code, title, commitment, drill_cadence_days, derived_from, seq)
  values ('zztest_recovery', 'Suite recovery commitment', 'A commitment the recovery suite drills.', 30, 'suite', 9001);

  -- 1
  v_id := erp.record_restore_drill('zztest_recovery', now() - interval '10 minutes', now(),
            'pg_dump of nowhere', 'suite database', array['erp.assert_isolation', 'erp.assert_whole_database_reconciles'],
            2, 0, 'passed', null, 'suite', 'suite');
  select r.state into v_state from erp.continuity_report() r where r.commitment_code = 'zztest_recovery';
  case_name := 'a trusted session records a passed drill and the commitment reads proved';
  passed := v_id is not null and v_state = 'proved';
  detail := format('drill %s; state %s', v_id, coalesce(v_state, 'none'));
  return next;

  -- 2
  case_name := 'the record carries the assertions it ran and who recorded it';
  passed := exists (select 1 from erp_meta.restore_drill d
                     where d.id = v_id and cardinality(d.assertions_run) = 2 and d.assertions_failed = 0
                       and d.recorded_by = 'suite' and d.finished_at >= d.started_at);
  detail := (select format('%s assertion(s), %s failed, recorded by %s', cardinality(d.assertions_run), d.assertions_failed, d.recorded_by)
               from erp_meta.restore_drill d where d.id = v_id);
  return next;

  -- 3
  delete from erp_meta.restore_drill where id = v_id;
  v_id2 := erp.record_restore_drill('zztest_recovery', now() - interval '10 minutes', now(),
             'pg_dump of nowhere', 'suite database', array['erp.assert_isolation'], 0, 1, 'failed', null,
             'erp.assert_isolation refused: a policy was missing', 'suite');
  select r.state into v_state from erp.continuity_report() r where r.commitment_code = 'zztest_recovery';
  case_name := 'a failed drill is recorded with its note and the commitment does not read proved';
  passed := v_id2 is not null and v_state = 'never drilled'
        and exists (select 1 from erp_meta.restore_drill d where d.id = v_id2 and d.outcome = 'failed' and d.note like 'erp.assert_isolation%');
  detail := format('state after a failed drill: %s', coalesce(v_state, 'none'));
  return next;

  -- 4
  case_name := 'a passed drill that ran nothing is refused by name';
  begin
    perform erp.record_restore_drill('zztest_recovery', now(), now(), 'x', 'y', '{}'::text[], 0, 0, 'passed');
    v_ok := false; v_msg := 'a drill that ran nothing was recorded as passed';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_DRILL_PROVED_NOTHING%'; v_msg := left(sqlerrm, 90);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  -- 5
  case_name := 'an outcome the register does not have is refused';
  begin
    perform erp.record_restore_drill('zztest_recovery', now(), now(), 'x', 'y', array['a'], 1, 0, 'probably');
    v_ok := false; v_msg := 'an unknown outcome was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_DRILL_OUTCOME_UNKNOWN%'; v_msg := left(sqlerrm, 90);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  -- 6
  case_name := 'a per-organisation drill must name its organisation';
  begin
    perform erp.record_restore_drill('per_tenant_restore', now(), now(), 'x', 'y', array['a'], 1, 0, 'passed');
    v_ok := false; v_msg := 'a per-organisation drill with no organisation was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_DRILL_NEEDS_SCOPE%'; v_msg := left(sqlerrm, 90);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  -- 7
  case_name := 'an untrusted session may not record a drill';
  begin
    execute 'set local role authenticated';
    perform erp.record_restore_drill('zztest_recovery', now(), now(), 'x', 'y', array['a'], 1, 0, 'passed');
    execute 'reset role';
    v_ok := false; v_msg := 'an untrusted session recorded a drill';
  exception when others then
    execute 'reset role';
    v_ok := sqlerrm like 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION%' or sqlstate = '42501';
    v_msg := left(sqlerrm, 90);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  -- 8
  case_name := 'the platform audit trail names the drill';
  passed := exists (select 1 from erp_meta.platform_audit a
                     where a.action = 'platform.restore_drill_recorded' and a.target = v_id2::text
                       and a.actor_email = 'system' and a.detail ->> 'commitment' = 'zztest_recovery');
  detail := format('%s audit row(s) for drill %s',
                   (select count(*) from erp_meta.platform_audit a where a.target = v_id2::text), v_id2);
  return next;

  -- 9 and 10: the console door, as support and as an operator.
  insert into auth.users (id, email) values (v_support, 'support@zzrecovery.test'), (v_operator, 'operator@zzrecovery.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('support@zzrecovery.test', v_support, 'Recovery Support', 'support'),
         ('operator@zzrecovery.test', v_operator, 'Recovery Operator', 'operator');

  perform set_config('request.jwt.claims', json_build_object('sub', v_support)::text, true);
  case_name := 'the console door refuses support-level staff';
  begin
    perform public.erp_platform_record_restore_drill('zztest_recovery', now(), now(), 'x', 'y', array['a'], 1, 0, 'passed');
    v_ok := false; v_msg := 'support recorded a drill';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 90);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  perform set_config('request.jwt.claims', json_build_object('sub', v_operator)::text, true);
  v_res := public.erp_platform_record_restore_drill('zztest_recovery', now() - interval '5 minutes', now(),
             'a dump on a laptop', 'a laptop', array['erp.assert_isolation'], 1, 0, 'passed', null, 'done by hand');
  perform set_config('request.jwt.claims', '', true);
  case_name := 'and accepts an operator, who is named on the record and in the audit trail';
  passed := (v_res ->> 'state') = 'proved'
        and exists (select 1 from erp_meta.restore_drill d where d.id = (v_res ->> 'drill_id')::uuid and d.recorded_by = 'operator@zzrecovery.test')
        and exists (select 1 from erp_meta.platform_audit a where a.action = 'platform.restore_drill_recorded_by_hand'
                       and a.target = v_res ->> 'drill_id' and a.actor_email = 'operator@zzrecovery.test');
  detail := format('door returned %s', v_res::text);
  return next;

  -- 11 and 12: isolation, under a subtransaction that is always undone. The
  -- build's demonstration organisation must survive this suite.
  begin
    perform erp.provision_tenant('zz-iso-a', 'Isolated A', 'admin@zz-iso-a.test', 'Iso Admin A');
    perform erp.provision_tenant('zz-iso-b', 'Isolated B', 'admin@zz-iso-b.test', 'Iso Admin B');

    -- 11a: the database name must be typed.
    begin
      perform erp.isolate_tenant('zz-iso-a', 'somewhere-else');
      v_ok := false; v_msg := 'an untyped database name was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_RESTORE_TARGET_NOT_CONFIRMED%'; v_msg := left(sqlerrm, 80);
    end;
    -- 11b: and the database declared a restore target.
    begin
      perform erp.isolate_tenant('zz-iso-a', current_database());
      v_ok := false; v_msg := v_msg || '; an undeclared restore target was accepted';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_NOT_A_RESTORE_TARGET%'; v_msg := v_msg || ' / ' || left(sqlerrm, 80);
    end;

    if current_database() = 'postgres' then
      v_skipped := true;
    else
      perform set_config('erp.restore_target', current_database(), true);
      v_iso := erp.isolate_tenant('zz-iso-a', current_database());
      select count(*), min(tn.code) into v_left, v_kept from erp.tenant tn;
    end if;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_msg := 'isolation block failed: ' || left(sqlerrm, 120);
      v_ok := false; v_left := null;
    end if;
  end;

  case_name := 'isolating an organisation is refused unless the database is named and declared a restore target';
  passed := v_ok; detail := v_msg;
  return next;

  case_name := 'isolating one organisation leaves exactly that one';
  if v_skipped then
    passed := true;
    detail := 'not run: this database is called postgres, which the isolator refuses by design';
  else
    passed := v_left = 1 and v_kept = 'zz-iso-a' and (v_iso ->> 'organisations_remaining')::integer = 1
          and jsonb_array_length(v_iso -> 'removed') >= 1;
    detail := format('%s organisation(s) left (%s); isolator reported %s', v_left, coalesce(v_kept, 'none'), coalesce(v_iso::text, 'nothing'));
  end if;
  return next;

  -- 13
  case_name := 'the release assertion and the continuity report still hold';
  begin
    perform erp.assert_release_integrity();
    v_ok := (select count(*) from erp.continuity_report()) >= 4; v_msg := 'release integrity green; continuity report answers';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 120);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  -- 14: cleanup, and the proof of it. The audit rows stay: the trail is
  -- append-only, and a suite that could erase its own trace would be a
  -- worse thing to have than three rows naming a suite.
  delete from erp_meta.restore_drill where commitment_code = 'zztest_recovery';
  delete from erp_meta.continuity_commitment where code = 'zztest_recovery';
  delete from erp_meta.platform_staff where email in ('support@zzrecovery.test', 'operator@zzrecovery.test');
  delete from auth.users where id in (v_support, v_operator);
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp_meta.restore_drill d where d.commitment_code = 'zztest_recovery')
        and not exists (select 1 from erp_meta.continuity_commitment c where c.code = 'zztest_recovery')
        and not exists (select 1 from erp_meta.platform_staff s where s.email like '%@zzrecovery.test')
        and not exists (select 1 from erp.tenant tn where tn.code like 'zz-iso-%');
  detail := 'drills, commitment, staff and organisations removed';
  return next;
end;
$$;
revoke all on function erp_test.recovery_record_suite() from public, anon, authenticated;

create or replace function erp_test.assert_recovery_record_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 14;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _recovery_record on commit drop as
    select * from erp_test.recovery_record_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _recovery_record;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_RECOVERY_RECORD_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_RECOVERY_RECORD_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('recovery record: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_recovery_record_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_recovery_record_suite();
select erp_test.assert_release_suite();
select erp_test.assert_incident_operations_suite();
select erp_test.assert_tenant_deletion_suite();
select erp.assert_release_integrity();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_no_dead_configuration();
select erp.assert_scheduler_integrity();
select erp.assert_job_handlers_resolvable();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

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
