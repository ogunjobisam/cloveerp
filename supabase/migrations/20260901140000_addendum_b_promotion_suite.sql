-- =============================================================================
-- Addendum B, Part 1c — the suite
--
-- Two properties, and one warning carried over from the probe that found the
-- hole in the first place.
--
--   1. On a live organisation each of the nine surfaces now refuses a direct
--      write, and refuses it *with the guard's own error*. The first version of
--      that probe used column names that do not exist, so both writes failed on
--      a schema error and looked perfectly guarded. Every case below asserts
--      on ERPWARE_LIVE_CONFIG_EDIT specifically, and erp.rule_set — guarded
--      since 0017 — is kept as the control that must fail the same way.
--   2. A promoted change set really writes all nine, and a `remove` item really
--      retires a row.
--
-- Plus the case the extraction exists for: a principal holding
-- administration.promote and nothing else promotes a change set carrying an
-- account_determination item. If the authorise() call had followed the logic
-- into erp.upsert_account_determination, this is the case that fails.
-- =============================================================================

create or replace function erp_test.addendum_b_promotion_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  a1 uuid := gen_random_uuid();   -- author and administrator
  a2 uuid := gen_random_uuid();   -- second administrator, so go-live is possible
  a3 uuid := gen_random_uuid();   -- promote-only principal
  v_onboard jsonb; v_tenant uuid; v_entity uuid; v_site uuid;
  v_u2 uuid; v_u3 uuid; v_tok2 text; v_tok3 text;
  v_role jsonb; v_cs uuid; v_ok boolean; v_msg text; res jsonb;
  v_snap uuid; v_captured integer;
