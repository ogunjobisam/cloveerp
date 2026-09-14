-- Pickers offer only what can still move.
--
-- On 14 September the owner opened Procurement, pressed "Send this requisition
-- back", and the Requisition picker offered REQ-2026-000001, Cancelled, Dales
-- Dairy Co. Choosing it could only be refused: a cancelled requisition has no
-- way back to draft, or anywhere else. Closed, cancelled, posted and the rest
-- are the end of a document's process, and a list of things to act on should
-- not offer them.
--
-- The database was not wrong to refuse. The picker had no way to ask for less.
-- public.erp_documents (20260829190000) lists every document of a type with its
-- state, and every picker on the desk that chooses a document reads it; it has
-- no notion of whether a document can still move, so every picker offered
-- everything, and the person found out by pressing the button. The line picker
-- reads public.erp_document_lines (20260830100930) and had the same blindness.
--
-- So erp_documents gains four arguments, each defaulted so that every existing
-- call answers exactly as before:
--
--   p_exclude_cancelled  true leaves out a cancelled document, and nothing else.
--                        For the verbs that may name a finished document but
--                        never a void one: linking, rendering, labelling.
--   p_actionable         true also leaves out a document whose current state is
--                        terminal. For verbs that move the document itself.
--   p_transition_code    lists only documents whose current state has a
--                        transition with that code, in the state machine
--                        version the document runs under. It implies
--                        p_actionable. An unknown code lists nothing; it is a
--                        question with no answer, not an error.
--   p_states             lists only documents whose current state code is one
--                        of these. For verbs that consume a document which has
--                        finished its own process — a posted goods receipt is
--                        billed, a posted delivery is invoiced, shipped and
--                        returned against — and so cannot use p_actionable.
--                        An empty list lists nothing.
--
-- Cancelled means either thing that says so: the document's own is_cancelled,
-- or a current state coded 'cancelled'. Every one of the four leaves a
-- cancelled document out, including p_states naming 'cancelled'; with none of
-- them the door lists everything, cancelled included, because the registers
-- and the process strips read it that way and must keep showing the history.
-- The four compose by conjunction: posted is terminal, so p_actionable with
-- p_states => '{posted}' lists nothing, and that is the right answer.
--
-- The transition is found the way erp.perform_transition() finds the one it
-- performs: same organisation, the version pinned on the document's
-- erp.object_state (spec 3.6: a document finishes under the definition it
-- started with, so a newer version of the lifecycle is not consulted), that
-- code, leaving from the state the document is in. A transition carries no
-- status of its own; being declared in the pinned version is what makes it
-- available. What the picker does not read is the guard or the permission. A
-- guard is evaluated over facts supplied at the moment of the move, and the
-- move refuses with its own reason; a picker that hid a document by permission
-- would tell a person the document is not there when the truth is that they
-- may not move it, and the refusal says that better.
--
-- erp_document_lines gains p_open_only. It leaves out a line whose document is
-- cancelled or in a terminal state, and a line with nothing left to do on it:
-- received in full and invoiced in full, as the order line's own
-- quantity_fulfilled and quantity_invoiced say (erp.refresh_order_line_progress
-- keeps both). Both, not either. Goods are invoiced after they arrive and
-- sometimes before, so a line received in full is exactly the line "Invoice
-- against an order" is for, and a line invoiced in full may still be waiting
-- for its goods; hiding either would stop the ordinary case to tidy the rare
-- one. The line row records no reservation, so reserving is not read here;
-- erp.reserve_for_line refuses a line that already holds stock.
--
-- Both functions are dropped rather than overloaded: a name carries one
-- function (erp.public_api_report() refuses two), and a caller relying on
-- defaults would match both and resolve to neither. Nothing in SQL calls either
-- door; the desk does, by name, and PostgREST resolves named arguments against
-- the one function that remains. Each stays SECURITY INVOKER and STABLE, with
-- the same organisation filter, the same keys, the same order, and the same
-- limit — applied after the new filters, so a picker asking for two hundred
-- gets two hundred it can act on rather than two hundred of which some were
-- thrown away. They read and never authorise, so they need no write allowance
-- and no gate.
--
-- Proof: erp_test.actionable_documents_suite(), seventeen cases, pinned by its
-- wrapper.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The document door lists what can still move, when asked
-- ═════════════════════════════════════════════════════════════════════════════

drop function public.erp_documents(text, integer);

