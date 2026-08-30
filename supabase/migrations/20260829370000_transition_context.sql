-- =============================================================================
-- The menu and the enforcement, from one definition
--
-- public.erp_document() returned available_transitions built from a raw join on
-- erp.transition: every transition out of the current state, with no notion of
-- whether the caller may take it. erp.available_transitions() already answers
-- that — code, name, to_state, guard_passes, permitted, is_automatic — and
-- nothing called it.
--
-- The difference is not cosmetic. On a confirmed sales order, asked by an
-- administrator and by a clerk holding sales.order but not sales.despatch:
--
--   administrator   pick {permitted: true}   cancel_confirmed {permitted: true}
--   order taker     pick {permitted: false}  cancel_confirmed {permitted: true}
--
-- The raw join returned the same two rows to both, so a screen would have
-- offered "Start picking" to somebody the database refuses.
--
-- The context extraction is the other half, and it is worth being exact about
-- what it does and does not fix. erp.available_transitions() evaluates guards
-- against a jsonb context defaulting to '{}'. The real context —
-- total_minor, max_discount_pct, credit_limit_minor, exposure_after_minor —
-- was assembled inside erp.transition_document() and nowhere else, so any
-- caller other than that function could only ask with '{}'.
--
-- Today that changes no answer, and it would be dishonest to imply otherwise:
-- **no transition in the installed product carries a guard at all**. Checked
-- rather than assumed — `select count(*) from erp.transition where guard is
-- not null and guard <> '{}'` is zero after every module is installed. The
-- value banding people expect to find in guards lives in approval chains
-- instead. erp.transition.guard is read by erp.perform_transition() and
-- erp.available_transitions() and written by nothing, which is the same shape
-- as the dead configuration erp.assert_no_dead_configuration() already
-- catalogues, from the other side: machinery nobody has authored against
-- rather than configuration nothing reads.
--
-- So this extraction is not repairing a live bug. It means the first guard
-- somebody authors is evaluated against the real numbers from both sides,
-- instead of being correct where transition_document asks and silently false
-- everywhere else. That is worth doing before the facility is used, not after.
--
-- erp.transition_document() is re-emitted around the call and is otherwise
-- unchanged — including, deliberately, the literal text erp.perform_transition(
-- in its body. Rule 3d of erp.public_api_report() walks the call graph by
-- searching prosrc, so erp_transition_document's allowance reaches
-- erp.authorise() only while that string survives the edit.
-- =============================================================================

create or replace function erp.document_transition_context(
  p_document_id     uuid,
  p_transition_code text default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_ctx    jsonb;
  v_total  bigint;
  v_discount numeric;
  v_limit  bigint;
  v_exposure bigint;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  v_total := erp.document_value_minor(p_document_id);

  select coalesce(max(l.discount_pct), 0) into v_discount
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled;

  -- The customer's limit, from their customer role. Absent means no limit was
  -- set, and an absent limit must not read as a limit of zero — that would put
  -- every order through credit release.
  select coalesce((pr.attributes ->> 'credit_limit_minor')::bigint, 9223372036854775807)
    into v_limit
    from erp.party_role pr
   where pr.tenant_id = v_tenant and pr.party_id = d.party_id
     and pr.role_kind = 'customer' and pr.status = 'active'
   limit 1;

  -- Everything already committed for this customer and not yet invoiced or
  -- finished, excluding this document so the sum below is not doubled.
  select coalesce(sum(erp.document_value_minor(d2.id)), 0) into v_exposure
    from erp.document d2
    join erp.document_type dt2 on dt2.tenant_id = d2.tenant_id and dt2.id = d2.document_type_id
    join erp.object_state os2 on os2.tenant_id = d2.tenant_id
                             and os2.object_type = 'document' and os2.object_id = d2.id
    join erp.state s2 on s2.id = os2.current_state_id
   where d2.tenant_id = v_tenant
     and d2.party_id = d.party_id
     and dt2.base_type_code = 'sales_order'
     and s2.is_committed and not s2.is_terminal
     and d2.id <> p_document_id
     and not d2.is_cancelled;

  v_ctx := jsonb_build_object(
    'document_type', dt.code,
    'document_number', d.document_number,
    'total_minor', v_total,
    'currency', d.currency,
    'party_id', d.party_id,
    'entity_id', d.entity_id,
    'transition', p_transition_code,
    'max_discount_pct', v_discount,
    'credit_limit_minor', coalesce(v_limit, 9223372036854775807),
    'exposure_after_minor', v_exposure + v_total);

  return v_ctx;
end;
$$;

create or replace function erp.transition_document(
  p_document_id    uuid,
  p_transition_code text,
  p_reason         text default null
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_ctx    jsonb;
  v_to     text;
  v_committed boolean;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  -- The context the guards are evaluated against, from the one function that
  -- knows how to build it. It was assembled here and nowhere else, which meant
  -- erp.available_transitions() — the function a screen asks "what may I do
  -- next?" — could only be called with '{}', and reported every value-banded
  -- transition as blocked. The menu and the enforcement now read one
  -- definition.
  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);

  if p_transition_code = 'submit' and dt.approval_chain_code is not null then
    perform erp.request_approval('document', p_document_id, v_ctx, 1,
                                 d.entity_id, d.site_id);
  end if;

  v_to := erp.perform_transition('document', p_document_id, p_transition_code,
                                 v_ctx, p_reason);

  select s.is_committed into v_committed
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id;

  -- Committed means the outside world now believes this, and both ledgers have
  -- to agree at that moment.
  --
  -- Each half is asked separately, because a sales order passes through three
  -- committed states and only the first of them should raise anything. Asking
  -- "has this already posted?" of each ledger is what makes the second and
  -- third transitions quiet instead of a duplicate-posting error.
  if coalesce(v_committed, false) then
    if bt.affects_stock
       and not exists (select 1 from erp.stock_movement m
                        where m.tenant_id = v_tenant and m.document_id = p_document_id)
    then
      perform erp.post_document_stock(p_document_id);
    end if;

    if bt.affects_finance
       and not exists (select 1 from erp.journal j
                        where j.tenant_id = v_tenant and j.document_id = p_document_id)
    then
      perform erp.post_document_finance(p_document_id);
    end if;
  end if;

  return v_to;
end;
$$;

-- -----------------------------------------------------------------------------
-- What a screen may offer
-- -----------------------------------------------------------------------------

create or replace function public.erp_available_transitions(
  p_document_id uuid
) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', a.transition_code, 'name', a.name, 'to_state', a.to_state,
           'guard_passes', a.guard_passes, 'permitted', a.permitted,
           'is_automatic', a.is_automatic)), '[]'::jsonb)
    from erp.available_transitions('document', p_document_id,
           erp.document_transition_context(p_document_id)) a
