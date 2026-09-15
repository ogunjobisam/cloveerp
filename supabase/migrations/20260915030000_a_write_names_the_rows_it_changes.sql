-- =============================================================================
-- A write names the rows it changes
--
-- On 15 September the owner opened Catalogue, Selling setup, chose the
-- organisation that is Clove ERP itself and pressed Use this organisation. The
-- console answered "This did not work. DELETE requires a WHERE clause." and
-- selling could not be set up at all.
--
-- erp.designate_platform_organisation() keeps one row and replaces it:
--
--   delete from erp_meta.platform_organisation;
--
-- The host runs pg-safeupdate, which refuses a DELETE or an UPDATE that names
-- no rows for the roles a request arrives on. The build never sees it: every
-- migration and every suite runs as the owner, where the guard is off, so the
-- statement passed here and was refused there. That is the shape of the bug
-- worth catching, not the one line.
--
--   1. The designation deletes the row it is replacing: every row of a table
--      whose one row belongs to no organisation in particular, said as
--      "where tenant_id is not null", which is what the statement always meant.
--
--   2. erp.unqualified_write_report() reads every routine a request can reach
--      in erp, erp_ref, erp_meta, erp_ai and the public surface, on
--      comment-stripped, string-blanked text, and reports a DELETE or an UPDATE
--      that names no rows. erp.assert_writes_name_their_rows() fails the build
--      for one, and the check is registered so CI and every deploy run it.
--      erp_test routines are not read: a suite runs as the owner, never from a
--      request.
--
--   3. erp_test.unqualified_write_suite() proves the report by planting one,
--      and proves the designation works and can be moved.
-- =============================================================================

-- ── 1. The designation names the row it replaces ─────────────────────────────

do $designate$
declare
  v_sig    constant text := 'erp.designate_platform_organisation(text, text)';
  v_def    text := pg_get_functiondef('erp.designate_platform_organisation(text, text)'::regprocedure);
  v_needle constant text := '  delete from erp_meta.platform_organisation;';
  v_new    constant text := '  -- The one row this replaces (20260915030000). pg-safeupdate refuses a'
                         || E'\n  -- delete that names no rows, and the console is where that shows.'
                         || E'\n  delete from erp_meta.platform_organisation where tenant_id is not null;';
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not clear the designation exactly once as 20260904590000 wrote it', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$designate$;

-- ── 2. The rule ──────────────────────────────────────────────────────────────

create or replace function erp.unqualified_write_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with code as (
    -- Comments removed, then every string blanked, the way
    -- erp.app_gate_report() reads code: a semicolon inside a message is not
    -- the end of a statement, and a table named in one is not a write.
    select p.oid,
           regexp_replace(erp.prosrc_code(p.prosrc), '''(?:[^'']|'''')*''', '''''', 'g') as src
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where (n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')
            or (n.nspname = 'public' and p.proname like 'erp\_%'))
       and p.prokind = 'f'
  ),
  statement as (
    -- The whole statement is the first capture, so the WHERE it may carry is
    -- read from the statement itself rather than from the line it started on.
    select c.oid, m[2] as verb, m[3] as target, m[1] as whole
      from code c, regexp_matches(
             c.src,
             '(\m(delete\s+from|update)\s+((?:erp|erp_ref|erp_meta|erp_ai)\.[a-z_0-9]+)[^;]*;)',
             'gi') m
  )
  select 'a routine changes every row of a table',
         s.oid::regprocedure::text,
         format('%s %s names no rows. The host runs pg-safeupdate, which refuses that for a '
                'request''s role while the build, which runs as the owner, accepts it. Say which '
                'rows, even where that is every row of a table that holds one.',
                lower(split_part(s.verb, ' ', 1)), s.target)
    from statement s
   where s.whole !~* '\mwhere\M'
     -- An UPDATE without SET is a word in a sentence, not a statement.
     and (lower(split_part(s.verb, ' ', 1)) = 'delete' or s.whole ~* '\mset\M')
$$;

revoke all on function erp.unqualified_write_report() from public, anon;

comment on function erp.unqualified_write_report() is
  'Every routine a request can reach whose DELETE or UPDATE names no rows. The '
  'host''s pg-safeupdate refuses those for the roles requests arrive on, and '
  'refuses nothing for the owner, so only a rule like this one sees them before '
  'a customer does.';

create or replace function erp.assert_writes_name_their_rows()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s: %s', r.reference, r.detail), E'\n' order by r.reference)
    into v_count, v_detail
    from erp.unqualified_write_report() r;

  if v_count > 0 then
    raise exception E'CLOVEERP_WRITE_NAMES_NO_ROWS: % routine(s)\n%', v_count, v_detail
      using errcode = 'P0001',
            hint = 'Add a WHERE that says which rows the statement changes, even when it is every row of a table that holds one.';
  end if;

  return format('writes naming their rows: %s routine(s) read', (select count(*) from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')
       or (n.nspname = 'public' and p.proname like 'erp\_%')));
