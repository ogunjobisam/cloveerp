-- ─────────────────────────────────────────────────────────────────────────────
-- Reaching erp.authorise() is transitive, and so is the rule about it.
--
-- 20260904670000 fixed the six public doors that call erp.authorise() in their
-- own body, and asserted on that set. It was the wrong set. A door that calls
-- an erp.* function which authorises writes the same access-log row and fails
-- the same way — "Your agreement" is exactly that shape, and it was still
-- refusing with 25006 after the first repair:
--
--   public.erp_my_agreement()  ->  erp.my_agreement()  ->  erp.authorise()
--
-- Testing the direct callers and then asserting on direct calls only is the
-- same mistake twice: the check was written to the shape of the examples in
-- hand rather than to the mechanism. The mechanism is that PostgREST runs a
-- non-volatile function in a READ ONLY transaction, and anything reaching
-- erp.authorise() writes.
--
-- Seven doors call a function that authorises. Each is made volatile and
-- registered against the function it actually calls, which is what
-- erp.assert_public_api_safe() checks: the gate has to appear in the door's
-- own body, so `erp.authorise` would be a false declaration here.
--
-- The rule is two levels deep, and that is a deliberate limit rather than an
-- oversight. A full transitive closure over prosrc was tried first and is too
-- loose to act on: it matches a name inside a comment, and it pulled in
-- erp_tenant_state (via a mention of erp.go_live), erp_pack_acceptance and
-- erp_integration_backlog, none of which write. With the transaction forced
-- read-only those three return normally while erp_my_agreement raises 25006,
-- so the closure was claiming a fault the database disagrees with. Two levels
-- is what can be stated precisely and gated honestly. A door three calls deep
-- from an authorisation would still slip through, and the comment is here so
-- the next person knows that rather than trusting the assertion further than
-- it goes.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── The seven ────────────────────────────────────────────────────────────────

alter function public.erp_my_agreement() volatile;
alter function public.erp_my_contract_document(p_document_id uuid) volatile;
alter function public.erp_device_stock_position(p_reference_id uuid, p_device_code text) volatile;
alter function public.erp_report_reproducibility() volatile;
alter function public.erp_resolve_scan(p_key text, p_barcode text, p_fields jsonb, p_device_code text) volatile;
alter function public.erp_scan(p_device_code text, p_task_code text, p_barcode text, p_symbology text, p_item_class text) volatile;
alter function public.erp_tenant_state() volatile;

