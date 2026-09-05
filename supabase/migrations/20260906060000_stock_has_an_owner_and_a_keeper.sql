-- Stock has an owner and a keeper.
--
-- D9 says every position and every movement carries an owner and a custody
-- party, valuation follows ownership, and operational visibility and counting
-- follow custody. Until this file nothing in the schema carried either. A
-- consignment location type existed, and stock in it was valued and counted
-- like everything else; a third-party warehouse was a site like any other;
-- and D9 was bound to an assertion about costing rules that could not tell
-- the difference. Third-party logistics, consignment in both directions and
-- contract manufacturing are ordinary in the target profile, and each is the
-- case that collapses when ownership and custody are one field.
--
-- Four things, in order.
--
-- A company is a party. erp.entity.party_id names the party a company is when
-- it owns or holds stock, or trades with a sister company. Every entity gets
-- one on creation (adopting a party that already carries its code, which is
-- how intercompany counterparties were set up when they were set up at all),
-- and every existing entity gets one here. erp.intercompany_position() reads
-- that identity instead of inferring it from a matching code.
--
-- Sites and documents declare. erp.site.operator_party_id names who keeps the
-- stock at a site the company does not run (null: the company does).
-- erp.document.stock_owner_party_id names who owns what a document moves
-- (null: the company does). A goods receipt with a supplier as owner is
-- consignment inbound; a site operated by a logistics provider is custody
-- outbound.
--
-- Movements and positions carry both. erp.stock_movement and erp.stock_balance
-- gain owner_party_id and custody_party_id, resolved by a BEFORE INSERT
-- trigger when the caller does not say (owner from the document, custody from
-- the site, both falling back to the company), so the seven routines that
-- insert movements carry them without being restated. Existing rows are
-- backfilled to the company on both sides, which is what they meant. The
-- balance key, the position view and the stock reconciliation include the two
-- parties, so owned and consigned stock of one item in one location are two
-- positions, not one.
--
-- Valuation follows ownership; counting follows custody. Stock the company
-- moves but does not own carries no cost, adds nothing to the value on hand,
-- posts nothing to the ledger, and is absent from the valuation report;
-- erp.inventory_reconciliation_report() therefore still ties to the penny.
-- Count programmes raise tasks over stock the company holds, owned or not,
-- summed across owners so one location gives one counter one expected figure;
-- stock at a provider's site is not counted, because nobody with a scanner can
-- stand in front of it. A third-party site kept as one place gets one implicit
-- location, SITE, on its first posting. Recall and genealogy include
-- everything, as before.
--
-- The rule is erp.assert_ownership_carried(), per organisation and driven by
-- the whole-database step: every company has a party, no un-owned stock is
-- valued, no un-held stock is counted. D9 is re-bound to it and to
-- erp_test.ownership_suite(), which exercises consignment inbound, a
-- third-party site, the split balance key, counting across owners and
-- intercompany identity.
--
-- Left for later, deliberately. A change of owner or keeper in place (a
-- consignment consumed, stock handed to a provider) is an issue and a receipt
-- today; a movement that changes a party on one side is Phase 4c's, with the
-- consignment and intercompany order types. Posting a count variance or a
-- write-off against consigned stock is Phase 4b's, with the identity policy
-- that reshapes count tasks. Existing movements on the append-only ledger are
-- given their two parties by a one-off backfill that disables the append-only
-- trigger for exactly that statement: a column that did not exist is not
-- history being rewritten, and the statement is here to be read.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A company is a party
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.entity add column if not exists party_id uuid;

do $fk$
begin
  if not exists (select 1 from pg_constraint where conname = 'entity_party_fkey') then
    alter table erp.entity
      add constraint entity_party_fkey
      foreign key (tenant_id, party_id) references erp.party(tenant_id, id) on delete restrict;
  end if;
end
$fk$;

comment on column erp.entity.party_id is
  'The party this company is: the owner and keeper of its own stock, and the '
  'counterparty a sister company trades with. Set on creation; never null once set.';

-- Adopts a party that already carries the company''s code, otherwise creates
-- one, and gives it the internal role either way.
create or replace function erp.ensure_entity_party(p_entity_id uuid)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  e       erp.entity%rowtype;
  v_party uuid;
begin
  select * into e from erp.entity where id = p_entity_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_ENTITY: %', p_entity_id using errcode = '23503',
      hint = 'The company does not exist in this organisation.';
  end if;
  if e.party_id is not null then
    return e.party_id;
  end if;

  select p.id into v_party from erp.party p
   where p.tenant_id = e.tenant_id and p.code = e.code and p.merged_into_id is null;
  if v_party is null then
    insert into erp.party (tenant_id, code, name, legal_name, country_code, registration_number, status)
    values (e.tenant_id, e.code, e.name, e.legal_name, e.country_code, e.registration_number, 'active')
    returning id into v_party;
  end if;

  insert into erp.party_role (tenant_id, party_id, role_kind, is_approved, status)
  values (e.tenant_id, v_party, 'internal', true, 'active')
  on conflict (tenant_id, party_id, role_kind) do nothing;

  update erp.entity set party_id = v_party, updated_at = now() where id = p_entity_id;
  return v_party;
end;
$$;
revoke all on function erp.ensure_entity_party(uuid) from public, anon, authenticated;

comment on function erp.ensure_entity_party is
  'Gives a company its party: the one already carrying its code, or a new one; '
  'with the internal role. Idempotent.';

create or replace function erp.stamp_entity_party()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_party uuid;
begin
  if new.party_id is not null then
    return new;
  end if;
  select p.id into v_party from erp.party p
   where p.tenant_id = new.tenant_id and p.code = new.code and p.merged_into_id is null;
  if v_party is null then
    insert into erp.party (tenant_id, code, name, legal_name, country_code, registration_number, status)
    values (new.tenant_id, new.code, new.name, new.legal_name, new.country_code, new.registration_number, 'active')
    returning id into v_party;
  end if;
  insert into erp.party_role (tenant_id, party_id, role_kind, is_approved, status)
  values (new.tenant_id, v_party, 'internal', true, 'active')
  on conflict (tenant_id, party_id, role_kind) do nothing;
  new.party_id := v_party;
  return new;
end;
$$;

drop trigger if exists t_entity_party on erp.entity;
create trigger t_entity_party
  before insert on erp.entity
  for each row execute function erp.stamp_entity_party();

-- Every company that exists already.
select count(erp.ensure_entity_party(e.id)) as companies_given_a_party
  from erp.entity e where e.party_id is null;

do $check$
begin
  if exists (select 1 from erp.entity where party_id is null) then
    raise exception 'CLOVEERP_BACKFILL_INCOMPLETE: a company has no party after the backfill';
  end if;