end;
$$;

revoke all on function erp.assert_writes_name_their_rows() from public, anon;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('writes_name_their_rows', 'Every write names the rows it changes',
   'assertion', 'platform', 'erp', 'assert_writes_name_their_rows', '',
   'unqualified_write_report', '',
   'The host refuses a delete or an update that names no rows for the roles requests arrive on, and allows it for the owner the build runs as. Selling could not be set up on 15 September because one statement said no rows, and nothing here had seen it.',
   true, 100)
on conflict (code) do update set
  title = excluded.title, function_name = excluded.function_name,
  detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

-- ── 3. The suite ─────────────────────────────────────────────────────────────

create or replace function erp_test.unqualified_write_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  rp record;
  ow uuid := gen_random_uuid();
  v_code  text := 'zzuw-' || substr(md5(random()::text), 1, 6);
  v_code2 text := 'zzuw2-' || substr(md5(random()::text), 1, 6);
  v_prior erp_meta.platform_organisation;
  v_id    uuid;
  v_n     integer;
  v_ok    boolean;
  v_msg   text;
begin
  return query select 'no routine a request can reach changes every row of a table'::text,
    not exists (select 1 from erp.unqualified_write_report()),
    coalesce((select string_agg(r.reference, ', ') from erp.unqualified_write_report() r), 'none');

  -- The rule sees one when there is one, and says whose it is.
  create or replace function erp_meta.zz_unqualified_write_probe()
  returns void language sql set search_path = '' as $probe$
    delete from erp_meta.drain_pass;
  $probe$;
  select count(*) into v_n from erp.unqualified_write_report() r
   where r.reference like 'erp_meta.zz_unqualified_write_probe%';
  return query select 'a write that names no rows is found, whatever it deletes'::text,
    v_n = 1, format('%s finding(s) for the probe', v_n);
  drop function erp_meta.zz_unqualified_write_probe();

  -- And the designation, which is where it was met.
  select po.* into v_prior from erp_meta.platform_organisation po;
  select * into rp from erp.provision_tenant(v_code, 'Unqualified Write One', 'admin@zzuw.test', 'Admin One');
  perform erp.provision_tenant(v_code2, 'Unqualified Write Two', 'admin2@zzuw.test', 'Admin Two');
  insert into auth.users (id, email) values (ow, 'owner@zzuw.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzuw.test', ow, 'Unqualified Write Owner', 'owner');
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);

  v_id := erp.designate_platform_organisation(v_code, 'suite: the first designation');
  return query select 'an owner names the organisation that is Clove ERP itself'::text,
    v_id = rp.tenant_id
    and (select po.tenant_code from erp_meta.platform_organisation po) = v_code,
    format('designated %s', v_code);

  begin
    perform erp.designate_platform_organisation(v_code2, 'suite: moving it states why');
    v_ok := (select po.tenant_code from erp_meta.platform_organisation po) = v_code2;
    v_msg := 'moved, and the row it replaced went with it';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 90);
  end;
  return query select 'and moves it, replacing the one row there was'::text, v_ok, v_msg;

  return query select 'one organisation is the platform''s, never two'::text,
    (select count(*) from erp_meta.platform_organisation) = 1,
    format('%s row(s)', (select count(*) from erp_meta.platform_organisation));

  -- ── Clean up ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.platform_organisation where tenant_id is not null;
  if v_prior.tenant_id is not null then
    insert into erp_meta.platform_organisation (tenant_id, tenant_code, designated_at, designated_by, reason)
    values (v_prior.tenant_id, v_prior.tenant_code, v_prior.designated_at, v_prior.designated_by, v_prior.reason);
  end if;
  perform erp.begin_tenant_purge(rp.tenant_id);
  delete from erp.tenant where id = rp.tenant_id;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge((select t.id from erp.tenant t where t.code = v_code2));
  delete from erp.tenant where code = v_code2;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email = 'owner@zzuw.test';
  delete from auth.users where id = ow;

  return query select 'the suite leaves the designation as it found it'::text,
    not exists (select 1 from erp.tenant t where t.code in (v_code, v_code2))
    and (v_prior.tenant_id is null) = (not exists (select 1 from erp_meta.platform_organisation)),
    'organisations gone, and any designation that was there before is back';
end;
$$;

revoke all on function erp_test.unqualified_write_suite() from public, anon;

create or replace function erp_test.assert_unqualified_write_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _unqualified_write_result on commit drop as
    select * from erp_test.unqualified_write_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _unqualified_write_result;
  if v_total <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: unqualified_write_suite ran % cases, expected 6', v_total;
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_UNQUALIFIED_WRITE_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('writes name their rows: %s/%s', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_unqualified_write_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_writes_name_their_rows();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp_test.assert_unqualified_write_suite();
