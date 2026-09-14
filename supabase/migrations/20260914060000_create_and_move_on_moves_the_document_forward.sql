-- "Create and move on" moves the document forward.
--
-- The New document form has two buttons: Create, which leaves a draft, and
-- Create and move on, which passes p_transition => 'auto' to
-- public.erp_create_document_full. The stock forecast's Create and send does
-- the same. erp.create_document_full (20260910180854) resolved 'auto' as the
-- first row erp.available_transitions() offered whose guard passed, which the
-- caller may perform, and which is not automatic.
--
-- erp.available_transitions() (0013) orders by the transition's sort_order and
-- then its code. No installer gives a transition a sort_order, so every one is
-- 100 and the code decides. Out of draft, requisition, purchase order, goods
-- receipt, purchase invoice, sales order, delivery and sales invoice each offer
-- cancel beside the move forward, and 'cancel' sorts before 'issue', 'post',
-- 'register' and 'submit'. So Create and move on cancelled the document it had
-- just created, in the same transaction, with the reason "Created and moved
-- on". erp.convert_document (20260910225559) resolved 'auto' for the order it
-- raises the same way, and cancelled that too.
--
-- The menu's order is not wrong; it is a menu. "Move it on" is a question of
-- its own, and it now has one answer, erp.onward_transition():
--
--   * a move a person drives (not is_automatic);
--   * whose guard passes on the facts given, and which the caller may perform:
--     the same two tests erp.available_transitions() applies and
--     erp.perform_transition() enforces;
--   * into a state that is not a way out. A terminal state that commits
--     nothing (cancelled, declined, expired; is_terminal and not is_committed)
--     is where a document stops, not where it goes next. A terminal state that
--     commits (posted, ordered, paid) is the end of the road forward, and is
--     allowed;
--   * and not back into the state the lifecycle starts in (is_initial), which
--     is what a reject is;
--   * the nearest such move: by the target state's sort_order, then the
--     transition's, then its code. The installers order states the way a
--     document travels, so the nearest forward state is the next step;
--   * and none when there is no such move. Nothing is moved, rather than
--     moving the document somewhere nobody asked for.
--
-- Out of draft that is: requisition submit, purchase order submit, goods
-- receipt post, purchase invoice register, sales order submit, delivery post,
-- sales invoice issue, quotation send.
--
-- It reads erp.object_state, erp.transition and erp.state for the organisation
-- erp.require_tenant_id() answers, and nothing else: it runs as the caller, it
-- is stable, and it names nothing a signed-in caller cannot reach. It is not a
-- door; it is reached from public.erp_create_document_full and
-- public.erp_convert_document through the two functions it is patched into,
-- and erp.apply_execute_grants() grants it from that reach.
--
-- Both functions are patched in place, as 20260914040000 patched the line
-- writers: read the body, require the 'auto' branch exactly once as its
-- migration wrote it, replace that branch and nothing else, and read the body
-- back. Every other byte is as it was.
--
-- Proof: erp_test.onward_transition_suite(), sixteen cases, pinned by its
-- wrapper.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The move "move it on" means
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.onward_transition(
  p_object_type text,
  p_object_id   uuid,
  p_data        jsonb default '{}'::jsonb
)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select t.code
    from erp.object_state os
    join erp.transition t
      on t.tenant_id = os.tenant_id
     and t.state_machine_version_id = os.state_machine_version_id
     and t.from_state_id = os.current_state_id
    join erp.state ts
      on ts.tenant_id = t.tenant_id
     and ts.id = t.to_state_id
   where os.tenant_id = erp.require_tenant_id()
     and os.object_type = p_object_type
     and os.object_id = p_object_id
     -- A move a person drives.
     and not t.is_automatic
     -- Forward: not a way out, which is a terminal state that commits
     -- nothing, and not back to where the lifecycle starts.
     and not (ts.is_terminal and not ts.is_committed)
     and not ts.is_initial
     -- The guard and the permission the move itself will check.
     and erp.jsonlogic_bool(t.guard, coalesce(p_data, '{}'::jsonb))
     and (t.required_permission is null
          or erp.has_permission(t.required_permission, os.entity_id, os.site_id))
   order by ts.sort_order, t.sort_order, t.code
   limit 1
