-- An organisation restored alone is not the platform.
--
-- The restore drill's second half (restore_drill.yml) cuts a restored copy of
-- the control plane down to one organisation with erp.isolate_tenant() and
-- runs the console again. On 11 October 2026 it kept Clove Foods, purged the
-- platform's own organisation (Clove ERP Ltd), and the console refused the
-- copy: commercial — "the platform organisation is not an active
-- organisation". erp_meta.platform_organisation has no foreign key to
-- erp.tenant, on purpose (the platform's record must not cascade away with a
-- tenant row), so the designation outlived the organisation it named.
--
-- In a copy holding one customer there is no platform organisation; the
-- designation goes with the organisation it named. Withdrawn only when that
-- organisation was purged here: an isolation that keeps the platform's own
-- organisation keeps its designation. The isolator says which, and so does
-- the audit row.

create or replace function erp.isolate_tenant(p_tenant_code text, p_confirm_database text)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_keep      erp.tenant%rowtype;
  t           record;
  v_removed   text[] := '{}';
  v_withdrawn text;
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

  -- The platform's designation goes with the organisation it named.
  delete from erp_meta.platform_organisation po
   where po.tenant_id <> v_keep.id
     and not exists (select 1 from erp.tenant tn where tn.id = po.tenant_id)
  returning po.tenant_code into v_withdrawn;

  insert into erp_meta.platform_audit (actor_email, actor_role, action, tenant_id, tenant_code, target, reason, detail)
  values ('system', 'platform', 'platform.tenant_isolated', v_keep.id, v_keep.code, current_database(),
          'per-organisation restore drill',
          jsonb_build_object('kept', v_keep.code, 'removed', to_jsonb(v_removed), 'database', current_database(),
                             'platform_designation_withdrawn', v_withdrawn));

  return jsonb_build_object('kept', v_keep.code, 'removed', to_jsonb(v_removed),
                            'organisations_remaining', (select count(*) from erp.tenant),
                            'platform_designation_withdrawn', v_withdrawn);
end;
$$;
revoke all on function erp.isolate_tenant(text, text) from public, anon, authenticated;
comment on function erp.isolate_tenant is
  'In a restored copy declared a restore target, purges every organisation but one, so the per-organisation restore commitment can be drilled; the platform''s designation goes with the organisation it named. Refuses anywhere else.';

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Not run from this migration: its fixture designates a platform organisation,
-- a live singleton. The catalogue runs it on the build.

create or replace function erp_test.organisation_restored_alone_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tag      text := substr(md5(clock_timestamp()::text), 1, 6);
  v_pcode    text;
  v_ccode    text;
  v_platform uuid;
  v_iso      jsonb;
  v_iso2     jsonb;
  v_left     integer;
  v_po       text;
  v_po2      text;
  v_finding  integer;
  v_before   text;
  v_skipped  boolean := false;
  v_msg      text;
begin
  v_pcode := 'zzira-p-' || v_tag;
  v_ccode := 'zzira-c-' || v_tag;
  select po.tenant_code into v_before from erp_meta.platform_organisation po;

  -- Under a subtransaction that is always undone: the build's organisations
  -- must survive this suite.
  begin
    if current_database() = 'postgres' then
      v_skipped := true;
    else
      perform set_config('erp.job_tenant_id', '', true);
      perform set_config('erp.job_principal_id', '', true);
      perform set_config('request.jwt.claims', '', true);
      select r.tenant_id into v_platform
        from erp.provision_tenant(v_pcode, 'Restored Alone Platform', 'admin@' || v_pcode || '.test', 'Platform Admin') r;
      perform erp.provision_tenant(v_ccode, 'Restored Alone Customer', 'admin@' || v_ccode || '.test', 'Customer Admin');
      delete from erp_meta.platform_organisation where tenant_id is not null;
      insert into erp_meta.platform_organisation (tenant_id, tenant_code, designated_by, reason)
      values (v_platform, v_pcode, 'suite', 'the organisation restored alone suite');

      -- The customer kept, the platform purged.
      perform set_config('erp.restore_target', current_database(), true);
      v_iso := erp.isolate_tenant(v_ccode, current_database());
      select count(*) into v_left from erp.tenant;
      select po.tenant_code into v_po from erp_meta.platform_organisation po;
      select count(*) into v_finding from erp.commercial_report() r
       where r.finding = 'the platform organisation is not an active organisation';

      -- The platform's own organisation kept: its designation stays. Only the
      -- customer is left to keep, so designate it and isolate it again.
      insert into erp_meta.platform_organisation (tenant_id, tenant_code, designated_by, reason)
      select tn.id, tn.code, 'suite', 'the organisation restored alone suite' from erp.tenant tn where tn.code = v_ccode;
      v_iso2 := erp.isolate_tenant(v_ccode, current_database());
      select po.tenant_code into v_po2 from erp_meta.platform_organisation po;
    end if;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_msg := 'isolation block failed: ' || left(sqlerrm, 160);
    end if;
  end;

  case_name := 'isolating a customer withdraws the designation of the platform organisation it purged';
  if v_skipped then
    passed := true; detail := 'not run: this database is called postgres, which the isolator refuses by design';
  else
    passed := v_msg is null and v_left = 1 and v_po is null
          and v_iso ->> 'platform_designation_withdrawn' = v_pcode;
    detail := coalesce(v_msg, format('%s organisation(s) left; designation now %s; isolator reported %s',
                                     v_left, coalesce(v_po, 'none'), coalesce(v_iso::text, 'nothing')));
  end if;
  return next;

  case_name := 'and the commercial report finds no platform organisation that is not active';
  if v_skipped then
    passed := true; detail := 'not run: this database is called postgres';
  else
    passed := v_msg is null and v_finding = 0;
    detail := coalesce(v_msg, format('%s such finding(s)', v_finding));
  end if;
  return next;

  case_name := 'isolating the platform''s own organisation keeps its designation';
  if v_skipped then
    passed := true; detail := 'not run: this database is called postgres';
  else
    passed := v_msg is null and v_po2 = v_ccode and v_iso2 ? 'platform_designation_withdrawn'
          and v_iso2 -> 'platform_designation_withdrawn' = 'null'::jsonb;
    detail := coalesce(v_msg, format('designation now %s; isolator reported %s',
                                     coalesce(v_po2, 'none'), coalesce(v_iso2::text, 'nothing')));
  end if;
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code like 'zzira-%')
        and (select po.tenant_code from erp_meta.platform_organisation po) is not distinct from v_before;
  detail := format('designation %s, as before', coalesce(v_before, 'none'));
  return next;
end;
$$;
revoke all on function erp_test.organisation_restored_alone_suite() from public, anon, authenticated;

create or replace function erp_test.assert_organisation_restored_alone_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _organisation_restored_alone on commit drop as
    select * from erp_test.organisation_restored_alone_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _organisation_restored_alone;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_ORGANISATION_RESTORED_ALONE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_ORGANISATION_RESTORED_ALONE_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('organisation restored alone: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_organisation_restored_alone_suite() from public, anon, authenticated;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
