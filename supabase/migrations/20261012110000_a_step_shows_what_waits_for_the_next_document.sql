-- A step shows what waits for the next document.
--
-- Found in the live walk of 12 October 2026. On the Sales page the Delivery
-- step read 0 while DN-000472, posted on 7 October, had never been invoiced:
-- the step lists draft deliveries ("waiting to leave"), posted is where a
-- delivery's own lifecycle ends, and the Invoice step lists invoices, so a
-- delivery still to be invoiced sat on no step at all. "Invoice a delivery"
-- offered every posted delivery, including DN-000479, invoiced and paid an
-- hour before. Procurement had the same gap: a goods receipt posted and not
-- yet billed sat on no step, and "Bill a receipt" offered receipts already
-- billed.
--
-- What a finished document still waits for is known: erp.document_awaiting
-- (20261010011000) answers 'invoice' for a delivery that moved stock and has
-- no invoice, and 'bill' for a goods receipt received against an order and not
-- yet billed. public.erp_document shows it on a document's page. The list door
-- never asked it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
-- public.erp_documents gains p_awaiting, defaulted, so every existing call
-- answers as before (positional calls of six arguments included):
--
--   p_awaiting   'invoice' or 'bill'. A document whose current state is
--                terminal (its own moves are over) is listed only while
--                erp.document_awaiting says it still waits for that; a
--                document still able to move is listed as the other filters
--                say. It composes with p_states by conjunction, so the
--                Delivery step asks for draft and posted awaiting an invoice,
--                and "Invoice a delivery" for posted awaiting an invoice.
--                Like every other filter it leaves out a cancelled document.
--
-- And every row says what it awaits ('awaiting'), read only for a finished
-- delivery or receipt, so the step can say "Waiting to be invoiced" beside it.
--
-- The function is dropped and made again, as 20260914050000 did: a name
-- carries one function (erp.public_api_report() refuses two). It stays
-- SECURITY INVOKER and STABLE, reads under row security as the caller, and
-- authorises nothing. erp.document_awaiting is already executable by a
-- signed-in caller (public.erp_document, an invoker door, calls it).
--
-- Proof: erp_test.documents_awaiting_suite, six cases, pinned by its wrapper.
-- Not run from this migration: it provisions an organisation, and the
-- catalogue runs it on the build.

drop function public.erp_documents(text, integer, boolean, boolean, text, text[]);

create function public.erp_documents(
  p_type_code         text    default null,
  p_limit             integer default 100,
  p_exclude_cancelled boolean default false,
  p_actionable        boolean default false,
  p_transition_code   text    default null,
  p_states            text[]  default null,
  p_awaiting          text    default null
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'document_number' desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'document_id', d.id, 'document_number', d.document_number,
      'document_type', dt.code, 'document_date', d.document_date,
      'required_date', d.required_date, 'currency', d.currency,
      'party', p.name, 'total_minor', erp.document_value_minor(d.id),
      'state', s.code, 'state_name', s.name, 'is_committed', s.is_committed,
      'is_cancelled', d.is_cancelled,
      -- What a finished delivery or receipt still waits for from another
      -- document (erp.document_awaiting); nothing for anything else.
      'awaiting', case when coalesce(s.is_terminal, false)
                         and dt.base_type_code in ('delivery', 'receipt')
                       then erp.document_awaiting(d.id) end) as x
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
      left join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      left join erp.state s on s.id = os.current_state_id
     where d.tenant_id = erp.current_tenant_id()
       and (p_type_code is null or dt.code = p_type_code)
       -- Narrowed in any way at all: never a cancelled document, whether the
       -- document says so or its lifecycle does.
       and (not (coalesce(p_exclude_cancelled, false) or coalesce(p_actionable, false)
                 or p_transition_code is not null or p_states is not null or p_awaiting is not null)
            or not (d.is_cancelled or coalesce(s.code = 'cancelled', false)))
       -- Offered for acting, or asked for a move: not finished either.
       and (not (coalesce(p_actionable, false) or p_transition_code is not null)
            or not coalesce(s.is_terminal, false))
       -- Asked for a move: the pinned version declares it out of this state.
       and (p_transition_code is null
            or exists (
              select 1
                from erp.transition tr
               where tr.tenant_id = os.tenant_id
                 and tr.state_machine_version_id = os.state_machine_version_id
                 and tr.code = p_transition_code
                 and tr.from_state_id = os.current_state_id))
       -- Asked for states: the current state is one of them. A document with
       -- no lifecycle is in none.
       and (p_states is null or coalesce(s.code = any (p_states), false))
       -- Asked what it awaits: a finished document only while it still waits
       -- for that from another document.
       and (p_awaiting is null
            or not coalesce(s.is_terminal, false)
            or erp.document_awaiting(d.id) is not distinct from p_awaiting)
     order by d.document_number desc
     limit greatest(p_limit, 1)) t
$$;

