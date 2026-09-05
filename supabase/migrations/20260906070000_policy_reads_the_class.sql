-- Policy reads the class.
--
-- Three decisions said that a behaviour is configuration, and in each case the
-- configuration existed and nothing read it.
--
-- D12: the level at which a handling unit carries an identity, and how it is
-- counted, is policy per product class, site and process step. Containers nest
-- without limit (erp.container has a path and a depth), but container_type was
-- free text with no vocabulary, nothing in the product built a container (the
-- device task handling_unit_build says so in its own register), and D12 was
-- bound to an assertion whose report has no clause about containers at all.
-- Now there is a vocabulary of levels (erp_ref.container_type), a policy row
-- per class, site and step (erp.container_identity_policy) that promotes like
-- every other configuration kind, a function that builds a unit and refuses
-- one finer than the policy or nested inside a smaller one, and a count that
-- is bound to the same policy: a homogeneous container at or above the
-- identity level is one thing to count and asserting it present asserts its
-- contents; a mixed one counts by unit inside. Units keep the policy they were
-- built under.
--
-- D13: allocation scope is configuration. stock.allocation_policy was declared
-- with a schema and defaults — first-expiring or first-in, one batch per
-- order, nearest location — and read by nothing: erp.commit_allocation ordered
-- by the item's own FEFO flag and then by quantity, never subtracted what other
-- orders had already committed, and wrote a policy code nobody read. It now
-- reads the policy at site scope: FEFO by expiry, FIFO and LIFO by first
-- receipt into the position (a fact the position now carries), the method
-- first and the nearest pickable location deciding between positions the
-- method cannot separate — same batch, or receipts on the same day in the
-- site's own clock — so a warehouse picks the front of the rack without ever
-- shipping later stock ahead of earlier. One batch per order binds every line
-- of the order to the batch the first line took, and refuses by name when no
-- single batch covers a line. Committed lines are subtracted, blocked
-- locations are skipped, and the method used is written on the allocation.
--
-- Phase 4a's finding: a count task had no owner, so a variance on consigned
-- stock resolved to the company and, count_adjustment being allowed to go
-- negative, left a silent negative owned position beside an untouched
-- consigned one. Tasks are raised per owner and carry it, and the adjustment
-- posts against the right position with no cost, because stock the company
-- does not own is not on its books.
--
-- Deferred, and said here: erp.write_off_stock() still resolves the owner to
-- the company (its signature is pinned by a wrapper, a device handler and the
-- coverage list; it gains an owner in Phase 4c with the consignment order
-- types); the device count handler still needs a figure, so a scanner cannot
-- yet say "present"; five other declared configuration keys are read by
-- nothing and no assertion notices (a general clause is later work);
-- allocation statuses picked, released and consumed are never assigned; the
-- backfilled first receipt is all-time, not since the position last emptied.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The levels a handling unit can carry an identity at
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_ref.container_type (
  code          text primary key,
  name          text not null,
  level_rank    integer not null,
  is_buildable  boolean not null default true,
  description   text not null,
  seq           integer not null default 100,
  registered_at timestamptz not null default now()
);

select erp_meta.register_table('erp_ref', 'container_type', 'product_content',
  'D12. The levels at which a handling unit can carry an identity, coarsest last.');

insert into erp_ref.container_type (code, name, level_rank, is_buildable, description, seq) values
  ('none',          'No handling-unit identity', -1, false, 'Stock is identified by product, batch and serial only; no container carries an identity.', 0),
  ('unit',          'Unit',                       0, false, 'The saleable unit itself. A level, not a container anybody builds.', 10),
  ('case',          'Case',                       1, true,  'A case or inner pack of units.', 20),
  ('carton',        'Carton',                     1, true,  'A carton of units; the same level as a case under another name.', 21),
  ('pallet',        'Pallet',                     2, true,  'A pallet of cases or of loose units.', 30),
  ('master_pallet', 'Master pallet',              3, true,  'A pallet of pallets, or a stack built for one consignment.', 40)
on conflict (code) do update
  set name = excluded.name, level_rank = excluded.level_rank, is_buildable = excluded.is_buildable,
      description = excluded.description, seq = excluded.seq;

-- Every unit that exists names a level, then the column says so.
do $fk$
begin
  if exists (select 1 from erp.container c
              where not exists (select 1 from erp_ref.container_type t where t.code = c.container_type)) then
    raise exception 'CLOVEERP_CONTAINER_TYPE_UNKNOWN: a handling unit names a type outside erp_ref.container_type'
      using hint = 'Add the type to the vocabulary or retype the unit before this migration runs.';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'container_container_type_fkey') then
    alter table erp.container
      add constraint container_container_type_fkey
      foreign key (container_type) references erp_ref.container_type(code);
  end if;
end
$fk$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The policy, promotable
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp.container_identity_policy (
  id               uuid not null default gen_random_uuid(),
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  code             text not null,
  name             text not null,
  item_class       text,
  site_id          uuid,
  device_task_code text references erp_ref.device_task(code),
  identity_level   text not null default 'none' references erp_ref.container_type(code),
  count_method     text not null default 'by_unit'
                   constraint container_identity_policy_count_method_known
                   check (count_method in ('by_unit', 'by_container', 'hybrid')),
  effective_from   date not null default current_date,
  status           erp.record_status not null default 'active',
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade,
  constraint container_identity_policy_counts_what_it_identifies
    check (count_method = 'by_unit' or identity_level <> 'none')
);

create index if not exists container_identity_policy_scope
  on erp.container_identity_policy (tenant_id, site_id, device_task_code) where status = 'active';

comment on table erp.container_identity_policy is
  'D12. Per product class (comma list), site and process step: the finest level '
  'at which a handling unit carries an identity, and how stock in units is '
  'counted. Narrowing, most specific wins; all null is the organisation''s default.';

select erp_meta.register_table('erp', 'container_identity_policy', 'tenant_scoped',
  'D12. Handling-unit identity depth and count method, per class, site and step.');

insert into erp_meta.promotable_surface (schema_name, table_name, object_kind, rationale) values
  ('erp', 'container_identity_policy', 'container_identity_policy',
   'D12 says changing the identity level is a configuration change, not a development project: '
   'it moves by change set and is guarded on a live environment like every configuration row.')
on conflict (schema_name, table_name) do update
  set object_kind = excluded.object_kind, rationale = excluded.rationale;

-- A unit keeps the policy it was built under.
alter table erp.container add column if not exists identity_policy_id uuid;
do $fk$
begin
  if not exists (select 1 from pg_constraint where conname = 'container_identity_policy_fkey') then
    alter table erp.container
      add constraint container_identity_policy_fkey
      foreign key (tenant_id, identity_policy_id) references erp.container_identity_policy (tenant_id, id)
      on delete restrict;
  end if;
end
$fk$;
comment on column erp.container.identity_policy_id is
  'The identity policy in force when the unit was built. Null for a unit built before any policy existed.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The resolver
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.identity_policy_for(p_item_id uuid, p_site_id uuid, p_device_task_code text)
returns table(policy_id uuid, identity_level text, level_rank integer, count_method text)
language sql
stable
set search_path = ''
as $$
  with best as (
    select p.id, p.identity_level, ct.level_rank, p.count_method
      from erp.container_identity_policy p
      join erp_ref.container_type ct on ct.code = p.identity_level
      left join erp.item i on i.id = p_item_id
     where p.tenant_id = erp.require_tenant_id()
       and p.status = 'active'
       and p.effective_from <= current_date
       and (p.site_id is null or p.site_id = p_site_id)
       and (p.item_class is null
            or i.item_class = any (string_to_array(replace(p.item_class, ' ', ''), ',')))
       and (p.device_task_code is null or p.device_task_code = p_device_task_code)
     order by (p.site_id is not null) desc,
              (p.item_class is not null) desc,
              (p.device_task_code is not null) desc,
              p.effective_from desc,
              p.code
     limit 1
  )
  select * from best
  union all
  select null::uuid, 'none', -1, 'by_unit' where not exists (select 1 from best)
$$;
revoke all on function erp.identity_policy_for(uuid, uuid, text) from public, anon, authenticated;

comment on function erp.identity_policy_for is
  'The identity policy in force for an item at a site in a process step: site '
  'beats class beats step beats the later date. No policy is "none, count by unit".';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Building a unit
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.create_handling_unit(
  p_site_id             uuid,
  p_location_id         uuid,
  p_container_type      text,
  p_parent_container_id uuid default null,
  p_code                text default null,
  p_item_id             uuid default null)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  ct       erp_ref.container_type%rowtype;
  pt       erp_ref.container_type%rowtype;
  parent   erp.container%rowtype;
  pol      record;
  v_loc    uuid := p_location_id;
  v_id     uuid;