$$;

create or replace function public.erp_document(p_document_id uuid)
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select jsonb_build_object(
    'document', (
      select jsonb_build_object(
        'document_id', d.id, 'document_number', d.document_number,
        'document_type', dt.code, 'document_date', d.document_date,
        'currency', d.currency, 'party', p.name,
        'their_reference', d.their_reference,
        'total_minor', erp.document_value_minor(d.id),
        'state', s.code, 'state_name', s.name, 'is_committed', s.is_committed)
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
        left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
        left join erp.object_state os
          on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
        left join erp.state s on s.id = os.current_state_id
       where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'line_id', l.id, 'line_no', l.line_no, 'description', l.description,
        'quantity', l.quantity, 'unit_price_minor', l.unit_price_minor,
        'net_minor', l.net_minor, 'item', i.code) order by l.line_no)
        from erp.document_line l
        left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
       where l.tenant_id = erp.current_tenant_id() and l.document_id = p_document_id), '[]'::jsonb),
    -- Spec 4.5: navigable in both directions.
    'lineage', coalesce((
      select jsonb_agg(jsonb_build_object(
        'depth', depth, 'direction', direction, 'document_id', document_id,
        'document_number', document_number, 'base_type', base_type,
        'relation', relation_kind) order by depth)
        from erp.document_lineage(p_document_id)), '[]'::jsonb),
    -- Was a raw join on erp.transition: every transition out of the current
    -- state, with no idea whether the caller may take it or whether its guard
    -- would pass. A screen built on that offers actions the database refuses.
    'available_transitions', public.erp_available_transitions(p_document_id))
$$;

do $$
begin
  execute 'revoke all on function public.erp_available_transitions(uuid) from public, anon';
  execute 'grant execute on function public.erp_available_transitions(uuid) to authenticated';
end;
$$;

-- =============================================================================
-- The suite
--
-- Built on a delivery rather than a sales order. Delivery's transitions all
-- require sales.despatch, so one document gives a clean contrast between a
-- principal who holds it and one who does not — and a delivery in draft posts
-- nothing, which keeps the suite about the transition menu rather than about
-- the ledger.
-- =============================================================================