-- Gated on the function each door actually calls, because that is the one its
-- body names. Volatile means "may write" to erp.assert_public_api_safe(), and
-- that is the honest claim: the callee authorises, and authorising writes.
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_my_agreement', 'erp.my_agreement',
   '§17.11. A read of this organisation''s own agreement. Volatile because erp.my_agreement() authorises and erp.authorise() records the decision, which a stable declaration would put inside PostgREST''s read-only transaction.'),
  ('erp_my_contract_document', 'erp.my_contract_document',
   '§17.11. A read of one contract document this organisation is party to. Volatile for the access-log row its authorisation writes.'),
  ('erp_device_stock_position', 'erp.device_stock_position',
   'A read of stock at a scanned reference. Volatile for the access-log row its authorisation writes.'),
  ('erp_report_reproducibility', 'erp.report_reproducibility_report',
   'A read of report versions and their runs. Volatile for the access-log row its authorisation writes.'),
  ('erp_resolve_scan', 'erp.resolve_scan_reference',
   'Resolves a scanned barcode to what it refers to. Volatile for the access-log row its authorisation writes.'),
  ('erp_scan', 'erp.evaluate_scan',
   'Resolves a scan for a device task. Volatile for the access-log row its authorisation writes.'),
  ('erp_tenant_state', 'erp.go_live',
   'A read of this organisation''s own state, from the same function that takes it live. Volatile for the access-log row its authorisation writes.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ── The report, one level further than it looked ─────────────────────────────

create or replace function erp.authorising_door_report()
returns table (door text, volatility text, finding text)
language sql
stable
set search_path = ''
as $$
  with fn as (
    select n.nspname || '.' || p.proname as qname, n.nspname as sch,
           p.prosrc, p.provolatile, p.oid
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ai', 'erp_meta', 'erp_ref', 'public')
  ),
  authorises as (select f.qname, f.prosrc from fn f where f.prosrc ~ 'erp\.authorise\s*\(')
  select f.qname || '(' || pg_get_function_identity_arguments(f.oid) || ')',
         case f.provolatile when 's' then 'stable' else 'immutable' end,
         'a public door reaches erp.authorise() through ' || a.qname
           || '(), which writes an access-log row, but is declared '
           || case f.provolatile when 's' then 'stable' else 'immutable' end
           || ', so PostgREST runs it in a read-only transaction and the call fails'
    from fn f
    -- Directly, or through one function that does.
    join authorises a
      on f.prosrc ~ (replace(a.qname, '.', '\.') || '\s*\(')
      or (a.qname = 'erp.authorise' and f.prosrc ~ 'erp\.authorise\s*\(')
   where f.sch = 'public'
     and f.provolatile in ('s', 'i')
   group by 1, 2, 3
   order by 1;
$$;

comment on function erp.authorising_door_report is
  'Public doors that reach erp.authorise() — in their own body or through one '
  'function that does — while declared non-volatile. PostgREST runs those in a '
  'read-only transaction, where recording the access decision raises 25006. '
  'Two levels deep: see the migration for why it is not the full closure.';

create or replace function erp.assert_authorising_doors_are_volatile()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_count    integer;
  v_findings text;
  v_doors    integer;
  v_reach    integer;
begin
  select count(*), string_agg(format('  %s [%s]', r.finding, r.door), E'\n' order by r.door)
    into v_count, v_findings
    from erp.authorising_door_report() r;
  if v_count > 0 then
    raise exception E'ERPWARE_AUTHORISING_DOOR_NOT_VOLATILE: % finding(s)\n%', v_count, v_findings
      using errcode = 'P0001',
            hint = 'Declare the door volatile. Reaching erp.authorise() means writing an access-log row, and PostgREST honours a stable declaration by opening a read-only transaction.';
  end if;

  select count(*) into v_doors
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'erp\_%';

  with fn as (
    select n.nspname || '.' || p.proname as qname, n.nspname as sch, p.prosrc
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ai', 'erp_meta', 'erp_ref', 'public')
  ),
  authorises as (select f.qname from fn f where f.prosrc ~ 'erp\.authorise\s*\(')
  select count(distinct f.qname) into v_reach
    from fn f join authorises a on f.prosrc ~ (replace(a.qname, '.', '\.') || '\s*\(')
   where f.sch = 'public';

  return format('doors: %s public entry points, %s reach erp.authorise() within one call and every one of those is volatile',
                v_doors, v_reach);
end;
$$;

comment on function erp.assert_authorising_doors_are_volatile is
  'Fails when a public door reaches erp.authorise() and is declared stable or '
  'immutable. Such a door raises 25006 through PostgREST and nowhere else: '
  'from SQL, a suite or psql the transaction is read-write and the write '
  'succeeds, so nothing but this notices.';

-- ── Tell PostgREST, which is the half the database cannot see ───────────────
--
-- PostgREST reads volatility from a schema cache it builds once. Until it
-- reloads, an ALTER FUNCTION ... VOLATILE changes nothing a browser can see:
-- the door is volatile in pg_proc and still called inside a read-only
-- transaction. Supabase reloads on DDL through an event trigger, and this is
-- belt and braces for the case where that does not fire. It is a no-op with
-- nothing listening, which is what CI is.
notify pgrst, 'reload schema';

-- ── The suite, extended to the case the first repair missed ─────────────────

create or replace function erp_test.authorising_doors_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_msg text;
begin
  return query select 'no public door reaches erp.authorise from a non-volatile declaration',
    (select count(*) from erp.authorising_door_report()) = 0,
    format('%s finding(s)', (select count(*) from erp.authorising_door_report()));

  v_msg := erp.assert_authorising_doors_are_volatile();
  return query select 'the assertion counts the doors rather than asserting silence',
    v_msg ~ '^doors: \d+ public entry points, \d+ reach erp\.authorise\(\) within one call', v_msg;

  return query select 'the six doors that called erp.authorise directly are volatile',
    not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.provolatile <> 'v'
         and p.proname in ('erp_commercial_renewals', 'erp_interview_questions',
                           'erp_opening_balance_reconciliation', 'erp_pack_plan',
                           'erp_render_output_template', 'erp_report_extract_content')),
    'the first repair';

  -- The case the first repair missed: reaching erp.authorise through another
  -- function is reaching it.
  return query select 'and so are the seven that reach it through another function',
    not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.provolatile <> 'v'
         and p.proname in ('erp_my_agreement', 'erp_my_contract_document', 'erp_tenant_state',
                           'erp_report_reproducibility', 'erp_device_stock_position',
                           'erp_resolve_scan', 'erp_scan')),
    'erp_my_agreement and the six beside it';

  -- The report must look past the door's own body. erp_my_agreement does not
  -- name erp.authorise, and a report that only read bodies called it sound.
  return query select 'the report looks past the door''s own body',
    (select p.prosrc !~ 'erp\.authorise\s*\('
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'erp_my_agreement'),
    'erp_my_agreement authorises through erp.my_agreement()';

  return query select 'erp.authorise records the decision, so it is a write',
    (select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp' and p.proname = 'authorise') like '%log_access_decision%',
    'erp.log_access_decision inserts into erp.access_log';

  return query select 'and erp.authorise is itself declared volatile',
    (select p.provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp' and p.proname = 'authorise') = 'v',
    'erp.authorise';
end;
$$;

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
