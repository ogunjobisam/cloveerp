set lock_timeout = '30s';

-- =============================================================================
-- 20261010170000  The demonstration's second person raises the invoice
-- -----------------------------------------------------------------------------
-- Found by walking order to cash live on demo.cloveerp.com on 7 October, as
-- the Definition of Done's exit criterion asks: "Both flows can be
-- demonstrated live, front to back, without intervention."
--
-- The flow stopped at the invoice. The presenter had despatched the goods,
-- and erp.invoice_from_delivery() refuses the same person invoicing them
-- ("Doing both halves of a job the organisation keeps for two people"), which
-- is right. The demonstration has a second person for exactly this, Priya
-- Shah (20261006150000), and the presenter acts as her for the payment run.
-- But she holds the standard Finance role, which cannot raise an invoice, so
-- acting as her the Invoice step is closed. The only way on was the
-- self-invoice override, which is for an organisation where nobody else
-- exists, and a demonstration should not teach it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.ensure_demo_receivables_role(tenant): in a demonstration that is
--      not live, a role "Accounts receivable" holding sales.invoice and
--      sales.read, given to the demonstration's persona. She raises invoices
--      from deliveries; she does not order, despatch or price, so the two
--      halves stay with two people. Standard roles are not changed.
--   B. erp.seed_demo_personas() gives it as it seeds her, for every
--      demonstration from now on.
--   C. Each demonstration that already has her is given it now.
--   D. erp_test.persona_switch_suite expected her permissions to be the
--      Finance role's exactly; it now expects those and the two above.
--   E. erp_test.demo_persona_invoices_suite proves the walk: the presenter
--      despatches, is refused the invoice, and acting as her the invoice is
--      raised and issued.
--
-- Production: production makes no demonstrations (20261010061000), so only
-- the demonstration project's organisation is given the role.
--
-- Proof: erp_test.demo_persona_invoices_suite.
-- =============================================================================