begin
  perform erp.authorise('inventory.move', null, p_site_id, null, 'location', p_location_id);

  select * into ct from erp_ref.container_type where code = p_container_type;
  if not found then
    raise exception 'CLOVEERP_CONTAINER_TYPE_UNKNOWN: % is not a handling-unit level', p_container_type
      using errcode = '23503',
            hint = 'Name a code from erp_ref.container_type: case, carton, pallet or master_pallet.';
  end if;
  if not ct.is_buildable then
    raise exception 'CLOVEERP_CONTAINER_TYPE_NOT_BUILDABLE: % is a level, not a unit anybody builds', p_container_type
      using errcode = '23514',
            hint = 'Build a case, carton, pallet or master pallet; "unit" and "none" describe stock that has no container.';
  end if;

  if p_parent_container_id is not null then
    select * into parent from erp.container
     where tenant_id = v_tenant and id = p_parent_container_id;
    if not found then
      raise exception 'CLOVEERP_UNKNOWN_CONTAINER: %', p_parent_container_id using errcode = '23503',
        hint = 'The parent unit does not exist in this organisation.';
    end if;
    select * into pt from erp_ref.container_type where code = parent.container_type;
    if pt.level_rank <= ct.level_rank then
      raise exception 'CLOVEERP_CONTAINER_NESTING_INVERTED: a % cannot be put inside a %', ct.code, pt.code
        using errcode = '23514',
              hint = 'A unit nests only inside a coarser one: a case in a pallet, a pallet in a master pallet.';
    end if;
    v_loc := coalesce(v_loc, parent.location_id);
  end if;

  if v_loc is null or not exists (select 1 from erp.location l
                                    where l.tenant_id = v_tenant and l.id = v_loc and l.site_id = p_site_id) then
    raise exception 'CLOVEERP_CONTAINER_LOCATION_NOT_AT_SITE: the location is not at the site the unit is built at'
      using errcode = '23514',
            hint = 'Build the unit at a location of the site, or inside a parent that has one.';
  end if;

  select * into pol from erp.identity_policy_for(p_item_id, p_site_id, 'handling_unit_build');
  if pol.level_rank >= 0 and ct.level_rank < pol.level_rank then
    raise exception 'CLOVEERP_IDENTITY_LEVEL_NOT_POLICY: identity is captured at % here, and a % is finer than that',
      pol.identity_level, ct.code
      using errcode = '23514',
            hint = 'The identity policy names the finest level that carries an identity for this class, site and step. Build at that level or above, or promote a policy that captures identity finer here.';
  end if;

  insert into erp.container (tenant_id, code, container_type, parent_container_id, site_id, location_id,
                             identity_policy_id, status, created_by)
  values (v_tenant,
          coalesce(nullif(trim(p_code), ''), 'HU-' || upper(left(replace(gen_random_uuid()::text, '-', ''), 12))),
          ct.code, p_parent_container_id, p_site_id, v_loc, pol.policy_id, 'active', erp.current_principal_id())
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function erp.create_handling_unit(uuid, uuid, text, uuid, text, uuid) from public, anon, authenticated;

comment on function erp.create_handling_unit is
  'Closes a new handling unit at a site and location, optionally inside a '
  'coarser one, at or above the level the identity policy captures for the '
  'product class, site and the handling_unit_build step. The unit records the '
  'policy it was built under.';

-- The device task that had no function has one.
update erp_ref.device_task_handler
   set module_code = 'inventory',
       sql_function = 'create_handling_unit',
       arguments = '[{"arg":"p_site_id","type":"uuid","key":"site_id","required":true},
                     {"arg":"p_location_id","type":"uuid","key":"location_id","required":true},
                     {"arg":"p_container_type","type":"text","key":"container_type","required":true},
                     {"arg":"p_parent_container_id","type":"uuid","key":"parent_container_id"},
                     {"arg":"p_code","type":"text","key":"code"},
                     {"arg":"p_item_id","type":"uuid","key":"item_id"}]'::jsonb,
       not_handled_reason = null,
       note = 'Inbound. Closes a new unit at the level the identity policy captures for the product class, '
              'site and step; a unit finer than policy, or nested inside a smaller one, is refused by name.'
 where device_task_code = 'handling_unit_build';

-- The drain suite pinned "4 not yet handled"; one of them is handled.
do $drain$
declare
  v_def text := pg_get_functiondef('erp_test.device_drain_suite()'::regprocedure);
  v_old text := '17 apply%1 read only, 4 not yet handled';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'CLOVEERP_NEEDLE_NOT_FOUND: erp_test.device_drain_suite no longer pins the handler tally this migration moves';
  end if;
  execute replace(v_def, v_old, '18 apply%1 read only, 3 not yet handled');
end
$drain$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Counting follows the policy, and carries the owner
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.count_task
  add column if not exists container_id     uuid,
  add column if not exists owner_party_id   uuid,
  add column if not exists counts_container boolean not null default false;

do $fk$
begin
  if not exists (select 1 from pg_constraint where conname = 'count_task_container_fkey') then
    alter table erp.count_task
      add constraint count_task_container_fkey
      foreign key (tenant_id, container_id) references erp.container (tenant_id, id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'count_task_owner_party_fkey') then
    alter table erp.count_task
      add constraint count_task_owner_party_fkey
      foreign key (tenant_id, owner_party_id) references erp.party (tenant_id, id) on delete restrict;
  end if;
end
$fk$;

comment on column erp.count_task.container_id is
  'The handling unit the task counts, or the unit whose contents are counted by unit when it is mixed.';
comment on column erp.count_task.owner_party_id is
  'Who owns the stock counted; a variance posts against that owner''s position. Null means the company.';
comment on column erp.count_task.counts_container is
  'The task counts a whole homogeneous handling unit: recording it present asserts its contents.';

-- Restated from 20260906060000 (the check first): tasks are raised over what
-- the company holds, per owner, and per handling unit where the policy for the
-- count step says a unit is one thing to count.
do $check$
declare v_def text := pg_get_functiondef('erp.raise_count_tasks(text)'::regprocedure);
begin
  if position('and b.custody_party_id = erp.entity_party_for_site(b.site_id)' in v_def) = 0
     or position('and t.location_id is not distinct from r.location_id);' in v_def) = 0 then
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
       where t.tenant_id = v_tenant and t.status in ('open','counted','pending_approval')
         and t.item_id = r.item_id
         and t.location_id is not distinct from r.location_id
         and t.owner_party_id is not distinct from r.owner_party_id
         and t.container_id is not distinct from r.container_id);

    select coalesce(sum(al.quantity), 0) into v_committed
      from erp.allocation_line al
      join erp.allocation a on a.id = al.allocation_id
     where al.tenant_id = v_tenant
       and a.item_id = r.item_id
       and al.location_id is not distinct from r.location_id
       and al.status in ('reserved', 'committed', 'picked');

    insert into erp.count_task (
      tenant_id, count_programme_id, site_id, location_id, item_id, batch_id,
      expected_quantity, committed_quantity, status,
      owner_party_id, container_id, counts_container)
    values (v_tenant, pg.id, r.site_id, r.location_id, r.item_id, r.batch_id,
            r.quantity, v_committed, 'open',
            r.owner_party_id, r.container_id, r.counts_container)
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
  'among what the company holds (D9), one per owner, and one per handling unit '
  'where the identity policy for the count step makes a unit one thing to count '
  '(D12); a mixed unit counts by unit inside. Records what was committed and '
  'takes a soft lock that warns rather than blocks.';

-- A whole unit recorded present asserts its contents. Deployed body, one needle.
do $record$
declare
  v_def text := pg_get_functiondef('erp.record_count(uuid, numeric)'::regprocedure);
  v_n   text := E'  select * into pg from erp.count_programme where id = t.count_programme_id;\n';
begin
  if position(v_n in v_def) = 0 then
    raise exception 'CLOVEERP_NEEDLE_NOT_FOUND: erp.record_count is not the body this migration patches';
  end if;
  execute replace(v_def, v_n,
       E'  if p_quantity is null then\n'
    || E'    if not coalesce(t.counts_container, false) then\n'
    || E'      raise exception ''CLOVEERP_COUNT_NEEDS_A_QUANTITY: % counts units, not a whole handling unit'', p_task_id\n'
    || E'        using errcode = ''23514'',\n'
    || E'              hint = ''Only a task that counts a whole handling unit may be recorded without a figure (present means its contents are there). Record how many.'';\n'
    || E'    end if;\n'
    || E'    p_quantity := t.expected_quantity + t.movement_during - t.committed_quantity;\n'
    || E'  end if;\n'
    || v_n);
end
$record$;

-- The posting, restated: the variance moves the owner's position, in the unit
-- the task counted, and costs only what the company owns. The check first.
do $check$
declare v_def text := pg_get_functiondef('erp.post_count(uuid)'::regprocedure);
begin
  if position(E'v_uom    uuid;\n  v_move   bigint;\nbegin' in v_def) = 0
     or (select count(*) from regexp_matches(v_def, E'returning id into v_move;\n    perform erp.post_movement_finance\\(v_move\\);', 'g')) <> 2 then
    raise exception 'CLOVEERP_COUNT_POSTING_UNRECOGNISED: erp.post_count is not the body this migration restates';
  end if;
