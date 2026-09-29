set lock_timeout = '30s';

-- =============================================================================
-- 20261002000000  A carrier is a party, and a shipment names it
-- -----------------------------------------------------------------------------
-- LPR1 of docs/spec/logistics-target-flow.md: nodes L1 and L2, the fixes that
-- do not wait for the shipment to become a document.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- On a database built from main:
--
--   * Book a shipment could not be completed from the screen. Its Carrier
--     picker listed parties holding a carrier role; erp.configure_logistics()
--     installs rows in erp.carrier and no party, so an organisation that had
--     installed logistics was offered nothing to book with. A party given the
--     role by hand was offered and then refused, because erp.book_shipment()
--     looks its code up in erp.carrier.
--   * public.erp_shipments joined sh.carrier_id, a key of erp.carrier, to
--     erp.party, so the carrier column of every shipment read null.
--   * erp.record_proof_of_delivery() took proof on a shipment in any state,
--     one that was never booked included, and read it delivered.
--   * The Despatch strip's first step listed deliveries in draft; the one
--     verb on it, Plan a shipment, offers only posted deliveries that no
--     shipment carries (public.erp_deliveries_to_ship), so the step showed
--     work its own verb refuses.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * erp.link_carrier_party(): a carrier is a party. It takes the party of
--     the carrier's code, or opens one, gives it an active carrier role and
--     sets erp.carrier.party_id. erp.apply_change_set_item() calls it as it
--     installs a carrier, and every carrier installed before this is linked
--     here. A carrier's bill (option A of the spec's section 7) will be raised
--     on that party.
--   * public.erp_carriers(): the carriers an organisation may book with, read
--     from erp.carrier, with their services. What Book a shipment offers.
--   * public.erp_shipments names the carrier from erp.carrier.
--   * erp.record_proof_of_delivery() refuses a shipment that has not been
--     booked (CLOVEERP_SHIPMENT_NOT_BOOKED).
--   * public.erp_deliveries_to_ship(): a null site means every site, and each
--     row says which site it leaves from. The strip's first step reads it, so
--     it lists exactly what Plan a shipment will take.
--   * erp_test.logistics_suite, read as the authenticated role beside a
--     second organisation.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * erp.plan_shipment() still accepts a delivery that is not posted. Its
--     picker offers only posted ones; the door itself is replaced by one press,
--     Ship these deliveries, in L4, which takes posted deliveries only.
--   * The shipment as a document, the one press, the derived states and the
--     parameters: L3 to L7.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusal this adds
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_SHIPMENT_NOT_BOOKED',
  'Recording proof of delivery on a shipment that has not been booked with a carrier.',
  'Proof of delivery says a carrier took the goods and handed them over; a shipment nobody booked has no carrier to have done it, and reading it delivered would put a delivery in the carrier''s performance that never happened.',
  'Book the shipment with its carrier first, then record the proof of delivery.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A carrier is a party
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.link_carrier_party(p_carrier_id uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  c       erp.carrier%rowtype;
  v_party uuid;
begin
  select * into c from erp.carrier where id = p_carrier_id;
  if not found then
    return null;
  end if;

  v_party := c.party_id;
  if v_party is null then
    -- The party already known by the carrier's code, if the organisation has
    -- one; otherwise a party opened for it. Matched within the carrier's own
    -- organisation only.
    select p.id into v_party from erp.party p
     where p.tenant_id = c.tenant_id and p.code = c.code and p.merged_into_id is null
     order by p.created_at
     limit 1;
    if v_party is null then
      insert into erp.party (tenant_id, code, name, status)
      values (c.tenant_id, c.code, c.name, 'active')
      returning id into v_party;
    end if;
    update erp.carrier set party_id = v_party, updated_at = now() where id = c.id;
  end if;

  if not exists (select 1 from erp.party_role pr
                  where pr.tenant_id = c.tenant_id and pr.party_id = v_party
                    and pr.role_kind = 'carrier') then
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (c.tenant_id, v_party, 'carrier', 'active');
  else
    update erp.party_role set status = 'active', updated_at = now()
     where tenant_id = c.tenant_id and party_id = v_party
       and role_kind = 'carrier' and status <> 'active';
  end if;

  return v_party;
end;
$$;

revoke all on function erp.link_carrier_party(uuid) from public, anon, authenticated;

comment on function erp.link_carrier_party(uuid) is
  'A carrier is a party (20261002000000): the party of its code in its own organisation, or one opened '
  'for it, with an active carrier role, set as erp.carrier.party_id. Called as a carrier is installed.';

-- The install: a carrier promoted from a change set is linked as it lands.
do $install$
declare
  v_sig constant text := 'erp.apply_change_set_item(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$          set name = excluded.name, services = excluded.services,
              status = 'active', updated_at = now();
      end if;
$o$;
  v_new constant text := $n$          set name = excluded.name, services = excluded.services,
              status = 'active', updated_at = now();
        -- A carrier is a party (20261002000000): its bill is raised on it.
        perform erp.link_carrier_party(
          (select c.id from erp.carrier c where c.tenant_id = v_tenant and c.code = (p ->> 'code')));
      end if;
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % carrier install found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$install$;

-- Every carrier installed before this.
do $link$
declare
  v_n integer := 0;
  c record;
begin
  for c in select id from erp.carrier where party_id is null loop
    perform erp.link_carrier_party(c.id);
    v_n := v_n + 1;
  end loop;
  raise warning 'carriers linked to a party: %', v_n;
  if exists (select 1 from erp.carrier where party_id is null) then
    raise exception 'CLOVEERP_CARRIER_WITHOUT_PARTY: a carrier is still without its party';
  end if;
end
$link$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The carriers Book a shipment offers
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_carriers()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x ->> 'code'), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'carrier_id', c.id, 'code', c.code, 'name', c.name,
               'party_id', c.party_id,
               'services', coalesce((select string_agg(sv.value ->> 'code', ', ' order by sv.value ->> 'code')
                                       from jsonb_array_elements(c.services) sv), '')) as x
        from erp.carrier c
       where c.tenant_id = erp.current_tenant_id()
         and c.status = 'active'
    ) t
