set lock_timeout = '30s';

-- =============================================================================
-- 20260922390000  One press installs procurement and its bills
-- -----------------------------------------------------------------------------
-- PR4 M2, second migration (P4). The first, 20260922380000, is version 2 of
-- the procurement lifecycle. This one changes what pressing Install on
-- Procurement does.
--
-- ── 1. One press, two change sets ───────────────────────────────────────────
--
-- public.erp_configure_procurement installed the procurement lifecycle and
-- nothing else: the requisition, the purchase order and the goods receipt.
-- The supplier bill and the supplier credit note came from a second card,
-- Procurement controls, which an organisation had to find and press on its
-- own. An organisation that pressed only the first could order and receive,
-- and had no way to be billed for what it received: goods received but not
-- invoiced grew, and nothing on the desk could clear it.
--
-- The door now installs both, each as its own change set:
--
--   * procurement-lifecycle, through erp.configure_procurement(), with the
--     threshold and the approving role the press names;
--   * procurement-controls, through erp.configure_procurement_controls(),
--     with its own default approver ('administrator'): the supplier bill and
--     supplier credit note lifecycles, their numbering and posting, the
--     receipt and match tolerances, and the match exception chain.
--
-- Five lifecycles in two change sets. It returns change_set_id (the first it
-- made, as before), change_set_ids (every one it made),
-- lifecycle_change_set_id and controls_change_set_id (null where the
-- organisation already had it). An organisation holding only the lifecycle
-- gets the controls, and nothing else.
--
-- Before go-live both are put in force by the press. Once live both wait in
-- Change requests for somebody other than their author, as every installed
-- module does (erp.install_module_config()).
--
-- ── 2. Both doors are idempotent by refusal ─────────────────────────────────
--
-- A change set's code is unique in its organisation
-- (change_set_tenant_id_code_key). A second press used to meet that
-- constraint as a raw duplicate key, and after this migration the controls
-- card would have met it every time, because the procurement door has
-- already made its change set. So each door now, in this order:
--
--   1. authorises administration.configure, as erp.install_module_config()
--      does, so a caller without it learns nothing and takes no lock;
--   2. takes one advisory lock per organisation, shared by both doors, so two
--      presses at once cannot both find nothing and both install;
--   3. looks the change sets up by code and refuses, by name, when there is
--      nothing left for it to install: CLOVEERP_PROCUREMENT_ALREADY_INSTALLED
--      and CLOVEERP_PROCUREMENT_CONTROLS_ALREADY_INSTALLED. The refusal names
--      the status of each change set it found.
--
-- ── 3. A cancelled or failed install ────────────────────────────────────────
--
-- A change set that was cancelled, failed in promotion or was rolled back
-- keeps its code, so it still counts as there: pressing again is refused,
-- and the refusal says which of those it is. Re-installing over it would
-- mean retiring the old code, and a change set is the record of what was
-- proposed. That is out of scope here, and the refusal says where to look.
--
-- ── 4. The suites ───────────────────────────────────────────────────────────
--
--   * erp_test.second_organisation_suite counts promoted change sets after
--     onboarding through the doors: nine now, not eight.
--   * erp_test.approval_hold_suite and erp_test.administrator_approval_suite
--     install procurement through the door in a live organisation and put
--     what it made in force. There are two change sets to approve now.
--   * erp_test.procurement_door_suite is new, nine cases.
--
-- ── WHAT IS DELIBERATELY NOT HERE ────────────────────────────────────────────
--
--   * erp.configure_procurement() and erp.configure_procurement_controls()
--     are unchanged. Suites, the demonstration and the seeders call them
--     directly and in their own order, and they stay the installers.
--   * Retrying a cancelled or failed install (section 3).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The procurement door
-- ─────────────────────────────────────────────────────────────────────────────

