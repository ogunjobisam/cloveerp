-- =============================================================================
-- Billing counts what was sold
--
-- 20260914095000 measured full and light users, and left three places where
-- what the product counts still differed from what the price list sells. The
-- owner approved all three fixes on 15 September.
--
--   1. SOMEBODY WHO ONLY USES THE SCANNER IS A LIGHT USER. The pricing page
--      says so. Every scanner door authorised inventory.move, and
--      inventory.move also builds batches and handling units and moves stock
--      that no task planned, so it needs a full seat.
--
--      inventory.scan, "Use the scanner", is added to the catalogue as a light
--      permission, with English and German words. It opens the scanner, but it
--      does not move stock on its own authority: it confirms work somebody
--      else has already planned. Door by door:
--
--        erp.open_device_session, erp.close_device_session,
--        erp.record_device_action    inventory.scan or inventory.move. Signing
--            on to a registered scanner, signing off, and queueing a scan
--            write nothing but the session and the queue.
--        erp.drain_device_actions    inventory.scan or inventory.move. For
--            somebody who holds inventory.scan and not inventory.move, only
--            the confirmations below are applied. Any other queued task
--            conflicts, saying that it needs somebody who may move stock:
--            erp.move_container has no gate of its own, so without this a
--            scanner could move a pallet that no task named.
--        erp.record_count            'count': the counted quantity against a
--            count task somebody raised.
--        erp.complete_warehouse_task 'putaway' and 'replenishment': a task
--            erp.raise_putaway_tasks or erp.raise_replenishment_tasks raised.
--        erp.commit_allocation       'pick': a reservation the order desk or
--            erp.pick_document made.
--        erp.receive_against         'receipt': a line of an open receipt
--            against a sent order.
--
--      Each of those four module routines accepts inventory.scan only while
--      erp.drain_device_actions is applying that operator's own queued action
--      of that kind, and only for a caller who lacks the routine's own
--      permission at that entity and site. From the desk, or for any other
--      task, each routine asks for exactly what it asked for before. Whatever
--      a routine reaches further in (a tolerance approval, a credit check, an
--      inspection) keeps its own rules. Staying on inventory.move: raising
--      putaway and replenishment tasks, erp.create_batch,
--      erp.create_handling_unit, and every device task that is not a
--      confirmation (internal move, marshalling, handling unit build, batch
--      action, adjustment).
--
--      A "Scanner operator" role template joins the base pack: inventory.scan,
--      inventory.read and master_data.read. A new organisation meets it when
--      it applies the pack. Provisioning's administrator already holds every
--      permission, so new administrators hold inventory.scan too.
--
--      Existing organisations. No role is rewritten here. erp.role_permission
--      is a promotable surface: in a live organisation the live-configuration
--      guard refuses a grant written outside a promotion (20260914098000). An
--      organisation that wants the role applies the base pack again, or builds
--      the role on Permissions, and approves and promotes the change like any
--      other; the pack's plan now offers the Scanner operator. Nothing is
--      granted directly in organisations that are not live either. Nobody
--      loses the scanner: every role that opened it holds inventory.move,
--      which still opens it. The desk offers the Scanner to a holder of either
--      permission.
--
--   2. A CONTRACT SETS ITS FULL USERS LIMIT. create_contract_from_quote now
--      provisions 'users' as the plan tier's included_users plus every full
--      user line's quantity (Standard with 5 extra full users: 15 + 5 = 20).
--      Where the quote sells a users band, the band still sets the limit, as
--      before. erp.provision_sold_seats() gives contracts already in force the
--      users and light users limits their quote sold, and does nothing where a
--      row is already there; the migration runs it once for every contract.
--      The console's seats card reads the contract's limit, "As sold on the
--      contract."
--
--   3. A QUOTE'S USERS CHECK COUNTS FULL USERS ONLY. CLOVEERP_QUOTE_USERS_BEYOND_PLAN
--      counted light user lines against the plan's users limit, so a Starter
--      customer with 5 included users could not be sold 30 light users. Full
--      users (included plus extra full) are counted against 'users'. Light
--      users are refused only where a plan states a light_users limit, and no
--      plan on the list does. The registered refusal now says full users.
--      erp_test.selling_setup_suite proved the old rule with a light line; it
--      now proves the refusal with a full line on a quote of its own.
--      erp_test.light_users_suite expected the plan's users limit on its
--      contract, and now expects the contract's: 15 included and 2 extra.
--      erp_test.starter_pack_acceptance_suite counts 347 planned items, one
--      more for the Scanner operator template.
--
-- First pushed as 20260915010000, whose build failed only on that count. It
-- was never applied anywhere outside the build, and is replaced by this file.
--
-- Proof: erp_test.billing_matches_the_list_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The scanner permission
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.permission (code, module_code, action, name_key, data_class_aware, is_mutating, seat) values
  ('inventory.scan', 'inventory', 'scan', 'permission.inventory.scan', false, true, 'light')
on conflict (code) do update set seat = excluded.seat;