$$;

comment on function public.erp_carriers() is
  'The carriers the organisation may book a shipment with, from erp.carrier, each with its party and the '
  'codes of its services: what Book a shipment offers (20261002000000). Reads under row security as the '
  'caller, and authorises nothing.';

revoke all on function public.erp_carriers() from public, anon;
grant execute on function public.erp_carriers() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. A shipment names its carrier
-- ─────────────────────────────────────────────────────────────────────────────

do $shipments$
declare
  v_sig constant text := 'public.erp_shipments(integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$left join erp.party c on c.tenant_id = sh.tenant_id and c.id = sh.carrier_id$o$;
  v_new constant text := $n$left join erp.carrier c on c.tenant_id = sh.tenant_id and c.id = sh.carrier_id$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % carrier join found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$shipments$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Proof of delivery is for a booked shipment
-- ─────────────────────────────────────────────────────────────────────────────

do $proof$
declare
  v_sig constant text := 'erp.record_proof_of_delivery(uuid,timestamp with time zone,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  perform erp.authorise('logistics.despatch', null, null, null,
                        'shipment', p_shipment_id);
$o$;
  v_new constant text := $n$  perform erp.authorise('logistics.despatch', null, null, null,
                        'shipment', p_shipment_id);

  -- Only a shipment a carrier was booked for can have been handed over by one
  -- (20261002000000). Despatched and exception are listed for the day the
  -- shipment reaches them; nothing does yet.
  if exists (select 1 from erp.shipment sh
              where sh.tenant_id = v_tenant and sh.id = p_shipment_id
                and sh.status not in ('booked', 'despatched', 'exception')) then
    raise exception 'CLOVEERP_SHIPMENT_NOT_BOOKED: % is %, not booked with a carrier',
      (select sh.reference from erp.shipment sh where sh.tenant_id = v_tenant and sh.id = p_shipment_id),
      (select sh.status from erp.shipment sh where sh.tenant_id = v_tenant and sh.id = p_shipment_id)
      using errcode = '23514',
            hint = 'Book the shipment with its carrier first, then record the proof of delivery.';
  end if;
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % authorisation found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$proof$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The deliveries a shipment can carry, from every site when none is named
-- ─────────────────────────────────────────────────────────────────────────────

do $to_ship$
declare
  v_sig constant text := 'public.erp_deliveries_to_ship(uuid,integer,integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$               'state', s.code, 'state_name', s.name) as x$o$,
    $n$               'state', s.code, 'state_name', s.name,
               'site_id', d.site_id, 'site', st.code) as x$n$,
    $o$        left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
