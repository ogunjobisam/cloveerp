set lock_timeout = '30s';

-- =============================================================================
-- 20261007131000  A count can be raised for one place or product
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-86). Stock audit's
-- "Raise count tasks" asked for a counting programme and nothing else, and
-- public.erp_raise_count_tasks(text) raised a task for every balance the
-- programme's selector matched: in the demonstration, cycle_a raised 24
-- tasks across two sites. Nobody could count one bin or one product.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.open_count_tasks(text, uuid, uuid): what erp.raise_count_tasks(text)
--      did, the same checks, gate and lock, with the balances narrowed to one
--      location and to one product when either is given, answering how many
--      it raised and the sheets they are on. It does not issue the sheets.
--   B. erp.raise_count_tasks(text), same signature, for the whole programme as
--      every scheduled and suite caller asks: it opens the tasks through A and
--      issues each sheet, as it did. It keeps its name and signature because
--      erp.transition_driver_register() names it as what issues a count sheet,
--      and erp_ref.part5_capability lists it.
--   C. erp.raise_count_tasks(text, uuid, uuid), not defaulted so the
--      one-argument form stays the programme's own: the same for one place
--      or product.
--   D. public.erp_raise_count_tasks(p_programme_code text, p_location_id uuid
--      default null, p_item_id uuid default null) replaces the one-argument
--      door. The same name, gate (erp.raise_count_tasks, inventory.count at
--      the programme's site) and grants. Called with the programme alone, as
--      the published screen calls it, it raises what it always did.
--   E. The two hints the form's new pickers say, in English and German.
--   F. erp_test.count_raised_for_one_place_suite: one product, one place, a
--      place and a product that do not meet, the whole programme by its code
--      alone, and somebody who may not count, refused.
--
-- The screen's half (optional Location and Product pickers on Raise count
-- tasks) is in src/routes/inventory/audit.tsx.
--
-- On production: two routines are added, one is rewritten as a call to them,
-- and one door is replaced by one of the same name taking two optional
-- arguments. No table is altered and no row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- The bodies this expects
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  v_sig  constant text := 'erp.raise_count_tasks(text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_door text := (select p.prosrc from pg_catalog.pg_proc p
                   where p.oid = pg_catalog.to_regprocedure('public.erp_raise_count_tasks(text)'));
begin
  if strpos(v_src, '20261007131000') > 0 then
    raise notice '% already opens its tasks through erp.open_count_tasks; replaced with the same bodies', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd6196f657d01ae7302b7c9400ac73fb4' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007131000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if v_door is null or md5(v_door) <> 'b1ee52109a608a509b6dad3a87e71463' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: public.erp_raise_count_tasks(text) is not the door 20261007131000 expects (md5 %)',
      coalesce(md5(v_door), 'none');
  end if;