insert into erp_ref.resource (key, locale, value, description) values
  ('permission.inventory.scan', 'en', 'Use the scanner',
   'Confirms counts, put-aways, replenishments, picks and receipts that somebody else planned, on a registered scanner.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value) values
  ('permission.inventory.scan', 'de', 'Scanner verwenden')
on conflict (key, locale) do update set value = excluded.value;

create or replace function erp.scan_confirmable_tasks()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['count', 'putaway', 'replenishment', 'pick', 'receipt']::text[]
$$;

comment on function erp.scan_confirmable_tasks() is
  'The device tasks somebody holding only inventory.scan may apply: each '
  'confirms work somebody else planned.';

create or replace function erp.scan_confirms(p_permission_code text, p_task_codes text[],
                                             p_entity_id uuid default null, p_site_id uuid default null)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  v_action uuid := nullif(current_setting('erp.applying_device_action', true), '')::uuid;
begin
  -- Only while erp.drain_device_actions applies a queued action.
  if v_action is null then
    return false;
  end if;
  -- Somebody who holds the routine's own permission is authorised by it.
  if erp.has_permission(p_permission_code, p_entity_id, p_site_id) then
    return false;
  end if;
  if not erp.has_permission('inventory.scan', p_entity_id, p_site_id) then
    return false;
  end if;
  -- The caller's own queued action, of a kind this routine confirms.
  return exists (
    select 1
      from erp.device_action a
      join erp.device_session s on s.tenant_id = a.tenant_id and s.id = a.device_session_id
     where a.tenant_id = erp.require_tenant_id()
       and a.id = v_action
       and a.status = 'queued'
       and a.device_task_code = any (p_task_codes)
       and a.device_task_code = any (erp.scan_confirmable_tasks())
       and s.app_user_id = erp.current_principal_id());
end;
$$;

comment on function erp.scan_confirms(text, text[], uuid, uuid) is
  'True while erp.drain_device_actions applies the caller''s own queued action '
  'of one of the named kinds, and the caller holds inventory.scan but not the '
  'permission the routine asks for, at that entity and site. The routine then '
  'authorises inventory.scan instead. False from the desk, always.';

revoke all on function erp.scan_confirmable_tasks() from public, anon;
revoke all on function erp.scan_confirms(text, text[], uuid, uuid) from public, anon;

-- ── The scanner doors: either permission ─────────────────────────────────────

do $doors$
declare
  v_sig    text;
  v_def    text;
  v_needle constant text := $n$  perform erp.authorise('inventory.move');$n$;
  v_new    constant text := $n$  -- A scanner operator's inventory.scan opens the scanner as inventory.move
  -- does (20260915011000). Somebody with neither is refused naming inventory.move.
  if erp.has_permission('inventory.scan') and not erp.has_permission('inventory.move') then
    perform erp.authorise('inventory.scan');
  else
    perform erp.authorise('inventory.move');
  end if;$n$;
begin
  foreach v_sig in array array['erp.open_device_session(text,uuid,text)',
                               'erp.close_device_session(text)',
                               'erp.record_device_action(text,text,text,jsonb,text,text,timestamptz)'] loop
    v_def := pg_get_functiondef(v_sig::regprocedure);
    if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not authorise inventory.move exactly once', v_sig
        using hint = 'Read the live body and write the needle against it.';
    end if;
    execute replace(v_def, v_needle, v_new);
  end loop;
end
$doors$;

-- ── The drain: a scanner operator applies confirmations only ─────────────────

do $drain$
declare
  v_sig   constant text := 'erp.drain_device_actions(text,integer)';
  v_def   text := pg_get_functiondef('erp.drain_device_actions(text,integer)'::regprocedure);
  v_pairs text[][] := array[
    array[$n$  n_applied integer := 0; n_conflicted integer := 0; n_held integer := 0;$n$,
          $n$  n_applied integer := 0; n_conflicted integer := 0; n_held integer := 0;
  v_scan_only boolean;$n$],
    array[$n$  perform erp.authorise('inventory.move');$n$,
          $n$  -- Somebody holding inventory.scan and not inventory.move applies only
  -- confirmations of work somebody else planned (20260915011000).
  v_scan_only := erp.has_permission('inventory.scan') and not erp.has_permission('inventory.move');
  if v_scan_only then
    perform erp.authorise('inventory.scan');
  else
    perform erp.authorise('inventory.move');
  end if;$n$],
    array[$n$      else
        v_parts := '{}'; v_missing := null;$n$,
          $n$      elsif v_scan_only and not (a.device_task_code = any (erp.scan_confirmable_tasks())) then
        v_reason := format('a scanner confirms counts, put-aways, replenishments, picks and receipts; '
                           '%s is applied by somebody who may move stock', a.device_task_code);
      else
        v_parts := '{}'; v_missing := null;$n$],
    array[$n$          begin
            execute format('select (erp.%I(%s))::text', h.sql_function,
                           array_to_string(v_parts, ', '))
               into v_result using a.payload;
          exception when others then$n$,
          $n$          begin
            -- The routine may accept inventory.scan for this action alone
            -- (erp.scan_confirms). Undone with the block if it refuses.
            perform set_config('erp.applying_device_action', a.id::text, true);
            execute format('select (erp.%I(%s))::text', h.sql_function,
                           array_to_string(v_parts, ', '))
               into v_result using a.payload;
            perform set_config('erp.applying_device_action', '', true);
          exception when others then$n$]];
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    if (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]) <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry "%" exactly once', v_sig, left(v_pairs[i][1], 60)
        using hint = 'Read the live body and write the needle against it.';
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  execute v_def;
end
$drain$;

-- ── The confirmations: inventory.scan from the drain ─────────────────────────