$o$,
    $n$        left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
        left join erp.site st on st.tenant_id = d.tenant_id and st.id = d.site_id
$n$,
    $o$         and d.site_id = p_site_id
$o$,
    $n$         -- No site named: every site, for the Despatch strip's first step.
         and (p_site_id is null or d.site_id = p_site_id)
$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) by 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[v_i], ''))) / length(v_pairs[v_i]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, (v_i + 1) / 2, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[v_i], v_pairs[v_i + 1]);
  end loop;
  execute v_def;
end
$to_ship$;

comment on function public.erp_deliveries_to_ship(uuid, integer, integer) is
  'The posted deliveries of one site, or of every site when p_site_id is null (20261002000000), that no '
  'shipment still standing carries, dated within the last p_within_days days (30 unless asked; null for '
  'any date), newest first, each with its site: what Plan a shipment offers, and what the Despatch '
  'strip''s first step lists. Reads under row security as the caller, and authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- G. The screen's words, rendered through ui()
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The Despatch strip, whose first step lists what a shipment can carry (20261002000000).'
  from (values
    ('Posted deliveries that no shipment carries yet, from every site. A shipment carries them to one customer.'),
    ('Deliveries appear here once they are posted, that is once the goods have left stock.'),
    ('A shipment carries posted deliveries to one customer. Its freight is priced from the carrier''s rate card and shared across its deliveries by weight.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- H. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.logistics_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases integer := 0;
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  a2      uuid := gen_random_uuid();
  v_step  text := 'provisioning';
  v_state text;
  v_owner text := current_user;
  r       record;
  r2      record;
  v_site uuid; v_site2 uuid; v_uom uuid; v_cust uuid; v_sup uuid; v_item uuid;
  v_loc uuid; v_loc2 uuid; v_grn uuid; v_grn2 uuid;
  v_dn1 uuid; v_dn2 uuid; v_dn3 uuid; v_dn_draft uuid;
  v_ship uuid; v_ship2 uuid; v_hand uuid;
  v_carriers jsonb; v_carriers2 jsonb; v_shipments jsonb; v_to_ship jsonb; v_to_ship_one jsonb;
  v_err text; v_status text; v_party uuid; v_parties integer;
begin
  begin
    v_step := 'two organisations, each with logistics installed as the Configuration screen installs it';
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zzlg-' || v_tag, 'Logistics Suite', 'admin@zzlg-' || v_tag || '.test', 'Logistics Admin');
    select * into r2 from erp.provision_tenant(
      'zzlg2-' || v_tag, 'Logistics Suite Other', 'admin@zzlg2-' || v_tag || '.test', 'Other Admin');
    update erp.environment set is_live = false where tenant_id in (r.tenant_id, r2.tenant_id) and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzlg-' || v_tag || '.test'),
                                              (a2, 'admin@zzlg2-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(r2.admin_token);
    perform erp.ensure_demo_configuration(r2.tenant_id, r2.admin_user_id);
    perform erp.configure_logistics();
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    perform erp.configure_logistics();

    -- ── 1. A carrier is a party ────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'each carrier logistics installs is a party with the carrier role';
    passed := (select count(*) from erp.carrier c
                where c.tenant_id = r.tenant_id and c.status = 'active') = 2
          and not exists (select 1 from erp.carrier c
                           where c.tenant_id = r.tenant_id
                             and (c.party_id is null
                                  or not exists (select 1 from erp.party_role pr
                                                  where pr.tenant_id = c.tenant_id
                                                    and pr.party_id = c.party_id
                                                    and pr.role_kind = 'carrier'
                                                    and pr.status = 'active')
                                  or (select p.code from erp.party p where p.id = c.party_id) <> c.code));
    detail := format('%s carrier(s), each on the party of its code with an active carrier role',
                     (select count(*) from erp.carrier c where c.tenant_id = r.tenant_id));
    return next;

    v_step := 'a party given the carrier role by hand, with no rate card, and ROAD linked a second time';
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZLHAND', 'Carrier by hand', 'active') returning id into v_hand;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_hand, 'carrier', 'active');
    select c.party_id into v_party from erp.carrier c where c.tenant_id = r.tenant_id and c.code = 'ROAD';
    perform erp.link_carrier_party((select c.id from erp.carrier c where c.tenant_id = r.tenant_id and c.code = 'ROAD'));
    select count(*) into v_parties from erp.party p where p.tenant_id = r.tenant_id and p.code = 'ROAD';

    v_step := 'a site with stock, a customer, and deliveries: two posted, one posted at another site, one draft';
    select u.id into v_uom from erp.uom u where u.tenant_id = r.tenant_id order by u.code limit 1;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'ZLMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'ZLNORTH', 'North', 'warehouse', 'active') returning id into v_site2;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'ZLSTK', 'Stock', 'bulk', 'active') returning id into v_loc;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site2, 'ZLSTK2', 'Stock', 'bulk', 'active') returning id into v_loc2;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZLCUST', 'Logistics suite customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZLSUP', 'Logistics suite supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, gross_weight_g, status)
    values (r.tenant_id, 'ZLBOX', 'Logistics suite box', v_uom, 1000, 'active') returning id into v_item;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_item, 20, 1000, 'in');
    update erp.document_line set location_id = v_loc where document_id = v_grn;
    perform erp.transition_document(v_grn, 'post');
    v_grn2 := erp.open_document('goods_receipt', v_sup, null, v_site2);
    perform erp.add_document_line(v_grn2, v_item, 20, 1000, 'in');
    update erp.document_line set location_id = v_loc2 where document_id = v_grn2;
    perform erp.transition_document(v_grn2, 'post');
    v_dn1 := erp.open_document('delivery', v_cust, null, v_site);
    perform erp.add_document_line(v_dn1, v_item, 4, 2500, 'out');
    update erp.document_line set location_id = v_loc where document_id = v_dn1;
    perform erp.transition_document(v_dn1, 'post');
    v_dn2 := erp.open_document('delivery', v_cust, null, v_site);
    perform erp.add_document_line(v_dn2, v_item, 3, 2500, 'out');
    update erp.document_line set location_id = v_loc where document_id = v_dn2;
    perform erp.transition_document(v_dn2, 'post');
    v_dn3 := erp.open_document('delivery', v_cust, null, v_site2);
    perform erp.add_document_line(v_dn3, v_item, 2, 2500, 'out');
    update erp.document_line set location_id = v_loc2 where document_id = v_dn3;
    perform erp.transition_document(v_dn3, 'post');
    v_dn_draft := erp.open_document('delivery', v_cust, null, v_site);
    perform erp.add_document_line(v_dn_draft, v_item, 1, 2500, 'not yet');

    v_step := 'a shipment of the first delivery, planned and not booked, and proof of delivery tried on it';
    v_ship := erp.plan_shipment(v_site, array[v_dn1], current_date);
    begin
      perform erp.record_proof_of_delivery(v_ship, now(), 'J. Smith', 'POD-EARLY');
    exception when sqlstate '23514' then
      v_err := sqlerrm;
    end;
    select sh.status::text into v_status from erp.shipment sh where sh.id = v_ship;

    -- ── 2. Proof of delivery waits for a booking ──────────────────────────
    v_cases := v_cases + 1;
    case_name := 'proof of delivery is refused on a shipment nobody has booked, and the shipment stays planned';
    passed := coalesce(v_err like 'CLOVEERP_SHIPMENT_NOT_BOOKED:%', false)
          and v_status = 'planned'
          and (select sh.proof_of_delivery from erp.shipment sh where sh.id = v_ship) is null;
    detail := coalesce(v_err, 'no refusal') || '; ' || coalesce(v_status, '?');
    return next;

    v_step := 'the shipment booked with ROAD at its rate card, and its proof recorded';
    perform erp.book_shipment(v_ship, 'ROAD', 'NEXT_DAY');
    perform erp.record_proof_of_delivery(v_ship, now(), 'J. Smith', 'POD-1');

    -- ── 3. A booked shipment takes its proof ──────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a booked shipment takes its proof of delivery and reads delivered';
    passed := (select sh.status::text from erp.shipment sh where sh.id = v_ship) = 'delivered'
          and (select sh.proof_of_delivery ->> 'reference' from erp.shipment sh where sh.id = v_ship) = 'POD-1';
    detail := (select sh.status::text from erp.shipment sh where sh.id = v_ship);
    return next;

    v_step := 'the doors read as the authenticated role, by this organisation and by the other';
    perform set_config('request.jwt.claims', json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_carriers := public.erp_carriers();
    v_shipments := public.erp_shipments(200);
    v_to_ship := public.erp_deliveries_to_ship(null);
    v_to_ship_one := public.erp_deliveries_to_ship(v_site);
    execute format('set local role %I', v_owner);
    perform set_config('request.jwt.claims', json_build_object('sub', a2, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_carriers2 := public.erp_carriers();
    execute format('set local role %I', v_owner);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- ── 4. What Book a shipment offers ────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'Book a shipment is offered the installed carriers, once each, and not a carrier nobody can book or another organisation''s';
    passed := jsonb_array_length(v_carriers) = 2
          and v_carriers @> '[{"code": "ROAD"}, {"code": "AIR"}]'::jsonb
          and not (v_carriers @> '[{"code": "ZLHAND"}]'::jsonb)
          and (select x ->> 'services' from jsonb_array_elements(v_carriers) x where x ->> 'code' = 'ROAD')
              = 'ECONOMY, NEXT_DAY'
          and not exists (select 1 from jsonb_array_elements(v_carriers) x
                           where (x ->> 'carrier_id')::uuid in (select c.id from erp.carrier c
                                                                 where c.tenant_id = r2.tenant_id))
          and jsonb_array_length(v_carriers2) = 2
          and v_parties = 1
          and (select c.party_id from erp.carrier c where c.tenant_id = r.tenant_id and c.code = 'ROAD') = v_party;
    detail := format('%s carrier(s) here, %s in the other organisation; ROAD on one party after linking twice',
                     jsonb_array_length(v_carriers), jsonb_array_length(v_carriers2));
    return next;

    -- ── 5. A shipment names its carrier ───────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the shipment list names the carrier a shipment was booked with';
    passed := exists (select 1 from jsonb_array_elements(v_shipments) x
                       where x ->> 'shipment_id' = v_ship::text and x ->> 'carrier' = 'Road haulier');
    detail := coalesce((select x ->> 'carrier' from jsonb_array_elements(v_shipments) x
                         where x ->> 'shipment_id' = v_ship::text), 'no carrier named');
    return next;

    -- ── 6. The strip's first step lists what the door takes ───────────────
    v_cases := v_cases + 1;
    case_name := 'with no site named, the deliveries a shipment can carry are the posted ones on no shipment, from every site';
    passed := jsonb_array_length(v_to_ship) = 2
          and v_to_ship @> jsonb_build_array(jsonb_build_object('document_id', v_dn2, 'site', 'ZLMAIN'),
                                             jsonb_build_object('document_id', v_dn3, 'site', 'ZLNORTH'))
          and jsonb_array_length(v_to_ship_one) = 1
          and v_to_ship_one @> jsonb_build_array(jsonb_build_object('document_id', v_dn2));
    detail := format('%s from every site (the shipped one and the draft left out), %s from Main',
                     jsonb_array_length(v_to_ship), jsonb_array_length(v_to_ship_one));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  if current_user <> v_owner then
    execute format('set local role %I', v_owner);
  end if;
  perform set_config('request.jwt.claims', '', true);

  -- ── 7. Undone ───────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code in ('zzlg-' || v_tag, 'zzlg2-' || v_tag))
        and not exists (select 1 from auth.users u where u.id in (a1, a2))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzlg rolled back with its shipments');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_LOGISTICS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.logistics_suite() from public, anon;

comment on function erp_test.logistics_suite() is
  'A carrier is a party; Book a shipment is offered what it can book; a shipment names its carrier; proof '
  'of delivery waits for a booking; and the Despatch strip''s first step lists what Plan a shipment takes '
  '(20261002000000).';

create or replace function erp_test.assert_logistics_suite()
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
    from erp_test.logistics_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_LOGISTICS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Despatch would offer a carrier it cannot book, lose a carrier''s name, or take proof nobody could give. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_LOGISTICS_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('logistics: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_logistics_suite() from public, anon;

comment on function erp_test.assert_logistics_suite() is
  'A carrier is a party, a shipment names it, and proof of delivery waits for a booking (20261002000000).';

select erp_test.assert_logistics_suite();

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
select erp.assert_parameter_budget();