$$;

comment on function erp.onward_transition(text, uuid, jsonb) is
  'The transition "move it on" means for an object where it stands: one a '
  'person drives, whose guard passes on the facts given and which the caller '
  'may perform, into a state that is neither a way out (terminal and '
  'committing nothing, such as cancelled) nor the state its lifecycle starts '
  'in. The nearest by the target state''s order, then the transition''s, then '
  'its code; none when there is no such move. Reads as the caller.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Create and move on asks it
-- ═════════════════════════════════════════════════════════════════════════════

do $create_full$
declare
  v_sig    constant text := 'erp.create_document_full(text,uuid,uuid,text,date,text,jsonb,text)';
  v_def    text := pg_get_functiondef('erp.create_document_full(text,uuid,uuid,text,date,text,jsonb,text)'::regprocedure);
  v_needle constant text :=
       E'    if p_transition = ''auto'' then\n'
    || E'      select at.transition_code into v_moved\n'
    || E'        from erp.available_transitions(''document'', v_id,\n'
    || E'               erp.document_transition_context(v_id, null)) at\n'
    || E'       where at.guard_passes and at.permitted and not at.is_automatic\n'
    || E'       limit 1;\n';
  v_onward constant text :=
       E'    if p_transition = ''auto'' then\n'
    || E'      -- The move forward, never a cancel and never back to the start. The\n'
    || E'      -- first move offered was taken until 20260914060000, and out of draft\n'
    || E'      -- that was cancel.\n'
    || E'      v_moved := erp.onward_transition(''document'', v_id,\n'
    || E'                   erp.document_transition_context(v_id, null));\n';
