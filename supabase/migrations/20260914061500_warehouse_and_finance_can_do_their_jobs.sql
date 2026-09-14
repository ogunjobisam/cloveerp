-- The warehouse and finance can do their jobs.
--
-- A walk through every persona the base pack ships, reading each door's latest
-- body, found a company that follows the setup walkthrough and hands people
-- the pack's roles could not receive, put away, pick or despatch, and that its
-- first administrator lost the permission to set up finance on the day the
-- base pack was applied. Each finding was checked against the definition the
-- database carries before it was fixed here:
--
--   1. Applying the base pack strips the first administrator. Provisioning
--      gives role administrator every permission, with no template mark. The
--      pack's administrator template carries the eight administration codes
--      and from_template base-1.0.0, so erp.plan_content_pack found the role
--      "missing" (its manifest row says from_template null) and planned it,
--      and the role arm of erp.apply_change_set_item deletes a promoted role's
--      grants and inserts the template's. Before go-live the author may
--      approve their own change, so the organisation's only administrator
--      ended holding administration.* and nothing else: not finance.configure,
--      not master_data.*, not procurement or sales. Confirmed: nothing after
--      20260904920000 touched either the containment line or the role arm.
--
--      A content pack now never takes a permission away from a role the
--      organisation already had and did not get from that pack's template.
--      When a pack's role item meets an active role whose from_template is not
--      the item's, promotion adds what the template grants and deletes
--      nothing, and the role keeps its name and its template mark; the planner
--      plans that item only while the role lacks a permission the template
--      grants. A role the template made is still replaced by the template, and
--      a change set that is not a pack's (a promotion from another
--      environment, a rollback) still describes the whole role. The template
--      code is unchanged, so no organisation's roles are renamed.
--
--   2. Nobody can put away. erp.raise_putaway_tasks,
--      erp.raise_replenishment_tasks and erp.complete_warehouse_task authorised
--      inventory.adjust, which neither the warehouse operative template nor the
--      warehouse module role holds, while the first-run step "Complete a
--      putaway task" is offered on inventory.move. A warehouse task is only
--      ever a putaway or a replenishment (the table's own check), and both are
--      a move within the site that erp_ref.movement_type registers as a
--      transfer. All three now authorise inventory.move; counting and posting
--      a count stay on inventory.count and inventory.adjust. The desk moves
--      with them.
--
--   3. Nobody but a manager can pick. erp.pick_document authorises
--      sales.despatch and reserves any unreserved line through
--      erp.reserve_for_line, which authorised sales.order, so a despatcher
--      could pick only an order the order desk had already reserved in full.
--      Reserving now takes sales.order or sales.despatch: whoever may despatch
--      an order may hold its stock for it, which is what picking does. A
--      caller with neither is still refused naming sales.order. No persona
--      template held sales.despatch at all; see 4.
--
--   4. The warehouse cannot reach receiving or despatch. The warehouse
--      operative and warehouse manager templates held procurement.receive
--      without procurement.read, so Procurement, where goods are received, was
--      not in their navigation; and neither held sales.read or sales.despatch.
--      Both now hold all four. The warehouse module role gains
--      procurement.read and procurement.receive (it already picked and
--      despatched). The pack's segregation rules were read against the result:
--      neither template nor the module role holds both sides of a prohibited
--      rule, and APPROVE_RECEIVE_PO is not met because none holds
--      procurement.approve. DELIVER_INVOICE named logistics.despatch alone,
--      while posting a delivery requires sales.despatch; it now names both.
--
--   5. Finance cannot be installed from the screen that says to. Confirmed:
--      erp.configure_finance authorises finance.configure, and the change set
--      it raises authorises administration.configure, so it takes both. The
--      database keeps asking for finance.configure. The walkthrough step
--      "Install finance first" named administration.configure; it now names
--      finance.configure and says who holds it, and the Configuration screen's
--      Finance card asks for it and says the same.
--
-- Organisations that already applied the base pack. No tenant row is
-- rewritten here, live or not:
--
--   * An administrator role the pack already narrowed stays narrow. What it
--     held before cannot be known from what is left, and giving permissions
--     back silently is a grant nobody made. Before go-live an administrator
--     restores it on Permissions; re-applying the pack will not narrow it
--     again.
--   * The pack's warehouse roles, and DELIVER_INVOICE, change when the
--     organisation applies the base pack again (Settings, Features and
--     content): each is planned as an update, shown in the change set's
--     preview, and promoted like any other change. Those roles were made by
--     the template, so their grants become the template's.
--   * An organisation's seeded warehouse module role is not touched: seeding
--     never rewrites a role that exists. New organisations get the new shape.
--   * A pending base-pack change set, planned before this and not yet
--     promoted, now adds to the administrator instead of replacing it.
--
-- Proof: erp_test.warehouse_and_finance_jobs_suite(), twenty-one cases, pinned
-- by its wrapper. The starter pack acceptance suite plans one item fewer on a
-- new organisation (the administrator), and says so.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A pack adds to a role it did not make
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Both are patched from the definition the database carries, by asserted
-- replacement, as 20260913101000 did; nothing else in either changes.

do $promoter$
declare
  v_def text := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_n   text := $n$        insert into erp.role (tenant_id, code, name, name_key, from_template)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'name_key', p ->> 'from_template')
        on conflict (tenant_id, code) do update
          set name = excluded.name, name_key = excluded.name_key,
              status = 'active', updated_at = now()
        returning id into v_obj;

        -- The grant set is replaced wholesale: a promoted role is the role the
        -- change set describes, not a merge with whatever was here before.
        delete from erp.role_permission rp
         where rp.tenant_id = v_tenant and rp.role_id = v_obj;

        insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
        select v_tenant, v_obj, e.value ->> 'permission',
               coalesce((select array_agg(dc #>> '{}')
                           from jsonb_array_elements(e.value -> 'data_classes') dc),
                        '{}'::text[])
          from jsonb_array_elements(coalesce(p -> 'permissions', '[]'::jsonb)) e;
$n$;
  v_r   text := $r$        -- A content pack meeting a role this organisation already holds, and
        -- did not get from that pack's template, adds what the template
        -- grants and takes nothing away (20260914061500). The first
        -- administrator is why: provisioning gives it every permission, the
        -- base pack's administrator template carries the eight administration
        -- codes, and replacing the grant set left the organisation's first
        -- person unable to set up finance or keep master data. The role keeps
        -- its name, its template mark and every grant it holds.
        --
        -- A role the pack's own template made is still the role the change set
        -- describes, and so is every role in a change set that is not a
        -- pack's: a promotion from another environment or a rollback replaces
        -- the grant set wholesale, as it always has.
        if exists (select 1 from erp.tenant_pack pk
                    where pk.tenant_id = v_tenant and pk.change_set_id = i.change_set_id)
           and exists (select 1 from erp.role held
                        where held.tenant_id = v_tenant and held.code = (p ->> 'code')
                          and held.status = 'active'
                          and held.from_template is distinct from (p ->> 'from_template')) then
          select held.id into v_obj
            from erp.role held
           where held.tenant_id = v_tenant and held.code = (p ->> 'code');

          insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
          select v_tenant, v_obj, e.value ->> 'permission',
                 coalesce((select array_agg(dc #>> '{}')
                             from jsonb_array_elements(e.value -> 'data_classes') dc),
                          '{}'::text[])
            from jsonb_array_elements(coalesce(p -> 'permissions', '[]'::jsonb)) e
          on conflict (tenant_id, role_id, permission_code) do nothing;
        else
          insert into erp.role (tenant_id, code, name, name_key, from_template)
          values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'name_key', p ->> 'from_template')
          on conflict (tenant_id, code) do update
            set name = excluded.name, name_key = excluded.name_key,
                status = 'active', updated_at = now()
          returning id into v_obj;

          -- The grant set is replaced wholesale: a promoted role is the role
          -- the change set describes, not a merge with whatever was here before.
          delete from erp.role_permission rp
           where rp.tenant_id = v_tenant and rp.role_id = v_obj;

          insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
          select v_tenant, v_obj, e.value ->> 'permission',
                 coalesce((select array_agg(dc #>> '{}')
                             from jsonb_array_elements(e.value -> 'data_classes') dc),
                          '{}'::text[])
            from jsonb_array_elements(coalesce(p -> 'permissions', '[]'::jsonb)) e;
        end if;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the role arm of erp.apply_change_set_item() is not the text this migration patches'
      using hint = 'A later migration changed the role arm. Read pg_get_functiondef() of the promoter and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('erp.tenant_pack pk' in pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the promoter did not take the additive role arm'
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the promoter.';
  end if;
end
$promoter$;

do $planner$
declare
  v_def text := pg_get_functiondef('erp.plan_content_pack(text)'::regprocedure);
  v_n   text := $n$   where not (coalesce(m.content, '{}'::jsonb) @> i.effective_payload)
$n$;
  v_r   text := $r$   where not (coalesce(m.content, '{}'::jsonb) @> i.effective_payload)
     -- A role the organisation holds that did not come from this item's
     -- template (the administrator provisioning made, or a role the
     -- organisation built) is added to on promotion and never replaced
     -- (erp.apply_change_set_item, 20260914061500). It is missing only while
     -- it lacks a permission the template grants: its name, its other grants
     -- and its template mark are not the pack's to change.
     and not (i.object_kind = 'role'
              and m.object_key is not null
              and (m.content ->> 'from_template') is distinct from (i.effective_payload ->> 'from_template')
              and coalesce(m.content -> 'permissions', '[]'::jsonb)
                    @> coalesce(i.effective_payload -> 'permissions', '[]'::jsonb))
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PLANNER_UNRECOGNISED: erp.plan_content_pack() does not test containment the way this migration patches'
      using hint = 'A later migration changed the planner. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('its template mark are not the pack''s to change' in pg_get_functiondef('erp.plan_content_pack(text)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PLANNER_UNRECOGNISED: the planner did not take the role rule'
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the planner.';
  end if;
end
$planner$;

-- The acceptance suite counts what the base pack plans on a new organisation,
-- on purpose. The administrator provisioning made already holds every
-- permission the template grants, so it is one item fewer.
do $acceptance$
declare
  v_def text := pg_get_functiondef('erp_test.starter_pack_acceptance_suite()'::regprocedure);
  v_n   text := $n$    (res ->> 'items')::integer = 346
$n$;
  v_r   text := $r$    -- 345, not 346, since 20260914061500: the administrator provisioning
    -- made already holds every permission the pack's administrator template
    -- grants, and a pack adds to a role it did not make rather than replacing
    -- it, so that item is no longer planned.
    (res ->> 'items')::integer = 345
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_ACCEPTANCE_SUITE_UNRECOGNISED: erp_test.starter_pack_acceptance_suite() does not count 346 planned items once'
      using hint = 'A later migration recounted the base pack. Read the suite and patch its count.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('integer = 345' in pg_get_functiondef('erp_test.starter_pack_acceptance_suite()'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_ACCEPTANCE_SUITE_UNRECOGNISED: the acceptance suite did not take its new count'
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the suite.';
  end if;
end
$acceptance$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Putting away is a move
-- ═════════════════════════════════════════════════════════════════════════════

do $warehouse$
declare
  v_sig  text;
  v_def  text;
  v_n    text;
  v_r    text;
begin
  foreach v_sig in array array['erp.raise_putaway_tasks(uuid)',
                               'erp.raise_replenishment_tasks(uuid)',
                               'erp.complete_warehouse_task(uuid,numeric)'] loop
    v_def := pg_get_functiondef(v_sig::regprocedure);
    if v_sig = 'erp.complete_warehouse_task(uuid,numeric)' then
      v_n := $n$  perform erp.authorise('inventory.adjust', null, t.site_id, null, 'warehouse_task', t.id);$n$;
      v_r := $r$  -- A warehouse task is a putaway or a replenishment, and either moves stock
  -- within its site: inventory.move, as the warehouse holds it
  -- (20260914061500). Correcting the books stays with inventory.adjust.
  perform erp.authorise('inventory.move', null, t.site_id, null, 'warehouse_task', t.id);$r$;
    else
      v_n := $n$  perform erp.authorise('inventory.adjust', null, p_site_id, null, 'site', p_site_id);$n$;
      v_r := $r$  -- Raising the tasks that move stock within a site is the warehouse's:
  -- inventory.move, as it holds it (20260914061500). Correcting the books
  -- stays with inventory.adjust.
  perform erp.authorise('inventory.move', null, p_site_id, null, 'site', p_site_id);$r$;
    end if;

    if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
      raise exception 'CLOVEERP_WAREHOUSE_TASK_DOOR_UNRECOGNISED: % does not authorise inventory.adjust the way this migration patches', v_sig
        using hint = 'A later migration changed the function. Read pg_get_functiondef() of it and patch that body.';
    end if;
    execute replace(v_def, v_n, v_r);

    v_def := pg_get_functiondef(v_sig::regprocedure);
    if position('''inventory.adjust''' in v_def) > 0 or position('''inventory.move''' in v_def) = 0 then
      raise exception 'CLOVEERP_WAREHOUSE_TASK_DOOR_UNRECOGNISED: % did not move to inventory.move', v_sig
        using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
    end if;
  end loop;
end
$warehouse$;

-- Replenishment never ran where a pick face held stock: its pick CTE took
-- min(a.location_id), and PostgreSQL 17 has no min(uuid), so the door failed
-- with "function min(uuid) does not exist" for anyone who reached a pickable
-- balance. The first case to raise replenishment as a signed-in person found
-- it. The lowest location by its text form is the same choice min() meant.
do $replenish$
declare
  v_sig text := 'erp.raise_replenishment_tasks(uuid)';
  v_def text;
  v_n   text := 'min(a.location_id) as location_id';
  v_r   text := '(array_agg(a.location_id order by a.location_id::text))[1] as location_id';
begin
  v_def := pg_get_functiondef(v_sig::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_REPLENISHMENT_DOOR_UNRECOGNISED: % does not choose its pick location the way this migration patches', v_sig
      using hint = 'A later migration changed the function. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('min(a.location_id)' in v_def) > 0 then
    raise exception 'CLOVEERP_REPLENISHMENT_DOOR_UNRECOGNISED: % still takes min() of a uuid', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$replenish$;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'raise_putaway_tasks',
   'Reads stock standing in receiving locations and raises a putaway task for '
   'each. Scoped to erp.require_tenant_id() throughout and gated on '
   'inventory.move for the site before it writes anything (20260914061500).'),
  ('erp', 'raise_replenishment_tasks',
   'Compares pick-location cover against its minimum and raises replenishment '
   'tasks. Same tenant scope and the same inventory.move gate as putaway.'),
  ('erp', 'complete_warehouse_task',
   'Completes one warehouse task and posts the stock movement it represents. '
   'Loads the task by (tenant_id, id) first and refuses a task belonging to '
   'anyone else; authorises on inventory.move for that task''s own site.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Picking reserves what it picks
-- ═════════════════════════════════════════════════════════════════════════════

do $reserve$
declare
  v_def text := pg_get_functiondef('erp.reserve_for_line(uuid,text)'::regprocedure);
  v_n   text := $n$  perform erp.authorise('sales.order', d.entity_id, d.site_id, null,
                        'document_line', p_document_line_id);$n$;
  v_r   text := $r$  -- Reserving is the order desk's, under sales.order, and the despatcher's,
  -- under sales.despatch: picking an order reserves whatever nobody reserved
  -- yet (erp.pick_document), and whoever may despatch an order may hold its
  -- stock for it (20260914061500). A caller with neither is refused naming
  -- sales.order, as before.
  if erp.has_permission('sales.despatch', d.entity_id, d.site_id) then
    perform erp.authorise('sales.despatch', d.entity_id, d.site_id, null,
                          'document_line', p_document_line_id);
  else
    perform erp.authorise('sales.order', d.entity_id, d.site_id, null,
                          'document_line', p_document_line_id);
  end if;$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_RESERVE_FOR_LINE_UNRECOGNISED: erp.reserve_for_line() does not authorise sales.order the way this migration patches'
      using hint = 'A later migration changed the function. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('erp.has_permission(''sales.despatch''' in pg_get_functiondef('erp.reserve_for_line(uuid,text)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_RESERVE_FOR_LINE_UNRECOGNISED: erp.reserve_for_line() did not take the despatcher'
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$reserve$;

do $allowances$
declare
  v_n integer;
begin
  update erp_meta.public_write_allowance a
     set rationale = v.rationale
    from (values
      ('erp_reserve_for_line',
       'Reserves stock for an order line under sales.order, or under sales.despatch for whoever may despatch the order (20260914061500), using the promoted allocation policy rather than an argument.'),
      ('erp_pick_document',
       'Reserves and picks a sales order in one press. Gated on sales.despatch inside erp.pick_document(); each reservation it makes is authorised again inside erp.reserve_for_line(), which accepts sales.despatch as well as sales.order (20260914061500).')
    ) as v(function_name, rationale)
   where a.function_name = v.function_name;
  get diagnostics v_n = row_count;
  if v_n <> 2 then
    raise exception 'CLOVEERP_WRITE_ALLOWANCE_NOT_UPDATED: % of 2 write allowance rows were reworded', v_n
      using hint = 'The rows are written by 20260829320000 and 20260910165931. If row security refused the update, the migration role has lost its bypass.';
  end if;
end
$allowances$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The warehouse roles receive, pick and despatch
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The base pack's items are upserted in place, as 20260904930000 did: a pack
-- item is what the next application plans, and an organisation sees the change
-- in that change set's preview before anything lands.

do $templates$
declare
  v_n integer;
begin
  update erp_ref.pack_item pi
     set payload = jsonb_set(pi.payload, '{permissions}',
                     (select jsonb_agg(jsonb_build_object('permission', u.perm) order by u.ord)
                        from unnest(v.perms) with ordinality as u(perm, ord))),
         provenance = v.why
    from (values
      ('warehouse_manager',
       array['inventory.read','inventory.move','inventory.count','inventory.adjust',
             'inventory.write_off','logistics.read','logistics.plan','logistics.despatch',
             'procurement.read','procurement.receive','sales.read','sales.despatch',
             'master_data.read','reporting.read'],
       'Starter Content Packs §3.2. Holds adjust and write_off; §3.3''s seventh '
       'conflict refuses the same person approving the adjustment. Receives against '
       'an order, and picks and despatches a sales order, because that is where the '
       'goods are (20260914061500).'),
      ('warehouse_operative',
       array['inventory.read','inventory.move','inventory.count','procurement.read',
             'procurement.receive','sales.read','sales.despatch','logistics.read',
             'logistics.despatch'],
       'Starter Content Packs §3.2. Counts but does not adjust: a variance is a '
       'finding for somebody else to accept. Receives against an order, and picks and '
       'despatches a sales order, because that is where the goods are (20260914061500).')
    ) as v(code, perms, why)
   where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = v.code;
  get diagnostics v_n = row_count;
  if v_n <> 2 then
    raise exception 'CLOVEERP_PACK_TEMPLATE_MISSING: % of 2 warehouse role templates found in the base pack', v_n
      using hint = 'The templates are registered by 20260903150000; a code changed name.';
  end if;

  -- Posting a delivery requires sales.despatch; proof of delivery is
  -- logistics.despatch. Either is confirming a despatch.
  update erp_ref.pack_item pi
     set payload = jsonb_set(pi.payload, '{permissions_a}', to_jsonb('logistics.despatch,sales.despatch'::text))
   where pi.pack_code = 'base' and pi.object_kind = 'sod_rule' and pi.object_key = 'DELIVER_INVOICE';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_PACK_TEMPLATE_MISSING: % DELIVER_INVOICE rule(s) found in the base pack, expected 1', v_n
      using hint = 'The rule is registered by 20260903150000; its key changed.';
  end if;
end
$templates$;

-- Same signature and return type as 20260911113637, so the grants stay.
create or replace function erp.standard_role_permissions(p_code text)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct p.code order by p.code), '{}')
    from erp_ref.permission p
   where p.module_code = case p_code
                           when 'purchasing'  then 'procurement'
                           when 'despatch'    then 'logistics'
                           when 'master_data' then 'master_data'
                           when 'warehouse'   then null
                           else p_code
                         end
      or p.code = any (case p_code
        when 'inventory'   then array['master_data.read','reporting.read']
        when 'purchasing'  then array['master_data.read','inventory.read','reporting.read']
        -- Whoever raises the invoice issues and reprints it. Managing the
        -- template is a different job and stays out.
        when 'sales'       then array['master_data.read','inventory.read','reporting.read',
                                      'document.issue','document.reprint']
        when 'finance'     then array['master_data.read','reporting.read','reporting.export',
                                      'document.issue','document.reprint']
        when 'production'  then array['inventory.read','master_data.read','reporting.read']
        when 'quality'     then array['inventory.read','production.read','reporting.read']
        when 'despatch'    then array['inventory.read','sales.read','reporting.read']
        when 'planning'    then array['inventory.read','procurement.read','production.read','reporting.read']
        when 'reporting'   then array['master_data.read']
        -- The template is reference material, kept by the people who keep the
        -- rest of it. Issuing is not theirs.
        when 'master_data' then array['reporting.read','document.template_manage']
        -- Goods arrive at the warehouse, so receiving against an order is the
        -- warehouse's, and so is reading the order it is received against
        -- (20260914061500). Approving that order is not.
        when 'warehouse'   then array[
                                'inventory.read','inventory.move','inventory.count',
                                'logistics.read','logistics.despatch',
                                'procurement.read','procurement.receive',
                                'sales.read','sales.despatch',
                                'master_data.read','reporting.read']
        else '{}'::text[]
      end)
$$;

comment on function erp.standard_role_permissions is
  'What one job needs, by role code. Roles combine, so a person doing two jobs '
  'holds both roles rather than a third role made for the pair. Issuing and '
  'reprinting a document sit with the roles that already raise it; managing the '
  'template sits with master data. The warehouse receives, moves, counts, picks '
  'and despatches, and neither adjusts nor approves.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The walkthrough says who installs finance
-- ═════════════════════════════════════════════════════════════════════════════

do $step$
declare
  v_n integer;
begin
  update erp_ref.setup_step s
     set permission_code = 'finance.configure',
         why = 'The finance installer creates the ledgers and periods every other module posts into. It needs finance.configure as well as administration.configure, held by the same person: the finance manager role carries finance.configure, and so does the administrator role an organisation is created with.'
   where s.code = 'configuration.finance';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_COPY_TARGET_MISSING: % configuration.finance setup step(s), expected 1', v_n
      using hint = 'The step is registered by 20260913022000; its code changed.';
  end if;
end
$step$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Three parts. The content, read from the pack, the module role and the doors.
-- Organisation A, built the way the starter pack acceptance suite builds one
-- (seven modules, the Standard preset, a second administrator who approves),
-- with a buyer role of its own made before the base pack is applied and
-- promoted. Organisation B, opened for setting up, with a hundred in goods-in,
-- an order nobody has reserved, and three people holding one narrow role each,
-- whose doors are called as a signed-in caller through
-- erp_test.warehouse_door_as(). Both organisations are undone.

create or replace function erp_test.warehouse_door_as(p_subject uuid, p_door text, p_arg uuid)
returns table (outcome jsonb, err_state text, err_message text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_owner text := current_user;
begin
  if p_door not in ('erp_raise_putaway_tasks', 'erp_raise_replenishment_tasks',
                    'erp_complete_warehouse_task', 'erp_pick_document', 'erp_reserve_for_line') then
    raise exception 'CLOVEERP_SUITE_HELPER_MISUSED: % is not a door erp_test.warehouse_and_finance_jobs_suite calls', p_door
      using hint = 'Call erp_raise_putaway_tasks, erp_raise_replenishment_tasks, erp_complete_warehouse_task, erp_pick_document or erp_reserve_for_line.';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_subject, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute format('select to_jsonb(public.%I($1))', p_door) into outcome using p_arg;
  exception when others then
    get stacked diagnostics err_state = returned_sqlstate,
                            err_message = message_text;
  end;
  execute format('set local role %I', v_owner);
  return next;
end;
$$;
revoke all on function erp_test.warehouse_door_as(uuid, text, uuid) from public, anon, authenticated;

comment on function erp_test.warehouse_door_as(uuid, text, uuid) is
  'Suite helper: calls one warehouse or picking door with one id as the given '
  'sign-in, in the authenticated role, and returns its answer as jsonb or its '
  'refusal. Returns to the calling role before it returns.';

create or replace function erp_test.warehouse_and_finance_jobs_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  -- Organisation A.
  a1         uuid := gen_random_uuid();   -- its first administrator, who applies the pack
  a2         uuid := gen_random_uuid();   -- its second, who approves and promotes it
  ra         record;
  res        jsonb;
  c          record;
  d          record;
  i          integer := 0;
  v_second   uuid;
  v_tok      text;
  v_cs       uuid;
  v_admin_before  integer;
  v_admin_codes   text[];
  v_admin_mark    text;
  v_plan_admin    boolean;
  v_plan_buyer    boolean;
  v_plan_operative boolean;
  v_buyer_name    text;
  v_buyer_mark    text;
  v_buyer_codes   text[];
  v_op_mark       text;
  v_op_codes      text[];
  v_replan_roles  integer;
  v_state_a  text;
  v_step     text := 'reading the pack';
  -- Organisation B.
  b1         uuid := gen_random_uuid();   -- its administrator, who sets it up
  s_mover    uuid := gen_random_uuid();   -- holds inventory.read and inventory.move
  s_desp     uuid := gen_random_uuid();   -- holds sales.read and sales.despatch
  s_onlooker uuid := gen_random_uuid();   -- holds inventory.read and sales.read
  rb         record;
  g          record;
  u_mover    uuid;
  u_desp     uuid;
  u_onlooker uuid;
  v_uom      uuid;
  v_site     uuid;
  v_recv     uuid;
  v_bulk     uuid;
  v_sup      uuid;
  v_cust     uuid;
  v_item     uuid;
  v_grn      uuid;
  v_line     uuid;
  v_task     uuid;
  v_so       uuid;
  v_sol      uuid;
  v_warehouse_codes text[];
  v_state_b  text;
  -- The content.
  v_operative text[];
  v_manager   text[];
  v_module    text[] := erp.standard_role_permissions('warehouse');
  v_deliver   jsonb;
  v_breaks    text;
  v_match     integer;
  v_pairs     integer;
  v_gates     text;
  c_expected_buyer constant text[] := array[
    'finance.read', 'procurement.read', 'procurement.order', 'procurement.requisition',
    'master_data.read', 'planning.read', 'inventory.read', 'reporting.read'];

  ok_fixture  boolean; msg_fixture  text;
  ok_org_role boolean;
  ok_refused  boolean; msg_refused  text;
  ok_raise    boolean; msg_raise    text;
  ok_complete boolean; msg_complete text;
  ok_replen   boolean; msg_replen   text;
  ok_nopick   boolean; msg_nopick   text;
  ok_pick     boolean; msg_pick     text;
begin
  -- ── The content ────────────────────────────────────────────────────────
  select coalesce(array_agg(e.value ->> 'permission'), '{}'::text[]) into v_operative
    from erp_ref.pack_item pi, jsonb_array_elements(pi.payload -> 'permissions') e
   where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = 'warehouse_operative';
  select coalesce(array_agg(e.value ->> 'permission'), '{}'::text[]) into v_manager
    from erp_ref.pack_item pi, jsonb_array_elements(pi.payload -> 'permissions') e
   where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = 'warehouse_manager';
  select pi.payload into v_deliver
    from erp_ref.pack_item pi
   where pi.pack_code = 'base' and pi.object_kind = 'sod_rule' and pi.object_key = 'DELIVER_INVOICE';

  select string_agg(format('%s holds both sides of %s', h.holder, s.object_key), '; ' order by h.holder, s.object_key)
    into v_breaks
    from (select 'warehouse_manager'::text as holder, v_manager as perms
          union all select 'warehouse_operative', v_operative
          union all select 'the warehouse module role', v_module) h
    cross join erp_ref.pack_item s
   where s.pack_code = 'base' and s.object_kind = 'sod_rule'
     and s.payload ->> 'severity' = 'prohibited'
     and h.perms && string_to_array(s.payload ->> 'permissions_a', ',')
     and h.perms && string_to_array(s.payload ->> 'permissions_b', ',');

  select count(*) filter (where g2.verdict = 'match'), count(*),
         string_agg(format('%s under %s: %s', g2.door, g2.permission_code, g2.verdict), '; ' order by g2.door)
    into v_match, v_pairs, v_gates
    from erp.app_gate_report(array[
      'erp_raise_putaway_tasks|inventory.move',
      'erp_raise_replenishment_tasks|inventory.move',
      'erp_complete_warehouse_task|inventory.move',
      'erp_commit_allocation|sales.despatch',
      'erp_pick_document|sales.despatch',
      'erp_reserve_for_line|sales.order',
      'erp_configure_finance|finance.configure']) g2;

  -- ── Organisation A: the base pack meets roles it did not make ──────────
  begin
    v_step := 'organisation A is provisioned and its two administrators join';
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant('zzwfa-' || v_tag, 'Warehouse Finance Suite A',
                                               'admin@zzwfa-' || v_tag || '.test', 'Suite Admin');
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(ra.admin_token);
    res := public.erp_invite_principal('second@zzwfa-' || v_tag || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid;
    v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    v_step := 'the modules the base pack presupposes are installed and promoted';
    perform erp.configure_finance();
    perform erp.configure_procurement(1000000);
    perform erp.configure_sales();
    perform erp.configure_inventory();
    perform erp.configure_quality();
    perform erp.configure_logistics();
    perform erp.configure_period_close();
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    for c in select cs.id from erp.change_set cs
              where cs.tenant_id = ra.tenant_id and cs.status = 'ready'
              order by cs.created_at loop
      perform erp.approve_change_set(c.id);
      perform erp.promote_change_set(c.id);
    end loop;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'the Standard preset is switched on';
    res := erp.apply_preset('standard');
    v_cs := (res ->> 'change_set_id')::uuid;
    perform erp.submit_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'the organisation builds a buyer role of its own';
    v_cs := erp.create_change_set('zzwfa-buyer-' || v_tag, 'Our buyer',
                                  'The organisation''s own buyer role, made before the base pack.');
    perform erp.add_change_set_item(v_cs, 'role', 'buyer',
      jsonb_build_object('code', 'buyer', 'name', 'Our buyer',
        'permissions', jsonb_build_array(
          jsonb_build_object('permission', 'procurement.read'),
          jsonb_build_object('permission', 'procurement.order'),
          jsonb_build_object('permission', 'finance.read'))),
      'upsert'::erp.change_operation, null, 'the warehouse and finance suite');
    perform erp.submit_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select count(*) into v_admin_before
      from erp.role ro
      join erp.role_permission rp on rp.tenant_id = ro.tenant_id and rp.role_id = ro.id
     where ro.tenant_id = ra.tenant_id and ro.code = 'administrator';

    v_step := 'the first administrator applies the base pack';
    res := erp.apply_content_pack('base');
    v_cs := (res ->> 'change_set_id')::uuid;
    select coalesce(bool_or(csi.object_key = 'administrator'), false),
           coalesce(bool_or(csi.object_key = 'buyer'), false),
           coalesce(bool_or(csi.object_key = 'warehouse_operative'), false)
      into v_plan_admin, v_plan_buyer, v_plan_operative
      from erp.change_set_item csi
     where csi.tenant_id = ra.tenant_id and csi.change_set_id = v_cs and csi.object_kind = 'role';

    v_step := 'the pack''s decisions are answered and the second administrator promotes it';
    for d in select * from erp.pack_decisions('base') where not answered loop
      i := i + 1;
      perform erp.answer_pack_decision('base', d.object_kind, d.object_key,
        jsonb_build_object('upper_bound_minor', i * 500000));
    end loop;
    perform erp.submit_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'reading the roles the promotion left';
    select coalesce(array_agg(rp.permission_code), '{}'::text[]), min(ro.from_template)
      into v_admin_codes, v_admin_mark
      from erp.role ro
      join erp.role_permission rp on rp.tenant_id = ro.tenant_id and rp.role_id = ro.id
     where ro.tenant_id = ra.tenant_id and ro.code = 'administrator';

    select min(ro.name), min(ro.from_template), coalesce(array_agg(rp.permission_code), '{}'::text[])
      into v_buyer_name, v_buyer_mark, v_buyer_codes
      from erp.role ro
      join erp.role_permission rp on rp.tenant_id = ro.tenant_id and rp.role_id = ro.id
     where ro.tenant_id = ra.tenant_id and ro.code = 'buyer';

    select min(ro.from_template), coalesce(array_agg(rp.permission_code), '{}'::text[])
      into v_op_mark, v_op_codes
      from erp.role ro
      join erp.role_permission rp on rp.tenant_id = ro.tenant_id and rp.role_id = ro.id
     where ro.tenant_id = ra.tenant_id and ro.code = 'warehouse_operative';

    select count(*) into v_replan_roles
      from erp.plan_content_pack('base') p
     where p.object_kind = 'role';

    -- Asked while organisation A still exists; answered below.
    ok_org_role := erp.has_permission('finance.configure', null, null, null, v_second)
               and erp.has_permission('master_data.write', null, null, null, v_second)
               and erp.has_permission('master_data.approve', null, null, null, v_second)
               and erp.has_permission('finance.configure', null, null, null, ra.admin_user_id)
               and erp.has_permission('master_data.write', null, null, null, ra.admin_user_id)
               and erp.has_permission('administration.promote', null, null, null, v_second);

    perform set_config('request.jwt.claims', '', true);
    raise exception 'ZZ_WAREHOUSE_FINANCE_SUITE_A_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_WAREHOUSE_FINANCE_SUITE_A_UNDO' then
      v_state_a := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  -- ── Organisation B: putting away and picking, as the people who do it ──
  begin
    v_step := 'organisation B is provisioned and opened for setting up';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant('zzwfb-' || v_tag, 'Warehouse Finance Suite B',
                                               'admin@zzwfb-' || v_tag || '.test', 'Warehouse Suite Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', b1)::text, true);
    perform erp.claim_invitation(rb.admin_token);

    select coalesce(array_agg(rp.permission_code), '{}'::text[]) into v_warehouse_codes
      from erp.role ro
      join erp.role_permission rp on rp.tenant_id = ro.tenant_id and rp.role_id = ro.id
     where ro.tenant_id = rb.tenant_id and ro.code = 'warehouse';

    v_step := 'finance, procurement, sales and inventory are installed';
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');

    v_step := 'a site with goods-in and bulk, a supplier, a customer and a product';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZWEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZWMAIN', 'Suite warehouse', 'warehouse', 'active')
    returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (rb.tenant_id, v_site, 'ZWRECV', 'Goods in', 'receiving', 'active') returning id into v_recv;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (rb.tenant_id, v_site, 'ZWBULK', 'Bulk', 'bulk', 'active') returning id into v_bulk;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZWSUP', 'Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZWCUST', 'Suite Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active'), (rb.tenant_id, v_cust, 'customer', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZWWID', 'Suite Widget', v_uom, 'active') returning id into v_item;

    v_step := 'a hundred arrive in goods-in';
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    v_line := erp.add_document_line(v_grn, v_item, 100, 1000, 'the stock', current_date);
    update erp.document_line set location_id = v_recv where id = v_line;
    perform erp.transition_document(v_grn, 'post', 'warehouse and finance suite');

    v_step := 'three people, each holding one narrow role';
    insert into erp.role (tenant_id, code, name, status) values
      (rb.tenant_id, 'zz_mover', 'Suite mover', 'active'),
      (rb.tenant_id, 'zz_despatcher', 'Suite despatcher', 'active'),
      (rb.tenant_id, 'zz_onlooker', 'Suite onlooker', 'active');
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select rb.tenant_id, ro.id, x.perm
      from (values ('zz_mover', 'inventory.read'), ('zz_mover', 'inventory.move'),
                   ('zz_despatcher', 'sales.read'), ('zz_despatcher', 'sales.despatch'),
                   ('zz_onlooker', 'inventory.read'), ('zz_onlooker', 'sales.read')) as x(role_code, perm)
      join erp.role ro on ro.tenant_id = rb.tenant_id and ro.code = x.role_code;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (rb.tenant_id, s_mover, 'person', 'active', 'Suite Mover', 'mover@zzwfb-' || v_tag || '.test')
    returning id into u_mover;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (rb.tenant_id, s_desp, 'person', 'active', 'Suite Despatcher', 'despatch@zzwfb-' || v_tag || '.test')
    returning id into u_desp;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (rb.tenant_id, s_onlooker, 'person', 'active', 'Suite Onlooker', 'onlooker@zzwfb-' || v_tag || '.test')
    returning id into u_onlooker;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    select rb.tenant_id, x.person, ro.id, 'The suite''s narrow role.'
      from (values (u_mover, 'zz_mover'), (u_desp, 'zz_despatcher'), (u_onlooker, 'zz_onlooker')) as x(person, role_code)
      join erp.role ro on ro.tenant_id = rb.tenant_id and ro.code = x.role_code;

    ok_fixture := erp.has_permission('inventory.move', null, null, null, u_mover)
              and not erp.has_permission('inventory.adjust', null, null, null, u_mover)
              and erp.has_permission('sales.despatch', null, null, null, u_desp)
              and not erp.has_permission('sales.order', null, null, null, u_desp)
              and not erp.has_permission('inventory.move', null, null, null, u_onlooker)
              and not erp.has_permission('sales.despatch', null, null, null, u_onlooker)
              and not erp.has_permission('sales.order', null, null, null, u_onlooker)
              and exists (select 1 from erp.stock_balance sb
                           where sb.tenant_id = rb.tenant_id and sb.item_id = v_item
                             and sb.location_id = v_recv and sb.quantity = 100);
    msg_fixture := format('stock in goods-in: %s',
                          coalesce((select sum(sb.quantity) from erp.stock_balance sb
                                     where sb.tenant_id = rb.tenant_id and sb.item_id = v_item
                                       and sb.location_id = v_recv)::text, 'none'));

    -- ── Putting away ─────────────────────────────────────────────────────
    v_step := 'somebody without inventory.move asks for putaway and replenishment';
    select * into g from erp_test.warehouse_door_as(s_onlooker, 'erp_raise_putaway_tasks', v_site);
    ok_refused := coalesce(g.err_state = '42501' and g.err_message like 'CLOVEERP_PERMISSION_DENIED: inventory.move%', false);
    msg_refused := 'raise putaway: ' || coalesce(g.err_message, g.outcome::text, 'no answer');
    select * into g from erp_test.warehouse_door_as(s_onlooker, 'erp_raise_replenishment_tasks', v_site);
    ok_refused := ok_refused and coalesce(g.err_state = '42501' and g.err_message like 'CLOVEERP_PERMISSION_DENIED: inventory.move%', false);
    msg_refused := msg_refused || '; raise replenishment: ' || coalesce(g.err_message, g.outcome::text, 'no answer');

    v_step := 'somebody with inventory.move and not inventory.adjust raises putaway';
    select * into g from erp_test.warehouse_door_as(s_mover, 'erp_raise_putaway_tasks', v_site);
    select t.id into v_task
      from erp.warehouse_task t
     where t.tenant_id = rb.tenant_id and t.kind = 'putaway' and t.status = 'open'
       and t.item_id = v_item and t.from_location_id = v_recv
     limit 1;
    ok_raise := coalesce(g.err_state is null and (g.outcome #>> '{}')::integer >= 1 and v_task is not null, false);
    msg_raise := coalesce(g.err_message, 'raised ' || (g.outcome #>> '{}'), 'no answer')
      || case when v_task is null then '; no open putaway task out of goods-in' else '; a task out of goods-in is open' end;

    v_step := 'somebody without inventory.move tries to complete the task';
    select * into g from erp_test.warehouse_door_as(s_onlooker, 'erp_complete_warehouse_task', v_task);
    ok_refused := ok_refused and coalesce(g.err_state = '42501' and g.err_message like 'CLOVEERP_PERMISSION_DENIED: inventory.move%', false);
    msg_refused := msg_refused || '; complete: ' || coalesce(g.err_message, g.outcome::text, 'no answer');

    v_step := 'somebody with inventory.move completes the task';
    select * into g from erp_test.warehouse_door_as(s_mover, 'erp_complete_warehouse_task', v_task);
    ok_complete := coalesce(
      g.err_state is null
      and (g.outcome ->> 'moved')::numeric = 100
      and (select t.status from erp.warehouse_task t where t.id = v_task) = 'done'
      and exists (select 1 from erp.stock_movement m
                   where m.tenant_id = rb.tenant_id and m.item_id = v_item
                     and m.movement_type = 'putaway' and m.from_location_id = v_recv)
      and not exists (select 1 from erp.stock_balance sb
                       where sb.tenant_id = rb.tenant_id and sb.item_id = v_item
                         and sb.location_id = v_recv and sb.quantity <> 0), false);
    msg_complete := coalesce(g.err_message, g.outcome::text, 'no answer');

    v_step := 'somebody with inventory.move raises replenishment';
    select * into g from erp_test.warehouse_door_as(s_mover, 'erp_raise_replenishment_tasks', v_site);
    ok_replen := coalesce(g.err_state is null and (g.outcome #>> '{}')::integer >= 0, false);
    msg_replen := coalesce(g.err_message, 'raised ' || (g.outcome #>> '{}'), 'no answer');

    -- ── Picking ──────────────────────────────────────────────────────────
    v_step := 'an order nobody has reserved';
    perform set_config('request.jwt.claims', json_build_object('sub', b1)::text, true);
    v_so := erp.open_document('sales_order', v_cust, rb.entity_id, v_site);
    v_sol := erp.add_document_line(v_so, v_item, 4, 2500, 'ordered', current_date);

    v_step := 'somebody with neither sales.despatch nor sales.order picks and reserves';
    select * into g from erp_test.warehouse_door_as(s_onlooker, 'erp_pick_document', v_so);
    ok_nopick := coalesce(g.err_state = '42501' and g.err_message like 'CLOVEERP_PERMISSION_DENIED: sales.despatch%', false);
    msg_nopick := 'pick: ' || coalesce(g.err_message, g.outcome::text, 'no answer');
    select * into g from erp_test.warehouse_door_as(s_onlooker, 'erp_reserve_for_line', v_sol);
    ok_nopick := ok_nopick
      and coalesce(g.err_state = '42501' and g.err_message like 'CLOVEERP_PERMISSION_DENIED: sales.order%', false)
      and not exists (select 1 from erp.allocation al
                       where al.tenant_id = rb.tenant_id and al.document_line_id = v_sol);
    msg_nopick := msg_nopick || '; reserve: ' || coalesce(g.err_message, g.outcome::text, 'no answer');

    v_step := 'somebody with sales.despatch and not sales.order picks the order';
    select * into g from erp_test.warehouse_door_as(s_desp, 'erp_pick_document', v_so);
    ok_pick := coalesce(
      g.err_state is null
      and (g.outcome ->> 'reserved')::integer = 1
      and (g.outcome ->> 'picked')::integer = 1
      and (g.outcome ->> 'pick_lines')::integer >= 1
      and exists (select 1 from erp.allocation al
                   where al.tenant_id = rb.tenant_id and al.document_line_id = v_sol
                     and al.status = 'committed'), false);
    msg_pick := coalesce(g.err_message, g.outcome::text, 'no answer');

    perform set_config('request.jwt.claims', '', true);
    raise exception 'ZZ_WAREHOUSE_FINANCE_SUITE_B_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_WAREHOUSE_FINANCE_SUITE_B_UNDO' then
      v_state_b := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  -- ── The verdicts ───────────────────────────────────────────────────────

  case_name := 'the warehouse operative template receives, picks and despatches, and neither adjusts nor writes off';
  passed := v_operative @> array['procurement.read', 'procurement.receive', 'sales.read', 'sales.despatch', 'inventory.move']
            and not (v_operative && array['inventory.adjust', 'inventory.write_off']);
  detail := array_to_string(v_operative, ', ');
  return next;

  case_name := 'the warehouse manager template receives, picks and despatches';
  passed := v_manager @> array['procurement.read', 'procurement.receive', 'sales.read', 'sales.despatch', 'inventory.move'];
  detail := array_to_string(v_manager, ', ');
  return next;

  case_name := 'the warehouse module role receives, picks and despatches, and neither adjusts nor writes off';
  passed := v_module @> array['procurement.read', 'procurement.receive', 'sales.read', 'sales.despatch', 'inventory.move']
            and not (v_module && array['inventory.adjust', 'inventory.write_off', 'procurement.approve']);
  detail := array_to_string(v_module, ', ');
  return next;

  case_name := 'the delivery-and-invoice rule names the permission that posts a delivery, and every code it names exists';
  passed := coalesce(string_to_array(v_deliver ->> 'permissions_a', ',') @> array['logistics.despatch', 'sales.despatch']
                     and v_deliver ->> 'permissions_b' = 'sales.invoice'
                     and not exists (select 1 from unnest(string_to_array(v_deliver ->> 'permissions_a', ',')
                                                          || string_to_array(v_deliver ->> 'permissions_b', ',')) x
                                      where not exists (select 1 from erp_ref.permission pm where pm.code = x)), false);
  detail := coalesce(v_deliver::text, 'no DELIVER_INVOICE rule in the base pack');
  return next;

  case_name := 'neither warehouse template, nor the warehouse module role, holds both sides of a prohibited rule';
  passed := v_breaks is null and cardinality(v_operative) > 0 and cardinality(v_manager) > 0;
  detail := coalesce(v_breaks, 'no prohibited pairing');
  return next;

  case_name := 'the putaway, replenishment and pick doors authorise what the desk asks for, no putaway door asks for inventory.adjust, and installing finance is walked through under finance.configure';
  passed := coalesce(v_match = 7 and v_pairs = 7
    and position('''inventory.adjust''' in pg_catalog.pg_get_functiondef('erp.raise_putaway_tasks(uuid)'::regprocedure)) = 0
    and position('''inventory.adjust''' in pg_catalog.pg_get_functiondef('erp.raise_replenishment_tasks(uuid)'::regprocedure)) = 0
    and position('''inventory.adjust''' in pg_catalog.pg_get_functiondef('erp.complete_warehouse_task(uuid,numeric)'::regprocedure)) = 0
    and (select s.permission_code from erp_ref.setup_step s where s.code = 'configuration.finance') = 'finance.configure', false);
  detail := format('%s of %s pairs match: %s; walkthrough step under %s', v_match, v_pairs, v_gates,
                   coalesce((select s.permission_code from erp_ref.setup_step s where s.code = 'configuration.finance'), 'nothing'));
  return next;

  case_name := 'applying the base pack plans the organisation''s own buyer and the pack''s new roles, and not the administrator provisioning made';
  passed := v_state_a is null and coalesce(v_plan_buyer and v_plan_operative and not v_plan_admin, false);
  detail := coalesce(v_state_a, format('administrator planned: %s; buyer planned: %s; warehouse_operative planned: %s',
                                       v_plan_admin, v_plan_buyer, v_plan_operative));
  return next;

  case_name := 'promoting the base pack leaves the administrator every permission it held, and no template mark';
  passed := v_state_a is null
            and coalesce(cardinality(v_admin_codes) = v_admin_before
                         and v_admin_before > 8
                         and v_admin_codes @> array['finance.configure', 'master_data.write', 'master_data.approve',
                                                    'procurement.approve', 'sales.order', 'administration.promote']
                         and v_admin_mark is null, false);
  detail := coalesce(v_state_a, format('%s permission(s) before, %s after; template mark %s',
                                       v_admin_before, cardinality(v_admin_codes), coalesce(v_admin_mark, 'none')));
  return next;

  case_name := 'both administrators can still set up finance and keep master data after promoting it';
  passed := v_state_a is null and coalesce(ok_org_role, false);
  detail := coalesce(v_state_a, case when ok_org_role then 'finance.configure, master_data.write and master_data.approve held by both'
                                     else 'a permission was lost' end);
  return next;

  case_name := 'a role the organisation made keeps its name, its grants and no template mark, and gains what the template adds';
  passed := v_state_a is null
            and coalesce(v_buyer_name = 'Our buyer' and v_buyer_mark is null
                         and v_buyer_codes @> c_expected_buyer and c_expected_buyer @> v_buyer_codes, false);
  detail := coalesce(v_state_a, format('%s, template %s: %s', v_buyer_name, coalesce(v_buyer_mark, 'none'),
                                       array_to_string(v_buyer_codes, ', ')));
  return next;

  case_name := 'a role the pack creates holds exactly its template, receiving, picking and despatching included';
  passed := v_state_a is null
            and coalesce(v_op_mark = 'base-1.0.0' and v_op_codes @> v_operative and v_operative @> v_op_codes, false);
  detail := coalesce(v_state_a, format('template %s: %s', coalesce(v_op_mark, 'none'), array_to_string(v_op_codes, ', ')));
  return next;

  case_name := 'applying the base pack again plans no role at all';
  passed := v_state_a is null and coalesce(v_replan_roles = 0, false);
  detail := coalesce(v_state_a, format('%s role item(s) planned', v_replan_roles));
  return next;

  case_name := 'the three people hold what the cases say, and a hundred stand in goods-in';
  passed := v_state_b is null and coalesce(ok_fixture, false);
  detail := coalesce(v_state_b, msg_fixture, 'no answer');
  return next;

  case_name := 'a new organisation''s warehouse role receives against an order, picks and despatches';
  passed := v_state_b is null
            and coalesce(v_warehouse_codes @> array['procurement.read', 'procurement.receive', 'sales.despatch', 'inventory.move']
                         and not (v_warehouse_codes && array['inventory.adjust', 'inventory.write_off']), false);
  detail := coalesce(v_state_b, array_to_string(v_warehouse_codes, ', '));
  return next;

  case_name := 'somebody without inventory.move is refused raising putaway, raising replenishment and completing a task, naming inventory.move';
  passed := v_state_b is null and coalesce(ok_refused, false);
  detail := coalesce(v_state_b, msg_refused, 'no answer');
  return next;

  case_name := 'somebody with inventory.move and not inventory.adjust raises putaway tasks for what stands in goods-in';
  passed := v_state_b is null and coalesce(ok_raise, false);
  detail := coalesce(v_state_b, msg_raise, 'no answer');
  return next;

  case_name := 'and completes one, which moves the hundred out of goods-in';
  passed := v_state_b is null and coalesce(ok_complete, false);
  detail := coalesce(v_state_b, msg_complete, 'no answer');
  return next;

  case_name := 'somebody with inventory.move raises replenishment tasks';
  passed := v_state_b is null and coalesce(ok_replen, false);
  detail := coalesce(v_state_b, msg_replen, 'no answer');
  return next;

  case_name := 'somebody with neither sales.despatch nor sales.order is refused picking, naming sales.despatch, and reserving, naming sales.order';
  passed := v_state_b is null and coalesce(ok_nopick, false);
  detail := coalesce(v_state_b, msg_nopick, 'no answer');
  return next;

  case_name := 'somebody with sales.despatch and not sales.order picks an order nobody reserved';
  passed := v_state_b is null and coalesce(ok_pick, false);
  detail := coalesce(v_state_b, msg_pick, 'no answer');
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code in ('zzwfa-' || v_tag, 'zzwfb-' || v_tag));
  detail := 'two organisations, their people, roles, stock, orders and change sets rolled back';
  return next;
end;
$$;
revoke all on function erp_test.warehouse_and_finance_jobs_suite() from public, anon, authenticated;

comment on function erp_test.warehouse_and_finance_jobs_suite() is
  'The warehouse and finance roles against their jobs: the base pack''s warehouse '
  'templates and the warehouse module role, the delivery-and-invoice rule, the '
  'doors the desk names; an organisation whose first administrator applies and a '
  'second promotes the base pack over the provisioned administrator and a buyer '
  'role of its own; and an organisation where people holding one narrow role each '
  'put away, replenish, pick and are refused, through the doors as a signed-in '
  'caller. Rolls back everything it made.';

create or replace function erp_test.assert_warehouse_and_finance_jobs_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 21;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.warehouse_and_finance_jobs_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_WAREHOUSE_FINANCE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_WAREHOUSE_FINANCE_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail
      using hint = 'Read the failed case before the door: a warehouse or finance person cannot do their job, or the base pack took a permission away.';
  end if;
  return format('warehouse and finance jobs: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;
revoke all on function erp_test.assert_warehouse_and_finance_jobs_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Generators, then the checks that read what changed
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
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_packs_installable();
select erp.assert_setup_walkthrough_actionable();
select erp.assert_guidance_sound();
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
select erp.assert_refusals_name_next_action();

select erp_test.assert_warehouse_and_finance_jobs_suite();