create function public.erp_documents(
  p_type_code         text    default null,
  p_limit             integer default 100,
  p_exclude_cancelled boolean default false,
  p_actionable        boolean default false,
  p_transition_code   text    default null,
  p_states            text[]  default null
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
      'is_cancelled', d.is_cancelled) as x
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
                 or p_transition_code is not null or p_states is not null)
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
     order by d.document_number desc
     limit greatest(p_limit, 1)) t
$$;

comment on function public.erp_documents(text, integer, boolean, boolean, text, text[]) is
  'The organisation''s documents, newest number first, optionally of one type. '
  'p_exclude_cancelled leaves out a cancelled document; p_actionable also leaves '
  'out one in a terminal state; p_transition_code lists only documents whose '
  'current state declares that transition in the lifecycle version they run '
  'under, and implies p_actionable; p_states lists only documents in one of '
  'those states. Every filter leaves out a cancelled document (is_cancelled, or '
  'a state coded cancelled), and they compose by conjunction. An unknown '
  'transition code or an empty state list lists nothing. Reads under row '
  'security as the caller, and authorises nothing.';

revoke all on function public.erp_documents(text, integer, boolean, boolean, text, text[]) from public, anon;
grant execute on function public.erp_documents(text, integer, boolean, boolean, text, text[]) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The line door lists the lines that still have something to do, when asked
-- ═════════════════════════════════════════════════════════════════════════════

drop function public.erp_document_lines(uuid, text, integer);

create function public.erp_document_lines(
  p_document_id uuid    default null,
  p_type_code   text    default null,
  p_limit       integer default 200,
  p_open_only   boolean default false
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'document_number', (x->>'line_no')::int), '[]'::jsonb) from (
    select jsonb_build_object(
             'line_id', dl.id, 'document_id', d.id, 'document_number', d.document_number,
             'document_type', dt.code, 'line_no', dl.line_no,
             'item', i.code, 'description', dl.description,
             'quantity', dl.quantity, 'quantity_fulfilled', dl.quantity_fulfilled,
             'unit_price_minor', dl.unit_price_minor, 'currency', dl.currency,
             'line_state', dl.line_state) as x
      from erp.document_line dl
      join erp.document d on d.tenant_id = dl.tenant_id and d.id = dl.document_id
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      left join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
      left join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      left join erp.state s on s.id = os.current_state_id
     where dl.tenant_id = erp.current_tenant_id()
       and coalesce(dl.is_cancelled, false) = false
       and (p_document_id is null or dl.document_id = p_document_id)
       and (p_type_code is null or dt.code = p_type_code)
       -- Open: its document can still move, and the line is not both received
       -- and invoiced in full.
       and (not coalesce(p_open_only, false)
            or (not (d.is_cancelled or coalesce(s.code = 'cancelled', false))
                and not coalesce(s.is_terminal, false)
                and not (dl.quantity > 0
                         and dl.quantity_fulfilled >= dl.quantity
                         and dl.quantity_invoiced >= dl.quantity)))
     order by d.document_date desc nulls last, dl.line_no
     limit greatest(p_limit, 1)) t;
$$;

comment on function public.erp_document_lines(uuid, text, integer, boolean) is
  'Lines of the organisation''s documents, optionally of one document or one '
  'type; a cancelled line is never listed. p_open_only leaves out a line whose '
  'document is cancelled or in a terminal state, and a line already received '
  'and invoiced in full. Reads under row security as the caller, and '
  'authorises nothing.';