do $confirm$
declare
  v_list jsonb := jsonb_build_array(
    jsonb_build_array('erp.record_count(uuid,numeric)',
      $n$  perform erp.authorise('inventory.count', null, t.site_id, null,
                        'count_task', p_task_id);$n$,
      $n$  -- A count task confirmed on the scanner (20260915011000).
  if erp.scan_confirms('inventory.count', array['count'], null, t.site_id) then
    perform erp.authorise('inventory.scan', null, t.site_id, null,
                          'count_task', p_task_id);
  else
    perform erp.authorise('inventory.count', null, t.site_id, null,
                          'count_task', p_task_id);
  end if;$n$),
    jsonb_build_array('erp.complete_warehouse_task(uuid,numeric)',
      $n$  perform erp.authorise('inventory.move', null, t.site_id, null, 'warehouse_task', t.id);$n$,
      $n$  -- A putaway or replenishment task confirmed on the scanner (20260915011000).
  if erp.scan_confirms('inventory.move', array['putaway', 'replenishment'], null, t.site_id) then
    perform erp.authorise('inventory.scan', null, t.site_id, null, 'warehouse_task', t.id);
  else
    perform erp.authorise('inventory.move', null, t.site_id, null, 'warehouse_task', t.id);
  end if;$n$),
    jsonb_build_array('erp.commit_allocation(uuid,uuid,uuid)',
      $n$  perform erp.authorise('sales.despatch', al.entity_id, al.site_id, null,
                        'allocation', p_allocation_id);$n$,
      $n$  -- A pick confirmed on the scanner (20260915011000).
  if erp.scan_confirms('sales.despatch', array['pick'], al.entity_id, al.site_id) then
    perform erp.authorise('inventory.scan', al.entity_id, al.site_id, null,
                          'allocation', p_allocation_id);
  else
    perform erp.authorise('sales.despatch', al.entity_id, al.site_id, null,
                          'allocation', p_allocation_id);
  end if;$n$),
    jsonb_build_array('erp.receive_against(uuid,uuid,numeric,uuid)',
      $n$  perform erp.authorise('procurement.receive', rd.entity_id, rd.site_id, null,
                        'document', p_receipt_id);$n$,
      $n$  -- A receipt line confirmed on the scanner (20260915011000).
  if erp.scan_confirms('procurement.receive', array['receipt'], rd.entity_id, rd.site_id) then
    perform erp.authorise('inventory.scan', rd.entity_id, rd.site_id, null,
                          'document', p_receipt_id);
  else
    perform erp.authorise('procurement.receive', rd.entity_id, rd.site_id, null,
                          'document', p_receipt_id);
  end if;$n$));
  v_item jsonb;
  v_sig  text;
  v_def  text;
  v_n    text;
begin
  for v_item in select * from jsonb_array_elements(v_list) loop
    v_sig := v_item ->> 0;
    v_n := v_item ->> 1;
    v_def := pg_get_functiondef(v_sig::regprocedure);
    if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not authorise the way this migration patches', v_sig
        using hint = 'Read the live body and write the needle against it.';
    end if;
    execute replace(v_def, v_n, v_item ->> 2);
  end loop;
end
$confirm$;

-- ── The role template ────────────────────────────────────────────────────────

insert into erp_ref.pack_item (pack_code, object_kind, object_key, payload, provenance, seq)
values ('base', 'role', 'scanner_operator',
        jsonb_build_object(
          'code', 'scanner_operator', 'name', 'Scanner operator', 'from_template', 'base-1.0.0',
          'permissions', jsonb_build_array(
            jsonb_build_object('permission', 'inventory.scan'),
            jsonb_build_object('permission', 'inventory.read'),
            jsonb_build_object('permission', 'master_data.read'))),
        'Starter Content Packs §3.2, and the price list of 14 September 2026: somebody who only uses '
        'the scanner is a light user. Confirms the counts, put-aways, replenishments, picks and '
        'receipts somebody else planned; moves nothing on its own authority (20260915011000).',
        105)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- The acceptance suite counts what the base pack plans on a new organisation,
-- on purpose: the Scanner operator template is one item more.
do $acceptance$
declare
  v_sig text := 'erp_test.starter_pack_acceptance_suite()';
  v_def text := pg_get_functiondef('erp_test.starter_pack_acceptance_suite()'::regprocedure);
  v_n   text := $n$    (res ->> 'items')::integer = 346
$n$;
  v_r   text := $r$    -- 347 since 20260915011000: the base pack carries the Scanner operator
    -- role template, which a new organisation does not have yet.
    (res ->> 'items')::integer = 347
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_ACCEPTANCE_SUITE_UNRECOGNISED: % does not count 346 planned items once', v_sig
      using hint = 'A later migration recounted the base pack. Read the suite and patch its count.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('integer = 347' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_ACCEPTANCE_SUITE_UNRECOGNISED: % did not take its new count', v_sig
      using hint = 'The replacement did not land. Compare the needle with the suite''s definition.';
  end if;
end
$acceptance$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A contract sets its full users limit
-- ═════════════════════════════════════════════════════════════════════════════

do $contract$
declare
  v_sig    constant text := 'erp.create_contract_from_quote(uuid,text,text,text,date,integer,text,integer,text,text,jsonb,jsonb,date,integer)';
  v_def    text := pg_get_functiondef('erp.create_contract_from_quote(uuid,text,text,text,date,integer,text,integer,text,text,jsonb,jsonb,date,integer)'::regprocedure);
  v_needle constant text := $n$    elsif l ->> 'kind' = 'light_user' then$n$;
  v_new    constant text := $n$    elsif l ->> 'kind' = 'plan_tier'
          and not exists (select 1 from jsonb_array_elements(m -> 'lines') b
                           where b ->> 'entitlement_code' = 'users') then
      -- The full users sold: what the plan includes and every extra full
      -- user on the quote. A users band, where one is sold, sets the limit
      -- instead (20260915011000).
      insert into erp_meta.contract_entitlement (contract_id, entitlement_code, limit_value, effective_from)
      select v_id, 'users',
             pi.included_users
               + coalesce((select sum((f ->> 'quantity')::numeric)
                             from jsonb_array_elements(m -> 'lines') f
                            where f ->> 'kind' = 'full_user'), 0),
             p_commencement
        from erp.price_item pi
        join erp.item i on i.tenant_id = pi.tenant_id and i.id = pi.item_id
       where pi.tenant_id = v_platform and i.code = l ->> 'item_code'
         and pi.included_users is not null;
    elsif l ->> 'kind' = 'light_user' then$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not turn a light user line into a contract row exactly once', v_sig
      using hint = 'Read the live body and write the needle against it.';
  end if;
  execute replace(v_def, v_needle, v_new);