end
$check$;

create or replace function erp.post_count(p_task_id uuid)
returns numeric
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  t         erp.count_task%rowtype;
  v_cost    bigint;
  v_uom     uuid;
  v_move    bigint;
  v_company uuid;
  v_owner   uuid;
  v_ccy     char(3);
begin
  select * into t from erp.count_task
   where tenant_id = v_tenant and id = p_task_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_COUNT_TASK: %', p_task_id using errcode = '23503',
      hint = 'The count task does not exist in this organisation.';
  end if;

  if t.status <> 'approved' then
    raise exception
      'CLOVEERP_COUNT_NOT_APPROVED: % is %, and a variance is not written into '
      'the ledger on one person''s word', p_task_id, t.status
      using errcode = '42501',
            hint = 'Record the count; within tolerance it approves itself, otherwise the programme''s approval chain decides.';
  end if;

  perform erp.authorise('inventory.adjust', null, t.site_id, null,
                        'count_task', p_task_id);

  if coalesce(t.variance, 0) = 0 then
    update erp.count_task set status = 'posted', posted_at = now(), updated_at = now()
     where id = p_task_id;
    update erp.count_lock set released_at = now(), updated_at = now()
     where tenant_id = v_tenant and count_task_id = p_task_id and released_at is null;
    return 0;
  end if;

  select i.stock_uom_id into v_uom from erp.item i where i.id = t.item_id;
  v_company := erp.entity_party_for_site(t.site_id);
  v_owner   := coalesce(t.owner_party_id, v_company);
  v_ccy     := coalesce((select e.base_currency from erp.entity e
                          join erp.site s on s.entity_id = e.id where s.id = t.site_id), 'GBP');

  -- An adjustment is a movement like any other, which is what keeps
  -- erp.assert_stock_reconciles() true through a count. Stock the company does
  -- not own moves without a cost: it was never on the books.
  if t.variance > 0 then
    v_cost := case when v_owner = v_company then
                erp.receive_cost(t.item_id, t.site_id, t.variance,
                  coalesce((select c.unit_cost_minor from erp.item_cost c
                             where c.tenant_id = v_tenant and c.item_id = t.item_id
                               and c.site_id is not distinct from t.site_id), 0),
                  v_ccy, t.batch_id, null)
              end;
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, container_id,
      to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency,
      reason_code, owner_party_id)
    select v_tenant, s.entity_id, t.site_id, 'count_adjustment', t.item_id, t.batch_id, t.container_id,
           t.location_id, 'available', t.variance, v_uom, v_cost, v_ccy,
           'count_variance', v_owner
      from erp.site s where s.id = t.site_id
    returning id into v_move;
    perform erp.post_movement_finance(v_move);
  else
    v_cost := case when v_owner = v_company then erp.issue_cost(t.item_id, t.site_id, -t.variance) end;
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, container_id,
      from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
      reason_code, owner_party_id)
    select v_tenant, s.entity_id, t.site_id, 'count_adjustment', t.item_id, t.batch_id, t.container_id,
           t.location_id, 'available', -t.variance, v_uom, v_cost, v_ccy,
           'count_variance', v_owner
      from erp.site s where s.id = t.site_id
    returning id into v_move;
    perform erp.post_movement_finance(v_move);
  end if;

  update erp.count_task set status = 'posted', posted_at = now(), updated_at = now()
   where id = p_task_id;
  update erp.count_lock set released_at = now(), updated_at = now()
   where tenant_id = v_tenant and count_task_id = p_task_id and released_at is null;

  return t.variance;
end;
$$;

comment on function erp.post_count(uuid) is
  'Posts an approved count variance as a count_adjustment movement against the '
  'owner''s position, in the handling unit the task counted, costed only when '
  'the company owns the stock, and through the stock_adjustment posting rule.';

-- The ownership suite pinned one task over ten owned and five consigned; a
-- task per owner makes that two tasks summing fifteen. Its own words move.
do $own$
declare
  v_def text := pg_get_functiondef('erp_test.ownership_suite()'::regprocedure);
  v_a text := 'select ct.expected_quantity into v_q from erp.count_task ct';
  v_b text := 'passed := v_n = 1 and v_q = 15;';
  v_c text := '%s task(s) raised (expected 1), expected quantity %s (expected 15: 10 owned + 5 consigned)';
  v_d text := 'held stock is counted whoever owns it, as one expected figure per location';
begin
  if position(v_a in v_def) = 0 or position(v_b in v_def) = 0
     or position(v_c in v_def) = 0 or position(v_d in v_def) = 0 then
    raise exception 'CLOVEERP_NEEDLE_NOT_FOUND: erp_test.ownership_suite no longer carries the count case this migration re-states';
  end if;
  v_def := replace(v_def, v_a, 'select sum(ct.expected_quantity) into v_q from erp.count_task ct');
  v_def := replace(v_def, v_b, 'passed := v_n = 2 and v_q = 15;');
  v_def := replace(v_def, v_c, '%s task(s) raised (expected 2, one per owner), expected quantity %s (expected 15: 10 owned + 5 consigned)');
  v_def := replace(v_def, v_d, 'held stock is counted whoever owns it, one task per owner so a variance posts against the right position');
  execute v_def;
end
$own$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Allocation reads the policy
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.stock_balance add column if not exists first_received_at timestamptz;
comment on column erp.stock_balance.first_received_at is
  'When stock first arrived in this position; reset when a position that had '
  'emptied fills again. A cached fact for first-in and last-in allocation, not a quantity.';

do $backfill$
begin
  perform set_config('erp.ledger_write', 'on', true);
  update erp.stock_balance b
     set first_received_at = coalesce(
           (select min(m.occurred_at) from erp.stock_movement m
             where m.tenant_id = b.tenant_id and m.site_id = b.site_id
               and m.to_location_id = b.location_id and m.item_id = b.item_id
               and m.batch_id is not distinct from b.batch_id
               and m.serial_id is not distinct from b.serial_id
               and m.container_id is not distinct from b.container_id
               and m.to_status = b.stock_status
               and m.owner_party_id = b.owner_party_id
               and m.custody_party_id = b.custody_party_id),
           b.updated_at)
   where b.first_received_at is null and b.quantity <> 0;
  perform set_config('erp.ledger_write', '', true);
end
$backfill$;

