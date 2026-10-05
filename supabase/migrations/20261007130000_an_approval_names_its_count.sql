set lock_timeout = '30s';

-- =============================================================================
-- 20261007130000  An approval names its count
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-20). Stock audit's
-- "Decide a count difference" offered every approval waiting on the reader,
-- read from public.erp_my_approvals, labelled by its kind, who asked and the
-- raw time: "document — Samuel Ogunjobi — 2026-10-04T03:15:14.717477+00:00",
-- an unrelated document's approval with no number, which could be decided
-- from the count screen. A count's own approval said only "count_task": the
-- door answered nothing about which product or place it was, so the screen
-- could not name it even once it kept counts alone.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_my_approvals, same signature, still a stable read that
--      authorises nothing: an approval of a count also carries the product
--      counted (its code and name), the place (the location's code) and the
--      site's code, read from the count task inside the organisation. Every
--      other row is as it was, and carries them empty. What was expected and
--      counted was already there, in the request's context.
--   B. erp_test.approval_names_its_count_suite: a count outside its tolerance
--      waiting on the reader is listed with its product, place and site, and
--      what was expected and counted; a document's approval on the same list
--      names no product; and the door keeps its shape.
--
-- The screen's half (the picker keeps the counts and names each one by its
-- product, place, figures, who asked and the day) is in
-- src/routes/inventory/audit.tsx and src/lib/plain-words.ts.
--
-- On production: one door is replaced. No table is altered and no row is
-- changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The door
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  v_sig constant text := 'public.erp_my_approvals()';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261007130000') > 0 then
    raise notice '% already names its counts; replaced with the same body', v_sig;
    return;
  end if;
  if md5(v_src) <> '63bab5cb9a6afee2106933703bc8a5b8' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007130000 expects (md5 %)', v_sig, md5(v_src);
  end if;
end
$guard$;

create or replace function public.erp_my_approvals()
returns jsonb
language sql
stable
set search_path = ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id', t.id, 'approval_request_id', t.approval_request_id,
    'object_type', ar.object_type, 'object_id', ar.object_id,
    'seq', t.seq, 'status', t.status, 'assigned_at', t.created_at,
    'requested_by', a.display_name, 'requested_at', ar.requested_at,
    'context', ar.context,
    -- The step, by the name its chain gives it.
    'step_code', t.step_code,
    'step_name', coalesce(nullif(btrim(st.name), ''), t.step_code),
    -- What is being approved, when it is a document.
    'document_id', d.id,
    'document_number', d.document_number,
    'document_type', dt.code,
    'document_type_name', dt.name,
    'partner', p.name,
    'value_minor', case when d.id is not null then erp.document_value_minor(d.id) end,
    'currency', d.currency,
    -- What is being approved, when it is a count (20261007130000, J-20): the
    -- product, the place and the site, so a count is named by what was
    -- counted where. What was expected and counted is in the context.
    'item', ci.code,
    'item_name', ci.name,
    'location', cl.code,
    'site', cs.code) order by t.created_at), '[]'::jsonb)
    from erp.approval_task t
    join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
    left join erp.app_user a on a.tenant_id = ar.tenant_id and a.id = ar.requested_by
    left join erp.approval_step st on st.tenant_id = t.tenant_id and st.id = t.approval_step_id
    left join erp.document d
      on ar.object_type = 'document' and d.tenant_id = ar.tenant_id and d.id = ar.object_id
    left join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
    left join erp.count_task ct
      on ar.object_type = 'count_task' and ct.tenant_id = ar.tenant_id and ct.id = ar.object_id
    left join erp.item ci on ci.tenant_id = ct.tenant_id and ci.id = ct.item_id
    left join erp.location cl on cl.tenant_id = ct.tenant_id and cl.id = ct.location_id
    left join erp.site cs on cs.tenant_id = ct.tenant_id and cs.id = ct.site_id
   where t.tenant_id = erp.current_tenant_id()
     and t.status = 'pending'::erp.approval_task_status
     and (t.assignee_user_id = erp.current_principal_id()
          or exists (select 1 from erp.effective_permission ep
                      where ep.app_user_id = erp.current_principal_id()
                        and ep.role_id = t.assignee_role_id))
$function$;

revoke all on function public.erp_my_approvals() from public, anon;

comment on function public.erp_my_approvals() is
  'The approval tasks waiting on the reader, oldest first: what each is for, the step, who asked and when, and, for a '
  'document, its number, type, partner and value; for a count, the product, place and site counted '
  '(20261007130000, J-20), with what was expected and counted in the context. Authorises nothing; scoped to the '
  'organisation.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.approval_names_its_count_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases  integer := 0;
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  v_owner  text := current_user;
  v_step   text := 'provisioning';
  v_state  text;
  r        record;
  res      jsonb;
  v_tok    text;
  v_second uuid;
  csf uuid; csp uuid; csi uuid;
  v_uom uuid; v_site uuid; v_sup uuid; v_grn uuid; v_item uuid; v_task uuid; v_req uuid;
  v_status text;
  v_rows   jsonb;
  v_count  jsonb;
  v_doc    jsonb;