end
$contract$;

create or replace function erp.provision_sold_seats(p_contract_id uuid default null)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_users integer;
  v_light integer;
begin
  -- Full users: the plan tier's included users and the extra full users, on a
  -- contract in force whose quote sold no users band and that has no users
  -- limit yet.
  insert into erp_meta.contract_entitlement (contract_id, entitlement_code, limit_value, effective_from)
  select c.id, 'users', pt.included_users + coalesce(fu.quantity, 0), c.commencement
    from erp_meta.contract c
    cross join lateral (
      select pi.included_users
        from erp.document_line l
        join erp.price_item pi on pi.tenant_id = l.tenant_id and pi.item_id = l.item_id
       where l.tenant_id = c.platform_tenant_id and l.document_id = c.quote_document_id
         and not l.is_cancelled and pi.kind = 'plan_tier' and pi.included_users is not null
       limit 1) pt
    cross join lateral (
      select sum(l.quantity) as quantity
        from erp.document_line l
        join erp.price_item pi on pi.tenant_id = l.tenant_id and pi.item_id = l.item_id
       where l.tenant_id = c.platform_tenant_id and l.document_id = c.quote_document_id
         and not l.is_cancelled and pi.kind = 'full_user') fu
   where c.status in ('active', 'terminating')
     and (p_contract_id is null or c.id = p_contract_id)
     and not exists (select 1 from erp_meta.contract_entitlement ce
                      where ce.contract_id = c.id and ce.entitlement_code = 'users')
     and not exists (select 1
                       from erp.document_line l
                       join erp.price_item pi on pi.tenant_id = l.tenant_id and pi.item_id = l.item_id
                      where l.tenant_id = c.platform_tenant_id and l.document_id = c.quote_document_id
                        and not l.is_cancelled and pi.entitlement_code = 'users');
  get diagnostics v_users = row_count;

  -- Light users, as 20260914095000 gave them.
  insert into erp_meta.contract_entitlement (contract_id, entitlement_code, limit_value, effective_from)
  select c.id, 'light_users', sum(l.quantity), c.commencement
    from erp_meta.contract c
    join erp.document_line l
      on l.tenant_id = c.platform_tenant_id and l.document_id = c.quote_document_id and not l.is_cancelled
    join erp.price_item pi
      on pi.tenant_id = l.tenant_id and pi.item_id = l.item_id
     and pi.kind = 'light_user' and pi.entitlement_code is null
   where c.status in ('active', 'terminating')
     and (p_contract_id is null or c.id = p_contract_id)
     and not exists (select 1 from erp_meta.contract_entitlement ce
                      where ce.contract_id = c.id and ce.entitlement_code = 'light_users')
   group by c.id, c.commencement;
  get diagnostics v_light = row_count;

  return v_users + v_light;
end;
$$;

comment on function erp.provision_sold_seats(uuid) is
  'Gives a contract in force the users and light users limits its quote sold, '
  'where it has none: included plus extra full users, and the light users '
  'line. Adds nothing where a limit is already there. One contract, or all.';

revoke all on function erp.provision_sold_seats(uuid) from public, anon, authenticated;

select erp.provision_sold_seats();

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A quote's users check counts full users only
-- ═════════════════════════════════════════════════════════════════════════════

do $quote$
declare
  v_sig    constant text := 'erp.add_quote_line(uuid,text,numeric,numeric)';
  v_def    text := pg_get_functiondef('erp.add_quote_line(uuid,text,numeric,numeric)'::regprocedure);
  v_needle constant text := $n$      select pe.limit_value into v_limit from erp_meta.plan_entitlement pe
       where pe.plan_code = v_plan and pe.entitlement_code = 'users';
      if v_limit is not null
         and not exists (select 1 from erp.document_line l
                          join erp.price_item x on x.tenant_id = l.tenant_id and x.item_id = l.item_id
                         where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
                           and x.entitlement_code = 'users')
         and coalesce((select x.included_users from erp.document_line l
                         join erp.price_item x on x.tenant_id = l.tenant_id and x.item_id = l.item_id
                        where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
                          and x.kind = 'plan_tier' limit 1), 0)
             + coalesce((select sum(l.quantity) from erp.document_line l
                           join erp.price_item x on x.tenant_id = l.tenant_id and x.item_id = l.item_id
                          where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
                            and x.kind in ('full_user', 'light_user')), 0)
             + greatest(p_quantity, 1) > v_limit then
        raise exception 'CLOVEERP_QUOTE_USERS_BEYOND_PLAN: the % plan allows % users, and this line would take the quote past it',
          v_plan, v_limit using errcode = '23514';
      end if;$n$;
  v_new    constant text := $n$      -- Full users and light users are limited apart (20260915011000). The
      -- plan's users limit counts the users it includes and the extra full
      -- users; light users are limited only where the plan states a light
      -- users limit, and no plan on the list does.
      select pe.limit_value into v_limit from erp_meta.plan_entitlement pe
       where pe.plan_code = v_plan
         and pe.entitlement_code = case pi.kind when 'light_user' then 'light_users' else 'users' end;
      if v_limit is not null
         and not exists (select 1 from erp.document_line l
                          join erp.price_item x on x.tenant_id = l.tenant_id and x.item_id = l.item_id
                         where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
                           and x.entitlement_code = case pi.kind when 'light_user' then 'light_users' else 'users' end)
         and (case when pi.kind = 'full_user'
                   then coalesce((select x.included_users from erp.document_line l
                                    join erp.price_item x on x.tenant_id = l.tenant_id and x.item_id = l.item_id
                                   where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
                                     and x.kind = 'plan_tier' limit 1), 0)
                   else 0 end)
             + coalesce((select sum(l.quantity) from erp.document_line l
                           join erp.price_item x on x.tenant_id = l.tenant_id and x.item_id = l.item_id
                          where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
                            and x.kind = pi.kind), 0)
             + greatest(p_quantity, 1) > v_limit then
        raise exception 'CLOVEERP_QUOTE_USERS_BEYOND_PLAN: the % plan allows % %s, and this line would take the quote past it',
          v_plan, v_limit, replace(pi.kind, '_', ' ') using errcode = '23514';
      end if;$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not check users against the plan the way 20260914077000 wrote it', v_sig
      using hint = 'Read the live body and write the needle against it.';
  end if;
  execute replace(v_def, v_needle, v_new);