-- The applier, restated from 20260906060000 with the arrival stamped on the
-- inbound side. The check first.
do $check$
declare v_def text := pg_get_functiondef('erp.apply_stock_movement()'::regprocedure);
begin
  if (select count(*) from regexp_matches(v_def, 'new.serial_id, new.container_id, new.owner_party_id, new.custody_party_id,', 'g')) <> 2 then
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
      container_id, owner_party_id, custody_party_id, stock_status, quantity, first_received_at)
    values (
      new.tenant_id, new.site_id, new.to_location_id, new.item_id, new.batch_id,
      new.serial_id, new.container_id, new.owner_party_id, new.custody_party_id,
      new.to_status, new.quantity, new.occurred_at)
    on conflict (tenant_id, site_id, location_id, item_id,
                 coalesce(batch_id,     '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(serial_id,    '00000000-0000-0000-0000-000000000000'::uuid),
                 coalesce(container_id, '00000000-0000-0000-0000-000000000000'::uuid),
                 owner_party_id, custody_party_id, stock_status)
      do update set quantity = b.quantity + excluded.quantity,
                    -- A position that had emptied starts its clock again.
                    first_received_at = case when b.quantity <= 0 then excluded.first_received_at
                                             else coalesce(b.first_received_at, excluded.first_received_at) end,
                    updated_at = now();
  end if;

  perform set_config('erp.ledger_write', '', true);
  return new;
end;
$$;

-- Stage two of allocation, restated: the policy decides, the method first.
create or replace function erp.commit_allocation(
  p_allocation_id uuid,
  p_location_id   uuid default null,
  p_batch_id      uuid default null)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  al        erp.allocation%rowtype;
  it        erp.item%rowtype;
  r         record;
  v_left    numeric;
  v_take    numeric;
  v_lines   integer := 0;
  v_policy  jsonb;
  v_method  text;
  v_single  boolean;
  v_nearest boolean;
  v_batch   uuid := p_batch_id;
  v_sibling_locs uuid[];
  v_tz      text;
begin
  select * into al from erp.allocation
   where tenant_id = v_tenant and id = p_allocation_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_ALLOCATION: %', p_allocation_id using errcode = '23503',
      hint = 'The reservation does not exist in this organisation.';
  end if;

  if al.status <> 'reserved' then
    raise exception 'CLOVEERP_ALLOCATION_NOT_RESERVED: % is %', p_allocation_id, al.status
      using errcode = '23514',
            hint = 'Only a reservation is committed to specific stock; a committed or cancelled allocation is not committed again.';
  end if;

  perform erp.authorise('sales.despatch', al.entity_id, al.site_id, null,
                        'allocation', p_allocation_id);

  select * into it from erp.item where id = al.item_id;
  select coalesce(s.timezone, 'UTC') into v_tz from erp.site s where s.id = al.site_id;

  -- The policy at site scope (D13). A code passed at reservation wins; the
  -- item's own FEFO flag, being a statement about that item, wins over a site
  -- policy that says otherwise; an item without expiry cannot be FEFO.
  v_policy := coalesce(erp.config_value('stock.allocation_policy', null, null, al.entity_id, al.site_id), '{}'::jsonb);
  v_method := lower(coalesce(
    nullif(al.policy_code, ''),
    case when it.is_fefo then 'fefo'
         when it.has_expiry then v_policy ->> 'expiry_controlled'
         else v_policy ->> 'default' end,
    case when it.has_expiry then 'fefo' else 'fifo' end));
  if v_method = 'fefo' and not it.has_expiry then
    v_method := 'fifo';
  end if;
  if v_method not in ('fefo', 'fifo', 'lifo') then
    raise exception 'CLOVEERP_ALLOCATION_METHOD_UNKNOWN: % is not a way to choose stock', v_method
      using errcode = '23514',
            hint = 'stock.allocation_policy names fefo, fifo or lifo for expiry-controlled stock and for the rest.';
  end if;
  v_single  := coalesce((v_policy ->> 'single_batch_per_order')::boolean, false) and it.is_batch_controlled;
  v_nearest := coalesce((v_policy ->> 'prefer_nearest_location')::boolean, true);

  v_left := al.quantity - coalesce(al.unmet_quantity, 0);

  -- The order's other lines: where they pick from, and the batch they took.
  select array_agg(distinct l.location_id) into v_sibling_locs
    from erp.allocation_line l
    join erp.allocation a on a.tenant_id = l.tenant_id and a.id = l.allocation_id
   where a.tenant_id = v_tenant and a.document_id = al.document_id and a.id <> al.id
     and a.status in ('committed', 'picked') and l.status in ('committed', 'picked');

  if v_single and v_batch is null then
    select l.batch_id into v_batch
      from erp.allocation_line l
      join erp.allocation a on a.tenant_id = l.tenant_id and a.id = l.allocation_id
     where a.tenant_id = v_tenant and a.document_id = al.document_id and a.id <> al.id
       and a.item_id = al.item_id and l.batch_id is not null
       and a.status in ('committed', 'picked') and l.status in ('committed', 'picked')
     order by l.created_at limit 1;
  end if;

  -- One batch per order: the first batch by method that covers the line.
  if v_single and v_batch is null then
    select x.batch_id into v_batch
      from (select b.batch_id,
                   sum(b.quantity - coalesce(c.committed, 0)) as available,
                   min(bt.expires_on) as expires_on,
                   min(b.first_received_at) as first_received_at
              from erp.stock_balance b
              join erp.location l on l.id = b.location_id
              left join erp.batch bt on bt.id = b.batch_id
              left join lateral (
                select sum(al2.quantity) as committed
                  from erp.allocation_line al2
                  join erp.allocation a2 on a2.tenant_id = al2.tenant_id and a2.id = al2.allocation_id
                 where al2.tenant_id = b.tenant_id and al2.location_id = b.location_id
                   and al2.batch_id is not distinct from b.batch_id
                   and al2.stock_status = b.stock_status
                   and a2.item_id = b.item_id
                   and a2.status in ('committed', 'picked') and al2.status in ('committed', 'picked')) c on true
             where b.tenant_id = v_tenant and b.item_id = al.item_id and b.site_id = al.site_id
               and b.stock_status = 'available' and b.batch_id is not null
               and l.status = 'active' and not l.is_blocked
               and (p_location_id is null or b.location_id = p_location_id)
             group by b.batch_id
            having sum(b.quantity - coalesce(c.committed, 0)) >= v_left) x
     order by case when v_method = 'fefo' then x.expires_on end asc nulls last,
              case when v_method = 'fifo' then x.first_received_at end asc nulls last,
              case when v_method = 'lifo' then x.first_received_at end desc nulls last,
              x.available desc
     limit 1;
    if v_batch is null then
      raise exception 'CLOVEERP_SINGLE_BATCH_SHORT: no single batch of % holds % at this site', it.code, v_left
        using errcode = '23514',
              hint = 'The site''s stock.allocation_policy says one batch per order. Commit with p_batch_id to accept a batch that is short, split the order line, or switch single_batch_per_order off for the site.';
    end if;
  end if;

  for r in
    select b.location_id, b.batch_id,
           b.quantity - coalesce(c.committed, 0) as available
      from erp.stock_balance b
      join erp.location l on l.id = b.location_id
      left join erp.batch bt on bt.id = b.batch_id
      left join lateral (
        select sum(al2.quantity) as committed
          from erp.allocation_line al2
          join erp.allocation a2 on a2.tenant_id = al2.tenant_id and a2.id = al2.allocation_id
         where al2.tenant_id = b.tenant_id and al2.location_id = b.location_id
           and al2.batch_id is not distinct from b.batch_id
           and al2.stock_status = b.stock_status
           and a2.item_id = b.item_id
           and a2.status in ('committed', 'picked') and al2.status in ('committed', 'picked')) c on true
     where b.tenant_id = v_tenant and b.item_id = al.item_id
       and b.site_id = al.site_id and b.stock_status = 'available'
       and b.quantity - coalesce(c.committed, 0) > 0
       and l.status = 'active' and not l.is_blocked
       and (p_location_id is null or b.location_id = p_location_id)
       and (v_batch is null or b.batch_id = v_batch)
     order by
       -- The method first: expiry, or the day the stock first arrived in the
       -- site's own clock.
       case when v_method = 'fefo' then bt.expires_on end asc nulls last,
       case when v_method = 'fifo' then (b.first_received_at at time zone v_tz)::date end asc nulls last,
       case when v_method = 'lifo' then (b.first_received_at at time zone v_tz)::date end desc nulls last,
       -- Then the nearest: a pick face before bulk, and a location the order
       -- is already picking from before another.
       case when v_nearest then (not coalesce(l.is_pickable, false))::int else 0 end,
       case when v_nearest then (b.location_id <> all (coalesce(v_sibling_locs, '{}'::uuid[])))::int else 0 end,
       -- Then the exact moment, so two positions never tie by accident.
       case when v_method = 'lifo' then b.first_received_at end desc nulls last,
       b.first_received_at asc nulls last,
       l.code, b.quantity desc
  loop
    exit when v_left <= 0;
    v_take := least(v_left, r.available);

    insert into erp.allocation_line (
      tenant_id, allocation_id, location_id, batch_id, stock_status,
      quantity, status)
    values (v_tenant, p_allocation_id, r.location_id, r.batch_id, 'available',
            v_take, 'committed');

    v_left := v_left - v_take;
    v_lines := v_lines + 1;
  end loop;

  if v_lines = 0 then
    raise exception
      'CLOVEERP_NOTHING_TO_COMMIT: nothing available matches the scope asked for'
      using errcode = '23514',
            hint = 'Widen the location or batch asked for, or wait for a receipt; what is on hand is already committed to other orders.';
  end if;

  update erp.allocation
     set status = 'committed',
         policy_code = v_method,
         unmet_quantity = coalesce(unmet_quantity, 0) + greatest(v_left, 0),
         updated_at = now()
   where id = p_allocation_id;

  return v_lines;
end;
$$;

comment on function erp.commit_allocation is
  'Stage two of allocation: commits a reservation to specific stock by the '
  'site''s stock.allocation_policy (D13) — FEFO by expiry, FIFO or LIFO by the '
  'day the stock first arrived, the nearest pickable location between positions '
  'the method cannot separate, one batch per order where the policy says so — '
  'subtracting what other orders already committed. Writes the method used.';

-- D13's report clause: a site with stock whose allocation policy names a
-- method the product does not have. Deployed body, one needle.
do $sales$
declare
  v_def text := pg_get_functiondef('erp.sales_configuration_report()'::regprocedure);
  v_n   text := E'   where p.price_kind = ''contract'' and p.party_role_id is null\n';
begin
  if position(v_n in v_def) = 0 then
    raise exception 'CLOVEERP_NEEDLE_NOT_FOUND: erp.sales_configuration_report is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_n
    || E'  union all\n'
    || E'  select ''a site''''s allocation policy names a method the product does not have'',\n'
    || E'         s.code,\n'
    || E'         format(''expiry_controlled %s, default %s'', pol ->> ''expiry_controlled'', pol ->> ''default'')\n'
    || E'    from erp.site s\n'
    || E'    cross join lateral (select coalesce(\n'
    || E'      (select cv.value from erp.config_object co\n'
    || E'         join erp.config_version cv on cv.tenant_id = co.tenant_id and cv.config_object_id = co.id\n'
    || E'          and cv.status = ''active''\n'
    || E'          and daterange(cv.effective_from, cv.effective_to, ''[)'') @> current_date\n'
    || E'        where co.tenant_id = s.tenant_id and co.config_type_code = ''stock.allocation_policy''\n'
    || E'          and co.status = ''active'' and co.code is null\n'
    || E'          and (co.site_id is null or co.site_id = s.id)\n'
    || E'          and (co.entity_id is null or co.entity_id = s.entity_id)\n'
    || E'        order by (co.site_id is not null) desc, (co.entity_id is not null) desc limit 1),\n'
    || E'      (select ct.default_value from erp_ref.config_type ct where ct.code = ''stock.allocation_policy'')) as pol) x\n'
    || E'   where s.status = ''active''\n'
    || E'     and exists (select 1 from erp.stock_balance b where b.site_id = s.id and b.quantity <> 0)\n'
    || E'     and not (coalesce(pol ->> ''expiry_controlled'', '''') in (''fefo'', ''fifo'', ''lifo'')\n'
    || E'              and coalesce(pol ->> ''default'', '''') in (''fefo'', ''fifo'', ''lifo''))\n');
end
$sales$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The policy promotes and is captured
-- ═════════════════════════════════════════════════════════════════════════════

do $promoter$
declare
  v_def text := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_n   text := E'when ''count_programme'' then';
begin
  if (select count(*) from regexp_matches(v_def, 'when ''count_programme'' then', 'g')) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: erp.apply_change_set_item does not carry the count_programme arm this migration inserts before';
  end if;
  execute replace(v_def, v_n,
       E'when ''container_identity_policy'' then\n'
    || E'      if i.operation = ''remove'' then\n'
    || E'        update erp.container_identity_policy c set status = ''inactive'', updated_at = now()\n'
    || E'         where c.tenant_id = v_tenant and c.code = (p ->> ''code'');\n'
    || E'      else\n'
    || E'        insert into erp.container_identity_policy (\n'
    || E'          tenant_id, code, name, item_class, site_id, device_task_code,\n'
    || E'          identity_level, count_method, effective_from, status)\n'
    || E'        values (v_tenant, p ->> ''code'', p ->> ''name'', p ->> ''item_class'', v_site, p ->> ''device_task'',\n'
    || E'                coalesce(p ->> ''identity_level'', ''none''), coalesce(p ->> ''count_method'', ''by_unit''),\n'
    || E'                coalesce((p ->> ''effective_from'')::date, current_date), ''active'')\n'
    || E'        on conflict (tenant_id, code) do update\n'
    || E'          set name = excluded.name, item_class = excluded.item_class, site_id = excluded.site_id,\n'
    || E'              device_task_code = excluded.device_task_code, identity_level = excluded.identity_level,\n'
    || E'              count_method = excluded.count_method, effective_from = excluded.effective_from,\n'
    || E'              status = ''active'', updated_at = now();\n'
    || E'      end if;\n\n'
    || E'    ' || v_n);
end
$promoter$;

do $manifest$
declare
  v_def text := pg_get_functiondef('erp.configuration_manifest(text[])'::regprocedure);
  v_n   text := E'select ''numbering_rule'',';
begin
  if (select count(*) from regexp_matches(v_def, 'select ''numbering_rule'',', 'g')) <> 1 then
    raise exception 'CLOVEERP_MANIFEST_UNRECOGNISED: erp.configuration_manifest does not carry the numbering_rule arm this migration inserts before';
  end if;
  execute replace(v_def, v_n,
       E'select ''container_identity_policy'', cp.code,\n'
    || E'       jsonb_build_object(''code'', cp.code, ''name'', cp.name, ''item_class'', cp.item_class,\n'
    || E'                          ''site'', s.code, ''device_task'', cp.device_task_code,\n'
    || E'                          ''identity_level'', cp.identity_level, ''count_method'', cp.count_method,\n'
    || E'                          ''effective_from'', cp.effective_from)\n'
    || E'  from t\n'
    || E'  join erp.container_identity_policy cp on cp.tenant_id = t.tenant_id and cp.status = ''active''\n'
    || E'  left join erp.site s on s.id = cp.site_id\n\n'
    || E'union all\n\n'
    || v_n);
end
$manifest$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The rule
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.identity_policy_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  select 'container_type_not_buildable', c.code, format('a %s exists as a handling unit', c.container_type)
    from erp.container c join t on t.tenant_id = c.tenant_id
    join erp_ref.container_type ct on ct.code = c.container_type
   where not ct.is_buildable
  union all
  select 'container_nesting_inverted', c.code,
         format('%s (%s) inside %s (%s)', c.code, c.container_type, p.code, p.container_type)
    from erp.container c join t on t.tenant_id = c.tenant_id
    join erp.container p on p.id = c.parent_container_id
    join erp_ref.container_type tc on tc.code = c.container_type
    join erp_ref.container_type tp on tp.code = p.container_type
   where tp.level_rank <= tc.level_rank
  union all
  select 'policies_collide', a.code || ' / ' || b.code,
         'two policies in force for the same site, class and step; the resolver would guess by date'
    from erp.container_identity_policy a join t on t.tenant_id = a.tenant_id
    join erp.container_identity_policy b
      on b.tenant_id = a.tenant_id and b.code > a.code and b.status = 'active'
     and b.site_id is not distinct from a.site_id
     and b.item_class is not distinct from a.item_class
     and b.device_task_code is not distinct from a.device_task_code
     and b.effective_from <= current_date
   where a.status = 'active' and a.effective_from <= current_date
  union all
  select 'stock_in_container_elsewhere', c.code,
         format('%s unit(s) of stock in %s, which stands at another location', sum(b.quantity), c.code)
    from erp.stock_balance b join t on t.tenant_id = b.tenant_id
    join erp.container c on c.id = b.container_id
   where b.quantity <> 0 and b.location_id <> c.location_id
   group by c.code
$$;
revoke all on function erp.identity_policy_report() from public, anon, authenticated;

comment on function erp.identity_policy_report is
  'D12 findings for one organisation: an unbuildable level in use as a unit, a '
  'unit nested inside a smaller one, two policies in force for the same scope, '
  'stock recorded in a unit that stands elsewhere.';

create or replace function erp.assert_identity_policy_sound()
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
    from erp.identity_policy_report() r;
  if v_n > 0 then
    raise exception 'CLOVEERP_IDENTITY_POLICY_UNSOUND: % finding(s); handling-unit identity follows policy (D12)', v_n
      using errcode = 'P0001', detail = v_detail,
            hint = 'erp.identity_policy_report() names each finding: retire the colliding policy, move the stock or the unit, or rebuild the unit at a buildable level.';
  end if;
  return format('identity: %s policy(ies), %s handling unit(s); nesting never inverted, counting bound to the policy',
    (select count(*) from erp.container_identity_policy p where p.tenant_id = erp.require_tenant_id() and p.status = 'active'),
    (select count(*) from erp.container c where c.tenant_id = erp.require_tenant_id()));
end;
$$;
revoke all on function erp.assert_identity_policy_sound() from public, anon, authenticated;

comment on function erp.assert_identity_policy_sound() is
  'D12: every handling unit is a buildable level nested inside a coarser one; '
  'identity policies do not collide; stock sits where its unit does. Per organisation.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('identity_policy_sound', 'Handling-unit identity follows policy', 'assertion', 'tenant',
   'assert_identity_policy_sound', '', 'identity_policy_report', '',
   'Every handling unit is a buildable level nested inside a coarser one; identity policies do not collide; stock sits where its unit does.', true, 94)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

delete from erp_ref.product_decision_check where decision_code = 'D12';
insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D12', 'erp', 'assert_identity_policy_sound',
   'Handling-unit levels are a vocabulary and the identity level is a policy row per class, site and step; this fails where a unit is at an unbuildable level, nested inside a smaller one, or governed by two policies at once.'),
  ('D12', 'erp_test', 'assert_identity_policy_suite',
   'Builds units at and below the policy level, nests them both ways, counts by container, hybrid and unit, and posts a variance on consigned stock against its owner.'),
  ('D13', 'erp_test', 'assert_allocation_policy_suite',
   'FEFO, FIFO and LIFO from stock.allocation_policy at site scope, one batch per order honoured and refused, nearest location honoured, and the method written back on the allocation.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The suites
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.identity_policy_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases   integer := 0;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_site uuid; v_ccy char(3); v_company uuid;
  v_supplier uuid; v_recv uuid; v_bulk uuid;
  v_hu uuid; v_hu2 uuid; v_cons uuid;
  v_prog uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid; v_p4 uuid;
  v_pallet uuid; v_case uuid;
  v_doc uuid; v_line uuid;
  v_task uuid; v_task2 uuid;
  v_msg text;
  v_n integer; v_q numeric; v_m integer; v_j integer;
  v_status text; v_cc boolean;
  pol record;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-ident', 'Identity suite', 'admin@zz-ident.test', 'Identity Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000d1', 'admin@zz-ident.test');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000d1')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id, e.base_currency, e.party_id into v_entity, v_ccy, v_company
    from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.site_type = 'warehouse' order by s.code limit 1;
  select l.id into v_recv from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site and l.location_type = 'receiving' limit 1;
  select l.id into v_bulk from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site and l.location_type = 'bulk' limit 1;
  select pr.party_id into v_supplier from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;

  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
  select v_tenant, 'ZZ-HU', 'Unitised item', 'RAW', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
  returning id into v_hu;
  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
  select v_tenant, 'ZZ-HU2', 'Second unitised item', 'RAW', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
  returning id into v_hu2;
  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
  select v_tenant, 'ZZ-CONS', 'Consigned item', 'RAW', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
  returning id into v_cons;
  insert into erp.count_programme (tenant_id, code, name, site_id, kind, selector, tolerance_absolute, tolerance_pct, status)
  values (v_tenant, 'zz_hu_count', 'Identity suite count', v_site, 'cycle', 'true'::jsonb, 5, 100, 'active')
  returning id into v_prog;

  -- 1. The vocabulary.
  v_cases := v_cases + 1;
  select count(*) into v_n from erp_ref.container_type;
  case_name := 'the levels a unit can carry an identity at are a vocabulary, coarsest last, and a unit names one';
  passed := v_n = 6
        and (select level_rank from erp_ref.container_type where code = 'case') = (select level_rank from erp_ref.container_type where code = 'carton')
        and (select level_rank from erp_ref.container_type where code = 'pallet') > (select level_rank from erp_ref.container_type where code = 'case')
        and (select level_rank from erp_ref.container_type where code = 'master_pallet') > (select level_rank from erp_ref.container_type where code = 'pallet')
        and exists (select 1 from pg_constraint where conname = 'container_container_type_fkey');
  detail := format('%s levels (expected 6); case and carton one level; the column is a foreign key', v_n);
  return next;

  -- 2. No policy: no identity, count by unit.
  v_cases := v_cases + 1;
  select * into pol from erp.identity_policy_for(v_hu, v_site, 'count');
  case_name := 'with no policy a class carries no handling-unit identity and counts by unit';
  passed := pol.policy_id is null and pol.identity_level = 'none' and pol.level_rank = -1 and pol.count_method = 'by_unit';
  detail := format('resolved %s / %s', pol.identity_level, pol.count_method);
  return next;

  -- 3. A policy at pallet level: a pallet builds, a case is refused.
  v_cases := v_cases + 1;
  insert into erp.container_identity_policy (tenant_id, code, name, item_class, site_id, device_task_code, identity_level, count_method, effective_from)
  values (v_tenant, 'ZZ-HU-BUILD', 'Pallets for raw and packaging', 'RAW,PACK', v_site, 'handling_unit_build', 'pallet', 'by_unit', current_date - 1)
  returning id into v_p1;
  v_pallet := erp.create_handling_unit(v_site, v_bulk, 'pallet', null, 'ZZ-PAL-1', v_hu);
  v_msg := null;
  begin
    perform erp.create_handling_unit(v_site, v_bulk, 'case', null, 'ZZ-CASE-X', v_hu);
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a unit builds at the policy''s level and one finer than the policy is refused by name';
  passed := exists (select 1 from erp.container c where c.id = v_pallet and c.container_type = 'pallet' and c.identity_policy_id = v_p1 and c.depth = 0)
        and coalesce(v_msg like 'CLOVEERP_IDENTITY_LEVEL_NOT_POLICY%', false);
  detail := format('pallet built under policy %s; case: %s', (select code from erp.container_identity_policy where id = v_p1), left(coalesce(v_msg, 'no refusal'), 90));
  return next;

  -- 4. A later, narrower policy captures identity at case level; history is kept; nesting is one way.
  v_cases := v_cases + 1;
  insert into erp.container_identity_policy (tenant_id, code, name, item_class, site_id, device_task_code, identity_level, count_method, effective_from)
  values (v_tenant, 'ZZ-HU-BUILD-CASE', 'Cases for raw', 'RAW', v_site, 'handling_unit_build', 'case', 'by_unit', current_date)
  returning id into v_p2;
  v_case := erp.create_handling_unit(v_site, null, 'case', v_pallet, 'ZZ-CASE-1', v_hu);
  v_msg := null;
  begin
    perform erp.create_handling_unit(v_site, v_bulk, 'pallet', v_case, 'ZZ-PAL-X', v_hu);
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a case builds under the later case-level policy, inside the pallet that keeps its own policy, and a pallet inside a case is refused';
  passed := exists (select 1 from erp.container c where c.id = v_case and c.identity_policy_id = v_p2 and c.depth = 1 and c.location_id = v_bulk)
        and (select identity_policy_id from erp.container where id = v_pallet) = v_p1
        and coalesce(v_msg like 'CLOVEERP_CONTAINER_NESTING_INVERTED%', false);
  detail := format('case depth %s under policy %s; pallet still under %s; inverted: %s',
                   (select depth from erp.container where id = v_case),
                   (select code from erp.container_identity_policy where id = v_p2),
                   (select code from erp.container_identity_policy where id = v_p1),
                   left(coalesce(v_msg, 'no refusal'), 60));
  return next;

  -- 5. Counting by container: a homogeneous case is one thing to count.
  v_cases := v_cases + 1;
  insert into erp.container_identity_policy (tenant_id, code, name, item_class, site_id, device_task_code, identity_level, count_method, effective_from)
  values (v_tenant, 'ZZ-HU-COUNT', 'Count raw by case', 'RAW', v_site, 'count', 'case', 'by_container', current_date - 1)
  returning id into v_p3;
  v_doc := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-CASE', '{}'::jsonb);
  v_line := erp.add_document_line(v_doc, v_hu, 24, 1000, 'into the case', current_date);
  update erp.document_line set location_id = v_bulk, container_id = v_case where id = v_line;
  perform erp.transition_document(v_doc, 'post', 'identity suite');
  v_doc := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-LOOSE', '{}'::jsonb);
  v_line := erp.add_document_line(v_doc, v_hu, 6, 1000, 'loose', current_date);
  update erp.document_line set location_id = v_recv where id = v_line;
  perform erp.transition_document(v_doc, 'post', 'identity suite');
  set constraints all immediate;
  v_n := erp.raise_count_tasks('zz_hu_count');
  select ct.id, ct.expected_quantity into v_task, v_q from erp.count_task ct
   where ct.tenant_id = v_tenant and ct.container_id = v_case and ct.status = 'open' and ct.counts_container;
  select ct.id into v_task2 from erp.count_task ct
   where ct.tenant_id = v_tenant and ct.location_id = v_recv and ct.item_id = v_hu and ct.status = 'open' and ct.container_id is null;
  case_name := 'counting by container raises one task for a homogeneous case and one for the loose stock';
  passed := v_n = 2 and v_task is not null and v_q = 24 and v_task2 is not null;
  detail := format('%s task(s) (expected 2); case task expects %s (expected 24); loose task present: %s', v_n, v_q, v_task2 is not null);
  return next;

  -- 6. A case recorded present asserts its contents.
  v_cases := v_cases + 1;
  v_status := erp.record_count(v_task, null)::text;
  v_q := erp.post_count(v_task);
  perform erp.record_count(v_task2, 6);
  perform erp.post_count(v_task2);
  case_name := 'a whole unit recorded present asserts its contents and posts no variance';
  passed := v_status = 'approved' and v_q = 0
        and (select ct.counted_quantity from erp.count_task ct where ct.id = v_task) = 24
        and (select ct.variance from erp.count_task ct where ct.id = v_task) = 0;
  detail := format('status %s, counted %s, variance %s', v_status,
                   (select ct.counted_quantity from erp.count_task ct where ct.id = v_task),
                   (select ct.variance from erp.count_task ct where ct.id = v_task));
  return next;

  -- 7. A mixed case counts by unit, refuses "present", and posts against the unit.
  v_cases := v_cases + 1;
  v_doc := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-MIX', '{}'::jsonb);
  v_line := erp.add_document_line(v_doc, v_hu2, 12, 1000, 'into the same case', current_date);
  update erp.document_line set location_id = v_bulk, container_id = v_case where id = v_line;
  perform erp.transition_document(v_doc, 'post', 'identity suite');
  set constraints all immediate;
  v_n := erp.raise_count_tasks('zz_hu_count');
  select count(*) into v_m from erp.count_task ct where ct.tenant_id = v_tenant and ct.container_id = v_case and ct.status = 'open';
  select ct.id, ct.counts_container into v_task, v_cc from erp.count_task ct where ct.tenant_id = v_tenant and ct.container_id = v_case and ct.item_id = v_hu and ct.status = 'open';
  select ct.id into v_task2 from erp.count_task ct where ct.tenant_id = v_tenant and ct.container_id = v_case and ct.item_id = v_hu2 and ct.status = 'open';
  v_msg := null;
  begin
    perform erp.record_count(v_task, null);
  exception when others then v_msg := sqlerrm;
  end;
  perform erp.record_count(v_task, 23);
  v_q := erp.post_count(v_task);
  perform erp.record_count(v_task2, 12);
  perform erp.post_count(v_task2);
  -- and the loose task raised again, closed so the next raise is clean
  select ct.id into v_task from erp.count_task ct where ct.tenant_id = v_tenant and ct.location_id = v_recv and ct.item_id = v_hu and ct.status = 'open';
  if v_task is not null then perform erp.record_count(v_task, 6); perform erp.post_count(v_task); end if;
  case_name := 'a mixed unit counts by unit inside it, refuses a count without a figure, and posts the variance against the unit''s position';
  passed := v_m = 2
        and not coalesce(v_cc, true)
        and coalesce(v_msg like 'CLOVEERP_COUNT_NEEDS_A_QUANTITY%', false)
        and v_q = -1
        and exists (select 1 from erp.stock_movement m where m.tenant_id = v_tenant and m.reason_code = 'count_variance'
                     and m.item_id = v_hu and m.container_id = v_case and m.from_location_id = v_bulk and m.quantity = 1)
        and (select b.quantity from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_hu and b.location_id = v_bulk and b.container_id = v_case) = 23;
  detail := format('%s task(s) in the case (expected 2); present refused: %s; posted %s (expected -1); case position %s (expected 23)',
                   v_m, left(coalesce(v_msg, 'no refusal'), 60), v_q,
                   (select b.quantity from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_hu and b.location_id = v_bulk and b.container_id = v_case));
  return next;

  -- 8. Hybrid: pallets are one thing to count, cases inside count by unit.
  v_cases := v_cases + 1;
  update erp.container_identity_policy set status = 'inactive', updated_at = now() where id = v_p3;
  insert into erp.container_identity_policy (tenant_id, code, name, item_class, site_id, device_task_code, identity_level, count_method, effective_from)
  values (v_tenant, 'ZZ-HU-COUNT-HYBRID', 'Count raw by pallet', 'RAW', v_site, 'count', 'pallet', 'hybrid', current_date)
  returning id into v_p4;
  v_doc := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-PAL', '{}'::jsonb);
  v_line := erp.add_document_line(v_doc, v_hu, 10, 1000, 'onto the pallet', current_date);
  update erp.document_line set location_id = v_bulk, container_id = v_pallet where id = v_line;
  perform erp.transition_document(v_doc, 'post', 'identity suite');
  set constraints all immediate;
  v_n := erp.raise_count_tasks('zz_hu_count');
  v_msg := null;
  begin
    perform erp.assert_identity_policy_sound();
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'hybrid counting makes a pallet one thing to count while the case inside counts by unit';
  passed := v_n = 4
        and exists (select 1 from erp.count_task ct where ct.tenant_id = v_tenant and ct.container_id = v_pallet and ct.status = 'open' and ct.counts_container and ct.expected_quantity = 10)
        and (select count(*) from erp.count_task ct where ct.tenant_id = v_tenant and ct.status = 'open' and ct.container_id is null and ct.location_id = v_bulk) = 2
        and v_msg is null;
  detail := format('%s task(s) (expected 4: pallet, two by unit at bulk, one loose); %s', v_n, coalesce(v_msg, 'identity policy sound'));
  return next;

  -- 9. A variance on consigned stock posts against its owner, with no cost.
  v_cases := v_cases + 1;
  v_doc := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-OWNED', '{}'::jsonb);
  v_line := erp.add_document_line(v_doc, v_cons, 10, 800, 'owned', current_date);
  update erp.document_line set location_id = v_recv where id = v_line;
  perform erp.transition_document(v_doc, 'post', 'identity suite');
  v_doc := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-CONSIGNED', '{}'::jsonb);
  update erp.document set stock_owner_party_id = v_supplier where id = v_doc;
  v_line := erp.add_document_line(v_doc, v_cons, 5, 800, 'consigned', current_date);
  update erp.document_line set location_id = v_recv where id = v_line;
  perform erp.transition_document(v_doc, 'post', 'identity suite');
  set constraints all immediate;
  select count(*) into v_j from erp.journal j where j.tenant_id = v_tenant and j.source_code = 'stock.adjusted';
  perform erp.raise_count_tasks('zz_hu_count');
  select count(*) into v_n from erp.count_task ct where ct.tenant_id = v_tenant and ct.item_id = v_cons and ct.status = 'open';
  select ct.id into v_task from erp.count_task ct where ct.tenant_id = v_tenant and ct.item_id = v_cons and ct.owner_party_id = v_supplier and ct.status = 'open';
  perform erp.record_count(v_task, 3);
  v_q := erp.post_count(v_task);
  v_msg := null;
  begin
    perform erp.assert_stock_reconciles();
    perform erp.assert_ownership_carried();
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a variance on consigned stock is raised per owner and posts against the supplier''s position with no cost';
  passed := v_n = 2 and v_q = -2
        and exists (select 1 from erp.stock_movement m where m.tenant_id = v_tenant and m.item_id = v_cons and m.reason_code = 'count_variance'
                     and m.owner_party_id = v_supplier and m.unit_cost_minor is null and m.quantity = 2)
        and (select b.quantity from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_cons and b.location_id = v_recv and b.owner_party_id = v_supplier) = 3
        and (select b.quantity from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_cons and b.location_id = v_recv and b.owner_party_id = v_company) = 10
        and (select count(*) from erp.journal j where j.tenant_id = v_tenant and j.source_code = 'stock.adjusted') = v_j
        and v_msg is null;
  detail := format('%s task(s) for the item (expected 2, one per owner); posted %s (expected -2); supplier position %s (expected 3), company %s (expected 10); adjustment journals %s→%s; %s',
                   v_n, v_q,
                   (select b.quantity from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_cons and b.location_id = v_recv and b.owner_party_id = v_supplier),
                   (select b.quantity from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_cons and b.location_id = v_recv and b.owner_party_id = v_company),
                   v_j, (select count(*) from erp.journal j where j.tenant_id = v_tenant and j.source_code = 'stock.adjusted'),
                   coalesce(v_msg, 'stock and ownership reconcile'));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 10. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-ident')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000d1');
  detail := 'zz-ident rolled back with its units and policies';
  return next;

  if v_cases <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: identity_policy_suite ran % cases, expected 10', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_identity_policy_suite()
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
  create temp table if not exists _identity on commit drop as
    select * from erp_test.identity_policy_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _identity;
  drop table _identity;
  if v_fail > 0 then
    raise exception E'CLOVEERP_IDENTITY_POLICY_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: identity_policy_suite ran % cases, expected 10', v_all;
  end if;
  return format('identity policy: %s/%s cases passed', v_all, v_all);
end;
$$;

create or replace function erp_test.allocation_policy_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases   integer := 0;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_site uuid; v_ccy char(3);
  v_supplier uuid; v_customer uuid; v_recv uuid; v_bulk uuid;
  v_exp uuid; v_plain uuid;
  v_soon uuid; v_late uuid;
  v_doc uuid; v_line uuid; v_so uuid; v_sol uuid; v_alloc uuid; v_alloc2 uuid;
  v_msg text;
  v_n integer; v_m integer; v_loc uuid; v_batch uuid; v_code text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-alloc', 'Allocation suite', 'admin@zz-alloc.test', 'Allocation Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000d2', 'admin@zz-alloc.test');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000d2')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id, e.base_currency into v_entity, v_ccy from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.site_type = 'warehouse' order by s.code limit 1;
  select l.id into v_recv from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site and l.location_type = 'receiving' limit 1;
  select l.id into v_bulk from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site and l.location_type = 'bulk' limit 1;
  select pr.party_id into v_supplier from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;
  select pr.party_id into v_customer from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'customer' order by pr.party_id limit 1;

  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status, is_batch_controlled, has_expiry)
  select v_tenant, 'ZZ-EXP', 'Expiring item', 'RAW', u.id, 'active', true, true from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
  returning id into v_exp;
  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
  select v_tenant, 'ZZ-PLAIN', 'Plain item', 'RAW', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
  returning id into v_plain;
  insert into erp.batch (tenant_id, item_id, batch_number, status, expires_on) values (v_tenant, v_exp, 'B-SOON', 'released', current_date + 30) returning id into v_soon;
  insert into erp.batch (tenant_id, item_id, batch_number, status, expires_on) values (v_tenant, v_exp, 'B-LATE', 'released', current_date + 300) returning id into v_late;

  -- Ten of each batch at bulk; ten plain at receiving, then ten plain at bulk.
  v_doc := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-EXP', '{}'::jsonb);
  v_line := erp.add_document_line(v_doc, v_exp, 10, 1000, 'soon', current_date);
  update erp.document_line set location_id = v_bulk, batch_id = v_soon where id = v_line;
  v_line := erp.add_document_line(v_doc, v_exp, 10, 1000, 'late', current_date);
  update erp.document_line set location_id = v_bulk, batch_id = v_late where id = v_line;
  perform erp.transition_document(v_doc, 'post', 'allocation suite');
  v_doc := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-PLAIN-1', '{}'::jsonb);
  v_line := erp.add_document_line(v_doc, v_plain, 10, 1000, 'first in, at receiving', current_date);
  update erp.document_line set location_id = v_recv where id = v_line;
  perform erp.transition_document(v_doc, 'post', 'allocation suite');
  v_doc := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-PLAIN-2', '{}'::jsonb);
  v_line := erp.add_document_line(v_doc, v_plain, 10, 1000, 'later, at bulk', current_date);
  update erp.document_line set location_id = v_bulk where id = v_line;
  perform erp.transition_document(v_doc, 'post', 'allocation suite');
  set constraints all immediate;

  -- 1. FEFO by default.
  v_cases := v_cases + 1;
  v_so := erp.open_document('sales_order', v_customer, null, v_site);
  v_sol := erp.add_document_line(v_so, v_exp, 4, 2500, 'ordered');
  v_alloc := erp.reserve_for_line(v_sol);
  v_n := erp.commit_allocation(v_alloc);
  select l.batch_id into v_batch from erp.allocation_line l where l.allocation_id = v_alloc;
  select a.policy_code into v_code from erp.allocation a where a.id = v_alloc;
  case_name := 'expiry-controlled stock allocates first-expiring first by default, and the allocation says so';
  passed := v_n = 1 and v_batch = v_soon and v_code = 'fefo';
  detail := format('%s line(s), batch %s (expected B-SOON), method %s', v_n, (select batch_number from erp.batch where id = v_batch), v_code);
  return next;

  -- 2. FIFO with nearest off takes the older receipt.
  v_cases := v_cases + 1;
  perform erp.set_config_value('stock.allocation_policy',
    '{"expiry_controlled":"fefo","default":"fifo","single_batch_per_order":false,"prefer_nearest_location":false}'::jsonb,
    null, current_date, v_entity, v_site, 'allocation suite: fifo');
  v_so := erp.open_document('sales_order', v_customer, null, v_site);
  v_sol := erp.add_document_line(v_so, v_plain, 4, 2500, 'ordered');
  v_alloc := erp.reserve_for_line(v_sol);
  perform erp.commit_allocation(v_alloc);
  select l.location_id into v_loc from erp.allocation_line l where l.allocation_id = v_alloc;
  select a.policy_code into v_code from erp.allocation a where a.id = v_alloc;
  case_name := 'first-in first-out with no location preference takes the older receipt';
  passed := v_loc = v_recv and v_code = 'fifo';
  detail := format('picked from %s (expected the receiving bay), method %s', (select code from erp.location where id = v_loc), v_code);
  return next;

  -- 3. LIFO takes the newer receipt.
  v_cases := v_cases + 1;
  perform erp.set_config_value('stock.allocation_policy',
    '{"expiry_controlled":"fefo","default":"lifo","single_batch_per_order":false,"prefer_nearest_location":false}'::jsonb,
    null, current_date, v_entity, v_site, 'allocation suite: lifo');
  v_so := erp.open_document('sales_order', v_customer, null, v_site);
  v_sol := erp.add_document_line(v_so, v_plain, 4, 2500, 'ordered');
  v_alloc := erp.reserve_for_line(v_sol);
  perform erp.commit_allocation(v_alloc);
  select l.location_id into v_loc from erp.allocation_line l where l.allocation_id = v_alloc;
  select a.policy_code into v_code from erp.allocation a where a.id = v_alloc;
  case_name := 'last-in first-out takes the newer receipt';
  passed := v_loc = v_bulk and v_code = 'lifo';
  detail := format('picked from %s (expected bulk), method %s', (select code from erp.location where id = v_loc), v_code);
  return next;

  -- 4. Nearest: between two receipts on the same day, the pick face wins.
  v_cases := v_cases + 1;
  perform erp.set_config_value('stock.allocation_policy',
    '{"expiry_controlled":"fefo","default":"fifo","single_batch_per_order":false,"prefer_nearest_location":true}'::jsonb,
    null, current_date, v_entity, v_site, 'allocation suite: nearest');
  v_so := erp.open_document('sales_order', v_customer, null, v_site);
  v_sol := erp.add_document_line(v_so, v_plain, 4, 2500, 'ordered');
  v_alloc := erp.reserve_for_line(v_sol);
  perform erp.commit_allocation(v_alloc);
  select l.location_id into v_loc from erp.allocation_line l where l.allocation_id = v_alloc;
  case_name := 'between receipts on the same day the nearest pickable location wins';
  passed := v_loc = v_bulk;
  detail := format('picked from %s (expected bulk, the pick face)', (select code from erp.location where id = v_loc));
  return next;

  -- 5. One order, one FEFO line and one FIFO line.
  v_cases := v_cases + 1;
  v_so := erp.open_document('sales_order', v_customer, null, v_site);
  v_sol := erp.add_document_line(v_so, v_exp, 2, 2500, 'expiring');
  v_alloc := erp.reserve_for_line(v_sol);
  perform erp.commit_allocation(v_alloc);
  v_sol := erp.add_document_line(v_so, v_plain, 2, 2500, 'plain');
  v_alloc2 := erp.reserve_for_line(v_sol);
  perform erp.commit_allocation(v_alloc2);
  case_name := 'one order allocates an expiring line first-expiring and a plain line first-in';
  passed := (select a.policy_code from erp.allocation a where a.id = v_alloc) = 'fefo'
        and (select l.batch_id from erp.allocation_line l where l.allocation_id = v_alloc) = v_soon
        and (select a.policy_code from erp.allocation a where a.id = v_alloc2) = 'fifo'
        and (select l.location_id from erp.allocation_line l where l.allocation_id = v_alloc2) = v_bulk;
  detail := format('expiring: %s from %s; plain: %s from %s',
                   (select a.policy_code from erp.allocation a where a.id = v_alloc),
                   (select b.batch_number from erp.batch b join erp.allocation_line l on l.batch_id = b.id where l.allocation_id = v_alloc),
                   (select a.policy_code from erp.allocation a where a.id = v_alloc2),
                   (select loc.code from erp.location loc join erp.allocation_line l on l.location_id = loc.id where l.allocation_id = v_alloc2));
  return next;

  -- 6. One batch per order binds every line to the batch the first took.
  v_cases := v_cases + 1;
  perform erp.set_config_value('stock.allocation_policy',
    '{"expiry_controlled":"fefo","default":"fifo","single_batch_per_order":true,"prefer_nearest_location":true}'::jsonb,
    null, current_date, v_entity, v_site, 'allocation suite: single batch');
  v_so := erp.open_document('sales_order', v_customer, null, v_site);
  v_sol := erp.add_document_line(v_so, v_exp, 6, 2500, 'six');
  v_alloc := erp.reserve_for_line(v_sol);
  perform erp.commit_allocation(v_alloc);
  v_sol := erp.add_document_line(v_so, v_exp, 2, 2500, 'two more');
  v_alloc2 := erp.reserve_for_line(v_sol);
  perform erp.commit_allocation(v_alloc2);
  select count(*), count(*) filter (where l.batch_id = v_late) into v_n, v_m
    from erp.allocation_line l where l.allocation_id in (v_alloc, v_alloc2);
  case_name := 'one batch per order: the first line takes the first batch that covers it and the next line follows';
  passed := v_n = 2 and v_m = 2;
  detail := format('%s line(s), %s from B-LATE (expected 2 and 2: B-SOON had only 4 left)', v_n, v_m);
  return next;

  -- 7. And when no single batch covers a line, the refusal says so.
  v_cases := v_cases + 1;
  v_so := erp.open_document('sales_order', v_customer, null, v_site);
  v_sol := erp.add_document_line(v_so, v_exp, 12, 2500, 'too many for one batch');
  v_alloc := erp.reserve_for_line(v_sol);
  v_msg := null;
  begin
    perform erp.commit_allocation(v_alloc);
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a line no single batch can cover is refused by name';
  passed := coalesce(v_msg like 'CLOVEERP_SINGLE_BATCH_SHORT%', false);
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 8. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-alloc')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000d2');
  detail := 'zz-alloc rolled back with its orders and policy';
  return next;

  if v_cases <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: allocation_policy_suite ran % cases, expected 8', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_allocation_policy_suite()
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
  create temp table if not exists _allocation on commit drop as
    select * from erp_test.allocation_policy_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _allocation;
  drop table _allocation;
  if v_fail > 0 then
    raise exception E'CLOVEERP_ALLOCATION_POLICY_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: allocation_policy_suite ran % cases, expected 8', v_all;
  end if;
  return format('allocation policy: %s/%s cases passed', v_all, v_all);
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

select erp_test.assert_identity_policy_suite();
select erp_test.assert_allocation_policy_suite();
select erp_test.assert_ownership_suite();
select erp_test.assert_device_drain_suite();
select erp_test.assert_sales_depth_suite();
select erp_test.assert_inventory_suite();
select erp_test.assert_costing_suite();
select erp_test.assert_stock_invariants();
select erp.assert_whole_database_reconciles();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_configuration_promotable();
select erp.assert_packs_installable();
select erp.assert_device_task_handlers_sound();
select erp.assert_sales_controls_sane();
select erp.assert_inventory_sane();
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