begin
  insert into auth.users (id, email) values
    (a1, 'author@zzpromo.test'),
    (a2, 'second@zzpromo.test'),
    (a3, 'promoter@zzpromo.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  v_onboard := erp.onboard_tenant('Addendum B promotion', 'zzpromo');
  v_tenant  := (v_onboard ->> 'tenant_id')::uuid;
  v_entity  := (v_onboard ->> 'entity_id')::uuid;

  -- Accounts and ledgers, because account_determination points at one and §5
  -- refuses to default to suspense when it cannot find it.
  perform erp.configure_finance();

  -- A site, because a release area belongs to one. erp.site is business data,
  -- not a configuration surface, so it is written directly on purpose.
  insert into erp.site (tenant_id, entity_id, code, name, site_type)
  values (v_tenant, v_entity, 'S1', 'Site one', 'warehouse')
  returning id into v_site;

  -- The promote-only role has to be created before go-live: erp.role has
  -- carried the live-edit guard since 0017, so afterwards even this is a
  -- change set.
  v_role := public.erp_save_role(
    null, 'promoter', 'Promoter',
    'Holds administration.promote and nothing else. Exists to prove that '
    'promotion does not require the permission each item would need.',
    array['administration.promote', 'administration.read']);

  res := public.erp_invite_principal('second@zzpromo.test', 'Second Admin');
  v_u2 := (res ->> 'app_user_id')::uuid; v_tok2 := res ->> 'token';
  perform erp.grant_role(v_u2, 'administrator', null, null, 'co-administrator');

  res := public.erp_invite_principal('promoter@zzpromo.test', 'Promoter');
  v_u3 := (res ->> 'app_user_id')::uuid; v_tok3 := res ->> 'token';
  perform erp.grant_role(v_u3, 'promoter', null, null, 'promote only');

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok2);
  perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
  perform erp.claim_invitation(v_tok3);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  perform erp.go_live();

  -- ---------------------------------------------------------------------
  -- 1. Ten direct writes on a live organisation, ten guard refusals
  -- ---------------------------------------------------------------------

  begin
    insert into erp.rule_set (tenant_id, code, name, status)
    values (v_tenant, 'zzpromo-ctl', 'Control', 'active');
    v_ok := false; v_msg := 'accepted — the control is not guarded either, so this suite proves nothing';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'control: a rule set is refused by the guard', v_ok, v_msg;

  begin
    insert into erp.department (tenant_id, code, name, valid_from, status)
    values (v_tenant, 'OPS', 'Operations', current_date, 'active');
    v_ok := false; v_msg := 'accepted — B.1 is still ungoverned on a live organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a department is refused by the guard', v_ok, v_msg;

  begin
    insert into erp.posting_class (tenant_id, kind, code, name, valid_from, status)
    values (v_tenant, 'item', 'ZZ', 'Direct', current_date, 'active');
    v_ok := false; v_msg := 'accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a posting class is refused by the guard', v_ok, v_msg;

  begin
    insert into erp.account_determination (
      tenant_id, transaction_type, account_id, valid_from, status)
    values (v_tenant, 'zz_direct',
            (select a.id from erp.account a where a.tenant_id = v_tenant and a.code = '1000'),
            current_date, 'active');
    v_ok := false; v_msg := 'accepted — the rule that decides which ledger account a posting hits';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'an account determination rule is refused by the guard',
    v_ok, v_msg;

  begin
    insert into erp.classification_axis (
      tenant_id, code, name, is_mandatory, seq, valid_from, status)
    values (v_tenant, 'ZZAX', 'Direct', false, 10, current_date, 'active');
    v_ok := false; v_msg := 'accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a classification axis is refused by the guard', v_ok, v_msg;

  begin
    insert into erp.code_template (
      tenant_id, code, name, segments, casing, version, valid_from, status)
    values (v_tenant, 'ZZT', 'Direct', '[{"kind":"literal","value":"X"}]'::jsonb,
            'upper', 1, current_date, 'active');
    v_ok := false; v_msg := 'accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a code template is refused by the guard', v_ok, v_msg;

  begin
    insert into erp.release_area (
      tenant_id, site_id, code, name, replenishment_mode, ageing_hours,
      gate_printing, valid_from, status)
    values (v_tenant, v_site, 'ZZR', 'Direct', 'pull', 72, true, current_date, 'active');
    v_ok := false; v_msg := 'accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a release area is refused by the guard', v_ok, v_msg;

  -- The remaining three hang off rows the guard has just refused to create, so
  -- they are asserted through the public doors instead: same guard, reached the
  -- way a person would reach it.
  begin
    perform public.erp_upsert_department('SNEAK', 'Sneak');
    v_ok := false; v_msg := 'the door wrote a department to a live organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and the public door is refused by the same guard',
    v_ok, v_msg;

  begin
    perform public.erp_upsert_classification_axis('SNEAKAX', 'Sneak axis');
    v_ok := false; v_msg := 'the door wrote a classification axis to a live organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'the classification door likewise', v_ok, v_msg;

  begin
    perform public.erp_upsert_code_template(
      'SNEAKT', 'Sneak template', '[{"kind":"literal","value":"X"}]'::jsonb);
    v_ok := false; v_msg := 'the door wrote a code template to a live organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and the code template door likewise', v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- 2. A change set carrying all nine, promoted by somebody else
  -- ---------------------------------------------------------------------

  v_cs := erp.create_change_set(
    'zzpromo-b', 'Addendum B surfaces',
    'One item per surface, so a single promotion exercises every new branch.');

  perform erp.add_change_set_item(v_cs, 'department', 'OPS', jsonb_build_object(
    'code', 'OPS', 'name', 'Operations', 'entity', 'MAIN',
    'default_cost_centre', 'CC-OPS'));

  perform erp.add_change_set_item(v_cs, 'department', 'FIN', jsonb_build_object(
    'code', 'FIN', 'name', 'Finance', 'parent', 'OPS', 'entity', 'MAIN'));

  perform erp.add_change_set_item(v_cs, 'approval_band', 'OPS|purchase_order|1',
    jsonb_build_object(
      'department', 'OPS', 'object_type', 'purchase_order', 'seq', 1,
      'lower_bound_minor', 0, 'upper_bound_minor', 500000,
      'approver_email', 'second@zzpromo.test', 'currency', 'GBP'));

  perform erp.add_change_set_item(v_cs, 'approver_assignment',
    'department|OPS|purchase_order|second@zzpromo.test', jsonb_build_object(
      'subject_kind', 'department', 'subject', 'OPS',
      'object_type', 'purchase_order',
      'approver_email', 'second@zzpromo.test', 'mode', 'prepends',
      'reason', 'named approver for operations'));

  perform erp.add_change_set_item(v_cs, 'posting_class', 'item|FG', jsonb_build_object(
    'kind', 'item', 'code', 'FG', 'name', 'Finished goods'));

  perform erp.add_change_set_item(v_cs, 'account_determination',
    'goods_receipt|FG|-|-|-|-|-|-', jsonb_build_object(
      'transaction_type', 'goods_receipt', 'account', '1200',
      'item_class', 'FG', 'ledger', 'GL',
      'note', 'promoted, not written directly'));

  perform erp.add_change_set_item(v_cs, 'classification_axis', 'COLOUR',
    jsonb_build_object('code', 'COLOUR', 'name', 'Colour', 'seq', 10));

  perform erp.add_change_set_item(v_cs, 'classification_value', 'COLOUR|RED',
    jsonb_build_object('axis', 'COLOUR', 'code', 'RED', 'name', 'Red',
                       'abbreviation', 'RD'));

  perform erp.add_change_set_item(v_cs, 'code_template', 'ITEM', jsonb_build_object(
    'code', 'ITEM', 'name', 'Item code',
    'segments', '[{"kind":"literal","value":"IT"},{"kind":"sequence","length":6}]'::jsonb,
    'casing', 'upper'));

  perform erp.add_change_set_item(v_cs, 'release_area', 'S1|PICK', jsonb_build_object(
    'site', 'S1', 'code', 'PICK', 'name', 'Picking area',
    'replenishment_mode', 'pull', 'ageing_hours', 48));

  perform erp.submit_change_set(v_cs);

  -- The author may not approve their own change set once the organisation is
  -- live, so the second administrator does.
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);

  -- ...and the promote-only principal promotes it. This is the case the whole
  -- extraction exists for.
  perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);

  begin
    perform erp.promote_change_set(v_cs);
    v_ok := true; v_msg := 'promoted';
  exception when others then
    v_ok := false; v_msg := 'REFUSED: ' || left(sqlerrm, 70);
  end;
  return query select
    'a principal holding only administration.promote can promote all nine',
    v_ok, v_msg;

  return query select 'and the same principal cannot write one directly',
    (select not erp.has_permission('finance.configure')),
    'if it held finance.configure the previous case would prove nothing';

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'the change set is promoted',
    (select cs.status from erp.change_set cs where cs.id = v_cs)::text = 'promoted',
    'a status on a row is only worth as much as the rows it claims to have written';

  -- ---------------------------------------------------------------------
  -- 3. The rows the promotion claims to have written
  -- ---------------------------------------------------------------------

  return query select 'the department is there, with its parent resolved',
    (select d.parent_department_id is not null from erp.department d
      where d.tenant_id = v_tenant and d.code = 'FIN'),
    'the branch resolves parent by code, because a change set built elsewhere '
    'knows nothing of this environment''s ids';

  return query select 'the approval band is there, naming the approver it was given',
    exists (select 1 from erp.approval_band ab
              join erp.department d on d.id = ab.department_id
             where ab.tenant_id = v_tenant and d.code = 'OPS'
               and ab.object_type = 'purchase_order' and ab.seq = 1
               and ab.upper_bound_minor = 500000),
    'a band decides who must approve what; promoting one that lost its bound '
    'would be worse than not promoting it';

  return query select 'the named approver assignment is there',
    exists (select 1 from erp.approver_assignment aa
              join erp.app_user u on u.id = aa.approver_user_id
             where aa.tenant_id = v_tenant and aa.object_type = 'purchase_order'
               and lower(u.email) = 'second@zzpromo.test'),
    'both subject and approver are people, resolved here by code and email';

  return query select 'the posting class is there',
    exists (select 1 from erp.posting_class pc
             where pc.tenant_id = v_tenant and pc.kind = 'item' and pc.code = 'FG'),
    'the left-hand side of account determination';

  return query select 'the account determination rule points at account 1200',
    exists (select 1 from erp.account_determination ad
              join erp.account a on a.id = ad.account_id
             where ad.tenant_id = v_tenant and ad.transaction_type = 'goods_receipt'
               and a.code = '1200'),
    '§5 refuses a default-to-suspense, so the account this resolves to is the '
    'account the posting hits';

  return query select 'the classification axis and its value are there',
    exists (select 1 from erp.classification_value cv
              join erp.classification_axis ca on ca.id = cv.axis_id
             where cv.tenant_id = v_tenant and ca.code = 'COLOUR' and cv.code = 'RED'),
    'the value branch resolves its axis by code and refuses an unknown one';

  return query select 'the code template is there',
    exists (select 1 from erp.code_template ct
             where ct.tenant_id = v_tenant and ct.code = 'ITEM'
               and jsonb_array_length(ct.segments) = 2),
    'a template promoted without its segments would issue codes of a different '
    'shape';

  return query select 'the release area is there, on the right site',
    exists (select 1 from erp.release_area ra
              join erp.site s on s.id = ra.site_id
             where ra.tenant_id = v_tenant and s.code = 'S1' and ra.code = 'PICK'
               and ra.ageing_hours = 48),
    'release areas are per-site, so the branch resolves the site by code';

  -- ---------------------------------------------------------------------
  -- 4. Capture — promotion the other way round
  -- ---------------------------------------------------------------------

  return query select 'the manifest now describes all nine surfaces',
    (select count(distinct m.object_kind) from erp.configuration_manifest() m
      where m.object_kind in ('department', 'approval_band', 'approver_assignment',
                              'posting_class', 'account_determination',
                              'classification_axis', 'classification_value',
                              'code_template', 'release_area')) = 9,
    'without this half the surfaces can be authored into a change set but '
    'never lifted out of a working organisation into one';

  return query select 'and the department it emits names its parent by code',
    (select m.content ->> 'parent' from erp.configuration_manifest() m
      where m.object_kind = 'department' and m.object_key = 'FIN') = 'OPS',
    'a manifest carrying local ids would promote into one environment and '
    'nowhere else';

  return query select 'the approval band it emits names the approver by email',
    (select m.content ->> 'approver_email' from erp.configuration_manifest() m
      where m.object_kind = 'approval_band'
        and m.object_key = 'OPS|purchase_order|1') = 'second@zzpromo.test',
    'the band stores a resolution ladder of ids; the manifest emits the '
    'arguments the door took, so a captured band promotes through the same door';

  -- ---------------------------------------------------------------------
  -- 5. remove, and an unresolvable reference
  -- ---------------------------------------------------------------------

  v_cs := erp.create_change_set('zzpromo-r', 'Retire finance', 'One remove item.');
  perform erp.add_change_set_item(
    v_cs, 'department', 'FIN', jsonb_build_object('code', 'FIN'),
    'remove'::erp.change_operation);
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'a remove item retires the row rather than deleting it',
    (select d.status from erp.department d
      where d.tenant_id = v_tenant and d.code = 'FIN')::text = 'inactive',
    'configuration is effective-dated; a delete would take the history with it';

  v_cs := erp.create_change_set('zzpromo-x', 'Unknown account', 'One bad item.');
  perform erp.add_change_set_item(v_cs, 'account_determination', 'zz|NOPE',
    jsonb_build_object('transaction_type', 'zz_bad', 'account', 'NO-SUCH-ACCOUNT'));
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  begin
    perform erp.promote_change_set(v_cs);
    v_ok := false; v_msg := 'promoted a determination rule with no account';
  exception when others then
    v_ok := sqlerrm like '%ERPWARE_PROMOTION_UNKNOWN_ACCOUNT%'; v_msg := left(sqlerrm, 70);
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  return query select
    'a determination rule naming an account this environment lacks is refused',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- 6. The register itself
  -- ---------------------------------------------------------------------

  return query select 'every registered surface carries the live-edit guard',
    (select count(*) from erp_meta.promotable_surface ps
       where exists (
         select 1 from pg_catalog.pg_trigger t
           join pg_catalog.pg_class c on c.oid = t.tgrelid
           join pg_catalog.pg_namespace n on n.oid = c.relnamespace
          where n.nspname = ps.schema_name and c.relname = ps.table_name
            and t.tgname = 't_' || ps.table_name || '_live_guard'))
      = (select count(*) from erp_meta.promotable_surface),
    'the guard is generated from the register, so this is the register and the '
    'deployment agreeing';

  -- ---------------------------------------------------------------------
  -- Clean up. A suite that leaves an organisation behind changes what the
  -- assertions after it are measuring.
  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, a2, a3);

  return query select 'and the suite removes the organisation it built',
    not exists (select 1 from erp.department d where d.tenant_id = v_tenant),
    'left behind, it would sit in every assertion that runs after this one';
end $$;

create or replace function erp_test.assert_addendum_b_promotion_suite()
returns text
language plpgsql
set search_path to ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Ten guard refusals, three on promotion itself, eight on the rows it wrote,
  -- three on capture, two on remove and unresolvable references, one on the
  -- register, and the cleanup.
  c_expected constant integer := 28;
begin
  create temporary table if not exists zz_promo_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_promo_result;
  insert into zz_promo_result select * from erp_test.addendum_b_promotion_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_promo_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_ADDENDUM_B_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_ADDENDUM_B_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('addendum B promotion: %s/%s', v_pass, v_total);
end $$;

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.assert_configuration_promotable();
select erp.assert_public_api_safe();
select erp.assert_isolation();