begin
  -- 1. The door keeps its shape.
  v_cases := v_cases + 1;
  case_name := 'erp_my_approvals keeps its signature and stays a stable read that authorises nothing, granted to the signed-in only';
  passed := exists (select 1 from pg_catalog.pg_proc p
                     where p.oid = 'public.erp_my_approvals()'::regprocedure
                       and p.provolatile = 's' and not p.prosecdef
                       and p.prolang = (select l.oid from pg_catalog.pg_language l where l.lanname = 'sql')
                       and p.proconfig = array['search_path=""']
                       and p.prosrc not like '%erp.authorise(%'
                       and p.prosrc like '%erp.current_tenant_id()%')
        and has_function_privilege('authenticated', 'public.erp_my_approvals()', 'execute')
        and not has_function_privilege('anon', 'public.erp_my_approvals()', 'execute')
        and (select count(*) from pg_catalog.pg_proc p
              where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_my_approvals') = 1;
  detail := 'one stable sql read, no gate, signed-in only';
  return next;

  begin
    -- ── The fixture ───────────────────────────────────────────────────────────
    v_step := 'an organisation that counts, not yet live';
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zz-anc-' || v_hex, 'Approval names its count suite',
      'a@zz-anc-' || v_hex || '.test', 'Suite Admin');
    insert into auth.users (id, email) values (a1, 'a@zz-anc-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-anc-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    v_step := 'installing';
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    insert into auth.users (id, email) values (a2, 'second@zz-anc-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;

    v_step := 'the stock';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Goods in', 'receiving', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZANC-BOX', 'Packing box', v_uom, 'active') returning id into v_item;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_item, 100, 100, 'boxes');
    perform erp.transition_document(v_grn, 'post');

    -- A count far outside cycle_a's tolerance waits on its approver.
    v_step := 'counting outside tolerance';
    perform erp.raise_count_tasks('cycle_a');
    select t.id into v_task from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = v_item;
    v_status := erp.record_count(v_task, 50)::text;

    -- And a requisition submitted for approval, on the same list.
    v_step := 'a requisition submitted for approval';
    v_req := erp.open_document('requisition', v_sup, r.entity_id, v_site);
    perform erp.add_document_line(v_req, v_item, 10, 1000, 'ten boxes');
    perform erp.transition_document(v_req, 'submit', null);

    v_step := 'reading the approvals waiting on me';
    v_rows := public.erp_my_approvals();
    select e into v_count from jsonb_array_elements(v_rows) e
     where e ->> 'object_type' = 'count_task' and e ->> 'object_id' = v_task::text limit 1;
    select e into v_doc from jsonb_array_elements(v_rows) e
     where e ->> 'object_type' = 'document' and e ->> 'object_id' = v_req::text limit 1;

    -- 2. The count is named by what was counted where.
    v_cases := v_cases + 1;
    case_name := 'a count outside tolerance waiting on me names its product, place and site, and what was expected and counted';
    passed := v_status = 'pending_approval'
          and v_count ->> 'item' = 'ZANC-BOX'
          and v_count ->> 'item_name' = 'Packing box'
          and v_count ->> 'location' = 'RECV'
          and v_count ->> 'site' = 'MAIN'
          and (v_count #>> '{context,expected}')::numeric = 100
          and (v_count #>> '{context,counted}')::numeric = 50
          and v_count ->> 'document_number' is null;
    detail := coalesce(v_state, format('recorded %s; %s', v_status, left(coalesce(v_count::text, 'not listed'), 400)));
    return next;

    -- 3. A document's approval names no product.
    v_cases := v_cases + 1;
    case_name := 'a document''s approval on the same list names its number and no product, place or site';
    passed := v_doc ->> 'document_number' is not null
          and v_doc -> 'item' = 'null'::jsonb
          and v_doc -> 'location' = 'null'::jsonb
          and v_doc -> 'site' = 'null'::jsonb;
    detail := coalesce(v_state, left(coalesce(v_doc::text, 'not listed'), 400));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_APPROVAL_NAMES_ITS_COUNT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zz-anc-' || v_hex)
     or exists (select 1 from auth.users u where u.id in (a1, a2)) then
    raise exception 'CLOVEERP_APPROVAL_NAMES_ITS_COUNT_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.approval_names_its_count_suite() from public, anon;

comment on function erp_test.approval_names_its_count_suite() is
  'An approval names its count (20261007130000, J-20): a count waiting on the reader is listed with its product, '
  'place and site and what was expected and counted; a document''s approval beside it names no product; and '
  'erp_my_approvals keeps its shape.';

create or replace function erp_test.assert_approval_names_its_count_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.approval_names_its_count_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_APPROVAL_NAMES_ITS_COUNT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Stock audit would offer a count difference it cannot name. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_APPROVAL_NAMES_ITS_COUNT_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('approval names its count: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_approval_names_its_count_suite() from public, anon;

comment on function erp_test.assert_approval_names_its_count_suite() is
  'An approval of a count names the product, place and site counted (20261007130000).';

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
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