end
$guard$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Opening the tasks, narrowed when asked
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.open_count_tasks(p_programme_code text, p_location_id uuid, p_item_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $function$
-- What erp.raise_count_tasks(text) did until 20261007131000, less the issuing
-- of the sheets, and narrowed to one place or one product when either is
-- given (J-86). The raise that calls this issues the sheets it names.
declare
  v_tenant uuid := erp.require_tenant_id();
  pg       erp.count_programme%rowtype;
  r        record;
  v_task   uuid;
  v_n      integer := 0;
  v_committed numeric;
  v_lifecycle boolean;
  v_sheet_type text;
  v_sheet_dt   uuid;
  v_sheets     jsonb := '{}'::jsonb;
  v_sheet      uuid;
  v_line       uuid;
  v_line_nos   jsonb := '{}'::jsonb;
  v_line_no    integer;
begin
  select * into pg from erp.count_programme
   where tenant_id = v_tenant and code = p_programme_code and status = 'active';
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_COUNT_PROGRAMME: %', p_programme_code
      using errcode = '23503';
  end if;

  perform erp.authorise('inventory.count', null, pg.site_id, null,
                        'count_programme', pg.id);

  v_lifecycle := exists (select 1 from erp.state_machine sm
                          where sm.tenant_id = v_tenant and sm.object_type = 'count_task');

  -- Decided once, before a task is raised (found on review: the refusal came
  -- at the first task, and took every programme's scheduled run with it).
  if v_lifecycle and not exists (
       select 1 from erp.state_machine sm
         join erp.state_machine_version smv
           on smv.tenant_id = sm.tenant_id and smv.state_machine_id = sm.id
          and smv.status = 'active'
          and daterange(smv.effective_from, smv.effective_to, '[)') @> current_date
        where sm.tenant_id = v_tenant and sm.object_type = 'count_task' and sm.status = 'active') then
    raise exception 'CLOVEERP_COUNT_LIFECYCLE_NOT_IN_FORCE: the organisation''s count task lifecycle is not in force today, so programme % raises no count',
      pg.code
      using errcode = '23514',
            hint = 'Restore the count task lifecycle on the Configuration screen, or promote a version of it in force today.';
  end if;

  -- The count sheet (20260927100000), where the organisation has a type of
  -- one, decided once for the run like the lifecycle above.
  select dt.code, dt.id into v_sheet_type, v_sheet_dt
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.base_type_code = 'count' and dt.status = 'active'
   order by (dt.site_id is not null), dt.code
   limit 1;

  if v_sheet_type is not null and not exists (
       select 1 from erp.document_type dt
         join erp.state_machine sm
           on sm.tenant_id = dt.tenant_id and sm.code = dt.state_machine_code
          and sm.object_type = 'document' and sm.status = 'active'
         join erp.state_machine_version smv
           on smv.tenant_id = sm.tenant_id and smv.state_machine_id = sm.id
          and smv.status = 'active'
          and daterange(smv.effective_from, smv.effective_to, '[)') @> current_date
        where dt.tenant_id = v_tenant and dt.id = v_sheet_dt) then
    raise exception 'CLOVEERP_COUNT_LIFECYCLE_NOT_IN_FORCE: the organisation''s count sheet lifecycle is not in force today, so programme % raises no count',
      pg.code
      using errcode = '23514',
            hint = 'Restore the count sheet lifecycle on the Configuration screen, or promote a version of it in force today.';
  end if;

  for r in
    with pos as (
      -- What the company holds (D9), with the unit each position sits in and
      -- the identity policy for the count step.
      select b.site_id, b.location_id, b.item_id, b.batch_id, b.stock_status, b.owner_party_id,
             b.container_id, b.quantity, i.code as item_code, i.item_class,
             pol.count_method, pol.level_rank as policy_rank, ct.level_rank as container_rank
        from erp.stock_balance b
        join erp.item i on i.id = b.item_id
        left join erp.container c on c.id = b.container_id
        left join erp_ref.container_type ct on ct.code = c.container_type
        cross join lateral erp.identity_policy_for(b.item_id, b.site_id, 'count') pol
       where b.tenant_id = v_tenant
         and (pg.site_id is null or b.site_id = pg.site_id)
         -- One place, or one product, when the raise names it (20261007131000).
         and (p_location_id is null or b.location_id = p_location_id)
         and (p_item_id is null or b.item_id = p_item_id)
         and b.quantity <> 0
         and b.custody_party_id = erp.entity_party_for_site(b.site_id)
    ),
    keyed as (
      -- A unit is one thing to count when the policy counts by container, or
      -- counts hybrid and the unit is at or above the identity level.
      select p.*,
             case when p.container_id is null then null
                  when p.count_method = 'by_container' then p.container_id
                  when p.count_method = 'hybrid' and p.container_rank >= p.policy_rank then p.container_id
             end as counted_container
        from pos p
    ),
    mix as (
      select counted_container,
             count(distinct (item_id, batch_id, stock_status, owner_party_id)) as tuples
        from keyed where counted_container is not null
       group by counted_container
    )
    select k.site_id, k.location_id, k.item_id, k.batch_id, k.stock_status, k.owner_party_id,
           k.counted_container as container_id,
           sum(k.quantity) as quantity, k.item_code, k.item_class,
           (k.counted_container is not null and max(m.tuples) = 1) as counts_container
      from keyed k
      left join mix m on m.counted_container = k.counted_container
     group by k.site_id, k.location_id, k.item_id, k.batch_id, k.stock_status, k.owner_party_id,
              k.counted_container, k.item_code, k.item_class
    having sum(k.quantity) <> 0
  loop
    continue when not erp.jsonlogic_bool(pg.selector, to_jsonb(r));

    continue when exists (
      select 1 from erp.count_task t
       -- Approved and not yet posted is still in flight (20260927000000):
       -- its lock is live, and a second task over it would split what moves.
       -- So is a refused count, which is counted again or cancelled, and was
       -- raised again over (found on review: counted again beside its second,
       -- the place's variance posted twice).
       where t.tenant_id = v_tenant and t.status in ('open','counted','pending_approval','approved','rejected')
         and t.item_id = r.item_id
         and t.location_id is not distinct from r.location_id
         and t.owner_party_id is not distinct from r.owner_party_id
         and t.container_id is not distinct from r.container_id
         -- And the same batch and stock status (20260928100000): two batches,
         -- or quarantined stock beside available, at one place are two
         -- counts. A count held because its status is not known stands in
         -- the way of every status at its place and batch until it is
         -- cancelled.
         and t.batch_id is not distinct from r.batch_id
         and (t.stock_status is null or t.stock_status = r.stock_status));

    select coalesce(sum(al.quantity), 0) into v_committed
      from erp.allocation_line al
      join erp.allocation a on a.id = al.allocation_id
     where al.tenant_id = v_tenant
       and a.item_id = r.item_id
       and al.location_id is not distinct from r.location_id
       -- Of the batch and status counted (20260928100000).
       and al.batch_id is not distinct from r.batch_id
       and al.stock_status = r.stock_status
       and al.status in ('reserved', 'committed', 'picked');

    -- The place goes on its site's sheet, opened for the first place the
    -- raise finds there through the door every document is opened by.
    v_sheet := null;
    v_line := null;
    if v_sheet_type is not null then
      v_sheet := (v_sheets ->> r.site_id::text)::uuid;
      if v_sheet is null then
        v_sheet := erp.open_document(v_sheet_type, null,
                                     (select s.entity_id from erp.site s
                                       where s.tenant_id = v_tenant and s.id = r.site_id),
                                     r.site_id);
        update erp.document
           set our_reference = pg.code, notes = pg.name, updated_at = now()
         where tenant_id = v_tenant and id = v_sheet;
        v_sheets := v_sheets || jsonb_build_object(r.site_id::text, v_sheet);
      end if;

      v_line_no := coalesce((v_line_nos ->> v_sheet::text)::integer, 0) + 10;
      v_line_nos := v_line_nos || jsonb_build_object(v_sheet::text, v_line_no);
      insert into erp.document_line (
        tenant_id, document_id, line_no, item_id, description, quantity, uom_id,
        batch_id, location_id, container_id, unit_price_minor, net_minor,
        stock_status)
      values (
        v_tenant, v_sheet, v_line_no, r.item_id, erp.line_description(r.item_id, null),
        r.quantity, erp.item_line_uom(r.item_id, v_sheet_dt),
        r.batch_id, r.location_id, r.container_id, 0, 0,
        r.stock_status)   -- the status it counts (20260928100000)
      returning id into v_line;
    end if;

    insert into erp.count_task (
      tenant_id, count_programme_id, site_id, location_id, item_id, batch_id,
      expected_quantity, committed_quantity, status,
      owner_party_id, container_id, counts_container,
      document_id, document_line_id, stock_status)
    values (v_tenant, pg.id, r.site_id, r.location_id, r.item_id, r.batch_id,
            r.quantity, v_committed, 'open',
            r.owner_party_id, r.container_id, r.counts_container,
            v_sheet, v_line, r.stock_status)
    returning id into v_task;

    -- The batch and status it covers (20260928100000).
    insert into erp.count_lock (tenant_id, count_task_id, location_id, item_id,
                                batch_id, stock_status)
    values (v_tenant, v_task, r.location_id, r.item_id, r.batch_id, r.stock_status);

    if v_lifecycle then
      perform erp.start_lifecycle('count_task', v_task,
                                  (select s.entity_id from erp.site s where s.id = r.site_id),
                                  r.site_id, p_machine_code => null::text);
    end if;

    v_n := v_n + 1;
  end loop;

  -- How many were raised, and the sheets they are on, still to be issued.
  return jsonb_build_object(
    'raised', v_n,
    'sheets', coalesce((select jsonb_agg(e.value order by e.key) from jsonb_each(v_sheets) e), '[]'::jsonb));
end;
$function$;


revoke all on function erp.open_count_tasks(text, uuid, uuid) from public, anon;

comment on function erp.open_count_tasks(text, uuid, uuid) is
  'Raises the count tasks a counting programme is due, under inventory.count at its site, narrowed to one location '
  'and one product when given (20261007131000, J-86): each on its site''s count sheet, locked and started on its '
  'lifecycle. Answers {raised, sheets}; the sheets are left for the caller to issue, as erp.raise_count_tasks does.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The whole programme, as every caller asks
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.raise_count_tasks(p_programme_code text)
returns integer
language plpgsql
set search_path = ''
as $function$
declare
  v_opened jsonb;
  v_sheet  uuid;
begin
  -- Every place the programme is due, opened through erp.open_count_tasks
  -- (20261007131000), then each sheet issued once every place is on it.
  v_opened := erp.open_count_tasks(p_programme_code, null, null);
  for v_sheet in select (e.value #>> '{}')::uuid from jsonb_array_elements(v_opened -> 'sheets') e loop
    perform erp.transition_document(v_sheet, 'issue');
  end loop;
  return (v_opened ->> 'raised')::integer;
end;
$function$;

revoke all on function erp.raise_count_tasks(text) from public, anon;

comment on function erp.raise_count_tasks(text) is
  'Raises the count tasks a counting programme is due and issues their count sheets (20261007131000: through '
  'erp.open_count_tasks). What issues a count sheet, in erp.transition_driver_register().';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. One place, or one product
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.raise_count_tasks(p_programme_code text, p_location_id uuid, p_item_id uuid)
returns integer
language plpgsql
set search_path = ''
as $function$
declare
  v_opened jsonb;
  v_sheet  uuid;
begin
  -- As the one-argument form, narrowed to the place and product given
  -- (20261007131000, J-86). Not defaulted, so a call with the programme alone
  -- is the one-argument form's.
  v_opened := erp.open_count_tasks(p_programme_code, p_location_id, p_item_id);
  for v_sheet in select (e.value #>> '{}')::uuid from jsonb_array_elements(v_opened -> 'sheets') e loop
    perform erp.transition_document(v_sheet, 'issue');
  end loop;
  return (v_opened ->> 'raised')::integer;
end;
$function$;

revoke all on function erp.raise_count_tasks(text, uuid, uuid) from public, anon;

comment on function erp.raise_count_tasks(text, uuid, uuid) is
  'Raises the count tasks a counting programme is due at one location, of one product, or both, and issues their '
  'count sheets (20261007131000, J-86). Either left null counts every place or product the programme covers.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The door
-- ─────────────────────────────────────────────────────────────────────────────

drop function if exists public.erp_raise_count_tasks(text);

create or replace function public.erp_raise_count_tasks(
  p_programme_code text,
  p_location_id uuid default null,
  p_item_id uuid default null)
returns integer
language sql
set search_path = ''
as $function$ select erp.raise_count_tasks(p_programme_code, p_location_id, p_item_id) $function$;

revoke all on function public.erp_raise_count_tasks(text, uuid, uuid) from public, anon;
grant execute on function public.erp_raise_count_tasks(text, uuid, uuid) to authenticated, service_role;

comment on function public.erp_raise_count_tasks(text, uuid, uuid) is
  'Raise count tasks (Stock audit): the tasks a counting programme is due, at one location or of one product when '
  'either is chosen (20261007131000, J-86), each on its site''s count sheet, issued. Authorises inventory.count at the '
  'programme''s site, in erp.open_count_tasks.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.en), v.locale, v.value,
       'A screen string, rendered through ui(). A count can be raised for one place or product (20261007131000).'
  from (values
    ('Leave unchosen to count every place the programme covers.', 'en',
     'Leave unchosen to count every place the programme covers.'),
    ('Leave unchosen to count every place the programme covers.', 'de',
     'Leer lassen, um jeden Platz zu zählen, den das Programm umfasst.'),
    ('Leave unchosen to count every product the programme covers.', 'en',
     'Leave unchosen to count every product the programme covers.'),
    ('Leave unchosen to count every product the programme covers.', 'de',
     'Leer lassen, um jedes Produkt zu zählen, das das Programm umfasst.')
  ) as v(en, locale, value)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.count_raised_for_one_place_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  a3       uuid := gen_random_uuid();
  v_owner  text := current_user;
  v_step   text := 'provisioning';
  v_state  text;
  r        record;
  res      jsonb;
  v_tok    text; v_tok3 text;
  v_second uuid; v_reader uuid; v_role uuid;
  csf uuid; csp uuid; csi uuid;
  v_uom uuid; v_main uuid; v_north uuid; v_recv uuid; v_recv_n uuid; v_sup uuid; v_grn uuid;
  i_a uuid; i_b uuid;
  v_n integer; v_tasks integer; v_sheets integer; v_sheets0 integer;
  v_where text;
  v_err text;
begin
  -- 1. The door, and what issues a count sheet, keep their shape.
  v_cases := v_cases + 1;
  case_name := 'one erp_raise_count_tasks door, taking a programme and an optional place and product, granted to the signed-in only; the programme''s own raise still issues the sheet';
  passed := (select count(*) from pg_catalog.pg_proc p
              where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_raise_count_tasks') = 1
        and exists (select 1 from pg_catalog.pg_proc p
                     where p.oid = pg_catalog.to_regprocedure('public.erp_raise_count_tasks(text,uuid,uuid)')
                       and p.pronargdefaults = 2 and not p.prosecdef and p.provolatile = 'v'
                       and p.prosrc like '%erp.raise_count_tasks(%')
        and has_function_privilege('authenticated', 'public.erp_raise_count_tasks(text,uuid,uuid)', 'execute')
        and not has_function_privilege('anon', 'public.erp_raise_count_tasks(text,uuid,uuid)', 'execute')
        and (select p.pronargdefaults from pg_catalog.pg_proc p
              where p.oid = 'erp.raise_count_tasks(text,uuid,uuid)'::regprocedure) = 0
        and exists (select 1 from jsonb_array_elements(erp.transition_driver_register()) x
                     where x ->> 'machine_code' = 'count_sheet' and x ->> 'transition_code' = 'issue'
                       and x ->> 'detail' = 'erp.raise_count_tasks(text)')
        and strpos((select p.prosrc from pg_catalog.pg_proc p
                     where p.oid = 'erp.raise_count_tasks(text)'::regprocedure), 'transition_document(') > 0;
  detail := (select format('%s door(s): %s', count(*), string_agg(p.oid::regprocedure::text, ', '))
               from pg_catalog.pg_proc p
              where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_raise_count_tasks');
  return next;

  begin
    -- ── The fixture ───────────────────────────────────────────────────────────
    v_step := 'an organisation that counts, not yet live';
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zz-crp-' || v_hex, 'Count raised for one place suite',
      'a@zz-crp-' || v_hex || '.test', 'Suite Admin');
    insert into auth.users (id, email) values (a1, 'a@zz-crp-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-crp-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    v_step := 'installing';
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    insert into auth.users (id, email) values (a2, 'second@zz-crp-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;

    v_step := 'somebody who reads stock and counts nothing';
    insert into erp.role (tenant_id, code, name, status)
    values (r.tenant_id, 'zz_crp_reader', 'Stock reader', 'active') returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code) values
      (r.tenant_id, v_role, 'inventory.read');
    res := public.erp_invite_principal('reader@zz-crp-' || v_hex || '.test', 'Rita Reader');
    v_reader := (res ->> 'app_user_id')::uuid; v_tok3 := res ->> 'token';
    perform erp.grant_role(v_reader, 'zz_crp_reader', null, null, 'reads stock and counts nothing');
    insert into auth.users (id, email) values (a3, 'reader@zz-crp-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(v_tok3);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- A and B in goods in at MAIN, and A in goods in at NORTH.
    v_step := 'the stock';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_main;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'NORTH', 'North', 'warehouse', 'active') returning id into v_north;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_main, 'RECV', 'Goods in', 'receiving', 'active') returning id into v_recv;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_north, 'RECV-N', 'Goods in, north', 'receiving', 'active') returning id into v_recv_n;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'A', 'Stocked at both sites', v_uom, 'active') returning id into i_a;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'B', 'Stocked at MAIN', v_uom, 'active') returning id into i_b;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_main);
    perform erp.add_document_line(v_grn, i_a, 100, 100, 'A');
    perform erp.add_document_line(v_grn, i_b, 100, 100, 'B');
    perform erp.transition_document(v_grn, 'post');
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_north);
    perform erp.add_document_line(v_grn, i_a, 100, 100, 'A');
    perform erp.transition_document(v_grn, 'post');

    -- Every product everywhere, and nobody to approve.
    insert into erp.count_programme (tenant_id, code, name, kind, selector,
                                     tolerance_absolute, tolerance_pct, approval_chain_code, status)
    values (r.tenant_id, 'zz_crp', 'Everything, everywhere', 'cycle', 'true'::jsonb, 2, 0, null, 'active');

    -- 2. One product.
    v_step := 'raising for B alone';
    v_n := public.erp_raise_count_tasks('zz_crp', null, i_b);
    select count(*), string_agg(i.code || '@' || l.code, ', ' order by i.code, l.code) into v_tasks, v_where
      from erp.count_task t
      join erp.item i on i.id = t.item_id
      join erp.location l on l.id = t.location_id
     where t.tenant_id = r.tenant_id;
    v_cases := v_cases + 1;
    case_name := 'raised for one product, a programme over everything counts that product alone, on an issued sheet';
    passed := v_n = 1 and v_tasks = 1 and v_where = 'B@RECV'
          and (select erp.object_current_state('document', t.document_id) from erp.count_task t
                where t.tenant_id = r.tenant_id and t.item_id = i_b) = 'issued';
    detail := coalesce(v_state, format('%s raised: %s', v_n, coalesce(v_where, 'none')));
    return next;

    -- 3. One place.
    v_step := 'raising for goods in at NORTH alone';
    v_n := public.erp_raise_count_tasks('zz_crp', v_recv_n, null);
    select count(*), string_agg(i.code || '@' || l.code, ', ' order by i.code, l.code) into v_tasks, v_where
      from erp.count_task t
      join erp.item i on i.id = t.item_id
      join erp.location l on l.id = t.location_id
     where t.tenant_id = r.tenant_id;
    v_cases := v_cases + 1;
    case_name := 'raised for one place, it counts what stands there and nothing at the other site';
    passed := v_n = 1 and v_tasks = 2 and v_where = 'A@RECV-N, B@RECV'
          and (select erp.object_current_state('document', t.document_id) from erp.count_task t
                where t.tenant_id = r.tenant_id and t.location_id = v_recv_n) = 'issued';
    detail := coalesce(v_state, format('%s raised: %s', v_n, coalesce(v_where, 'none')));
    return next;

    -- 4. A place and a product that do not meet.
    v_step := 'raising for B at NORTH, where there is none';
    select count(*) into v_sheets0 from erp.document d
      join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = r.tenant_id and dt.base_type_code = 'count';
    v_n := public.erp_raise_count_tasks('zz_crp', v_recv_n, i_b);
    select count(*) into v_sheets from erp.document d
      join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = r.tenant_id and dt.base_type_code = 'count';
    v_cases := v_cases + 1;
    case_name := 'a place and a product that do not meet raise nothing and open no empty sheet';
    passed := v_n = 0 and v_sheets = v_sheets0 and v_sheets0 = 2
          and (select count(*) from erp.count_task t where t.tenant_id = r.tenant_id) = 2;
    detail := coalesce(v_state, format('%s raised; %s sheet(s) before, %s after', v_n, v_sheets0, v_sheets));
    return next;

    -- 5. The programme alone, as the published screen asks.
    v_step := 'raising the whole programme by its code alone';
    v_n := public.erp_raise_count_tasks('zz_crp');
    select count(*), string_agg(i.code || '@' || l.code, ', ' order by i.code, l.code) into v_tasks, v_where
      from erp.count_task t
      join erp.item i on i.id = t.item_id
      join erp.location l on l.id = t.location_id
     where t.tenant_id = r.tenant_id;
    v_cases := v_cases + 1;
    case_name := 'the programme alone raises everything it covers that is not already being counted, as before';
    passed := v_n = 1 and v_tasks = 3 and v_where = 'A@RECV, A@RECV-N, B@RECV';
    detail := coalesce(v_state, format('%s raised: %s', v_n, coalesce(v_where, 'none')));
    return next;

    -- 6. Somebody who may not count.
    v_step := 'raising as somebody who may not count';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_err := null;
    begin
      perform public.erp_raise_count_tasks('zz_crp', v_recv, i_a);
      v_err := 'raised';
    exception when others then v_err := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'somebody without inventory.count is refused, for one place as for the whole programme';
    passed := v_err like 'CLOVEERP_PERMISSION_DENIED: inventory.count%';
    detail := coalesce(v_state, v_err);
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
    raise exception 'CLOVEERP_COUNT_RAISED_FOR_ONE_PLACE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zz-crp-' || v_hex)
     or exists (select 1 from auth.users u where u.id in (a1, a2, a3)) then
    raise exception 'CLOVEERP_COUNT_RAISED_FOR_ONE_PLACE_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.count_raised_for_one_place_suite() from public, anon;

comment on function erp_test.count_raised_for_one_place_suite() is
  'A count can be raised for one place or product (20261007131000, J-86): one product, one place, a place and a '
  'product that do not meet, the whole programme by its code alone, and somebody without inventory.count refused; '
  'and what issues a count sheet is still the register''s.';

create or replace function erp_test.assert_count_raised_for_one_place_suite()
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
    from erp_test.count_raised_for_one_place_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_COUNT_RAISED_FOR_ONE_PLACE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Raising a count for one place or product would count the wrong places, or none. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_COUNT_RAISED_FOR_ONE_PLACE_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('count raised for one place: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_count_raised_for_one_place_suite() from public, anon;

comment on function erp_test.assert_count_raised_for_one_place_suite() is
  'A count can be raised for one place or product, and the programme alone still raises everything (20261007131000).';

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