-- Same arguments and return type as before, so this replaces the SQL body in
-- place and keeps its grants; the language may change under create or replace.
create or replace function public.erp_configure_procurement(
  p_approval_threshold_minor bigint default 1000000,
  p_approver_role            text   default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant      uuid;
  v_life        uuid;
  v_life_status text;
  v_ctrl        uuid;
  v_ctrl_status text;
  v_made        uuid[] := '{}';
begin
  -- Authorised first, as erp.install_module_config() is: a caller who may not
  -- configure learns nothing about what is installed and takes no lock.
  perform erp.authorise('administration.configure', null, null, null,
                        'change_set', null);
  v_tenant := erp.require_tenant_id();

  -- One lock for both procurement doors, so two presses cannot both find
  -- nothing and both install.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('erp.procurement_install'), pg_catalog.hashtext(v_tenant::text));

  select c.id, c.status::text into v_life, v_life_status
    from erp.change_set c
   where c.tenant_id = v_tenant and c.code = 'procurement-lifecycle';
  select c.id, c.status::text into v_ctrl, v_ctrl_status
    from erp.change_set c
   where c.tenant_id = v_tenant and c.code = 'procurement-controls';

  if v_life is not null and v_ctrl is not null then
    raise exception 'CLOVEERP_PROCUREMENT_ALREADY_INSTALLED: procurement is already installed here: its lifecycle change request is %, and its controls change request is %',
      v_life_status, v_ctrl_status
      using errcode = '23514',
            detail = format('procurement-lifecycle %s is %s; procurement-controls %s is %s.',
                            v_life, v_life_status, v_ctrl, v_ctrl_status),
            hint = case
              when v_life_status in ('failed', 'cancelled', 'rolled_back')
                or v_ctrl_status in ('failed', 'cancelled', 'rolled_back') then
                'An install that was cancelled, failed or rolled back keeps its name, so pressing again cannot install it. Open Change requests to see why it stopped.'
              when v_life_status = 'promoted' and v_ctrl_status = 'promoted' then
                'Both are in force. A newer version arrives as an upgrade from the Installed modules list, not by installing again.'
              else
                'Open Change requests: the install is waiting there for somebody other than its author to approve it and put it in force.'
            end;
  end if;

  if v_life is null then
    v_life := erp.configure_procurement(
                p_approval_threshold_minor,
                erp.approver_role_for(p_approver_role, 'procurement_manager'));
    v_made := v_made || v_life;
  else
    v_life := null;
  end if;

  -- The controls keep their own default approver.
  if v_ctrl is null then
    v_ctrl := erp.configure_procurement_controls();
    v_made := v_made || v_ctrl;
  else
    v_ctrl := null;
  end if;

  -- Every id here is a change set this press made; null where the
  -- organisation already had it.
  return jsonb_build_object(
    'change_set_id',           v_made[1],
    'change_set_ids',          to_jsonb(v_made),
    'lifecycle_change_set_id', v_life,
    'controls_change_set_id',  v_ctrl);
end;
$$;

comment on function public.erp_configure_procurement(bigint, text) is
  'Installs procurement in one press, as two changes: the requisition, purchase '
  'order and goods receipt lifecycles with their approval chains '
  '(procurement-lifecycle), and the supplier bill and supplier credit note '
  'lifecycles with the receipt and match tolerances (procurement-controls). '
  'Installs whichever the organisation does not have, and refuses by name when '
  'it has both. p_approver_role names the role asked to approve orders and '
  'requisitions; left empty, procurement_manager where somebody holds it, and '
  'administrator otherwise.';

revoke all on function public.erp_configure_procurement(bigint, text) from public, anon;
grant execute on function public.erp_configure_procurement(bigint, text) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. The controls door
-- ─────────────────────────────────────────────────────────────────────────────

-- Still there for an organisation that installed the lifecycle alone. Same
-- argument and return type as before.
create or replace function public.erp_configure_procurement_controls(
  p_approver_role text default 'administrator'
) returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_ctrl   uuid;
  v_status text;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'change_set', null);
  v_tenant := erp.require_tenant_id();

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('erp.procurement_install'), pg_catalog.hashtext(v_tenant::text));

  select c.id, c.status::text into v_ctrl, v_status
    from erp.change_set c
   where c.tenant_id = v_tenant and c.code = 'procurement-controls';

  if v_ctrl is not null then
    raise exception 'CLOVEERP_PROCUREMENT_CONTROLS_ALREADY_INSTALLED: the procurement controls are already installed here: their change request is %',
      v_status
      using errcode = '23514',
            detail = format('procurement-controls %s is %s.', v_ctrl, v_status),
            hint = case
              when v_status in ('failed', 'cancelled', 'rolled_back') then
                'An install that was cancelled, failed or rolled back keeps its name, so pressing again cannot install it. Open Change requests to see why it stopped.'
              when v_status = 'promoted' then
                'They are in force. Installing Procurement installs them with it, and a newer version arrives as an upgrade from the Installed modules list.'
              else
                'Open Change requests: the controls are waiting there for somebody other than their author to approve them and put them in force.'
            end;
  end if;

  return erp.configure_procurement_controls(p_approver_role);