end
$quote$;

select erp.register_refusal('CLOVEERP_QUOTE_USERS_BEYOND_PLAN',
  'Adding more full users to a quote than its plan allows.',
  'Every plan has a most full users figure. It counts the users the plan includes and the extra full users on the quote. Light users are not counted against it.',
  'Quote fewer full users, choose a larger plan, or add a users band that raises the limit.');

-- The suite that proved the old rule with a light line proves the refusal with
-- a full line, on a quote of its own.
do $selling_suite$
declare
  v_sig    constant text := 'erp_test.selling_setup_suite()';
  v_def    text := pg_get_functiondef('erp_test.selling_setup_suite()'::regprocedure);
  v_needle constant text := $n$  begin
    perform erp.add_quote_line(v_q, 'LIGHT-STANDARD', 6);
    v_ok := false; v_msg := '15 included, 80 full and 6 light went past the plan''s 100';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_QUOTE_USERS_BEYOND_PLAN%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a quote refuses users beyond what its plan allows', v_ok, v_msg;

  perform erp.add_quote_line(v_q, 'LIGHT-STANDARD', 5);$n$;
  v_new    constant text := $n$  -- Light users are not counted against the plan's users (20260915011000),
  -- so the refusal is proven with full users, on a quote of its own.
  declare
    v_q_full uuid;
  begin
    v_q_full := erp.open_commercial_quote('BETA', 'Beta Group', 'CLOVE-LIST', 'annual', 12, 'GBP', 30);
    perform erp.add_quote_line(v_q_full, 'PLAN-STANDARD');
    perform erp.add_quote_line(v_q_full, 'USER-STANDARD', 86);
    v_ok := false; v_msg := '15 included and 86 extra full users went past the plan''s 100';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_QUOTE_USERS_BEYOND_PLAN%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a quote refuses users beyond what its plan allows', v_ok, v_msg;

  perform erp.add_quote_line(v_q, 'LIGHT-STANDARD', 5);$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not prove the users limit with a light line exactly once', v_sig
      using hint = 'Read the live body and write the needle against it.';
  end if;
  execute replace(v_def, v_needle, v_new);
end
$selling_suite$;

-- The light users suite's contract sold 2 extra full users on Standard.
do $light_suite$
declare
  v_sig    constant text := 'erp_test.light_users_suite()';
  v_def    text := pg_get_functiondef('erp_test.light_users_suite()'::regprocedure);
  v_needle constant text := $n$             and res_limits -> 'full' ->> 'limit_from' = 'plan'
             and (res_limits -> 'full' ->> 'limit')::numeric is not distinct from v_plan_users, false),$n$;
  v_new    constant text := $n$             -- The contract sets the full users limit: 15 included and 2 extra
             -- (20260915011000).
             and res_limits -> 'full' ->> 'limit_from' = 'contract'
             and (res_limits -> 'full' ->> 'limit')::numeric = 17, false),$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not expect the plan''s users limit exactly once', v_sig
      using hint = 'Read the live body and write the needle against it.';
  end if;
  execute replace(v_def, v_needle, v_new);
end
$light_suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.billing_matches_the_list_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 6);
  rs record; rp record; rc record;
  -- The scanner organisation.
  a1 uuid := gen_random_uuid();      -- administrator
  a2 uuid := gen_random_uuid();      -- second administrator
  s_scan uuid := gen_random_uuid();  -- holds the Scanner operator role and nothing else
  s_none uuid := gen_random_uuid();  -- holds nothing
  u_second uuid; u_scan uuid; u_none uuid; t_tok text; res jsonb;
  csf uuid; csp uuid; css uuid; csi uuid;
  v_s uuid; v_uom uuid; v_site uuid; v_recv uuid; v_bulk uuid; v_sup uuid; v_item uuid;
  v_grn uuid; v_wtask uuid; v_ctask uuid;
  k_count uuid; k_put uuid; k_move uuid;
  v_template text[]; v_role_perms text[]; v_seat text; v_drain jsonb;
  v_door_none text; v_record_none text; v_drain_none text; v_desk_scan text;
  -- The commercial organisations.
  ow uuid := gen_random_uuid(); pa uuid := gen_random_uuid();
  v_p uuid; v_c uuid; v_prior erp_meta.platform_organisation;
  v_q1 uuid; v_q2 uuid; v_contract uuid;
  v_users numeric; v_users_rows integer; v_refill integer; v_refill_again integer; v_seats jsonb;
  v_light_ok text; v_full_refused text; v_full_at_limit text;
  ok_catalogue boolean; ok_role boolean; ok_confirm boolean; ok_gates boolean; d_move text;
  v_step text := 'provisioning';
  v_msg text;