create or replace function erp_test.transition_menu_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  ob jsonb; v_tenant uuid; v_entity uuid; v_site uuid;
  v_uom uuid; v_item uuid; v_party uuid; v_doc uuid;
  res jsonb; v_clerk uuid; v_tok text;
  v_admin jsonb; v_theirs jsonb; v_ctx jsonb;
begin
  insert into auth.users (id, email) values (a1, 'admin@zztmenu.test');
  insert into auth.users (id, email) values (a2, 'clerk@zztmenu.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  ob := erp.onboard_tenant('Transition Menu', 'zztmenu');
  v_tenant := (ob ->> 'tenant_id')::uuid;
  v_entity := (ob ->> 'entity_id')::uuid;

  perform erp.configure_finance();
  perform erp.configure_inventory();
  perform erp.configure_sales();

  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (v_tenant, v_entity, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;

  v_uom   := erp.create_uom('EA', 'Each', 'quantity'::erp.uom_class, 0::smallint, true);
  v_item  := erp.create_item('WIDGET', 'Widget');
  v_party := erp.create_party('CUST', 'Customer',
               array['customer']::erp.party_role_kind[]);

  -- Holds sales.order, not sales.despatch.
  res := public.erp_save_role(null, 'order_taker', 'Order taker',
    'Raises orders. Does not despatch them.',
    array['sales.read', 'sales.order']);
  res := public.erp_invite_principal('clerk@zztmenu.test', 'Order Taker');
  v_clerk := (res ->> 'app_user_id')::uuid;
  v_tok := res ->> 'token';
  perform erp.grant_role(v_clerk, 'order_taker', null, null, 'no despatch');

  v_doc := erp.open_document('delivery', v_party, v_entity, v_site);
  perform erp.add_document_line(v_doc, v_item, 3, 1000);

  -- ---------------------------------------------------------------------
  -- What the menu now carries at all
  -- ---------------------------------------------------------------------

  v_admin := public.erp_available_transitions(v_doc);

  return query select 'the menu reports whether the caller may act',
    jsonb_array_length(v_admin) > 0
      and not exists (select 1 from jsonb_array_elements(v_admin) e
                       where e ->> 'permitted' is null
                          or e ->> 'guard_passes' is null),
    'the raw join it replaces returned neither field';

  return query select 'and erp_document carries the same answer',
    (public.erp_document(v_doc) -> 'available_transitions') = v_admin,
    'one definition, so a detail screen and a list cannot disagree';

  return query select 'an administrator may post this delivery',
    v_admin @> '[{"code":"post","permitted":true}]'::jsonb,
    'holds sales.despatch, which the delivery machine requires';

  -- ---------------------------------------------------------------------
  -- The contrast, which is the whole point
  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);

  v_theirs := public.erp_available_transitions(v_doc);

  return query select 'an order taker is offered the same transitions',
    jsonb_array_length(v_theirs) = jsonb_array_length(v_admin),
    'the state machine does not change per principal; the answer about it does';

  return query select 'but may not post, and the menu says so',
    v_theirs @> '[{"code":"post","permitted":false}]'::jsonb,
    'before this, a screen would have offered it and the database refused';

  return query select 'and the database agrees when asked directly',
    (select not a.permitted from erp.available_transitions('document', v_doc,
       erp.document_transition_context(v_doc)) a where a.transition_code = 'post'),
    'the menu is a report of the rule, not a second copy of it';

  -- ---------------------------------------------------------------------
  -- The context both sides share
  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  v_ctx := erp.document_transition_context(v_doc, 'post');

  return query select 'the shared context carries the document''s real value',
    (v_ctx ->> 'total_minor')::bigint = erp.document_value_minor(v_doc)
      and (v_ctx ->> 'total_minor')::bigint > 0,
    format('total_minor=%s', v_ctx ->> 'total_minor');

  return query select 'and the fields a value band would be judged on',
    v_ctx ? 'max_discount_pct' and v_ctx ? 'credit_limit_minor'
      and v_ctx ? 'exposure_after_minor',
    'no transition in the product carries a guard yet, so this changes no '
    'answer today — it means the first one authored is judged on the real '
    'numbers from both sides rather than only from transition_document';

  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, a2);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = v_tenant),
    'tenant and both fabricated subjects';
end;
$$;

create or replace function erp_test.assert_transition_menu_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 9;
begin
  create temporary table if not exists zz_tmenu_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_tmenu_result;
  insert into zz_tmenu_result select * from erp_test.transition_menu_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_tmenu_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_TRANSITION_MENU_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_TRANSITION_MENU_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('transition menu: %s/%s', v_pass, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_isolation();