end;
$$;

comment on function public.erp_configure_procurement_controls(text) is
  'Installs the procurement controls (the supplier bill and supplier credit '
  'note lifecycles, the receipt and match tolerances and the match exception '
  'chain) for an organisation that installed the procurement lifecycle alone. '
  'Installing Procurement installs them with it; this refuses by name when '
  'they are there.';

revoke all on function public.erp_configure_procurement_controls(text) from public, anon;
grant execute on function public.erp_configure_procurement_controls(text) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Why the doors may write
-- ─────────────────────────────────────────────────────────────────────────────

-- Both rows exist; only the reason changes. Each update is checked to touch
-- its row.
do $allow$
declare
  v_n integer;
begin
  update erp_meta.public_write_allowance
     set rationale = 'Installs procurement in one press: the lifecycle through '
                     'erp.configure_procurement() and the controls through '
                     'erp.configure_procurement_controls(), each a B6 change set. '
                     'Authorises administration.configure before it reads anything, '
                     'and both installers are gated again inside '
                     'erp.install_module_config(), which they delegate to.'
   where function_name = 'erp_configure_procurement'
     and gate = 'erp.configure_procurement';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the write allowance for erp_configure_procurement touched % row(s)', v_n;
  end if;

  update erp_meta.public_write_allowance
     set rationale = 'Installs the procurement controls, for an organisation that '
                     'installed the lifecycle alone, as a B6 change set the caller '
                     'cannot approve once live. Authorises administration.configure '
                     'before it reads anything, and the controls path is gated again '
                     'inside erp.install_module_config(), which '
                     'erp.configure_procurement_controls() delegates to.'
   where function_name = 'erp_configure_procurement_controls'
     and gate = 'erp.configure_procurement_controls';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the write allowance for erp_configure_procurement_controls touched % row(s)', v_n;
  end if;
end
$allow$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The refusals, registered
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_PROCUREMENT_ALREADY_INSTALLED',
  'Installing Procurement in an organisation that already has both its lifecycle and its controls, in whatever state they are.',
  'Each install is a change request, and its name is the organisation''s record of what was proposed, so it is made once. Pressing again would either make a second request competing with the first or overwrite the record of what somebody approved.',
  'Open Change requests: an install waiting there is approved and put in force by somebody other than its author. One in force is upgraded from the Installed modules list. One that was cancelled, failed or rolled back keeps its name, and says there why it stopped.');

select erp.register_refusal('CLOVEERP_PROCUREMENT_CONTROLS_ALREADY_INSTALLED',
  'Installing the procurement controls in an organisation that already has them, in whatever state they are.',
  'Installing Procurement installs the controls with it, and the controls are a change request made once per organisation. Pressing the controls again would make a second request competing with the first or overwrite the record of what somebody approved.',
  'Open Change requests to see the controls'' request and approve it if it is waiting. Once they are in force there is nothing to install; a newer version is an upgrade from the Installed modules list.');

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. The suites the second change set touches
-- ─────────────────────────────────────────────────────────────────────────────

-- Nordwind is onboarded through the doors, so the controls come with
-- procurement: nine change sets in force.
do $nordwind$
declare
  v_sig constant text := 'erp_test.second_organisation_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$three legislation packs, eight modules installed,$o$;
  b1 constant text := $n$three legislation packs, nine modules installed,$n$;
  a2 constant text := $o$cs.status = 'promoted') = 8$o$;
  b2 constant text := $n$cs.status = 'promoted') = 9$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a1, b1), a2, b2);
end
$nordwind$;

-- The live organisation installs through the door the Configuration screen
-- calls, and the second administrator puts in force both change sets it made.
do $hold$
declare
  v_sig constant text := 'erp_test.approval_hold_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$  cs_proc  uuid;
  cs_sales uuid;
$o$;
  b1 constant text := $n$  cs_proc  uuid;
  cs_ctrl  uuid;
  cs_sales uuid;