begin
  select po.* into v_prior from erp_meta.platform_organisation po;

  begin
    -- ── A warehouse with a count task and a putaway task ──────────────────
    v_step := 'the scanner organisation is provisioned and its modules promoted';
    perform set_config('request.jwt.claims', '', true);
    select * into rs from erp.provision_tenant('zzbls-' || v_tag, 'Billing Scanner',
                                               'admin@zzbls-' || v_tag || '.test', 'Scanner Admin');
    v_s := rs.tenant_id;
    perform set_config('erp.job_tenant_id', '', true);
    insert into auth.users (id, email) values
      (a1, 'admin@zzbls-' || v_tag || '.test'), (a2, 'second@zzbls-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rs.admin_token);
    select i.app_user_id, i.token into u_second, t_tok
      from erp.invite_principal('second@zzbls-' || v_tag || '.test', 'Second Admin') i;
    perform erp.grant_role(u_second, 'administrator', null, null, 'co-administrator');
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    css := erp.configure_sales(15);
    csi := erp.configure_inventory('average');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(t_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(css); perform erp.promote_change_set(css);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'a site, two locations, a supplier and a product';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (v_s, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (v_s, rs.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (v_s, v_site, 'RECV', 'Receiving', 'receiving', 'active') returning id into v_recv;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (v_s, v_site, 'BULK-01', 'Bulk 01', 'bulk', 'active') returning id into v_bulk;
    insert into erp.party (tenant_id, code, name, status)
    values (v_s, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_s, 'WID', 'Widget', v_uom, 'active') returning id into v_item;

    v_step := 'a hundred received, a putaway task and a count task raised by the administrator';
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_item, 100, 1000, 'the stock');
    perform erp.transition_document(v_grn, 'post');
    perform erp.raise_putaway_tasks(v_site);
    select t.id into v_wtask from erp.warehouse_task t
     where t.tenant_id = v_s and t.kind = 'putaway' and t.status = 'open';
    perform erp.raise_count_tasks('cycle_a');
    select t.id into v_ctask from erp.count_task t
     where t.tenant_id = v_s and t.location_id = v_recv and t.status = 'open';
    perform erp.register_device('HH-01', 'MAIN', 'Handheld 1', 'handheld');

    v_step := 'the Scanner operator role, as the base pack writes it';
    select array(select e.value ->> 'permission'
                   from erp_ref.pack_item pi, jsonb_array_elements(pi.payload -> 'permissions') e
                  where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = 'scanner_operator'
                  order by 1)
      into v_template;
    perform erp_test.reopen_bootstrap_window(v_s);
    insert into erp.role (tenant_id, code, name, from_template, status)
    values (v_s, 'scanner_operator', 'Scanner operator', 'base-1.0.0', 'active');
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select v_s, ro.id, x.perm
      from unnest(v_template) as x(perm)
      join erp.role ro on ro.tenant_id = v_s and ro.code = 'scanner_operator';
    perform erp_test.close_bootstrap_window(v_s);

    v_step := 'a scanner operator and somebody with no role join';
    select i.app_user_id, i.token into u_scan, t_tok
      from erp.invite_principal('scanner@zzbls-' || v_tag || '.test', 'Sam Scanner') i;
    perform erp.grant_role(u_scan, 'scanner_operator', null, null, 'uses the scanner');
    perform set_config('request.jwt.claims', json_build_object('sub', s_scan)::text, true);
    perform erp.claim_invitation(t_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select i.app_user_id, i.token into u_none, t_tok
      from erp.invite_principal('none@zzbls-' || v_tag || '.test', 'Nora Nothing') i;
    perform set_config('request.jwt.claims', json_build_object('sub', s_none)::text, true);
    perform erp.claim_invitation(t_tok);
    v_seat := erp.person_seat(u_scan);
    select array(select ep.permission_code from erp.effective_permission ep
                  where ep.tenant_id = v_s and ep.app_user_id = u_scan order by 1)
      into v_role_perms;

    v_step := 'the scanner operator counts and puts away on the scanner, and tries a move';
    perform set_config('request.jwt.claims', json_build_object('sub', s_scan)::text, true);
    perform erp.open_device_session('HH-01');
    k_count := (erp.record_device_action('HH-01', 'count', 'zz-count',
                  jsonb_build_object('task_id', v_ctask, 'quantity', 100),
                  'scanned', null, now() - interval '3 minutes') ->> 'action_id')::uuid;
    k_put := (erp.record_device_action('HH-01', 'putaway', 'zz-put',
                jsonb_build_object('task_id', v_wtask, 'quantity', 100),
                'scanned', null, now() - interval '2 minutes') ->> 'action_id')::uuid;
    k_move := (erp.record_device_action('HH-01', 'internal_move', 'zz-move',
                 jsonb_build_object('container_id', gen_random_uuid(), 'to_location_id', v_bulk),
                 'scanned', null, now() - interval '1 minute') ->> 'action_id')::uuid;
    v_drain := erp.drain_device_actions('HH-01');
    begin
      perform erp.complete_warehouse_task(v_wtask, 1);
      v_desk_scan := 'the scanner operator completed a warehouse task from the desk';
    exception when others then
      v_desk_scan := left(sqlerrm, 100);
    end;
    perform erp.close_device_session('end of shift');

    v_step := 'somebody with neither permission tries the scanner';
    perform set_config('request.jwt.claims', json_build_object('sub', s_none)::text, true);
    begin
      perform erp.open_device_session('HH-01');
      v_door_none := 'opened a session';
    exception when others then
      v_door_none := left(sqlerrm, 100);
    end;
    begin
      perform erp.record_device_action('HH-01', 'count', 'zz-none',
                                       jsonb_build_object('task_id', v_ctask, 'quantity', 1));
      v_record_none := 'queued an action';
    exception when others then
      v_record_none := left(sqlerrm, 100);
    end;
    begin
      perform erp.drain_device_actions('HH-01');
      v_drain_none := 'drained the queue';
    exception when others then
      v_drain_none := left(sqlerrm, 100);
    end;

    -- ── What a quote sells, and what a contract provisions ────────────────
    v_step := 'the platform and a customer are provisioned, and selling is set up';
    perform set_config('request.jwt.claims', '', true);
    select * into rp from erp.provision_tenant('zzblp-' || v_tag, 'Billing Platform',
                                               'admin@zzblp-' || v_tag || '.test', 'Platform Admin');
    v_p := rp.tenant_id;
    select * into rc from erp.provision_tenant('zzblc-' || v_tag, 'Billing Customer',
                                               'admin@zzblc-' || v_tag || '.test', 'Customer Admin');
    v_c := rc.tenant_id;
    perform set_config('erp.job_tenant_id', '', true);
    insert into auth.users (id, email) values
      (ow, 'owner@zzblp-' || v_tag || '.test'), (pa, 'admin@zzblp-' || v_tag || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('owner@zzblp-' || v_tag || '.test', ow, 'Platform Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', pa)::text, true);
    perform erp.claim_invitation(rp.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    perform erp.designate_platform_organisation('zzblp-' || v_tag, 'the billing matches the list suite');
    perform set_config('request.jwt.claims', json_build_object('sub', pa)::text, true);
    perform erp_test.reopen_bootstrap_window(v_p);
    perform erp.set_up_selling();
    perform erp_test.close_bootstrap_window(v_p);

    v_step := 'a Starter quote takes thirty light users, and full users only up to the plan';
    v_q2 := erp.open_commercial_quote('GAMMA', 'Gamma Bakery', 'CLOVE-LIST', 'annual', 12, 'GBP', 30);
    perform erp.add_quote_line(v_q2, 'PLAN-STARTER');
    begin
      perform erp.add_quote_line(v_q2, 'LIGHT-STARTER', 30);
      v_light_ok := 'added';
    exception when others then
      v_light_ok := left(sqlerrm, 100);
    end;
    begin
      perform erp.add_quote_line(v_q2, 'USER-STARTER', 6);
      v_full_refused := 'added';
    exception when others then
      v_full_refused := left(sqlerrm, 100);
    end;
    begin
      perform erp.add_quote_line(v_q2, 'USER-STARTER', 5);
      v_full_at_limit := 'added';
    exception when others then
      v_full_at_limit := left(sqlerrm, 100);
    end;

    v_step := 'a Standard quote with five extra full users becomes a contract';
    v_q1 := erp.open_commercial_quote('BILL', 'Billing Customer Ltd', 'CLOVE-LIST', 'annual', 12, 'GBP', 30,
                                      'zzblc-' || v_tag);
    perform erp.add_quote_line(v_q1, 'PLAN-STANDARD');
    perform erp.add_quote_line(v_q1, 'USER-STANDARD', 5);
    perform erp.submit_quote(v_q1);
    perform erp.issue_quote(v_q1);
    perform erp.quote_transition(v_q1, 'accept', 'order form returned signed');
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    v_contract := erp.create_contract_from_quote(v_q1, 'zzblc-' || v_tag, 'Billing Customer Ltd', 'Clove ERP Ltd',
                                                 current_date, 12, 'automatic', 90, 'England and Wales', 'annual');
    perform erp.sign_contract(v_contract, 'A. Customer, director', 'Platform Owner, director',
                              'agreement to the order form');
    select ce.limit_value into v_users
      from erp_meta.contract_entitlement ce
     where ce.contract_id = v_contract and ce.entitlement_code = 'users';
    v_seats := public.erp_platform_seats(v_c);

    v_step := 'a contract made before its full users were provisioned is given them once';
    delete from erp_meta.contract_entitlement ce
     where ce.contract_id = v_contract and ce.entitlement_code = 'users';
    v_refill := erp.provision_sold_seats(v_contract);
    v_refill_again := erp.provision_sold_seats(v_contract);
    select count(*) into v_users_rows
      from erp_meta.contract_entitlement ce
     where ce.contract_id = v_contract and ce.entitlement_code = 'users' and ce.limit_value = 20;

    -- ── The verdicts, read before the block is undone ─────────────────────
    v_step := 'reading the verdicts';
    ok_catalogue := (select p.seat from erp_ref.permission p where p.code = 'inventory.scan') = 'light'
      and exists (select 1 from erp_ref.resource r where r.key = 'permission.inventory.scan' and r.locale = 'en')
      and exists (select 1 from erp_ref.resource r where r.key = 'permission.inventory.scan' and r.locale = 'de');
    ok_role := v_template = array['inventory.read', 'inventory.scan', 'master_data.read']
      and v_role_perms = v_template and v_seat = 'light';
    ok_confirm := (select a.status from erp.device_action a where a.id = k_count) = 'applied'
      and (select a.status from erp.device_action a where a.id = k_put) = 'applied'
      and (select t.counted_by from erp.count_task t where t.id = v_ctask) = u_scan
      and (select t.status from erp.warehouse_task t where t.id = v_wtask) = 'done'
      and (select t.completed_by from erp.warehouse_task t where t.id = v_wtask) = u_scan;
    d_move := (select a.status || ': ' || coalesce(a.conflict_reason, 'no reason')
                 from erp.device_action a where a.id = k_move);
    ok_gates := position('erp.scan_confirms(''sales.despatch'', array[''pick'']' in
                         pg_catalog.pg_get_functiondef('erp.commit_allocation(uuid,uuid,uuid)'::regprocedure)) > 0
      and position('erp.scan_confirms(''procurement.receive'', array[''receipt'']' in
                   pg_catalog.pg_get_functiondef('erp.receive_against(uuid,uuid,numeric,uuid)'::regprocedure)) > 0;

    -- Nothing this suite built is kept: not the organisations, not the
    -- designation it borrowed, and not an email an issued quote queued.
    raise exception 'zz_billing_suite_undone';
  exception when others then
    if sqlerrm <> 'zz_billing_suite_undone' then
      v_msg := format('%s: %s', v_step, left(sqlerrm, 200));
    end if;
  end;

  -- ── The verdicts ─────────────────────────────────────────────────────────

  return query select 'inventory.scan is a light permission in the catalogue, with English and German words',
    coalesce(v_msg is null and ok_catalogue, false),
    coalesce(v_msg, 'light, en and de');

  return query select 'the base pack''s Scanner operator holds the scanner and the reads, and its holder is a light user',
    coalesce(v_msg is null and ok_role, false),
    coalesce(v_msg, format('template %s; holds %s; seat %s', v_template, v_role_perms, v_seat));

  return query select 'a scanner operator counts and puts away through the device doors',
    coalesce(v_msg is null and ok_confirm, false),
    coalesce(v_msg, v_drain::text);

  return query select 'a move no task planned is not applied for a scanner operator',
    coalesce(v_msg is null
             and d_move like 'conflicted: a scanner confirms counts%internal_move is applied by somebody who may move stock', false),
    coalesce(v_msg, d_move, 'no action');

  return query select 'the scan permission confirms nothing from the desk',
    coalesce(v_msg is null and v_desk_scan like '%PERMISSION_DENIED: inventory.move%', false),
    coalesce(v_msg, v_desk_scan);

  return query select 'somebody with neither permission is refused by every scanner door',
    coalesce(v_msg is null
             and v_door_none like '%PERMISSION_DENIED: inventory.move%'
             and v_record_none like '%PERMISSION_DENIED: inventory.move%'
             and v_drain_none like '%PERMISSION_DENIED: inventory.move%', false),
    coalesce(v_msg, format('open: %s; record: %s; drain: %s', v_door_none, v_record_none, v_drain_none));

  return query select 'the pick and receipt confirmations take the scan permission only from the drain',
    coalesce(v_msg is null and ok_gates and not erp.scan_confirms('sales.despatch', array['pick']), false),
    coalesce(v_msg, 'both gates ask erp.scan_confirms, which is false outside the drain');

  return query select 'a Starter quote takes thirty light users with no extra full users',
    coalesce(v_msg is null and v_light_ok = 'added', false),
    coalesce(v_msg, v_light_ok);

  return query select 'one full user beyond the plan is still refused, and up to it is not',
    coalesce(v_msg is null
             and v_full_refused like 'CLOVEERP_QUOTE_USERS_BEYOND_PLAN%'
             and v_full_at_limit = 'added', false),
    coalesce(v_msg, format('six: %s; five: %s', v_full_refused, v_full_at_limit));

  return query select 'a contract from Standard with five extra full users has a users limit of 15 + 5, and the console shows it',
    coalesce(v_msg is null
             and v_users = 20
             and (v_seats -> 'full' ->> 'limit')::numeric = 20
             and v_seats -> 'full' ->> 'limit_from' = 'contract', false),
    coalesce(v_msg, format('users row %s; console %s', coalesce(v_users::text, 'none'), coalesce(v_seats::text, 'no answer')));

  return query select 'a contract already in force is given its full users once',
    coalesce(v_msg is null and v_refill = 1 and v_refill_again = 0 and v_users_rows = 1, false),
    coalesce(v_msg, format('first %s, second %s, rows %s', v_refill, v_refill_again, v_users_rows));

  perform set_config('request.jwt.claims', '', true);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant tn where tn.id in (v_s, v_p, v_c))
    and not exists (select 1 from erp.tenant tn where tn.code like 'zzbl_-' || v_tag)
    and not exists (select 1 from erp_meta.contract c where c.tenant_code = 'zzblc-' || v_tag)
    and not exists (select 1 from erp_meta.platform_staff ps where ps.email = 'owner@zzblp-' || v_tag || '.test')
    and not exists (select 1 from auth.users u where u.id in (a1, a2, ow, pa))
    and (v_prior.tenant_id is null
         or exists (select 1 from erp_meta.platform_organisation po where po.tenant_id = v_prior.tenant_id)),
    'everything the suite built was undone with its block, the designation included';
end;
$$;

comment on function erp_test.billing_matches_the_list_suite() is
  'A scanner operator is light and confirms counts and put-aways on the scanner, '
  'and nothing else; the scanner doors refuse somebody with neither permission; '
  'a Starter quote takes thirty light users; a contract provisions included '
  'plus extra full users, and contracts in force are given them once. Builds '
  'its zzbl organisations inside a block it rolls back.';

create or replace function erp_test.assert_billing_matches_the_list_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 12;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from erp_test.billing_matches_the_list_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_BILLING_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost.',
            hint = 'Update the expected count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_BILLING_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail
      using hint = 'Read the failing cases above; each names what it found.';
  end if;
  return format('billing matches the list: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.billing_matches_the_list_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_billing_matches_the_list_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_authorise_codes_exist();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_device_task_handlers_sound();
select erp.assert_every_permission_has_a_seat();
select erp_test.assert_billing_matches_the_list_suite();