comment on function public.erp_documents(text, integer, boolean, boolean, text, text[], text) is
  'The organisation''s documents, newest number first, optionally of one type. '
  'p_exclude_cancelled leaves out a cancelled document; p_actionable also leaves '
  'out one in a terminal state; p_transition_code lists only documents whose '
  'current state declares that transition in the lifecycle version they run '
  'under, and implies p_actionable; p_states lists only documents in one of '
  'those states; p_awaiting (''invoice'' or ''bill'') lists a document in a '
  'terminal state only while erp.document_awaiting says it still waits for that '
  '(20261012110000). Every filter leaves out a cancelled document (is_cancelled, '
  'or a state coded cancelled), and they compose by conjunction. Each row says '
  'what a finished delivery or receipt awaits. Reads under row security as the '
  'caller, and authorises nothing.';

revoke all on function public.erp_documents(text, integer, boolean, boolean, text, text[], text) from public, anon;
grant execute on function public.erp_documents(text, integer, boolean, boolean, text, text[], text) to authenticated, service_role;

-- The words a step shows beside a finished document it holds, in place of
-- "Posted".
insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A finished document a step holds while it waits for the next one (20261012110000).'
  from (values
    ('Waiting to be invoiced'),
    ('Waiting for the supplier''s bill')) v(text)
on conflict do nothing;

-- erp_test.actionable_documents_suite pins the door's arguments; it learns the
-- one added here, after the others, as 20260914062000 taught it the line door's.
do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.actionable_documents_suite()'::regprocedure);
  v_old text := $p$and v_args = 'p_type_code text, p_limit integer, p_exclude_cancelled boolean, p_actionable boolean, p_transition_code text, p_states text[]';$p$;
  v_new text := $q$and v_args = 'p_type_code text, p_limit integer, p_exclude_cancelled boolean, p_actionable boolean, p_transition_code text, p_states text[], p_awaiting text';$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.actionable_documents_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.documents_awaiting_suite()
returns table(case_name text, passed boolean, detail text)
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
  v_tenant uuid;
  v_ent    uuid; v_site uuid; i_fg uuid; p_sup uuid; p_cus uuid;
  v_po     uuid; v_grn uuid; v_so uuid; v_so2 uuid; v_dn uuid; v_dn2 uuid;
  x        jsonb;
  v_step_list   jsonb;
  v_picker      jsonb;
  v_plain       jsonb;
  v_bills       jsonb;
  v_wrong       jsonb;