$n$;
  a2 constant text := $o$    cs_proc := (public.erp_configure_procurement(1000000, 'purchasing') ->> 'change_set_id')::uuid;
$o$;
  b2 constant text := $n$    -- Procurement is two change sets: the lifecycle and its controls
    -- (20260922390000).
    select (d ->> 'lifecycle_change_set_id')::uuid, (d ->> 'controls_change_set_id')::uuid
      into cs_proc, cs_ctrl
      from public.erp_configure_procurement(1000000, 'purchasing') d;
$n$;
  a3 constant text := $o$    perform erp.promote_change_set(cs_proc);
$o$;
  b3 constant text := $n$    perform erp.promote_change_set(cs_proc);
    perform erp.approve_change_set(cs_ctrl);
    perform erp.promote_change_set(cs_ctrl);
$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2),
      (length(v_def) - length(replace(v_def, a3, ''))) / length(a3)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(replace(v_def, a1, b1), a2, b2), a3, b3);
end
$hold$;

-- Organisation A's second administrator puts both in force; organisation B's
-- one administrator approves and promotes whatever the press made.
do $adap$
declare
  v_sig constant text := 'erp_test.administrator_approval_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$  cs_proc  uuid;
  v_role   uuid;
$o$;
  b1 constant text := $n$  cs_proc  uuid;
  cs_ctrl  uuid;
  v_role   uuid;
$n$;
  a2 constant text := $o$    cs_proc := (public.erp_configure_procurement(1000000, 'purchasing') ->> 'change_set_id')::uuid;
$o$;
  b2 constant text := $n$    -- Procurement is two change sets: the lifecycle and its controls
    -- (20260922390000).
    select (d ->> 'lifecycle_change_set_id')::uuid, (d ->> 'controls_change_set_id')::uuid
      into cs_proc, cs_ctrl
      from public.erp_configure_procurement(1000000, 'purchasing') d;
$n$;
  a3 constant text := $o$    perform erp.promote_change_set(cs_proc);
$o$;
  b3 constant text := $n$    perform erp.promote_change_set(cs_proc);
    perform erp.approve_change_set(cs_ctrl);
    perform erp.promote_change_set(cs_ctrl);
$n$;
  a4 constant text := $o$    v_cs := (public.erp_configure_procurement(1000000, 'administrator') ->> 'change_set_id')::uuid;
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
$o$;
  b4 constant text := $n$    v_out := public.erp_configure_procurement(1000000, 'administrator');
    for x in select e.id from jsonb_array_elements_text(v_out -> 'change_set_ids') as e(id) loop
      perform erp.approve_change_set(x.id::uuid);
      perform erp.promote_change_set(x.id::uuid);
    end loop;
    v_cs := (v_out ->> 'lifecycle_change_set_id')::uuid;
$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2),
      (length(v_def) - length(replace(v_def, a3, ''))) / length(a3),
      (length(v_def) - length(replace(v_def, a4, ''))) / length(a4)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(replace(replace(v_def, a1, b1), a2, b2), a3, b3), a4, b4);
end
$adap$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. What proves it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.procurement_door_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_job_before    text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_claims_before text := coalesce(current_setting('request.jwt.claims', true), '');
  v_hex  text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1 uuid := gen_random_uuid();   -- A's administrator, before go-live
  a2 uuid := gen_random_uuid();   -- A's buyer, who may not configure
  a3 uuid := gen_random_uuid();   -- B's first administrator, live
  a5 uuid := gen_random_uuid();   -- C's administrator, the lifecycle alone
  ra record; rb record; rc record;
  v_step text := 'starting';
  v_fail text;
  res jsonb; v_uid uuid; v_tok text;
  -- What each case reads.
  r1 jsonb; v_active integer; v_in_force integer;
  e2 text; c2 text; h2 text;
  r3 jsonb;
  r4 jsonb; e4 text;
  e5 text; e5c text;
  e6 text; c6 text;
  v_uom uuid; v_site uuid; v_sup uuid; v_item uuid;
  v_po uuid; v_grn uuid; v_bill uuid; v_po_state text; v_bill_state text;
  e8 text; v_bill_after text;
  t uuid;