end
$check$;

alter table erp.entity alter column party_id set not null;

create or replace function erp.entity_party(p_entity_id uuid)
returns uuid
language sql
stable
set search_path = ''
as $$
  select e.party_id from erp.entity e where e.id = p_entity_id
$$;
revoke all on function erp.entity_party(uuid) from public, anon, authenticated;

create or replace function erp.entity_party_for_site(p_site_id uuid)
returns uuid
language sql
stable
set search_path = ''
as $$
  select e.party_id from erp.site s join erp.entity e on e.id = s.entity_id where s.id = p_site_id
$$;
revoke all on function erp.entity_party_for_site(uuid) from public, anon, authenticated;

comment on function erp.entity_party is 'The party a company is.';
comment on function erp.entity_party_for_site is 'The party of the company that owns a site.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Sites and documents declare
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.site add column if not exists operator_party_id uuid;
alter table erp.document add column if not exists stock_owner_party_id uuid;

do $fk$
begin
  if not exists (select 1 from pg_constraint where conname = 'site_operator_party_fkey') then
    alter table erp.site
      add constraint site_operator_party_fkey
      foreign key (tenant_id, operator_party_id) references erp.party(tenant_id, id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'document_stock_owner_party_fkey') then
    alter table erp.document
      add constraint document_stock_owner_party_fkey
      foreign key (tenant_id, stock_owner_party_id) references erp.party(tenant_id, id) on delete restrict;
  end if;
end
$fk$;

comment on column erp.site.operator_party_id is
  'Who keeps the stock at this site when the company does not run it: a '
  'logistics provider, a contract manufacturer. Null: the company does. '
  'Custody of every movement at the site defaults to this party.';
comment on column erp.document.stock_owner_party_id is
  'Who owns the stock this document moves when the company does not: a '
  'supplier whose goods are on consignment. Null: the company does. Ownership '
  'of every movement the document posts defaults to this party; stock the '
  'company does not own carries no cost and posts nothing.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Movements carry both
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.stock_movement
  add column if not exists owner_party_id   uuid,
  add column if not exists custody_party_id uuid;

-- The one-off backfill. The ledger is append-only and the trigger that says so
-- is disabled for this statement alone: the rows keep every value they were
-- written with and gain the two the schema now carries, which for every
-- movement to date is the company on both sides.
alter table erp.stock_movement disable trigger t_stock_movement_append_only;
update erp.stock_movement m
   set owner_party_id   = coalesce(m.owner_party_id, e.party_id),
       custody_party_id = coalesce(m.custody_party_id, e.party_id)
  from erp.entity e
 where e.id = m.entity_id
   and (m.owner_party_id is null or m.custody_party_id is null);
alter table erp.stock_movement enable trigger t_stock_movement_append_only;

do $check$
begin
  if exists (select 1 from erp.stock_movement where owner_party_id is null or custody_party_id is null) then
    raise exception 'CLOVEERP_BACKFILL_INCOMPLETE: a movement has no owner or keeper after the backfill';
  end if;
end
$check$;

alter table erp.stock_movement
  alter column owner_party_id set not null,
  alter column custody_party_id set not null;

do $fk$
begin
  if not exists (select 1 from pg_constraint where conname = 'stock_movement_owner_party_fkey') then
    alter table erp.stock_movement
      add constraint stock_movement_owner_party_fkey
      foreign key (tenant_id, owner_party_id) references erp.party(tenant_id, id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'stock_movement_custody_party_fkey') then
    alter table erp.stock_movement
      add constraint stock_movement_custody_party_fkey
      foreign key (tenant_id, custody_party_id) references erp.party(tenant_id, id) on delete restrict;
  end if;
end
$fk$;

comment on column erp.stock_movement.owner_party_id is
  'Who owns the stock this movement moves. Defaults from the document, then the company. Valuation follows this.';
comment on column erp.stock_movement.custody_party_id is
  'Who holds the stock this movement moves. Defaults from the site''s operator, then the company. Counting and operational visibility follow this.';

create or replace function erp.stamp_movement_parties()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_company uuid;
begin
  select e.party_id into v_company from erp.entity e where e.id = new.entity_id;
  if v_company is null then
    raise exception 'CLOVEERP_COMPANY_HAS_NO_PARTY: the company holding this movement has no party'
      using errcode = '23514',
            hint = 'erp.ensure_entity_party() gives a company its party; every company created since 20260906060000 has one.';
  end if;

  if new.owner_party_id is null then
    new.owner_party_id := coalesce(
      (select d.stock_owner_party_id from erp.document d where d.id = new.document_id),
      v_company);
  end if;
  if new.custody_party_id is null then
    new.custody_party_id := coalesce(
      (select s.operator_party_id from erp.site s where s.id = new.site_id),
      v_company);
  end if;

  -- Stock the company does not own is not on its books: no cost on the
  -- movement, so nothing values it and nothing posts it.
  if new.owner_party_id <> v_company then
    new.unit_cost_minor := null;
    new.cost_minor := null;
  end if;
  return new;
end;
$$;

drop trigger if exists t_stock_movement_parties on erp.stock_movement;
create trigger t_stock_movement_parties
  before insert on erp.stock_movement
  for each row execute function erp.stamp_movement_parties();

comment on function erp.stamp_movement_parties is
  'Resolves a new movement''s owner (document, then company) and keeper (site '
  'operator, then company) when the caller did not say, and strips the cost '
  'from stock the company does not own.';

-- A reversal carries the same two parties as the movement it reverses, not
-- whatever the site or document would resolve to today.
do $reverse$
declare
  v_def text := pg_get_functiondef('erp.reverse_stock_movement(bigint, text)'::regprocedure);
  v_a   text := E'    correlation_id, reverses_movement_id, is_reversal)\n  values (';
  v_b   text := E'    m.id, true)\n  returning id into v_new;';