create or replace function erp.ensure_demo_receivables_role(p_tenant_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_role    uuid;
  v_persona uuid;
  v_admin   uuid;
begin
  if not erp.tenant_is_demonstration(p_tenant_id)
     or exists (select 1 from erp.environment e
                 where e.tenant_id = p_tenant_id and e.is_self and e.is_live) then
    return 0;
  end if;

  select dp.app_user_id into v_persona
    from erp.demonstration_persona dp
   where dp.tenant_id = p_tenant_id
   order by dp.app_user_id limit 1;
  if v_persona is null then
    return 0;
  end if;

  insert into erp.role (tenant_id, code, name, description, status)
  values (p_tenant_id, 'demo_receivables', 'Accounts receivable',
          'The demonstration''s second person raises customer invoices from posted deliveries, so the person '
          'who despatched does not invoice their own goods.',
          'active'::erp.record_status)
  on conflict (tenant_id, code) do nothing;
  select r.id into v_role from erp.role r
   where r.tenant_id = p_tenant_id and r.code = 'demo_receivables';

  insert into erp.role_permission (tenant_id, role_id, permission_code)
  select p_tenant_id, v_role, p.code
    from (values ('sales.invoice'), ('sales.read')) p(code)
   where not exists (select 1 from erp.role_permission rp
                      where rp.tenant_id = p_tenant_id and rp.role_id = v_role
                        and rp.permission_code = p.code);

  if exists (select 1 from erp.user_role ur
              where ur.tenant_id = p_tenant_id and ur.app_user_id = v_persona and ur.role_id = v_role
                and (ur.valid_to is null or ur.valid_to >= current_date)) then
    return 0;
  end if;

  select u.id into v_admin
    from erp.app_user u
   where u.tenant_id = p_tenant_id and u.kind = 'person'::erp.principal_kind
     and u.status = 'active'::erp.principal_status and u.id <> v_persona
     and erp.has_permission('administration.roles', null, null, null, u.id)
   order by u.created_at, u.id
   limit 1;

  insert into erp.user_role (tenant_id, app_user_id, role_id, valid_from, granted_by, grant_reason)
  values (p_tenant_id, v_persona, v_role, current_date, v_admin,
          'Demonstration persona raises invoices (20261010170000)');
  return 1;
end;
$$;

revoke all on function erp.ensure_demo_receivables_role(uuid) from public, anon, authenticated;

comment on function erp.ensure_demo_receivables_role(uuid) is
  'In a demonstration that is not live, gives its persona an Accounts receivable role (sales.invoice, sales.read), '
  'so the presenter despatches and the persona invoices: two people for the two halves (20261010170000).';

-- ── B. As she is seeded ──────────────────────────────────────────────────────

do $seed_demo_personas$
declare
  v_sig  constant text := 'erp.seed_demo_personas(uuid)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  values (p_tenant_id, v_user, v_role, current_date, v_admin, 'Demonstration persona (20261006150000)');

  return 1;
$o$;
  v_new  constant text := $n$  values (p_tenant_id, v_user, v_role, current_date, v_admin, 'Demonstration persona (20261006150000)');

  -- And she raises the invoices the presenter's deliveries wait for
  -- (20261010170000).
  perform erp.ensure_demo_receivables_role(p_tenant_id);

  return 1;
$n$;
  n integer;
begin
  if position('erp.ensure_demo_receivables_role(' in v_def) > 0 then
    raise notice '% already gives her the invoices; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % grant found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$seed_demo_personas$;

-- ── C. Each demonstration that has her already ──────────────────────────────

do $repair$
declare
  r record;
  n integer := 0;
begin
  for r in select t.id, t.code from erp.tenant t
            where t.deleted_at is null
              and erp.tenant_is_demonstration(t.id)
              and exists (select 1 from erp.demonstration_persona dp where dp.tenant_id = t.id)
            order by t.code loop
    perform erp_meta.act_in_tenant(r.id);
    n := n + erp.ensure_demo_receivables_role(r.id);
    perform erp_meta.stop_acting_in_tenant();
  end loop;
  raise notice 'the demonstration persona raises invoices in % organisation(s) now', n;
end
$repair$;

-- ── D. The persona suite's expectation ──────────────────────────────────────

do $persona_switch_suite$
declare
  v_sig  constant text := 'erp_test.persona_switch_suite()';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$    select array_agg(x order by x) into v_want from unnest(erp.standard_role_permissions('finance')) x;$o$;
  v_new1 constant text := $n$    -- Finance, and the invoices the presenter's deliveries wait for (20261010170000).
    select array_agg(distinct x order by x) into v_want
      from unnest(erp.standard_role_permissions('finance') || array['sales.invoice', 'sales.read']) x;$n$;
  v_old2 constant text := $o$holds only her Finance permissions$o$;
  v_new2 constant text := $n$holds only her own permissions, Finance and invoicing$n$;
  n integer;
begin
  if position('20261010170000' in v_def) > 0 then
    raise notice '% already expects her invoicing; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % expected permissions found % time(s)', v_sig, n;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % case name found % time(s)', v_sig, n;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$persona_switch_suite$;

-- ── E. The proof ─────────────────────────────────────────────────────────────

create or replace function erp_test.demo_persona_invoices_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_priya  uuid; v_tab text;
  v_entity uuid; v_site uuid; v_cust uuid; v_item uuid; v_loc uuid;
  v_so uuid; v_sol uuid; v_dn uuid; v_dnl uuid; v_inv uuid;
  v_msg text; v_perms text[];
begin
  begin
    v_step := 'a demonstration, configured as the product configures one';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.headers', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzdpi' || v_tag, 'Demo Persona Invoices Suite',
      'admin@demo-zzdpi' || v_tag || '.test', 'Presenter');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzdpi' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select dp.app_user_id into v_priya from erp.demonstration_persona dp where dp.tenant_id = rb.tenant_id;
    v_tab := json_build_object('x-clove-act-as', v_priya)::text;

    select array_agg(distinct rp.permission_code order by rp.permission_code) into v_perms
      from erp.user_role ur
      join erp.role_permission rp on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
     where ur.tenant_id = rb.tenant_id and ur.app_user_id = v_priya
       and rp.permission_code like 'sales.%';

    v_cases := v_cases + 1;
    case_name := 'the demonstration''s second person may raise an invoice and read sales, and may not order, price or despatch';
    passed := v_state is null and v_perms = array['sales.invoice', 'sales.read'];
    detail := format('her sales permissions: %s', coalesce(array_to_string(v_perms, ', '), 'none'));
    return next;

    v_step := 'the presenter sells ten from stock and despatches them';
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select p.id into v_cust from erp.party p
      join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id and pr.role_kind = 'customer'
     where p.tenant_id = rb.tenant_id order by p.code limit 1;
    -- Fifty of a finished product on a pickable shelf, received at five
    -- pounds: the configuration seeds no stock until history is built.
    select i.id into v_item from erp.item i
     where i.tenant_id = rb.tenant_id and i.status = 'active' and i.item_class = 'finished_good'
     order by i.code limit 1;
    select l.id into v_loc from erp.location l
     where l.tenant_id = rb.tenant_id and l.site_id = v_site and l.is_pickable and l.status = 'active'
     order by l.code limit 1;
    perform erp.receive_cost(v_item, v_site, 50, 500,
                             (select e.base_currency from erp.entity e where e.id = v_entity));
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id,
      to_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
    select rb.tenant_id, v_entity, v_site, 'receipt_no_order', v_item, v_loc, 'available', 50, i.stock_uom_id, 500,
           (select e.base_currency from erp.entity e where e.id = v_entity), 'OPENING'
      from erp.item i where i.id = v_item;
    v_so := erp.create_document('sales_order', v_entity, v_site, v_cust, current_date,
                                (select e.base_currency from erp.entity e where e.id = v_entity), 'ZZDPI', '{}'::jsonb);
    v_sol := erp.add_document_line(v_so, v_item, 10, 1000, 'ten for the walk', current_date + 7);
    perform erp.transition_document(v_so, 'submit', 'demo persona invoices suite');
    perform erp.approve_my_document_tasks(v_so, 'demo persona invoices suite');
    if erp.document_state_code(v_so) not in ('approved', 'confirmed') then
      perform erp.transition_document(v_so, 'approve', 'demo persona invoices suite');
    end if;
    if coalesce((select cp.on_hold from erp.credit_position(v_cust) cp), false) then
      perform erp.release_credit_hold(v_so, 'demo persona invoices suite');
    end if;
    v_dn := (erp.create_delivery_from_order(v_so,
               jsonb_build_array(jsonb_build_object('line_id', v_sol, 'quantity', 10)), null) ->> 'document_id')::uuid;
    select dl.id into v_dnl from erp.document_line dl where dl.document_id = v_dn order by dl.line_no limit 1;
    perform erp.set_line_stock_identity(v_dnl, null, v_loc, null);
    perform erp.transition_document(v_dn, 'post', 'demo persona invoices suite');

    v_step := 'the presenter invoices their own delivery';
    begin
      perform erp.invoice_from_delivery(v_dn, false, null);
      v_msg := 'it was invoiced';
    exception when others then v_msg := left(sqlerrm, 200);
    end;

    v_cases := v_cases + 1;
    case_name := 'the presenter who despatched is still refused the invoice: the two halves stay with two people';
    passed := v_state is null and v_msg <> 'it was invoiced';
    detail := v_msg;
    return next;

    v_step := 'acting as her, as the signed-in role, the invoice is raised and issued';
    perform set_config('request.headers', v_tab, true);
    execute 'set local role authenticated';
    v_inv := (public.erp_invoice_from_delivery(v_dn, null, null));
    perform public.erp_transition_document(v_inv, 'issue', 'demo persona invoices suite');
    execute 'reset role';
    perform set_config('request.headers', '', true);

    v_cases := v_cases + 1;
    case_name := 'acting as her, the invoice is raised from the delivery and issued, with no override';
    passed := v_state is null and v_inv is not null and erp.document_state_code(v_inv) = 'issued';
    detail := format('%s reads %s',
                     coalesce((select d.document_number from erp.document d where d.id = v_inv), 'no invoice'),
                     coalesce(erp.document_state_code(v_inv), 'nothing'));
    return next;

    v_cases := v_cases + 1;
    case_name := 'and the trail says she raised it while the presenter was signed in';
    passed := v_state is null
          and exists (select 1 from erp.document d where d.id = v_inv and d.created_by = v_priya);
    detail := format('created by %s', coalesce((select u.display_name from erp.document d
                                                  join erp.app_user u on u.id = d.created_by
                                                 where d.id = v_inv), 'nobody'));
    return next;

    v_cases := v_cases + 1;
    case_name := 'ensuring her role again changes nothing';
    passed := v_state is null and erp.ensure_demo_receivables_role(rb.tenant_id) = 0;
    detail := 'already given';
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.headers', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'demo-zzdpi' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'the demonstration rolled back with its order, delivery and invoice');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_DEMO_PERSONA_INVOICES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_demo_persona_invoices_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _demo_persona_invoices on commit drop as
    select * from erp_test.demo_persona_invoices_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _demo_persona_invoices;
  drop table _demo_persona_invoices;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DEMO_PERSONA_INVOICES_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_DEMO_PERSONA_INVOICES_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('the demonstration''s second person raises the invoice: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.demo_persona_invoices_suite() from public, anon;
revoke all on function erp_test.assert_demo_persona_invoices_suite() from public, anon;

comment on function erp_test.demo_persona_invoices_suite() is
  'The demonstration''s second person raises the invoice (20261010170000): she may invoice and read sales only; the '
  'presenter who despatched is refused the invoice; acting as her it is raised and issued, recorded as hers.';

comment on function erp_test.assert_demo_persona_invoices_suite() is
  'erp_test.demo_persona_invoices_suite(), six cases: order to cash walked by one presenter and the persona.';

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