begin
  begin
    -- ── Organisation A: not live; finance and inventory, then one press ─────
    v_step := 'organisation A is provisioned';
    select * into ra from erp.provision_tenant('zzpd-a-' || v_hex, 'Procurement Door Suite A',
                                               'admin@zzpd-a-' || v_hex || '.test', 'Door Admin');
    perform set_config('erp.job_tenant_id', '', true);
    update erp.environment set is_live = false where tenant_id = ra.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(ra.admin_token);
    perform erp.configure_finance();
    perform erp.configure_inventory('average');

    v_step := 'organisation A presses Install on Procurement';
    r1 := public.erp_configure_procurement();
    select count(*) into v_active
      from erp.state_machine m
     where m.tenant_id = ra.tenant_id and m.status = 'active'
       and m.code in ('requisition', 'purchase_order', 'goods_receipt',
                      'purchase_invoice', 'purchase_credit_note')
       and exists (select 1 from erp.state_machine_version v
                    where v.tenant_id = m.tenant_id and v.state_machine_id = m.id
                      and v.status = 'active');
    select count(*) into v_in_force
      from erp.change_set c
     where c.tenant_id = ra.tenant_id and c.status = 'promoted'
       and ((c.code = 'procurement-lifecycle' and c.id = (r1 ->> 'lifecycle_change_set_id')::uuid)
         or (c.code = 'procurement-controls'  and c.id = (r1 ->> 'controls_change_set_id')::uuid));

    v_step := 'organisation A presses again';
    begin
      perform public.erp_configure_procurement();
    exception when others then
      get stacked diagnostics e2 = message_text, c2 = returned_sqlstate, h2 = pg_exception_hint;
    end;

    v_step := 'organisation A presses the controls card';
    begin
      perform public.erp_configure_procurement_controls();
    exception when others then
      get stacked diagnostics e6 = message_text, c6 = returned_sqlstate;
    end;

    v_step := 'a buyer who may not configure presses both doors';
    res := public.erp_invite_principal('buyer@zzpd-a-' || v_hex || '.test', 'Door Buyer');
    v_uid := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_uid, 'purchasing', null, null, 'the procurement door suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    begin
      perform public.erp_configure_procurement();
    exception when others then e5 := sqlerrm; end;
    begin
      perform public.erp_configure_procurement_controls();
    exception when others then e5c := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'an order is raised, received and billed in organisation A';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (ra.tenant_id, 'ZEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (ra.tenant_id, ra.entity_id, 'ZMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (ra.tenant_id, v_site, 'ZRECV', 'Receiving', 'receiving', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (ra.tenant_id, 'ZSUP', 'Door Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (ra.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, net_weight_g, status)
    values (ra.tenant_id, 'ZWID', 'Door Widget', v_uom, 100, 'active') returning id into v_item;

    v_po := erp.open_document('purchase_order', v_sup, ra.entity_id, v_site);
    perform erp.add_document_line(v_po, v_item, 10, 1000, 'ten widgets');
    perform public.erp_transition_document(v_po, 'submit', null);
    if erp.object_current_state('document', v_po) = 'pending_approval' then
      perform erp_test.approve_document(v_po, null);
    end if;
    perform public.erp_transition_document(v_po, 'send', null);
    v_grn := (public.erp_create_receipt_from_order(v_po, null, 'post') ->> 'document_id')::uuid;
    v_bill := (public.erp_bill_from_receipt(v_grn, 'ZPD-1', current_date, current_date + 30)
                 ->> 'document_id')::uuid;
    v_bill_state := erp.object_current_state('document', v_bill);
    v_po_state := erp.object_current_state('document', v_po);

    v_step := 'the bill is marked paid by hand';
    begin
      perform public.erp_transition_document(v_bill, 'pay', 'marked paid by hand');
    exception when others then e8 := sqlerrm; end;
    v_bill_after := erp.object_current_state('document', v_bill);

    -- ── Organisation C: the lifecycle alone, then the door ──────────────────
    v_step := 'organisation C is provisioned and installs the lifecycle alone';
    perform set_config('request.jwt.claims', '', true);
    select * into rc from erp.provision_tenant('zzpd-c-' || v_hex, 'Procurement Door Suite C',
                                               'admin@zzpd-c-' || v_hex || '.test', 'Lifecycle Admin');
    perform set_config('erp.job_tenant_id', '', true);
    update erp.environment set is_live = false where tenant_id = rc.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a5)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(1000000, 'administrator');
    v_step := 'organisation C presses Install on Procurement';
    r3 := public.erp_configure_procurement();

    -- ── Organisation B: live, two administrators ────────────────────────────
    v_step := 'organisation B is provisioned, live, with two administrators';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant('zzpd-b-' || v_hex, 'Procurement Door Suite B',
                                               'admin@zzpd-b-' || v_hex || '.test', 'Live Admin');
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp_test.administrator_approval_off(rb.tenant_id);
    res := public.erp_invite_principal('second@zzpd-b-' || v_hex || '.test', 'Second Admin');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    perform erp.configure_finance();
    v_step := 'organisation B presses Install on Procurement, twice';
    r4 := public.erp_configure_procurement(1000000, 'administrator');
    begin
      perform public.erp_configure_procurement();
    exception when others then e4 := sqlerrm; end;
  exception when others then
    v_fail := v_step || ': ' || left(sqlerrm, 300);
  end;

  -- 1.
  case_name := 'one press installs five lifecycles in two change sets: requisition, order, receipt, supplier bill and supplier credit note';
  passed := v_fail is null
            and v_active = 5 and v_in_force = 2
            and (r1 ->> 'change_set_id') = (r1 ->> 'lifecycle_change_set_id')
            and r1 -> 'change_set_ids' = jsonb_build_array(r1 -> 'lifecycle_change_set_id', r1 -> 'controls_change_set_id');
  detail := coalesce(v_fail, format('%s of 5 lifecycles active; %s of 2 change sets in force; returned %s',
                                    v_active, v_in_force, r1));
  return next;

  -- 2.
  case_name := 'a second press is refused by name, and the refusal gives each change set''s status';
  passed := v_fail is null
            and coalesce(e2 like 'CLOVEERP_PROCUREMENT_ALREADY_INSTALLED:%lifecycle change request is promoted, and its controls change request is promoted'
                         and c2 <> '23505' and h2 like 'Both are in force.%', false)
            and (select count(*) from erp.change_set c
                  where c.tenant_id = ra.tenant_id and c.code like 'procurement-%') = 2;
  detail := coalesce(v_fail, left(e2, 200), 'the second press was taken');
  return next;

  -- 3.
  case_name := 'an organisation holding only the lifecycle gets the controls, and nothing else';
  passed := v_fail is null
            and r3 ->> 'lifecycle_change_set_id' is null
            and (r3 ->> 'controls_change_set_id') = (r3 ->> 'change_set_id')
            and r3 -> 'change_set_ids' = jsonb_build_array(r3 -> 'controls_change_set_id')
            and exists (select 1 from erp.change_set c
                         where c.tenant_id = rc.tenant_id and c.code = 'procurement-controls'
                           and c.id = (r3 ->> 'controls_change_set_id')::uuid and c.status = 'promoted')
            and (select count(*) from erp.change_set c
                  where c.tenant_id = rc.tenant_id and c.code = 'procurement-lifecycle') = 1
            and exists (select 1 from erp.state_machine m
                         where m.tenant_id = rc.tenant_id and m.code = 'purchase_invoice' and m.status = 'active');
  detail := coalesce(v_fail, format('returned %s', r3));
  return next;

  -- 4.
  case_name := 'in a live organisation both change sets wait, and the door names both';
  passed := v_fail is null
            and r4 ->> 'lifecycle_change_set_id' is not null
            and r4 ->> 'controls_change_set_id' is not null
            and r4 -> 'change_set_ids' = jsonb_build_array(r4 -> 'lifecycle_change_set_id', r4 -> 'controls_change_set_id')
            and (select count(*) from erp.change_set c
                  where c.tenant_id = rb.tenant_id and c.status = 'ready'
                    and c.id in ((r4 ->> 'lifecycle_change_set_id')::uuid,
                                 (r4 ->> 'controls_change_set_id')::uuid)) = 2
            and not exists (select 1 from erp.state_machine m
                             where m.tenant_id = rb.tenant_id
                               and m.code in ('purchase_order', 'purchase_invoice'))
            and coalesce(e4 like 'CLOVEERP_PROCUREMENT_ALREADY_INSTALLED:%lifecycle change request is ready, and its controls change request is ready', false);
  detail := coalesce(v_fail, format('returned %s; statuses %s; pressed again: %s', r4,
                       (select string_agg(c.code || ' ' || c.status, ', ' order by c.code)
                          from erp.change_set c
                         where c.tenant_id = rb.tenant_id and c.code like 'procurement-%'),
                       coalesce(left(e4, 160), 'taken')));
  return next;

  -- 5. Both are installed in A, so a door that read before it authorised
  --    would answer with what is installed.
  case_name := 'a caller without administration.configure is refused before anything is read';
  passed := v_fail is null
            and coalesce(e5 like 'CLOVEERP_PERMISSION_DENIED: administration.configure%'
                         and e5c like 'CLOVEERP_PERMISSION_DENIED: administration.configure%', false);
  detail := coalesce(v_fail, format('procurement: %s; controls: %s',
                                    coalesce(left(e5, 120), 'taken'), coalesce(left(e5c, 120), 'taken')));
  return next;

  -- 6.
  case_name := 'the controls door after the procurement door is refused by name, not with a duplicate key';
  passed := v_fail is null
            and coalesce(e6 like 'CLOVEERP_PROCUREMENT_CONTROLS_ALREADY_INSTALLED:%change request is promoted'
                         and c6 <> '23505', false);
  detail := coalesce(v_fail, format('%s (%s)', coalesce(left(e6, 200), 'the controls were installed again'), c6));
  return next;

  -- 7.
  case_name := 'in an organisation installed through the door, a bill registered from the receipt closes its order';
  passed := v_fail is null and v_bill_state = 'registered' and v_po_state = 'closed';
  detail := coalesce(v_fail, format('the bill is %s; the order is %s', v_bill_state, v_po_state));
  return next;

  -- 8.
  case_name := 'a registered bill is not paid by hand while it owes';
  passed := v_fail is null
            and coalesce(e8 like 'CLOVEERP_DOCUMENT_STILL_OWES%', false)
            and v_bill_after = 'registered';
  detail := coalesce(v_fail, format('%s; the bill is %s',
                                    coalesce(left(e8, 120), 'it was marked paid'), v_bill_after));
  return next;

  -- 9.
  set constraints all immediate;
  perform set_config('request.jwt.claims', '', true);
  for t in select tn.id from erp.tenant tn
            where tn.code in ('zzpd-a-' || v_hex, 'zzpd-b-' || v_hex, 'zzpd-c-' || v_hex)
  loop
    perform erp.begin_tenant_purge(t);
    delete from erp.tenant where id = t;
    perform erp.end_tenant_purge();
  end loop;
  perform set_config('request.jwt.claims', v_claims_before, true);
  perform set_config('erp.job_tenant_id', v_job_before, true);

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code like 'zzpd-_-' || v_hex)
            and not exists (select 1 from erp.change_set c
                             where c.tenant_id in (ra.tenant_id, rb.tenant_id, rc.tenant_id))
            and coalesce(current_setting('request.jwt.claims', true), '') = v_claims_before
            and coalesce(current_setting('erp.job_tenant_id', true), '') = v_job_before;
  detail := 'three organisations, their change sets, the order and its bill purged; the caller''s context restored';
  return next;
end;
$$;

comment on function erp_test.procurement_door_suite() is
  'One press installs procurement and its bills (20260922390000): five '
  'lifecycles in two change sets, a second press and the controls card refused '
  'by name with each set''s status, the controls added to an organisation that '
  'had the lifecycle alone, both waiting once live, the permission asked before '
  'anything is read, and a bill from the receipt closing its order.';

create or replace function erp_test.assert_procurement_door_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ')
           filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.procurement_door_suite() s;

  if v_total <> 9 then
    raise exception 'CLOVEERP_PROCUREMENT_DOOR_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;

  if v_failed > 0 then
    raise exception 'CLOVEERP_PROCUREMENT_DOOR_SUITE_FAILED: %/% case(s) failed%',
      v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Installing procurement is one press that installs what is missing and refuses by name what is there. A raw duplicate key, a missing bill lifecycle or a door that reads before it authorises is the defect this suite exists for. Read the case that failed.';
  end if;
end;
$$;

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
select erp.assert_every_transition_is_driven();