begin
  begin
    -- ── The fixture: a demonstration that buys and sells ────────────────────
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzdwa' || v_tag, 'Documents Awaiting Suite',
      'admin@demo-zzdwa' || v_tag || '.test', 'Awaiting Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzdwa' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;
    select e.id into v_ent from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select i.id into i_fg from erp.item i where i.tenant_id = v_tenant and i.code = 'FG-1000';
    select pt.id into p_sup from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'S-FAST';
    select pt.id into p_cus from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'C-HARBOUR';

    v_step := 'an order received in a posted goods receipt';
    v_po := erp.open_document('purchase_order', p_sup, v_ent, v_site);
    perform erp.add_document_line(v_po, i_fg, 20, 4000, 'stock to sell');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'fixture');
    perform erp.transition_document(v_po, 'send', null);
    x := erp.create_receipt_from_order(v_po, null, 'post');
    v_grn := (x ->> 'document_id')::uuid;

    v_step := 'an order of the customer''s, delivered and posted';
    v_so := erp.open_document('sales_order', p_cus, v_ent, v_site, 'CUST-PO-88');
    perform erp.add_document_line(v_so, i_fg, 2, 4950, 'sensor');
    perform erp.transition_document(v_so, 'submit', null);
    if erp.document_state_code(v_so) = 'pending_approval' then
      perform erp_test.approve_document(v_so, 'fixture');
    end if;
    begin
      perform erp.release_credit_hold(v_so, 'released for the fixture');
    exception when others then
      null;
    end;
    x := erp.create_delivery_from_order(v_so, null, 'post');
    v_dn := (x ->> 'document_id')::uuid;

    v_step := 'another order, its delivery left in draft';
    v_so2 := erp.open_document('sales_order', p_cus, v_ent, v_site, 'CUST-PO-89');
    perform erp.add_document_line(v_so2, i_fg, 1, 4950, 'sensor');
    perform erp.transition_document(v_so2, 'submit', null);
    if erp.document_state_code(v_so2) = 'pending_approval' then
      perform erp_test.approve_document(v_so2, 'fixture');
    end if;
    begin
      perform erp.release_credit_hold(v_so2, 'released for the fixture');
    exception when others then
      null;
    end;
    x := erp.create_delivery_from_order(v_so2, null, null);
    v_dn2 := (x ->> 'document_id')::uuid;

    -- ── 1. The Delivery step lists the posted delivery still to be invoiced ──
    v_step := 'reading the Delivery step';
    v_step_list := public.erp_documents(p_type_code => 'delivery', p_limit => 500,
                                        p_states => array['draft', 'posted'], p_awaiting => 'invoice');
    v_cases := v_cases + 1;
    case_name := 'a delivery posted and not yet invoiced is listed at the Delivery step, saying it waits to be invoiced';
    passed := v_state is null
          and exists (select 1 from jsonb_array_elements(v_step_list) r
                       where (r ->> 'document_id')::uuid = v_dn and r ->> 'awaiting' = 'invoice');
    detail := coalesce(v_state, format('%s row(s): %s', jsonb_array_length(v_step_list), v_step_list::text));
    return next;

    -- ── 2. And the draft beside it, which awaits nothing yet ─────────────────
    v_cases := v_cases + 1;
    case_name := 'a draft delivery is listed there too, waiting for nothing from another document';
    passed := v_state is null
          and exists (select 1 from jsonb_array_elements(v_step_list) r
                       where (r ->> 'document_id')::uuid = v_dn2 and r -> 'awaiting' = 'null'::jsonb);
    detail := coalesce(v_state, format('%s row(s)', jsonb_array_length(v_step_list)));
    return next;

    -- ── 3. Invoiced, it leaves the step and the picker, not the register ─────
    v_step := 'invoicing the delivery';
    perform erp.invoice_from_delivery(v_dn, true, 'one person despatches and invoices in the suite');
    v_step_list := public.erp_documents(p_type_code => 'delivery', p_limit => 500,
                                        p_states => array['draft', 'posted'], p_awaiting => 'invoice');
    v_picker := public.erp_documents(p_type_code => 'delivery', p_limit => 500,
                                     p_states => array['posted'], p_awaiting => 'invoice');
    v_plain := public.erp_documents('delivery', 500, false, false, null, array['posted']);
    v_cases := v_cases + 1;
    case_name := 'once invoiced the delivery leaves the step and the picker, and a call without p_awaiting still lists it';
    passed := v_state is null
          and not exists (select 1 from jsonb_array_elements(v_step_list) r where (r ->> 'document_id')::uuid = v_dn)
          and not exists (select 1 from jsonb_array_elements(v_picker) r where (r ->> 'document_id')::uuid = v_dn)
          and exists (select 1 from jsonb_array_elements(v_plain) r
                       where (r ->> 'document_id')::uuid = v_dn and r -> 'awaiting' = 'null'::jsonb)
          and exists (select 1 from jsonb_array_elements(v_step_list) r where (r ->> 'document_id')::uuid = v_dn2);
    detail := coalesce(v_state, format('step %s, picker %s, plain %s row(s)', jsonb_array_length(v_step_list),
                                       jsonb_array_length(v_picker), jsonb_array_length(v_plain)));
    return next;

    -- ── 4. The receipt still to be billed is offered to Bill a receipt ───────
    v_step := 'reading Bill a receipt';
    v_bills := public.erp_documents(p_type_code => 'goods_receipt', p_limit => 500,
                                    p_states => array['posted'], p_awaiting => 'bill');
    v_cases := v_cases + 1;
    case_name := 'a goods receipt posted and not yet billed is offered for billing, saying it waits for the bill';
    passed := v_state is null
          and exists (select 1 from jsonb_array_elements(v_bills) r
                       where (r ->> 'document_id')::uuid = v_grn and r ->> 'awaiting' = 'bill');
    detail := coalesce(v_state, format('%s row(s): %s', jsonb_array_length(v_bills), v_bills::text));
    return next;

    -- ── 5. Asked for the other kind, it is not ───────────────────────────────
    v_wrong := public.erp_documents(p_type_code => 'goods_receipt', p_limit => 500,
                                    p_states => array['posted'], p_awaiting => 'invoice');
    v_cases := v_cases + 1;
    case_name := 'a receipt waiting for its bill is not listed as waiting to be invoiced';
    passed := v_state is null
          and not exists (select 1 from jsonb_array_elements(v_wrong) r where (r ->> 'document_id')::uuid = v_grn);
    detail := coalesce(v_state, format('%s row(s)', jsonb_array_length(v_wrong)));
    return next;

    -- ── 6. Billed, it is no longer offered ───────────────────────────────────
    v_step := 'billing the receipt';
    perform erp.bill_from_receipt(v_grn, 'DWA-BILL-1', current_date, null, true);
    v_bills := public.erp_documents(p_type_code => 'goods_receipt', p_limit => 500,
                                    p_states => array['posted'], p_awaiting => 'bill');
    v_cases := v_cases + 1;
    case_name := 'once billed the receipt is no longer offered for billing';
    passed := v_state is null
          and not exists (select 1 from jsonb_array_elements(v_bills) r where (r ->> 'document_id')::uuid = v_grn);
    detail := coalesce(v_state, format('%s row(s)', jsonb_array_length(v_bills)));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_DOCUMENTS_AWAITING_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.documents_awaiting_suite() from public, anon, authenticated;

create or replace function erp_test.assert_documents_awaiting_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _documents_awaiting on commit drop as
    select * from erp_test.documents_awaiting_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _documents_awaiting;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DOCUMENTS_AWAITING_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_DOCUMENTS_AWAITING_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('documents awaiting: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_documents_awaiting_suite() from public, anon, authenticated;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_isolation();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