begin
  if position('erp.onward_transition(' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already asks erp.onward_transition()', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not resolve auto exactly once the way the 20260910180854 body does', v_sig;
  end if;

  execute replace(v_def, v_needle, v_onward);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('v_moved := erp.onward_transition(''document'', v_id,' in v_def) = 0
     or position('not at.is_automatic' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without erp.onward_transition()', v_sig;
  end if;
end
$create_full$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. So does convert and move on
-- ═════════════════════════════════════════════════════════════════════════════

do $convert$
declare
  v_sig    constant text := 'erp.convert_document(uuid,uuid,uuid,jsonb,text)';
  v_def    text := pg_get_functiondef('erp.convert_document(uuid,uuid,uuid,jsonb,text)'::regprocedure);
  v_needle constant text :=
       E'    if p_transition = ''auto'' then\n'
    || E'      select at.transition_code into v_moved\n'
    || E'        from erp.available_transitions(''document'', v_new,\n'
    || E'               erp.document_transition_context(v_new, null)) at\n'
    || E'       where at.guard_passes and at.permitted and not at.is_automatic\n'
    || E'       limit 1;\n';
  v_onward constant text :=
       E'    if p_transition = ''auto'' then\n'
    || E'      -- The move forward for the order just raised, never a cancel and\n'
    || E'      -- never back to the start (20260914060000).\n'
    || E'      v_moved := erp.onward_transition(''document'', v_new,\n'
    || E'                   erp.document_transition_context(v_new, null));\n';
begin
  if position('erp.onward_transition(' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already asks erp.onward_transition()', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not resolve auto exactly once the way the 20260910225559 body does', v_sig;
  end if;

  execute replace(v_def, v_needle, v_onward);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('v_moved := erp.onward_transition(''document'', v_new,' in v_def) = 0
     or position('not at.is_automatic' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without erp.onward_transition()', v_sig;
  end if;
end
$convert$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A demonstration organisation, because it has every lifecycle installed the
-- day it is made: a draft of each of the eight document types, asked what
-- moves it on; a submitted requisition; a lifecycle version written for the
-- suite whose only move the guards allow is a way out; Create and move on
-- through the function and, signed in, through the door the desk calls; a
-- conversion that moves the order on; and another organisation asking about
-- the same documents. Every step that could fail on its own is caught on its
-- own, so one refusal names itself and does not hide the other cases, and the
-- whole block ends by raising, so nothing it made outlives it.

create or replace function erp_test.onward_transition_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_hex     text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1        uuid := gen_random_uuid();   -- the demonstration organisation's administrator
  a2        uuid := gen_random_uuid();   -- another organisation's administrator
  v_owner   text := current_user;
  r         record;
  r2        record;
  x         record;
  y         record;
  v_state   text;
  -- The function, and the two it is patched into, as the catalogue holds them.
  v_n        integer;
  v_definer  boolean;
  v_stable   boolean;
  v_path     boolean;
  v_args     text;
  v_granted  boolean;
  v_internal boolean;
  v_bodies   integer;
  v_asks     boolean;
  -- The demonstration organisation.
  v_entity  uuid;
  v_site    uuid;
  v_uom     uuid;
  v_sup     uuid;
  v_cus     uuid;
  v_item    uuid;
  v_doc     uuid;
  v_ctx     jsonb;
  -- A draft of each type, keyed by type: the document, whether it is a draft
  -- and not cancelled, the moves offered to this caller, what moves it on, and
  -- the first move offered, which 'auto' used to take.
  v_docs    jsonb := '{}'::jsonb;
  v_draft   jsonb := '{}'::jsonb;
  v_offered jsonb := '{}'::jsonb;
  v_onward  jsonb := '{}'::jsonb;
  v_first   jsonb := '{}'::jsonb;
  v_errors  jsonb := '{}'::jsonb;
  -- A submitted requisition.
  v_sub         uuid;
  v_sub_state   text;
  v_sub_onward  text;
  v_sub_offered text[];
  v_sub_err     text;
  -- A lifecycle whose only move the guards allow is a way out.
  v_ver         uuid;
  v_fake        uuid := gen_random_uuid();
  v_way_blocked text;
  v_way_ready   text;
  v_way_first   text;
  v_way_err     text;
  -- Create and move on, and convert and move on.
  v_made           jsonb;
  v_made_state     text;
  v_made_cancelled boolean;
  v_made_err       text;
  v_conv           jsonb;
  v_conv_state     text;
  v_conv_cancelled boolean;
  v_conv_err       text;
  -- Create and move on, signed in, through the door.
  v_door       jsonb;
  v_door_role  text;
  v_door_state text;
  v_door_err   text;
  -- Another organisation.
  v_other_ctx boolean;
  v_other_req text;
  v_other_so  text;
  v_other_err text;
begin
  select count(*),
         coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 's'), false),
         coalesce(bool_and(p.proconfig = array['search_path=""']), false),
         min(pg_catalog.pg_get_function_identity_arguments(p.oid)),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false),
         coalesce(bool_and(p.prosrc not like '%erp\_meta%'), false)
    into v_n, v_definer, v_stable, v_path, v_args, v_granted, v_internal
    from pg_catalog.pg_proc p
   where p.pronamespace = 'erp'::regnamespace
     and p.proname = 'onward_transition';

  select count(*),
         coalesce(bool_and(position('erp.onward_transition(' in p.prosrc) > 0
                           and position('not at.is_automatic' in p.prosrc) = 0), false)
    into v_bodies, v_asks
    from pg_catalog.pg_proc p
   where p.oid in ('erp.create_document_full(text,uuid,uuid,text,date,text,jsonb,text)'::regprocedure::oid,
                   'erp.convert_document(uuid,uuid,uuid,jsonb,text)'::regprocedure::oid);

  begin
    select * into r from erp.provision_tenant(
      'zz-onward-' || v_hex, 'Onward transition suite',
      'admin@zz-onward-' || v_hex || '.test', 'Onward Admin');
    select * into r2 from erp.provision_tenant(
      'zz-onward2-' || v_hex, 'Another organisation',
      'admin@zz-onward2-' || v_hex || '.test', 'Other Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zz-onward-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);

    select e.id into v_entity from erp.entity e where e.tenant_id = r.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = r.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (r.tenant_id, v_entity, 'ZMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = r.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (r.tenant_id, 'ZEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZONWARDSUP', 'Onward Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZONWARDCUS', 'Onward Suite Customer', 'active') returning id into v_cus;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_cus, 'customer', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, net_weight_g, status)
    values (r.tenant_id, 'ZONWARD', 'Onward Suite Widget', v_uom, 100, 'active') returning id into v_item;

    -- ── A draft of each type, and what it is offered ─────────────────────────
    for x in
      select * from (values
        ('requisition', v_sup), ('purchase_order', v_sup), ('goods_receipt', v_sup),
        ('purchase_invoice', v_sup), ('sales_order', v_cus), ('delivery', v_cus),
        ('sales_invoice', v_cus), ('quotation', v_cus)) as v(type_code, party_id)
    loop
      begin
        v_doc := erp.open_document(x.type_code, x.party_id, v_entity, v_site);
        v_ctx := erp.document_transition_context(v_doc, null);
        v_docs := v_docs || jsonb_build_object(x.type_code, v_doc);
        v_draft := v_draft || jsonb_build_object(x.type_code,
          (select s.code = 'draft' and not d.is_cancelled
             from erp.document d
             join erp.object_state os
               on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
             join erp.state s on s.id = os.current_state_id
            where d.tenant_id = r.tenant_id and d.id = v_doc));
        v_offered := v_offered || jsonb_build_object(x.type_code,
          (select coalesce(jsonb_agg(at.transition_code order by at.transition_code), '[]'::jsonb)
             from erp.available_transitions('document', v_doc, v_ctx) at
            where at.guard_passes and at.permitted and not at.is_automatic));
        v_onward := v_onward || jsonb_build_object(x.type_code,
          erp.onward_transition('document', v_doc, v_ctx));
        v_first := v_first || jsonb_build_object(x.type_code,
          (select at.transition_code
             from erp.available_transitions('document', v_doc, v_ctx) at
            where at.guard_passes and at.permitted and not at.is_automatic
            limit 1));
      exception when others then
        v_errors := v_errors || jsonb_build_object(x.type_code, left(sqlerrm, 300));
      end;
    end loop;

    -- ── A submitted requisition ──────────────────────────────────────────────
    begin
      v_sub := erp.open_document('requisition', v_sup, v_entity, v_site);
      perform erp.transition_document(v_sub, 'submit', 'onward transition suite');
      v_ctx := erp.document_transition_context(v_sub, null);
      v_sub_state := erp.object_current_state('document', v_sub);
      v_sub_onward := erp.onward_transition('document', v_sub, v_ctx);
      v_sub_offered := array(
        select at.transition_code
          from erp.available_transitions('document', v_sub, v_ctx) at
         where at.guard_passes and at.permitted and not at.is_automatic
         order by at.transition_code);
    exception when others then
      v_sub_err := left(sqlerrm, 300);
    end;

    -- ── A lifecycle whose only move the guards allow is a way out ────────────
    -- A draft version may be written directly; only one in force is protected.
    -- Out of start: advance, into a plain state, guarded on a fact; and
    -- abandon, into a terminal state that commits nothing, unguarded. The code
    -- 'abandon' sorts first, as 'cancel' did.
    begin
      insert into erp.state_machine_version (tenant_id, state_machine_id, version, status, effective_from, note)
      select r.tenant_id, m.id, 99, 'draft', current_date, 'onward transition suite'
        from erp.state_machine m where m.tenant_id = r.tenant_id and m.code = 'requisition'
      returning id into v_ver;
      insert into erp.state (tenant_id, state_machine_version_id, code, name, is_initial, is_terminal, is_committed, sort_order)
      values (r.tenant_id, v_ver, 'start', 'Start', true, false, false, 10),
             (r.tenant_id, v_ver, 'onward', 'Onward', false, false, false, 20),
             (r.tenant_id, v_ver, 'void', 'Void', false, true, false, 90);
      insert into erp.transition (tenant_id, state_machine_version_id, code, name, from_state_id, to_state_id, guard)
      values (r.tenant_id, v_ver, 'advance', 'Advance',
              (select s.id from erp.state s where s.state_machine_version_id = v_ver and s.code = 'start'),
              (select s.id from erp.state s where s.state_machine_version_id = v_ver and s.code = 'onward'),
              '{"==": [{"var": "ready"}, "yes"]}'::jsonb),
             (r.tenant_id, v_ver, 'abandon', 'Abandon',
              (select s.id from erp.state s where s.state_machine_version_id = v_ver and s.code = 'start'),
              (select s.id from erp.state s where s.state_machine_version_id = v_ver and s.code = 'void'),
              'true'::jsonb);
      insert into erp.object_state (tenant_id, object_type, object_id, entity_id, site_id,
                                    state_machine_version_id, current_state_id)
      select r.tenant_id, 'zz_onward', v_fake, v_entity, v_site, v_ver, s.id
        from erp.state s where s.state_machine_version_id = v_ver and s.code = 'start';

      v_way_blocked := erp.onward_transition('zz_onward', v_fake, '{}'::jsonb);
      v_way_ready := erp.onward_transition('zz_onward', v_fake, '{"ready": "yes"}'::jsonb);
      select at.transition_code into v_way_first
        from erp.available_transitions('zz_onward', v_fake, '{}'::jsonb) at
       where at.guard_passes and at.permitted and not at.is_automatic
       limit 1;
    exception when others then
      v_way_err := left(sqlerrm, 300);
    end;

    -- ── Create and move on, through the function the door calls ─────────────
    begin
      v_made := erp.create_document_full(
        'requisition', v_sup, v_site, 'ZZ-ONWARD-MADE', null, null,
        jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 4, 'unit_price_minor', 1250)),
        'auto');
      select s.code, d.is_cancelled into v_made_state, v_made_cancelled
        from erp.document d
        join erp.object_state os
          on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
        join erp.state s on s.id = os.current_state_id
       where d.tenant_id = r.tenant_id and d.id = (v_made ->> 'document_id')::uuid;
    exception when others then
      v_made_err := left(sqlerrm, 300);
    end;

    -- ── That requisition approved, and converted with move-on ────────────────
    begin
      perform erp.transition_document((v_made ->> 'document_id')::uuid, 'approve', 'onward transition suite');
      v_conv := erp.convert_document((v_made ->> 'document_id')::uuid, null, null, null, 'auto');
      select s.code, d.is_cancelled into v_conv_state, v_conv_cancelled
        from erp.document d
        join erp.object_state os
          on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
        join erp.state s on s.id = os.current_state_id
       where d.tenant_id = r.tenant_id and d.id = (v_conv ->> 'document_id')::uuid;
    exception when others then
      v_conv_err := left(sqlerrm, 300);
    end;

    -- ── Create and move on, signed in, through the door the desk calls ───────
    begin
      execute 'set local role authenticated';
      v_door := public.erp_create_document_full(
        p_type_code  => 'requisition',
        p_party_id   => v_sup,
        p_site_id    => v_site,
        p_their_ref  => 'ZZ-ONWARD-DOOR',
        p_lines      => jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 2, 'unit_price_minor', 1250)),
        p_transition => 'auto');
      v_door_role := current_user;
      execute format('set local role %I', v_owner);
    exception when others then
      v_door_err := left(sqlerrm, 300);
    end;
    execute format('set local role %I', v_owner);
    select s.code into v_door_state
      from erp.document d
      join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.id = os.current_state_id
     where d.tenant_id = r.tenant_id and d.id = (v_door ->> 'document_id')::uuid;

    -- ── Another organisation, signed in as its own administrator ─────────────
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      perform erp.claim_invitation(r2.admin_token);
      v_other_ctx := erp.current_tenant_id() is not distinct from r2.tenant_id;
      v_other_req := erp.onward_transition('document', (v_docs ->> 'requisition')::uuid, '{}'::jsonb);
      v_other_so := erp.onward_transition('document', (v_docs ->> 'sales_order')::uuid, '{}'::jsonb);
    exception when others then
      v_other_err := left(sqlerrm, 300);
    end;

    raise exception 'CLOVEERP_ONWARD_TRANSITION_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_ONWARD_TRANSITION_SUITE_UNDO' then
      v_state := left(sqlerrm, 300);
    end if;
    -- Whatever failed, and wherever, the rest of the suite runs as its owner.
    execute format('set local role %I', v_owner);
  end;

  -- ───────────────────────────────────────────────────────────────────────────
  -- The function
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'the onward transition is one function that runs as the caller, only reads, keeps an empty search path, names nothing internal, and a signed-in caller may execute it';
  passed := coalesce(v_n = 1 and not v_definer and v_stable and v_path and v_granted and v_internal
                     and v_args = 'p_object_type text, p_object_id uuid, p_data jsonb', false);
  detail := format('%s function(s); definer %s; stable %s; empty search path %s; authenticated and not anon %s; nothing internal %s; (%s)',
                   v_n, v_definer, v_stable, v_path, v_granted, v_internal, coalesce(v_args, 'none'));
  return next;

  case_name := 'create and move on, and convert and move on, both ask it, and neither keeps the query that took the first move offered';
  passed := coalesce(v_bodies = 2 and v_asks, false);
  detail := format('%s function(s) read; both ask it and neither keeps the old query: %s', v_bodies, v_asks);
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- A draft of each type
  -- ───────────────────────────────────────────────────────────────────────────

  for y in
    select * from (values
      ('requisition',      'a new requisition',      'submit'),
      ('purchase_order',   'a new purchase order',   'submit'),
      ('goods_receipt',    'a new goods receipt',    'post'),
      ('purchase_invoice', 'a new purchase invoice', 'register'),
      ('sales_order',      'a new sales order',      'submit'),
      ('delivery',         'a new delivery',         'post'),
      ('sales_invoice',    'a new sales invoice',    'issue')) as v(type_code, label, expected)
  loop
    case_name := format('%s moves on by %s, and cancel, offered beside it, is not chosen', y.label, y.expected);
    passed := coalesce(v_state is null
                       and (v_draft ->> y.type_code)::boolean
                       and v_onward ->> y.type_code = y.expected
                       and (v_offered -> y.type_code) ? 'cancel', false);
    detail := coalesce(v_state, v_errors ->> y.type_code,
                       format('a draft %s; offered %s; moved on by %s; the first offered, which it used to take, %s',
                              coalesce(v_draft ->> y.type_code, 'unknown'),
                              coalesce(v_offered ->> y.type_code, 'nothing'),
                              coalesce(v_onward ->> y.type_code, 'nothing'),
                              coalesce(v_first ->> y.type_code, 'nothing')));
    return next;
  end loop;

  case_name := 'a new quotation moves on by send, the one move forward it has';
  passed := coalesce(v_state is null
                     and (v_draft ->> 'quotation')::boolean
                     and v_onward ->> 'quotation' = 'send', false);
  detail := coalesce(v_state, v_errors ->> 'quotation',
                     format('a draft %s; offered %s; moved on by %s',
                            coalesce(v_draft ->> 'quotation', 'unknown'),
                            coalesce(v_offered ->> 'quotation', 'nothing'),
                            coalesce(v_onward ->> 'quotation', 'nothing')));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Beyond draft, and where nothing forward is allowed
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'a submitted requisition moves on by approve: not back to draft by reject, and not out by cancel, though both are offered';
  passed := coalesce(v_state is null and v_sub_err is null
                     and v_sub_state = 'submitted'
                     and v_sub_onward = 'approve'
                     and v_sub_offered @> array['reject', 'cancel_submitted'], false);
  detail := coalesce(v_state, v_sub_err,
                     format('%s; offered %s; moved on by %s',
                            coalesce(v_sub_state, 'no state'),
                            coalesce(array_to_string(v_sub_offered, ', '), 'nothing'),
                            coalesce(v_sub_onward, 'nothing')));
  return next;

  case_name := 'where the guards allow only a way out, nothing is chosen, and given the fact its guard asks for, the move forward is';
  passed := coalesce(v_state is null and v_way_err is null
                     and v_way_first = 'abandon'
                     and v_way_blocked is null
                     and v_way_ready = 'advance', false);
  detail := coalesce(v_state, v_way_err,
                     format('first offered %s; chosen without the fact %s; chosen with it %s',
                            coalesce(v_way_first, 'nothing'), coalesce(v_way_blocked, 'nothing'),
                            coalesce(v_way_ready, 'nothing')));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- The buttons
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'create and move on raises a requisition with its line and submits it, and does not cancel it';
  passed := coalesce(v_state is null and v_made_err is null
                     and v_made ->> 'moved_on' = 'submit'
                     and (v_made ->> 'lines')::integer = 1
                     and v_made_state = 'submitted'
                     and not v_made_cancelled, false);
  detail := coalesce(v_state, v_made_err,
                     format('moved on by %s; %s line(s); now %s; cancelled %s',
                            coalesce(v_made ->> 'moved_on', 'nothing'), coalesce(v_made ->> 'lines', 'no'),
                            coalesce(v_made_state, 'no state'), coalesce(v_made_cancelled::text, 'unknown')));
  return next;

  case_name := 'an approved requisition converted with move-on raises a purchase order submitted for approval, not a cancelled one';
  passed := coalesce(v_state is null and v_made_err is null and v_conv_err is null
                     and v_conv ->> 'moved_on' = 'submit'
                     and v_conv_state = 'pending_approval'
                     and not v_conv_cancelled, false);
  detail := coalesce(v_state, v_made_err, v_conv_err,
                     format('the order moved on by %s and is %s, cancelled %s; the requisition moved on by %s',
                            coalesce(v_conv ->> 'moved_on', 'nothing'), coalesce(v_conv_state, 'no state'),
                            coalesce(v_conv_cancelled::text, 'unknown'),
                            coalesce(v_conv ->> 'source_moved_on', 'nothing')));
  return next;

  case_name := 'a signed-in person pressing create and move on gets a submitted requisition through the door the desk calls';
  passed := coalesce(v_state is null and v_door_err is null
                     and v_door_role = 'authenticated'
                     and v_door ->> 'moved_on' = 'submit'
                     and v_door_state = 'submitted', false);
  detail := coalesce(v_state, v_door_err,
                     format('ran as %s; moved on by %s; now %s',
                            coalesce(v_door_role, 'nobody'), coalesce(v_door ->> 'moved_on', 'nothing'),
                            coalesce(v_door_state, 'no state')));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- From outside
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'another organisation is told of no move for these documents';
  passed := coalesce(v_state is null and v_other_err is null and v_other_ctx
                     and v_docs ? 'requisition' and v_docs ? 'sales_order'
                     and v_other_req is null and v_other_so is null, false);
  detail := coalesce(v_state, v_other_err,
                     format('in its own organisation %s; the requisition %s, the sales order %s',
                            coalesce(v_other_ctx::text, 'unknown'),
                            coalesce(v_other_req, 'nothing'), coalesce(v_other_so, 'nothing')));
  return next;
end;
$$;

comment on function erp_test.onward_transition_suite() is
  'A demonstration organisation: a draft of each of eight document types asked '
  'what moves it on; a submitted requisition; a lifecycle version whose only '
  'allowed move is a way out; create and move on through the function and, '
  'signed in, through the door; a conversion that moves its order on; and '
  'another organisation asking about the same documents. Rolls back everything '
  'it made.';

create or replace function erp_test.assert_onward_transition_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 16;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.onward_transition_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_ONWARD_TRANSITION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_ONWARD_TRANSITION_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail;
  end if;
  return format('onward transition: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.onward_transition_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_onward_transition_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();

select erp_test.assert_onward_transition_suite();