revoke all on function public.erp_document_lines(uuid, text, integer, boolean) from public, anon;
grant execute on function public.erp_document_lines(uuid, text, integer, boolean) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.actionable_documents_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_keys constant text[] := array[
    'document_id', 'document_number', 'document_type', 'document_date',
    'required_date', 'currency', 'party', 'total_minor',
    'state', 'state_name', 'is_committed', 'is_cancelled'];
  c_line_keys constant text[] := array[
    'line_id', 'document_id', 'document_number', 'document_type', 'line_no',
    'item', 'description', 'quantity', 'quantity_fulfilled',
    'unit_price_minor', 'currency', 'line_state'];
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();   -- this organisation's first administrator
  a2       uuid := gen_random_uuid();   -- its second, who approves configuration
  a3       uuid := gen_random_uuid();   -- another organisation's administrator
  a4       uuid := gen_random_uuid();   -- a demonstration organisation's administrator
  a5       uuid := gen_random_uuid();   -- and another organisation's, beside it
  r        record;
  r2       record;
  r3       record;
  r4       record;
  res      jsonb;
  v_second uuid;
  v_tok    text;
  cs_fin   uuid;
  cs_proc  uuid;
  v_party  uuid;
  v_draft   uuid;
  v_sub     uuid;
  v_ended   uuid;
  v_flagged uuid;
  v_state   text;
  -- The posting organisation.
  v_state3  text;
  v_entity  uuid;
  v_site    uuid;
  v_loc     uuid;
  v_uom     uuid;
  v_sup     uuid;
  v_item    uuid;
  g_posted   uuid;
  g_draft    uuid;
  g_ended    uuid;
  g_flagged  uuid;
  po_open    uuid;
  po_ended   uuid;
  po_flagged uuid;
  l_posted    uuid;
  l_untouched uuid;
  l_done      uuid;
  l_received  uuid;
  l_invoiced  uuid;
  l_ended     uuid;
  l_flagged   uuid;
  -- The doors as the catalogue holds them.
  v_n       integer;
  v_definer boolean;
  v_stable  boolean;
  v_args    text;
  v_granted boolean;
  v_ln       integer;
  v_ldefiner boolean;
  v_lstable  boolean;
  v_largs    text;
  v_lgranted boolean;
  -- The fixture is what the cases say it is.
  v_ended_terminal boolean;
  v_flagged_open   boolean;
  v_fixture3       boolean;
  -- What the door answered.
  v_old         jsonb;
  v_bare        jsonb;
  v_act         uuid[];
  v_act_any     uuid[];
  v_reject      uuid[];
  v_submit      uuid[];
  v_unknown     jsonb;
  v_unknown_err text;
  v_first       uuid[];
  v_first_act   uuid[];
  v_other_ctx   boolean;
  v_leaked      integer;
  v_posted_json   jsonb;
  v_posted_cancel uuid[];
  v_draft_grn     uuid[];
  v_empty         jsonb;
  v_empty_err     text;
  v_po_posted     jsonb;
  v_po_draft      uuid[];
  v_posted_act    jsonb;
  v_post_draft    uuid[];
  v_not_cancelled uuid[];
  v_lines_all     jsonb;
  v_lines_old     jsonb;
  v_lines_open    uuid[];
  v_lines_open_po uuid[];
  v_other_ctx4    boolean;
  v_leaked4       integer;