begin
  if position(v_a in v_def) = 0 or position(v_b in v_def) = 0 then
    raise exception 'CLOVEERP_NEEDLE_NOT_FOUND: erp.reverse_stock_movement is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_a, E'    correlation_id, reverses_movement_id, is_reversal, owner_party_id, custody_party_id)\n  values (');
  v_def := replace(v_def, v_b, E'    m.id, true, m.owner_party_id, m.custody_party_id)\n  returning id into v_new;');
  execute v_def;
end
$reverse$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Positions carry both
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.stock_balance
  add column if not exists owner_party_id   uuid,
  add column if not exists custody_party_id uuid;

do $backfill$
begin
  perform set_config('erp.ledger_write', 'on', true);
  update erp.stock_balance b
     set owner_party_id   = coalesce(b.owner_party_id, e.party_id),
         custody_party_id = coalesce(b.custody_party_id, e.party_id)
    from erp.site s join erp.entity e on e.id = s.entity_id
   where s.id = b.site_id
     and (b.owner_party_id is null or b.custody_party_id is null);
  perform set_config('erp.ledger_write', '', true);
  if exists (select 1 from erp.stock_balance where owner_party_id is null or custody_party_id is null) then
    raise exception 'CLOVEERP_BACKFILL_INCOMPLETE: a position has no owner or keeper after the backfill';
  end if;
end
$backfill$;

alter table erp.stock_balance
  alter column owner_party_id set not null,
  alter column custody_party_id set not null;

do $fk$
begin
  if not exists (select 1 from pg_constraint where conname = 'stock_balance_owner_party_fkey') then
    alter table erp.stock_balance
      add constraint stock_balance_owner_party_fkey
      foreign key (tenant_id, owner_party_id) references erp.party(tenant_id, id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'stock_balance_custody_party_fkey') then
    alter table erp.stock_balance
      add constraint stock_balance_custody_party_fkey
      foreign key (tenant_id, custody_party_id) references erp.party(tenant_id, id) on delete restrict;
  end if;
end
$fk$;

-- The position key: owned and consigned stock of one item in one location are
-- two positions.
drop index if exists erp.stock_balance_position;
create unique index stock_balance_position on erp.stock_balance (
  tenant_id, site_id, location_id, item_id,
  coalesce(batch_id,     '00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(serial_id,    '00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(container_id, '00000000-0000-0000-0000-000000000000'::uuid),
  owner_party_id, custody_party_id, stock_status);

-- The applier, restated with the two parties in the key. The body is the one
-- the database carries (0023, refusal prefix renamed since); the check first.
do $check$
declare v_def text := pg_get_functiondef('erp.apply_stock_movement()'::regprocedure);
begin
  if position(E'                 stock_status)\n      -- excluded.quantity is already negative' in v_def) = 0
     and position(E'                 stock_status)\n      do update set quantity = b.quantity + excluded.quantity, updated_at = now()\n    returning' in v_def) = 0 then
    raise exception 'CLOVEERP_APPLIER_UNRECOGNISED: erp.apply_stock_movement is not the body this migration restates';
  end if;
end
$check$;

create or replace function erp.apply_stock_movement()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_allows_negative boolean;
  v_requires_reason boolean;
  v_direction       erp.movement_direction;
  v_item            erp.item%rowtype;
  v_resulting       numeric(20,6);
begin
  select mt.allows_negative, mt.requires_reason, mt.direction
    into v_allows_negative, v_requires_reason, v_direction
    from erp_ref.movement_type mt where mt.code = new.movement_type;

  if v_requires_reason and coalesce(new.reason_code, '') = '' then
    raise exception 'CLOVEERP_MOVEMENT_REASON_REQUIRED: % requires a reason code',
      new.movement_type using errcode = '23514';
  end if;

  select * into v_item from erp.item i where i.id = new.item_id;

  if v_item.is_batch_controlled and new.batch_id is null then
    raise exception 'CLOVEERP_BATCH_REQUIRED: % is batch controlled', v_item.code
      using errcode = '23514';
  end if;
  if not v_item.is_batch_controlled and new.batch_id is not null then
    raise exception 'CLOVEERP_BATCH_NOT_APPLICABLE: % is not batch controlled', v_item.code
      using errcode = '23514';
  end if;
  if v_item.is_serial_controlled and new.serial_id is null then
    raise exception 'CLOVEERP_SERIAL_REQUIRED: % is serial controlled', v_item.code
      using errcode = '23514';
  end if;

  perform set_config('erp.ledger_write', 'on', true);

  if new.from_location_id is not null then
    insert into erp.stock_balance as b (
      tenant_id, site_id, location_id, item_id, batch_id, serial_id,
      container_id, owner_party_id, custody_party_id, stock_status, quantity)
    values (
      new.tenant_id, new.site_id, new.from_location_id, new.item_id, new.batch_id,
      new.serial_id, new.container_id, new.owner_party_id, new.custody_party_id,
      new.from_status, -new.quantity)
    on conflict (tenant_id, site_id, location_id, item_id,
                 coalesce(batch_id,     '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(serial_id,    '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(container_id, '00000000-0000-0000-0000-000000000000'::uuid),
                 owner_party_id, custody_party_id, stock_status)
      do update set quantity = b.quantity + excluded.quantity, updated_at = now()
    returning b.quantity into v_resulting;

    if v_resulting < 0 and not coalesce(v_allows_negative, false) then
      raise exception
        'CLOVEERP_NEGATIVE_STOCK: % would leave %.% at % in %',
        new.movement_type, v_item.code, coalesce(new.batch_id::text, ''),
        v_resulting, new.from_status
        using errcode = '23514',
              hint = 'Only movement types marked allows_negative may drive a position below zero. '
                     'A position is per owner and keeper: stock the company does not own cannot be issued as its own.';
    end if;
  end if;

  if new.to_location_id is not null then
    insert into erp.stock_balance as b (
      tenant_id, site_id, location_id, item_id, batch_id, serial_id,
      container_id, owner_party_id, custody_party_id, stock_status, quantity)
    values (
      new.tenant_id, new.site_id, new.to_location_id, new.item_id, new.batch_id,
      new.serial_id, new.container_id, new.owner_party_id, new.custody_party_id,
      new.to_status, new.quantity)
    on conflict (tenant_id, site_id, location_id, item_id,
                 coalesce(batch_id,     '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(serial_id,    '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(container_id, '00000000-0000-0000-0000-000000000000'::uuid),
                 owner_party_id, custody_party_id, stock_status)
      do update set quantity = b.quantity + excluded.quantity, updated_at = now();
  end if;

  perform set_config('erp.ledger_write', '', true);
  return new;
end;
$$;

-- The truth, aggregated, now by owner and keeper too. Columns are appended so
-- every reader of the view keeps working.
create or replace view erp.stock_position with (security_invoker = true) as
with sides as (
  select m.tenant_id, m.site_id, m.to_location_id as location_id, m.item_id,
         m.batch_id, m.serial_id, m.container_id, m.to_status as stock_status,
         m.quantity as delta, m.owner_party_id, m.custody_party_id
    from erp.stock_movement m
   where m.to_location_id is not null
  union all
  select m.tenant_id, m.site_id, m.from_location_id, m.item_id,
         m.batch_id, m.serial_id, m.container_id, m.from_status,
         -m.quantity, m.owner_party_id, m.custody_party_id
    from erp.stock_movement m
   where m.from_location_id is not null
)
select tenant_id, site_id, location_id, item_id, batch_id, serial_id, container_id,
       stock_status, sum(delta) as quantity, owner_party_id, custody_party_id
  from sides
 group by tenant_id, site_id, location_id, item_id, batch_id, serial_id, container_id,
          stock_status, owner_party_id, custody_party_id
having sum(delta) <> 0;

comment on view erp.stock_position is
  'The stock ledger aggregated: quantity per site, location, item, batch, '
  'serial, container, status, owner and keeper. Nothing writes it.';

-- The cache and the truth are compared position by position, and a position
-- now includes its two parties.
drop function if exists erp.stock_reconciliation_report();
create function erp.stock_reconciliation_report()
returns table(site_id uuid, location_id uuid, item_id uuid, batch_id uuid,
              stock_status erp.stock_status, ledger_quantity numeric,
              cached_quantity numeric, difference numeric,
              owner_party_id uuid, custody_party_id uuid)
language sql
stable
set search_path = ''
as $$
  select coalesce(p.site_id, b.site_id),
         coalesce(p.location_id, b.location_id),
         coalesce(p.item_id, b.item_id),
         coalesce(p.batch_id, b.batch_id),
         coalesce(p.stock_status, b.stock_status),
         coalesce(p.quantity, 0),
         coalesce(b.quantity, 0),
         coalesce(p.quantity, 0) - coalesce(b.quantity, 0),
         coalesce(p.owner_party_id, b.owner_party_id),
         coalesce(p.custody_party_id, b.custody_party_id)
    from erp.stock_position p
    full outer join erp.stock_balance b
      on b.tenant_id = p.tenant_id
     and b.site_id = p.site_id
     and b.location_id = p.location_id
     and b.item_id = p.item_id
     and b.batch_id is not distinct from p.batch_id
     and b.serial_id is not distinct from p.serial_id
     and b.container_id is not distinct from p.container_id
     and b.owner_party_id = p.owner_party_id
     and b.custody_party_id = p.custody_party_id
     and b.stock_status = p.stock_status
   where coalesce(p.tenant_id, b.tenant_id) = erp.require_tenant_id()
     and coalesce(p.quantity, 0) is distinct from coalesce(b.quantity, 0)
$$;
revoke all on function erp.stock_reconciliation_report() from public, anon, authenticated;

comment on function erp.stock_reconciliation_report is
  'Every position where the cached balance differs from the ledger, per owner '
  'and keeper. Empty is the only acceptable answer. Requires an organisation.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Valuation follows ownership
-- ═════════════════════════════════════════════════════════════════════════════

-- The valuation report values what the company owns. Restated from
-- 20260906050000 with the owner filter on the positions.
create or replace function erp.stock_valuation_report()
returns table(item_id uuid, item_code text, site_id uuid, site_code text,
              method erp.costing_method, quantity numeric, unit_cost_minor bigint,
              value_minor bigint, currency character)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id),
  on_hand as (
    -- Owned by the company that runs the site. Consigned stock is held, not
    -- owned, and is not on the books.
    select b.item_id, b.site_id, sum(b.quantity) as qty
      from erp.stock_balance b
      join t on t.tenant_id = b.tenant_id
      join erp.site s on s.id = b.site_id
      join erp.entity e on e.id = s.entity_id
     where b.owner_party_id = e.party_id
     group by b.item_id, b.site_id
    having sum(b.quantity) <> 0
  ),
  valued as (
    select h.item_id, h.site_id, h.qty,
           erp.costing_method_for(h.item_id, h.site_id) as method
      from on_hand h
  )
  select v.item_id, i.code, v.site_id, s.code, v.method, v.qty,
         case v.method
           when 'fifo' then
             coalesce((select round(sum(l.remaining * l.unit_cost_minor) / nullif(sum(l.remaining), 0))::bigint
                         from erp.stock_valuation_layer l, t
                        where l.tenant_id = t.tenant_id and l.item_id = v.item_id
                          and l.site_id is not distinct from v.site_id and l.remaining > 0), 0)
           else
             coalesce((select case when c.quantity_on_hand = 0 then c.unit_cost_minor
                                   else round(c.value_minor / c.quantity_on_hand)::bigint end
                         from erp.item_cost c, t
                        where c.tenant_id = t.tenant_id and c.item_id = v.item_id
                          and c.site_id is not distinct from v.site_id), 0)
         end,
         case v.method
           when 'fifo' then
             coalesce((select round(sum(l.remaining * l.unit_cost_minor))::bigint
                         from erp.stock_valuation_layer l, t
                        where l.tenant_id = t.tenant_id and l.item_id = v.item_id
                          and l.site_id is not distinct from v.site_id and l.remaining > 0), 0)
           else
             coalesce((select c.value_minor from erp.item_cost c, t
                        where c.tenant_id = t.tenant_id and c.item_id = v.item_id
                          and c.site_id is not distinct from v.site_id), 0)
         end,
         coalesce((select e.base_currency from erp.entity e
                    join erp.site ss on ss.entity_id = e.id where ss.id = v.site_id),
                  (select e.base_currency from erp.entity e, t where e.tenant_id = t.tenant_id order by e.code limit 1),
                  'GBP')
    from valued v
    join erp.item i on i.id = v.item_id
    left join erp.site s on s.id = v.site_id
$$;

comment on function erp.stock_valuation_report is
  'Stock the company owns and its value per item and site: FIFO from open '
  'layers, average and standard from the exact value on hand. Stock held for '
  'somebody else is not here. Requires an organisation.';

-- The report view behind "Stock on hand and valuation": every position, with
-- its owner and keeper, valued only when owned. Existing columns unchanged.
create or replace view erp.stock_valuation with (security_invoker = true) as
select sp.tenant_id, sp.site_id, sp.location_id, sp.item_id,
       it.code as item_code, it.name as item_name,
       sp.batch_id, sp.serial_id, sp.container_id, sp.stock_status, sp.quantity,
       ic.method, ic.unit_cost_minor, ic.currency,
       case when sp.owner_party_id = erp.entity_party_for_site(sp.site_id)
            then (sp.quantity * coalesce(ic.unit_cost_minor, 0))::bigint
            else 0::bigint end as value_minor,
       sp.owner_party_id, sp.custody_party_id,
       (sp.owner_party_id = erp.entity_party_for_site(sp.site_id)) as is_owned
  from erp.stock_position sp
  join erp.item it on it.tenant_id = sp.tenant_id and it.id = sp.item_id
  left join lateral (
    select c.method, c.unit_cost_minor, c.currency
      from erp.item_cost c
     where c.tenant_id = sp.tenant_id and c.item_id = sp.item_id
       and (c.site_id = sp.site_id or c.site_id is null)
     order by (c.site_id is not null) desc, c.effective_from desc
     limit 1) ic on true;

comment on view erp.stock_valuation is
  'Every stock position with its owner and keeper and the cost that applies '
  'to it; valued only when the company owns it. Behind the Stock on hand and '
  'valuation report.';

-- A site kept as one place gets one implicit location on its first posting.
create or replace function erp.ensure_site_location(p_site_id uuid)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  s        erp.site%rowtype;
  v_id     uuid;
begin
  select * into s from erp.site where tenant_id = v_tenant and id = p_site_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SITE: %', p_site_id using errcode = '23503',
      hint = 'The site does not exist in this organisation.';
  end if;
  if exists (select 1 from erp.location l where l.tenant_id = v_tenant and l.site_id = p_site_id) then
    return null;
  end if;
  insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
  values (v_tenant, p_site_id, 'SITE', s.name, 'virtual', true, 'active')
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function erp.ensure_site_location(uuid) from public, anon, authenticated;

comment on function erp.ensure_site_location is
  'A site with no locations (a provider''s warehouse the product does not map '
  'inside) gets one, SITE, so a posting has somewhere to go. Returns the new '
  'location, or null when the site already has locations.';

-- The default posting location falls back to SITE for such a site. Restated
-- from 20260829200000 (refusal prefix renamed since).
create or replace function erp.default_posting_location(
  p_site_id   uuid,
  p_direction erp.movement_direction
) returns uuid
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_kind   erp.location_type;
  v_id     uuid;
begin
  v_kind := case p_direction
              when 'in'  then 'receiving'::erp.location_type
              when 'out' then 'despatch'::erp.location_type
              else 'staging'::erp.location_type
            end;

  select l.id into v_id
    from erp.location l
   where l.tenant_id = v_tenant
     and l.site_id = p_site_id
     and l.location_type = v_kind
     and l.status = 'active'
     and not l.is_blocked
   order by l.code
   limit 1;

  if v_id is null then
    -- A site kept as one place: everything arrives and leaves through SITE.
    select l.id into v_id
      from erp.location l
     where l.tenant_id = v_tenant
       and l.site_id = p_site_id
       and l.code = 'SITE'
       and l.location_type = 'virtual'
       and l.status = 'active'
       and not l.is_blocked;
  end if;

  if v_id is null then
    raise exception
      'CLOVEERP_NO_POSTING_LOCATION: site has no active % location, so a % '
      'movement has nowhere to go', v_kind, p_direction
      using errcode = '23503',
      hint = 'Give the line an explicit location, or configure one of this type.';
  end if;

  return v_id;
end;
$$;

-- The stock half of posting: stock the company does not own is not costed,
-- and a site with no locations gets its one. Deployed body, asserted needles.
do $stock$
declare
  v_def text := pg_get_functiondef('erp.post_document_stock(uuid)'::regprocedure);
  v_n1  text := E'  v_count    integer := 0;\n';
  v_n2  text := E'  select * into mt from erp_ref.movement_type where code = dt.stock_movement_type;\n';
  v_n3  text := E'    if mt.direction = ''in'' then\n      v_cost := erp.receive_cost(';
  v_n4  text := E'  for ln in\n    select l.* from erp.document_line l';
begin
  if position(v_n1 in v_def) = 0 or position(v_n2 in v_def) = 0
     or position(v_n3 in v_def) = 0 or position(v_n4 in v_def) = 0 then
    raise exception 'CLOVEERP_NEEDLE_NOT_FOUND: erp.post_document_stock is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n1, E'  v_count    integer := 0;\n  v_owned    boolean;\n');
  v_def := replace(v_def, v_n2, v_n2
    || E'\n  v_owned := d.stock_owner_party_id is null\n'
    || E'          or d.stock_owner_party_id = erp.entity_party(d.entity_id);\n');
  v_def := replace(v_def, v_n3,
       E'    if not v_owned then\n      v_cost := null;\n'
    || E'    elsif mt.direction = ''in'' then\n      v_cost := erp.receive_cost(');
  v_def := replace(v_def, v_n4, E'  perform erp.ensure_site_location(d.site_id);\n\n' || v_n4);
  execute v_def;
end
$stock$;

-- The finance half: a document that moved stock the company does not own has
-- nothing to post. Deployed body, asserted needle.
do $finance$
declare
  v_def text := pg_get_functiondef('erp.post_document_finance(uuid)'::regprocedure);
  v_n   text := E'  v_cost  := erp.document_stock_cost_minor(p_document_id);\n';
begin
  if position(v_n in v_def) = 0 then
    raise exception 'CLOVEERP_NEEDLE_NOT_FOUND: erp.post_document_finance is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n, v_n
    || E'\n  if d.stock_owner_party_id is not null\n'
    || E'     and d.stock_owner_party_id <> erp.entity_party(d.entity_id) then\n'
    || E'    return null;\n'
    || E'  end if;\n');
  execute v_def;
end
$finance$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Counting follows custody
-- ═════════════════════════════════════════════════════════════════════════════

-- Restated from 20260829240000 (refusal prefix renamed since): tasks are
-- raised over stock the company holds, summed across owners so one location
-- gives one counter one expected figure. The check first.
do $check$
declare v_def text := pg_get_functiondef('erp.raise_count_tasks(text)'::regprocedure);
begin
  if position(E'       and b.quantity <> 0\n  loop' in v_def) = 0
     or position('erp.jsonlogic_bool(pg.selector, to_jsonb(r))' in v_def) = 0 then
    raise exception 'CLOVEERP_COUNTING_UNRECOGNISED: erp.raise_count_tasks is not the body this migration restates';
  end if;
end
$check$;

create or replace function erp.raise_count_tasks(p_programme_code text)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  pg       erp.count_programme%rowtype;
  r        record;
  v_task   uuid;
  v_n      integer := 0;
  v_committed numeric;
begin
  select * into pg from erp.count_programme
   where tenant_id = v_tenant and code = p_programme_code and status = 'active';
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_COUNT_PROGRAMME: %', p_programme_code
      using errcode = '23503';
  end if;

  perform erp.authorise('inventory.count', null, pg.site_id, null,
                        'count_programme', pg.id);

  for r in
    select b.site_id, b.location_id, b.item_id, b.batch_id, b.stock_status,
           sum(b.quantity) as quantity, i.code as item_code, i.item_class
      from erp.stock_balance b
      join erp.item i on i.id = b.item_id
     where b.tenant_id = v_tenant
       and (pg.site_id is null or b.site_id = pg.site_id)
       and b.quantity <> 0
       -- Counting follows custody (D9): what the company holds, whoever owns
       -- it. Stock at a provider's site is theirs to count.
       and b.custody_party_id = erp.entity_party_for_site(b.site_id)
     group by b.site_id, b.location_id, b.item_id, b.batch_id, b.stock_status, i.code, i.item_class
    having sum(b.quantity) <> 0
  loop
    continue when not erp.jsonlogic_bool(pg.selector, to_jsonb(r));

    continue when exists (
      select 1 from erp.count_task t
       where t.tenant_id = v_tenant and t.status in ('open','counted','pending_approval')
         and t.item_id = r.item_id
         and t.location_id is not distinct from r.location_id);

    select coalesce(sum(al.quantity), 0) into v_committed
      from erp.allocation_line al
      join erp.allocation a on a.id = al.allocation_id
     where al.tenant_id = v_tenant
       and a.item_id = r.item_id
       and al.location_id is not distinct from r.location_id
       and al.status in ('reserved', 'committed', 'picked');

    insert into erp.count_task (
      tenant_id, count_programme_id, site_id, location_id, item_id, batch_id,
      expected_quantity, committed_quantity, status)
    values (v_tenant, pg.id, r.site_id, r.location_id, r.item_id, r.batch_id,
            r.quantity, v_committed, 'open')
    returning id into v_task;

    insert into erp.count_lock (tenant_id, count_task_id, location_id, item_id)
    values (v_tenant, v_task, r.location_id, r.item_id);

    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

comment on function erp.raise_count_tasks(text) is
  'Spec 5.2: a count programme raises tasks over the stock its selector picks '
  'among what the company holds (D9: counting follows custody), summed across '
  'owners, recording what was committed at that moment and taking a soft lock '
  'that warns rather than blocks.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Intercompany by identity
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.intercompany_position()
returns table (from_entity text, to_entity text, currency char(3),
               receivable_minor bigint, payable_minor bigint,
               difference_minor bigint, matched boolean)
language sql
stable
security invoker
set search_path = ''
as $$
  with pairs as (
    select si.entity_id, e2.id as counterparty_entity_id, si.currency,
           sum(si.debit_minor - si.credit_minor)
             filter (where si.control_kind = 'receivable') as recv,
           sum(si.credit_minor - si.debit_minor)
             filter (where si.control_kind = 'payable') as pay
      from erp.subledger_item si
      -- A party that IS another company of this organisation: by identity,
      -- not by a code that happens to match.
      join erp.entity e2 on e2.tenant_id = si.tenant_id and e2.party_id = si.party_id
     where si.tenant_id = erp.current_tenant_id()
       and e2.id <> si.entity_id
     group by si.entity_id, e2.id, si.currency
  )
  select e1.code, e2.code, pr.currency,
         coalesce(pr.recv, 0)::bigint, coalesce(pr.pay, 0)::bigint,
         (coalesce(pr.recv, 0) - coalesce(pr.pay, 0))::bigint,
         coalesce(pr.recv, 0) = coalesce(pr.pay, 0)
    from pairs pr
    join erp.entity e1 on e1.id = pr.entity_id
    join erp.entity e2 on e2.id = pr.counterparty_entity_id
   order by 6 desc
$$;

comment on function erp.intercompany_position is
  'Receivable against payable between two companies of the organisation, the '
  'counterparty recognised by its party (erp.entity.party_id), not by code.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The rule
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.ownership_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  -- Every company is a party.
  select 'company_without_party', e.code, 'the company has no party; erp.ensure_entity_party() gives it one'
    from erp.entity e join t on t.tenant_id = e.tenant_id
   where e.party_id is null
  union all
  -- Nothing the company does not own is valued: the valuation quantity per
  -- item and site equals the owned quantity on hand.
  select 'unowned_stock_valued', i.code || ' @ ' || coalesce(s.code, '-'),
         format('valuation carries %s, the company owns %s', coalesce(v.quantity, 0), coalesce(o.qty, 0))
    from (select b.item_id, b.site_id, sum(b.quantity) as qty
            from erp.stock_balance b join t on t.tenant_id = b.tenant_id
           where b.owner_party_id = erp.entity_party_for_site(b.site_id)
           group by b.item_id, b.site_id having sum(b.quantity) <> 0) o
    full outer join erp.stock_valuation_report() v
      on v.item_id = o.item_id and v.site_id is not distinct from o.site_id
    join erp.item i on i.id = coalesce(v.item_id, o.item_id)
    left join erp.site s on s.id = coalesce(v.site_id, o.site_id)
   where coalesce(v.quantity, 0) <> coalesce(o.qty, 0)
  union all
  -- Nothing the company does not hold is counted.
  select 'count_of_stock_not_held', i.code || ' @ ' || coalesce(l.code, '-'),
         'an open count task stands over stock only somebody else holds'
    from erp.count_task ct join t on t.tenant_id = ct.tenant_id
    join erp.item i on i.id = ct.item_id
    left join erp.location l on l.id = ct.location_id
   where ct.status in ('open', 'counted', 'pending_approval')
     and exists (select 1 from erp.stock_balance b
                  where b.tenant_id = ct.tenant_id and b.site_id = ct.site_id
                    and b.location_id is not distinct from ct.location_id and b.item_id = ct.item_id
                    and b.quantity <> 0 and b.custody_party_id <> erp.entity_party_for_site(b.site_id))
     and not exists (select 1 from erp.stock_balance b
                      where b.tenant_id = ct.tenant_id and b.site_id = ct.site_id
                        and b.location_id is not distinct from ct.location_id and b.item_id = ct.item_id
                        and b.quantity <> 0 and b.custody_party_id = erp.entity_party_for_site(b.site_id))
  union all
  -- Structural, and said anyway: no movement or position without both.
  select 'movement_without_parties', m.movement_uid::text, 'a movement names no owner or no keeper'
    from erp.stock_movement m join t on t.tenant_id = m.tenant_id
   where m.owner_party_id is null or m.custody_party_id is null
  union all
  select 'position_without_parties', b.id::text, 'a position names no owner or no keeper'
    from erp.stock_balance b join t on t.tenant_id = b.tenant_id
   where b.owner_party_id is null or b.custody_party_id is null
$$;
revoke all on function erp.ownership_report() from public, anon, authenticated;

comment on function erp.ownership_report is
  'D9 findings for one organisation: a company without a party, stock valued '
  'that the company does not own, stock counted that the company does not '
  'hold, a movement or position without both parties.';

create or replace function erp.assert_ownership_carried()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_n      integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', r.finding, r.reference, r.detail), E'\n')
    into v_n, v_detail
    from erp.ownership_report() r;
  if v_n > 0 then
    raise exception 'CLOVEERP_OWNERSHIP_NOT_CARRIED: % finding(s); valuation follows ownership and counting follows custody (D9)', v_n
      using errcode = 'P0001', detail = v_detail,
            hint = 'erp.ownership_report() names each finding; give the company its party, or take the count task off stock it does not hold.';
  end if;
  return format('ownership: %s position(s) each with an owner and a keeper; valuation owned, counting held',
    (select count(*) from erp.stock_balance b where b.tenant_id = erp.require_tenant_id() and b.quantity <> 0));
end;
$$;
revoke all on function erp.assert_ownership_carried() from public, anon, authenticated;

comment on function erp.assert_ownership_carried() is
  'D9: every position and movement carries an owner and a keeper; nothing '
  'un-owned is valued; nothing un-held is counted. Per organisation.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('ownership_carried', 'Ownership and custody are carried', 'assertion', 'tenant',
   'assert_ownership_carried', '', 'ownership_report', '',
   'Every position and movement names who owns it and who holds it; valuation counts only what the organisation owns, counting only what it holds.', true, 93)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

-- D9 is bound to a check that can tell the difference.
delete from erp_ref.product_decision_check where decision_code = 'D9';
insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D9', 'erp', 'assert_ownership_carried',
   'Every position and movement carries an owner and a keeper; stock the organisation does not own is absent from valuation and stock it does not hold is absent from counts. Fails where either leaks.'),
  ('D9', 'erp_test', 'assert_ownership_suite',
   'Exercises consignment inbound (held, not owned), a third-party site (owned, not held), the split position key, counting across owners and intercompany identity by party.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.ownership_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases   integer := 0;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_site uuid; v_ccy char(3); v_company uuid;
  v_supplier uuid; v_recv uuid;
  v_item    uuid;
  v_grn     uuid; v_grn2 uuid; v_grn3 uuid;
  v_3pl     uuid; v_site3 uuid; v_loc3 uuid;
  v_e2      uuid; v_e2_party uuid;
  v_prog    uuid; v_prog3 uuid;
  v_msg     text; v_det text;
  v_n       integer; v_val bigint; v_q numeric;
  v_owner   uuid; v_keeper uuid; v_unit bigint;
begin
  begin
  -- Fixture: an organisation with the demonstration configuration and one item.
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-owner', 'Ownership suite', 'admin@zz-owner.test', 'Owner Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000d9', 'admin@zz-owner.test');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000d9')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id, e.base_currency, e.party_id into v_entity, v_ccy, v_company
    from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.site_type = 'warehouse' order by s.code limit 1;
  select l.id into v_recv from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site and l.location_type = 'receiving' limit 1;
  select pr.party_id into v_supplier from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;

  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
  select v_tenant, 'ZZ-OWN', 'Owned or held item', 'RAW', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
  returning id into v_item;

  -- 1. Every company is a party.
  v_cases := v_cases + 1;
  case_name := 'a company is a party from the moment it exists';
  passed := v_company is not null
        and exists (select 1 from erp.party p join erp.entity e on e.party_id = p.id where e.id = v_entity and p.code = e.code)
        and exists (select 1 from erp.party_role r where r.tenant_id = v_tenant and r.party_id = v_company and r.role_kind = 'internal')
        and erp.entity_party(v_entity) = v_company
        and erp.entity_party_for_site(v_site) = v_company;
  detail := format('company party %s, internal role present: %s', v_company,
                   exists (select 1 from erp.party_role r where r.party_id = v_company and r.role_kind = 'internal'));
  return next;

  -- 2. A receipt the company owns is owned, held and valued.
  v_cases := v_cases + 1;
  v_grn := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-OWN', '{}'::jsonb);
  perform erp.add_document_line(v_grn, v_item, 10, 1000, 'owned', current_date);
  perform erp.transition_document(v_grn, 'post', 'ownership suite');
  set constraints all immediate;
  select m.owner_party_id, m.custody_party_id into v_owner, v_keeper
    from erp.stock_movement m where m.tenant_id = v_tenant and m.document_id = v_grn limit 1;
  select coalesce(sum(v.value_minor), 0) into v_val from erp.stock_valuation_report() v where v.item_id = v_item;
  select count(*) filter (where r.difference_minor <> 0) into v_n from erp.inventory_reconciliation_report() r;
  case_name := 'a plain receipt is owned and held by the company and valued';
  passed := v_owner = v_company and v_keeper = v_company and v_val = 10000 and v_n = 0;
  detail := format('owner is company: %s, keeper is company: %s, value %s (expected 10000), %s account(s) out of balance',
                   v_owner = v_company, v_keeper = v_company, v_val, v_n);
  return next;

  -- 3. Consignment inbound: held, not owned, not valued, not posted.
  v_cases := v_cases + 1;
  v_grn2 := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-CONS', '{}'::jsonb);
  update erp.document set stock_owner_party_id = v_supplier where id = v_grn2;
  perform erp.add_document_line(v_grn2, v_item, 5, 900, 'consigned', current_date);
  perform erp.transition_document(v_grn2, 'post', 'ownership suite');
  set constraints all immediate;
  select m.owner_party_id, m.custody_party_id, m.unit_cost_minor into v_owner, v_keeper, v_unit
    from erp.stock_movement m where m.tenant_id = v_tenant and m.document_id = v_grn2 limit 1;
  select coalesce(sum(v.value_minor), 0) into v_val from erp.stock_valuation_report() v where v.item_id = v_item;
  select coalesce(sum(p.quantity), 0) into v_q from erp.stock_position p
   where p.tenant_id = v_tenant and p.item_id = v_item and p.owner_party_id = v_supplier and p.custody_party_id = v_company;
  select count(*) filter (where r.difference_minor <> 0) into v_n from erp.inventory_reconciliation_report() r;
  case_name := 'consignment inbound is held by the company, owned by the supplier, unvalued and unposted';
  passed := v_owner = v_supplier and v_keeper = v_company and v_unit is null
        and v_val = 10000 and v_q = 5 and v_n = 0
        and not exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.document_id = v_grn2);
  detail := format('owner is supplier: %s, keeper is company: %s, unit cost %s (expected none), value %s (expected 10000), consigned position %s, journal posted: %s',
                   v_owner = v_supplier, v_keeper = v_company, coalesce(v_unit::text, 'none'), v_val, v_q,
                   exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.document_id = v_grn2));
  return next;

  -- 4. The position key separates owners at one location.
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.stock_balance b
   where b.tenant_id = v_tenant and b.item_id = v_item and b.location_id = v_recv and b.quantity <> 0;
  v_msg := null;
  begin
    perform erp.assert_stock_reconciles();
    perform erp.assert_ownership_carried();
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'owned and consigned stock of one item in one location are two positions, and both reconcile';
  passed := v_n = 2 and v_msg is null;
  detail := format('%s position(s) at receiving (expected 2); %s', v_n, coalesce(v_msg, 'stock and ownership reconcile'));
  return next;

  -- 5. Counting follows custody: what the company holds is counted, whoever
  --    owns it, as one figure per location.
  v_cases := v_cases + 1;
  insert into erp.count_programme (tenant_id, code, name, site_id, kind, selector, status)
  values (v_tenant, 'zz_own_count', 'Ownership suite count', v_site, 'cycle', 'true'::jsonb, 'active')
  returning id into v_prog;
  v_n := erp.raise_count_tasks('zz_own_count');
  select ct.expected_quantity into v_q from erp.count_task ct
   where ct.tenant_id = v_tenant and ct.item_id = v_item and ct.location_id = v_recv and ct.status = 'open';
  case_name := 'held stock is counted whoever owns it, as one expected figure per location';
  passed := v_n = 1 and v_q = 15;
  detail := format('%s task(s) raised (expected 1), expected quantity %s (expected 15: 10 owned + 5 consigned)', v_n, v_q);
  return next;

  -- 6. A third-party site: owned, not held; one implicit location; not counted.
  v_cases := v_cases + 1;
  insert into erp.party (tenant_id, code, name, status) values (v_tenant, 'ZZ-3PL', 'Ownership suite logistics', 'active')
  returning id into v_3pl;
  insert into erp.party_role (tenant_id, party_id, role_kind, is_approved, status) values (v_tenant, v_3pl, 'agent', true, 'active');
  insert into erp.site (tenant_id, entity_id, code, name, site_type, operator_party_id)
  values (v_tenant, v_entity, 'ZZ-3PL', 'Provider warehouse', 'third_party', v_3pl)
  returning id into v_site3;
  v_grn3 := erp.create_document('goods_receipt', v_entity, v_site3, v_supplier, current_date, v_ccy, 'ZZ-GRN-3PL', '{}'::jsonb);
  perform erp.add_document_line(v_grn3, v_item, 8, 1000, 'at the provider', current_date);
  perform erp.transition_document(v_grn3, 'post', 'ownership suite');
  set constraints all immediate;
  select l.id into v_loc3 from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site3 and l.code = 'SITE';
  select m.owner_party_id, m.custody_party_id into v_owner, v_keeper
    from erp.stock_movement m where m.tenant_id = v_tenant and m.document_id = v_grn3 limit 1;
  select coalesce(sum(v.value_minor), 0) into v_val from erp.stock_valuation_report() v where v.item_id = v_item;
  insert into erp.count_programme (tenant_id, code, name, site_id, kind, selector, status)
  values (v_tenant, 'zz_3pl_count', 'Ownership suite provider count', v_site3, 'cycle', 'true'::jsonb, 'active')
  returning id into v_prog3;
  v_n := erp.raise_count_tasks('zz_3pl_count');
  select count(*) filter (where r.difference_minor <> 0) into v_q from erp.inventory_reconciliation_report() r;
  v_msg := null;
  begin
    perform erp.assert_ownership_carried();
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'stock at a provider''s site is owned and valued, held by the provider, posted into one implicit location, and not counted';
  passed := v_loc3 is not null and v_owner = v_company and v_keeper = v_3pl
        and v_val = 18000 and v_n = 0 and v_q = 0 and v_msg is null;
  detail := format('SITE location created: %s, owner is company: %s, keeper is provider: %s, value %s (expected 18000), %s task(s) raised at the provider (expected 0), %s out of balance; %s',
                   v_loc3 is not null, v_owner = v_company, v_keeper = v_3pl, v_val, v_n, v_q, coalesce(v_msg, 'ownership carried'));
  return next;

  -- 7. Intercompany by identity, not by code.
  v_cases := v_cases + 1;
  insert into erp.entity (tenant_id, code, name, base_currency)
  values (v_tenant, 'ZZ-E2', 'Second company', v_ccy)
  returning id, party_id into v_e2, v_e2_party;
  update erp.party set code = 'ZZ-E2-AS-A-CUSTOMER' where id = v_e2_party;
  insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                  party_id, currency, debit_minor, credit_minor, posting_date)
  select v_tenant, v_entity, l.id, 'receivable', a.id, v_e2_party, v_ccy, 12345, 0, current_date
    from erp.ledger l
    join erp.account a on a.tenant_id = l.tenant_id and a.entity_id = l.entity_id
   where l.tenant_id = v_tenant and l.entity_id = v_entity and l.is_primary and l.status = 'active'
     and a.control_kind = 'receivable' and a.status = 'active'
   order by a.code limit 1;
  select count(*) into v_n from erp.intercompany_position() ip
   where ip.to_entity = 'ZZ-E2' and ip.receivable_minor = 12345;
  case_name := 'a second company gets its party on creation and the intercompany position finds it by identity, not by code';
  passed := v_e2_party is not null and v_n = 1;
  detail := format('second company party %s (code renamed away from the company''s), %s intercompany pair(s) found (expected 1)',
                   v_e2_party, v_n);
  return next;

  -- 8. The assertion refuses a count task over stock the company does not hold.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    insert into erp.count_task (tenant_id, count_programme_id, site_id, location_id, item_id,
                                expected_quantity, committed_quantity, status)
    values (v_tenant, v_prog3, v_site3, v_loc3, v_item, 8, 0, 'open');
    begin
      perform erp.assert_ownership_carried();
    exception when others then
      get stacked diagnostics v_det = pg_exception_detail;
      v_msg := sqlerrm || ' ' || coalesce(v_det, '');
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a count task over stock only the provider holds is refused by the assertion';
  passed := v_msg like 'CLOVEERP_OWNERSHIP_NOT_CARRIED%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 9. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-owner')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000d9');
  detail := 'zz-owner rolled back with everything it owned and held';
  return next;

  if v_cases <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: ownership_suite ran % cases, expected 9', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_ownership_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _ownership on commit drop as
    select * from erp_test.ownership_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _ownership;
  drop table _ownership;
  if v_fail > 0 then
    raise exception E'CLOVEERP_OWNERSHIP_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: ownership_suite ran % cases, expected 9', v_all;
  end if;
  return format('ownership: %s/%s cases passed', v_all, v_all);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_ownership_suite();
select erp_test.assert_inventory_suite();
select erp_test.assert_costing_suite();
select erp_test.assert_stock_invariants();
select erp_test.assert_migration_cutover_suite();
select erp_test.assert_demo_history_suite();
select erp.assert_whole_database_reconciles();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_resource_coverage('en');
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

-- And the whole console, green.
do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