begin
  select count(*),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 's'), false),
         min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_n, v_definer, v_stable, v_args, v_granted
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'erp_documents';

  select count(*),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 's'), false),
         min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_ln, v_ldefiner, v_lstable, v_largs, v_lgranted
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'erp_document_lines';

  -- ───────────────────────────────────────────────────────────────────────────
  -- A live organisation's requisitions: acting and moving.
  -- ───────────────────────────────────────────────────────────────────────────
  begin
    select * into r from erp.provision_tenant(
      'zz-pick-' || v_hex, 'Actionable documents suite',
      'admin@zz-pick-' || v_hex || '.test', 'Suite Admin');
    select * into r2 from erp.provision_tenant(
      'zz-pick2-' || v_hex, 'Another organisation',
      'admin@zz-pick2-' || v_hex || '.test', 'Other Admin');

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-pick-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid;
    v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    -- Procurement reaches a ledger, so finance comes first. The organisation
    -- is live, so both arrive as change sets somebody else approves.
    cs_fin  := erp.configure_finance();
    cs_proc := erp.configure_procurement(1000000);

    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(cs_fin);
    perform erp.promote_change_set(cs_fin);
    perform erp.approve_change_set(cs_proc);
    perform erp.promote_change_set(cs_proc);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_party;

    -- Four requisitions, opened in this order so their numbers run the same
    -- way: one in draft, one submitted, one cancelled through its lifecycle
    -- (a terminal state), and one draft flagged cancelled on the document
    -- itself, whose state still has moves out of it.
    v_draft := erp.open_document('requisition', v_party);
    v_sub := erp.open_document('requisition', v_party);
    perform erp.transition_document(v_sub, 'submit');
    v_ended := erp.open_document('requisition', v_party);
    perform erp.transition_document(v_ended, 'cancel');
    v_flagged := erp.open_document('requisition', v_party);
    perform erp.cancel_document(v_flagged, 'Raised twice');

    select coalesce(bool_and(s.is_terminal and not d.is_cancelled), false) into v_ended_terminal
      from erp.document d
      join erp.object_state os on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where d.tenant_id = r.tenant_id and d.id = v_ended;
    select coalesce(bool_and(d.is_cancelled and not s.is_terminal), false) into v_flagged_open
      from erp.document d
      join erp.object_state os on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where d.tenant_id = r.tenant_id and d.id = v_flagged;

    -- The old shape, positionally, and no arguments at all.
    v_old  := public.erp_documents('requisition', 200);
    v_bare := public.erp_documents();

    v_act := array(select (e ->> 'document_id')::uuid from jsonb_array_elements(
      public.erp_documents(p_type_code => 'requisition', p_limit => 200, p_actionable => true)) e);
    v_act_any := array(select (e ->> 'document_id')::uuid from jsonb_array_elements(
      public.erp_documents(p_actionable => true)) e);
    v_reject := array(select (e ->> 'document_id')::uuid from jsonb_array_elements(
      public.erp_documents(p_type_code => 'requisition', p_limit => 200, p_transition_code => 'reject')) e);
    v_submit := array(select (e ->> 'document_id')::uuid from jsonb_array_elements(
      public.erp_documents(p_type_code => 'requisition', p_limit => 200, p_actionable => false,
                           p_transition_code => 'submit')) e);

    begin
      v_unknown := public.erp_documents(p_type_code => 'requisition', p_limit => 200,
                                        p_transition_code => 'zz_not_a_transition');
    exception when others then
      v_unknown_err := left(sqlerrm, 200);
    end;

    v_first := array(select (e ->> 'document_id')::uuid from jsonb_array_elements(
      public.erp_documents('requisition', 1)) e);
    v_first_act := array(select (e ->> 'document_id')::uuid from jsonb_array_elements(
      public.erp_documents(p_type_code => 'requisition', p_limit => 1, p_actionable => true)) e);

    -- The other organisation, signed in as its own administrator.
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(r2.admin_token);
    v_other_ctx := erp.current_tenant_id() is not distinct from r2.tenant_id;
    select count(*) into v_leaked
      from jsonb_array_elements(
             public.erp_documents()
             || public.erp_documents(p_actionable => true)
             || public.erp_documents(p_transition_code => 'reject')
             || public.erp_documents(p_transition_code => 'submit')
             || public.erp_documents(p_type_code => 'requisition', p_limit => 200,
                                     p_actionable => true, p_transition_code => 'cancel_submitted')
             || public.erp_documents(p_states => array['draft', 'submitted', 'cancelled'])
             || public.erp_documents(p_exclude_cancelled => true)) e
     where (e ->> 'document_id')::uuid in (v_draft, v_sub, v_ended, v_flagged);

    raise exception 'CLOVEERP_ACTIONABLE_DOCUMENTS_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_ACTIONABLE_DOCUMENTS_SUITE_UNDO' then
      v_state := left(sqlerrm, 300);
    end if;
  end;

  -- ───────────────────────────────────────────────────────────────────────────
  -- An organisation made the way the demonstration is, because a posted
  -- document needs stock and a ledger to post to: states, and lines.
  -- ───────────────────────────────────────────────────────────────────────────
  begin
    select * into r3 from erp.provision_tenant(
      'zz-pick3-' || v_hex, 'Posted documents suite',
      'admin@zz-pick3-' || v_hex || '.test', 'Posting Admin');
    select * into r4 from erp.provision_tenant(
      'zz-pick4-' || v_hex, 'Another organisation',
      'admin@zz-pick4-' || v_hex || '.test', 'Other Admin');
    update erp.environment set is_live = false where tenant_id = r3.tenant_id and is_self;
    insert into auth.users (id, email) values (a4, 'admin@zz-pick3-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a4)::text, true);
    perform erp.claim_invitation(r3.admin_token);
    perform erp.ensure_demo_configuration(r3.tenant_id, r3.admin_user_id);

    select e.id into v_entity from erp.entity e where e.tenant_id = r3.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = r3.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (r3.tenant_id, v_entity, 'ZMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select l.id into v_loc from erp.location l
     where l.tenant_id = r3.tenant_id and l.site_id = v_site
       and l.location_type = 'receiving' and l.status = 'active' order by l.code limit 1;
    if v_loc is null then
      insert into erp.location (tenant_id, site_id, code, name, location_type, status)
      values (r3.tenant_id, v_site, 'ZRECV', 'Receiving', 'receiving', 'active') returning id into v_loc;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = r3.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (r3.tenant_id, 'ZEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.party (tenant_id, code, name, status)
    values (r3.tenant_id, 'ZPICKSUP', 'Picker Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r3.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, net_weight_g, status)
    values (r3.tenant_id, 'ZPICK', 'Picker Suite Widget', v_uom, 100, 'active') returning id into v_item;

    -- Goods receipts: one posted, one left in draft, one cancelled through its
    -- lifecycle, and one draft flagged cancelled on the document itself.
    g_posted := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    l_posted := erp.add_document_line(g_posted, v_item, 10, 1000, 'posted', current_date);
    update erp.document_line set location_id = v_loc where id = l_posted;
    perform erp.transition_document(g_posted, 'post', 'actionable documents suite');
    g_draft := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    g_ended := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.transition_document(g_ended, 'cancel', 'actionable documents suite');
    g_flagged := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.cancel_document(g_flagged, 'Raised twice');

    -- Purchase orders in draft, so their lines can be written: one with a line
    -- untouched, one received and invoiced in full, one received only and one
    -- invoiced only; one cancelled through its lifecycle, one flagged.
    po_open := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    l_untouched := erp.add_document_line(po_open, v_item, 10, 1000, 'nothing done', current_date);
    l_done      := erp.add_document_line(po_open, v_item, 10, 1000, 'received and invoiced', current_date);
    l_received  := erp.add_document_line(po_open, v_item, 10, 1000, 'received, not invoiced', current_date);
    l_invoiced  := erp.add_document_line(po_open, v_item, 10, 1000, 'invoiced, not received', current_date);
    update erp.document_line set quantity_fulfilled = 10, quantity_invoiced = 10 where id = l_done;
    update erp.document_line set quantity_fulfilled = 10 where id = l_received;
    update erp.document_line set quantity_invoiced = 10 where id = l_invoiced;
    po_ended := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    l_ended := erp.add_document_line(po_ended, v_item, 10, 1000, 'on a cancelled order', current_date);
    perform erp.transition_document(po_ended, 'cancel', 'actionable documents suite');
    po_flagged := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    l_flagged := erp.add_document_line(po_flagged, v_item, 10, 1000, 'on a flagged order', current_date);
    perform erp.cancel_document(po_flagged, 'Raised twice');

    select coalesce(bool_and(case d.id
             when g_posted   then s.code = 'posted' and s.is_terminal and not d.is_cancelled
             when g_draft    then s.code = 'draft' and not d.is_cancelled
             when g_ended    then s.code = 'cancelled' and not d.is_cancelled
             when g_flagged  then s.code = 'draft' and d.is_cancelled
             when po_open    then s.code = 'draft' and not d.is_cancelled
             when po_ended   then s.code = 'cancelled' and not d.is_cancelled
             when po_flagged then s.code = 'draft' and d.is_cancelled
           end), false)
           and count(*) = 7
           and (select count(*) from erp.document_line l
                 where l.tenant_id = r3.tenant_id and not l.is_cancelled
                   and l.id in (l_posted, l_untouched, l_done, l_received, l_invoiced, l_ended, l_flagged)) = 7
      into v_fixture3
      from erp.document d
      join erp.object_state os on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where d.tenant_id = r3.tenant_id
       and d.id in (g_posted, g_draft, g_ended, g_flagged, po_open, po_ended, po_flagged);

    -- States.
    v_posted_json := public.erp_documents(p_limit => 1000, p_states => array['posted']);
    v_posted_cancel := array(select (e ->> 'document_id')::uuid from jsonb_array_elements(
      public.erp_documents(p_type_code => 'goods_receipt', p_limit => 1000,
                           p_states => array['posted', 'cancelled'])) e);
    v_draft_grn := array(select (e ->> 'document_id')::uuid from jsonb_array_elements(
      public.erp_documents(p_type_code => 'goods_receipt', p_limit => 1000, p_states => array['draft'])) e);
    begin
      v_empty := public.erp_documents(p_limit => 1000, p_states => array[]::text[]);
    exception when others then
      v_empty_err := left(sqlerrm, 200);
    end;
    v_po_posted := public.erp_documents(p_type_code => 'purchase_order', p_limit => 1000,
                                        p_states => array['posted']);
    v_po_draft := array(select (e ->> 'document_id')::uuid from jsonb_array_elements(
      public.erp_documents(p_type_code => 'purchase_order', p_limit => 1000, p_states => array['draft'])) e);
    v_posted_act := public.erp_documents(p_type_code => 'goods_receipt', p_limit => 1000,
                                         p_actionable => true, p_states => array['posted']);
    v_post_draft := array(select (e ->> 'document_id')::uuid from jsonb_array_elements(
      public.erp_documents(p_type_code => 'goods_receipt', p_limit => 1000, p_transition_code => 'post',
                           p_states => array['draft', 'posted'])) e);
    v_not_cancelled := array(select (e ->> 'document_id')::uuid from jsonb_array_elements(
      public.erp_documents(p_limit => 1000, p_exclude_cancelled => true)) e);

    -- Lines.
    v_lines_all := public.erp_document_lines(p_limit => 1000);
    v_lines_old := public.erp_document_lines(po_open, 'purchase_order', 200);
    v_lines_open := array(select (e ->> 'line_id')::uuid from jsonb_array_elements(
      public.erp_document_lines(p_limit => 1000, p_open_only => true)) e);
    v_lines_open_po := array(select (e ->> 'line_id')::uuid from jsonb_array_elements(
      public.erp_document_lines(p_document_id => po_open, p_type_code => 'purchase_order',
                                p_open_only => true)) e);

    -- The other organisation, signed in as its own administrator.
    perform set_config('request.jwt.claims', json_build_object('sub', a5)::text, true);
    perform erp.claim_invitation(r4.admin_token);
    v_other_ctx4 := erp.current_tenant_id() is not distinct from r4.tenant_id;
    select (select count(*)
              from jsonb_array_elements(
                     public.erp_documents(p_limit => 1000)
                     || public.erp_documents(p_limit => 1000, p_states => array['draft', 'posted', 'cancelled'])
                     || public.erp_documents(p_limit => 1000, p_exclude_cancelled => true)
                     || public.erp_documents(p_limit => 1000, p_actionable => true)) e
             where (e ->> 'document_id')::uuid in (g_posted, g_draft, g_ended, g_flagged,
                                                   po_open, po_ended, po_flagged))
         + (select count(*)
              from jsonb_array_elements(
                     public.erp_document_lines(p_limit => 1000)
                     || public.erp_document_lines(p_limit => 1000, p_open_only => true)
                     || public.erp_document_lines(p_document_id => po_open)) e
             where (e ->> 'line_id')::uuid in (l_posted, l_untouched, l_done, l_received,
                                               l_invoiced, l_ended, l_flagged))
      into v_leaked4;

    raise exception 'CLOVEERP_ACTIONABLE_DOCUMENTS_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_ACTIONABLE_DOCUMENTS_SUITE_UNDO' then
      v_state3 := left(sqlerrm, 300);
    end if;
  end;

  -- ───────────────────────────────────────────────────────────────────────────
  -- The document door
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'the document door is one function under its name, runs as the caller, only reads, and takes the new arguments after the old two';
  passed := v_n = 1 and not v_definer and v_stable and v_granted
            and v_args = 'p_type_code text, p_limit integer, p_exclude_cancelled boolean, p_actionable boolean, p_transition_code text, p_states text[]';
  detail := format('%s function(s); definer %s; stable %s; authenticated and not anon %s; (%s)',
                   v_n, v_definer, v_stable, v_granted, coalesce(v_args, 'none'));
  return next;

  case_name := 'with no filter, a cancelled document and one in a terminal state are still listed';
  passed := v_state is null and v_ended_terminal and v_flagged_open
            and array(select (e ->> 'document_id')::uuid from jsonb_array_elements(v_old) e)
                @> array[v_draft, v_sub, v_ended, v_flagged]
            and array(select (e ->> 'document_id')::uuid from jsonb_array_elements(v_bare) e)
                @> array[v_draft, v_sub, v_ended, v_flagged];
  detail := coalesce(v_state, format('%s listed by type, %s with no arguments; terminal fixture %s, flagged fixture %s',
                                     jsonb_array_length(v_old), jsonb_array_length(v_bare),
                                     v_ended_terminal, v_flagged_open));
  return next;

  case_name := 'the old two-argument call answers with every key it answered with before';
  passed := v_state is null and jsonb_array_length(v_old) >= 4
            and not exists (select 1 from jsonb_array_elements(v_old) e where not (e ?& c_keys));
  detail := coalesce(v_state, format('%s row(s), each carrying %s', jsonb_array_length(v_old), array_to_string(c_keys, ', ')));
  return next;

  case_name := 'offered for acting, a cancelled document and a terminal one are left out, and the draft and the submitted one stay';
  passed := v_state is null
            and v_act @> array[v_draft, v_sub] and not (v_act && array[v_ended, v_flagged])
            and v_act_any @> array[v_draft, v_sub] and not (v_act_any && array[v_ended, v_flagged]);
  detail := coalesce(v_state, format('%s requisition(s) offered, %s across every type', cardinality(v_act), cardinality(v_act_any)));
  return next;

  case_name := 'asked for the reject move, only the submitted requisition is listed: not the draft, not the cancelled ones';
  passed := v_state is null and v_reject = array[v_sub];
  detail := coalesce(v_state, format('%s document(s), the submitted one among them: %s',
                                     cardinality(v_reject), v_sub = any (v_reject)));
  return next;

  case_name := 'a transition code implies acting: the flagged draft is not offered to submit, even with p_actionable false';
  passed := v_state is null and v_submit = array[v_draft];
  detail := coalesce(v_state, format('%s document(s); the draft %s, the flagged draft %s',
                                     cardinality(v_submit), v_draft = any (v_submit), v_flagged = any (v_submit)));
  return next;

  case_name := 'an unknown transition code lists nothing and raises nothing';
  passed := v_state is null and v_unknown_err is null and v_unknown = '[]'::jsonb;
  detail := coalesce(v_state, v_unknown_err, coalesce(v_unknown::text, 'no answer'));
  return next;

  case_name := 'the limit counts what is offered: one row asked for is the newest document that can still move';
  passed := v_state is null and v_first = array[v_flagged] and v_first_act = array[v_sub];
  detail := coalesce(v_state, format('unfiltered gives the flagged draft %s; actionable gives the submitted one %s',
                                     v_first = array[v_flagged], v_first_act = array[v_sub]));
  return next;

  case_name := 'asked for posted documents, only posted ones are listed, and a cancelled one never is, even when its state is named';
  passed := v_state3 is null and v_fixture3
            and g_posted = any (array(select (e ->> 'document_id')::uuid from jsonb_array_elements(v_posted_json) e))
            and not exists (select 1 from jsonb_array_elements(v_posted_json) e
                             where e ->> 'state' is distinct from 'posted' or (e ->> 'is_cancelled')::boolean
                                or (e ->> 'document_id')::uuid in (g_draft, g_ended, g_flagged, po_open, po_ended, po_flagged))
            and g_posted = any (v_posted_cancel) and not (v_posted_cancel && array[g_draft, g_ended, g_flagged])
            and g_draft = any (v_draft_grn) and not (v_draft_grn && array[g_posted, g_ended, g_flagged]);
  detail := coalesce(v_state3, format('fixture %s; %s posted listed; posted or cancelled gives the cancelled receipt %s; draft gives the flagged draft %s',
                                      v_fixture3, jsonb_array_length(v_posted_json),
                                      g_ended = any (v_posted_cancel), g_flagged = any (v_draft_grn)));
  return next;

  case_name := 'an empty list of states lists nothing and raises nothing';
  passed := v_state3 is null and v_empty_err is null and v_empty = '[]'::jsonb;
  detail := coalesce(v_state3, v_empty_err, coalesce(v_empty::text, 'no answer'));
  return next;

  case_name := 'states compose with the type and with the other filters';
  passed := v_state3 is null
            -- A purchase order is never posted; a draft one is listed as a purchase order and a draft receipt is not.
            and v_po_posted = '[]'::jsonb
            and po_open = any (v_po_draft) and not (v_po_draft && array[g_draft, po_ended, po_flagged])
            -- Posted is terminal, so acting on a posted receipt lists nothing.
            and v_posted_act = '[]'::jsonb
            -- Of the drafts and the posted, only a draft can still be posted.
            and v_post_draft @> array[g_draft] and not (v_post_draft && array[g_posted, g_ended, g_flagged]);
  detail := coalesce(v_state3, format('posted orders %s; draft orders %s; posted and actionable %s; postable drafts or posted %s',
                                      jsonb_array_length(v_po_posted), cardinality(v_po_draft),
                                      jsonb_array_length(v_posted_act), cardinality(v_post_draft)));
  return next;

  case_name := 'leaving out the cancelled keeps the posted and the draft and leaves out only what was cancelled';
  passed := v_state3 is null
            and v_not_cancelled @> array[g_posted, g_draft, po_open]
            and not (v_not_cancelled && array[g_ended, g_flagged, po_ended, po_flagged]);
  detail := coalesce(v_state3, format('%s document(s) listed; posted %s, draft %s, a cancelled one %s',
                                      cardinality(v_not_cancelled), g_posted = any (v_not_cancelled),
                                      g_draft = any (v_not_cancelled),
                                      v_not_cancelled && array[g_ended, g_flagged, po_ended, po_flagged]));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- The line door
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'the line door is one function under its name, runs as the caller, only reads, and takes p_open_only after the old three';
  passed := v_ln = 1 and not v_ldefiner and v_lstable and v_lgranted
            and v_largs = 'p_document_id uuid, p_type_code text, p_limit integer, p_open_only boolean';
  detail := format('%s function(s); definer %s; stable %s; authenticated and not anon %s; (%s)',
                   v_ln, v_ldefiner, v_lstable, v_lgranted, coalesce(v_largs, 'none'));
  return next;

  case_name := 'with no filter, the line door lists every line it listed before, with every key it carried';
  passed := v_state3 is null and v_fixture3
            and array(select (e ->> 'line_id')::uuid from jsonb_array_elements(v_lines_all) e)
                @> array[l_posted, l_untouched, l_done, l_received, l_invoiced, l_ended, l_flagged]
            and jsonb_array_length(v_lines_old) = 4
            and not exists (select 1 from jsonb_array_elements(v_lines_old) e where not (e ?& c_line_keys));
  detail := coalesce(v_state3, format('%s line(s) with no arguments; %s on the open order by the old call',
                                      jsonb_array_length(v_lines_all), jsonb_array_length(v_lines_old)));
  return next;

  case_name := 'open only, a line on a cancelled or a finished document is left out';
  passed := v_state3 is null and v_fixture3
            and not (v_lines_open && array[l_posted, l_ended, l_flagged]);
  detail := coalesce(v_state3, format('posted receipt''s line %s; cancelled order''s %s; flagged order''s %s',
                                      l_posted = any (v_lines_open), l_ended = any (v_lines_open),
                                      l_flagged = any (v_lines_open)));
  return next;

  case_name := 'open only, a line received and invoiced in full is left out, and a line with either still to do stays';
  passed := v_state3 is null and v_fixture3
            and v_lines_open @> array[l_untouched, l_received, l_invoiced]
            and not (l_done = any (v_lines_open))
            and cardinality(v_lines_open_po) = 3
            and v_lines_open_po @> array[l_untouched, l_received, l_invoiced];
  detail := coalesce(v_state3, format('untouched %s, received only %s, invoiced only %s, both %s; %s open on the order',
                                      l_untouched = any (v_lines_open), l_received = any (v_lines_open),
                                      l_invoiced = any (v_lines_open), l_done = any (v_lines_open),
                                      cardinality(v_lines_open_po)));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Both doors, from outside
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'another organisation sees none of these documents or lines, whichever arguments it passes';
  passed := v_state is null and v_state3 is null
            and v_other_ctx and v_leaked = 0 and v_other_ctx4 and v_leaked4 = 0;
  detail := coalesce(v_state, v_state3,
                     format('in its own organisation %s and %s; %s requisition(s) and %s posting organisation document(s) or line(s) listed',
                            v_other_ctx, v_other_ctx4, v_leaked, v_leaked4));
  return next;
end;
$$;

comment on function erp_test.actionable_documents_suite() is
  'Four requisitions in a live organisation — draft, submitted, cancelled '
  'through the lifecycle, and a draft flagged cancelled — and, in a '
  'demonstration organisation, goods receipts posted, draft, cancelled and '
  'flagged, and purchase orders whose lines are untouched, received, invoiced, '
  'or both; read through public.erp_documents with every filter, through '
  'public.erp_document_lines with and without p_open_only, and from another '
  'organisation. Rolls back everything it made.';

create or replace function erp_test.assert_actionable_documents_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 17;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.actionable_documents_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_ACTIONABLE_DOCUMENTS_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_ACTIONABLE_DOCUMENTS_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail;
  end if;
  return format('actionable documents: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.actionable_documents_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_actionable_documents_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

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
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();

select erp_test.assert_actionable_documents_suite();
