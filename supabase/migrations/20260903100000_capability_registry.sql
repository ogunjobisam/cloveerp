-- =============================================================================
-- Starter Content Packs §2 — capabilities
--
-- "The answer to comprehensive but not overwhelming is not less content. It is
-- content that arrives switched off until wanted."
--
-- §2.1 is emphatic that a capability gates three things at once — the
-- navigation a user sees, the fields a form shows, and the rules the engine
-- evaluates — and that "switched off is not merely hidden: its rules do not
-- run". So the switch has to be readable from SQL rather than only from the
-- app, which is why erp.capability_enabled() is the single answer and
-- everything else asks it.
--
-- Two things here are load-bearing rather than decorative:
--
-- DEPENDENCIES ARE DATA. Expiry control requires batch control; recall requires
-- batch control and traceability. Written as rows, so enabling one can offer
-- its prerequisites and an assertion can refuse an organisation left with a
-- capability on and its prerequisite off.
--
-- DISABLING WITH LIVE DATA IS REFUSED, NOT WARNED (§2.2).
-- erp_ref.capability_guard names, per capability, the tables whose rows make
-- disabling a lie — batch control cannot be switched off while batches exist. A
-- warning would leave the rules that maintain those rows switched off
-- underneath them.
-- =============================================================================

create table if not exists erp_ref.capability (
  code        text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  title       text not null,
  description text not null,
  module_code text references erp_ref.module(code),
  seq         integer not null default 100
);

create table if not exists erp_ref.capability_dependency (
  capability_code text not null references erp_ref.capability(code) on delete cascade,
  requires_code   text not null references erp_ref.capability(code) on delete cascade,
  rationale       text not null,
  primary key (capability_code, requires_code),
  check (capability_code <> requires_code)
);

create table if not exists erp_ref.capability_guard (
  capability_code text not null references erp_ref.capability(code) on delete cascade,
  schema_name     text not null default 'erp',
  table_name      text not null,
  rationale       text not null,
  primary key (capability_code, schema_name, table_name)
);

create table if not exists erp_ref.preset (
  code        text primary key,
  title       text not null,
  description text not null,
  seq         integer not null default 100
);

create table if not exists erp_ref.preset_capability (
  preset_code     text not null references erp_ref.preset(code) on delete cascade,
  capability_code text not null references erp_ref.capability(code) on delete cascade,
  primary key (preset_code, capability_code)
);

comment on table erp_ref.capability is
  'Every switchable unit of product behaviour. Product content: the same list '
  'for every organisation, switched per organisation in erp.tenant_capability.';

comment on table erp_ref.capability_guard is
  'What live data blocks disabling a capability. §2.2 refuses rather than warns, '
  'because a warning leaves the rules that maintain those rows switched off '
  'underneath them.';

-- Effective-dated because §2.2 requires it: disabling is reversible, and
-- historical records keep the behaviour that was in force at their time.
create table if not exists erp.tenant_capability (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  capability_code text not null references erp_ref.capability(code),
  is_enabled      boolean not null default true,
  reason          text,
  valid_from      date not null default current_date,
  valid_to        date,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  unique (tenant_id, capability_code, valid_from)
);

comment on table erp.tenant_capability is
  'Which capabilities this organisation has switched on, effective-dated. A row '
  'is never overwritten in place: switching closes one period and opens '
  'another, so a document raised last year can still be read against the '
  'behaviour then in force.';

select erp_meta.register_table('erp_ref', 'capability', 'product_content',
  'The capability catalogue.');
select erp_meta.register_table('erp_ref', 'capability_dependency', 'product_content',
  'Which capabilities require which.');
select erp_meta.register_table('erp_ref', 'capability_guard', 'product_content',
  'What live data blocks disabling a capability.');
select erp_meta.register_table('erp_ref', 'preset', 'product_content',
  'Starting selections of capabilities.');
select erp_meta.register_table('erp_ref', 'preset_capability', 'product_content',
  'The capabilities each preset selects.');
select erp_meta.register_table('erp', 'tenant_capability', 'tenant_scoped',
  'Which capabilities an organisation has switched on.');

-- ── The catalogue, §2.1 verbatim ─────────────────────────────────────────────

insert into erp_ref.capability (code, title, description, seq) values
  ('batch_control',          'Batch control',          'Stock is identified and tracked by batch.', 10),
  ('expiry_control',         'Expiry control',         'Batches carry an expiry date, and it is enforced on allocation and despatch.', 11),
  ('serialisation',          'Serialisation',          'Individual units carry a serial number.', 12),
  ('container_identity',     'Container identity',     'Pallets and cartons are identified and tracked as containers.', 13),
  ('quality_inspection',     'Quality inspection',     'Receipts and production are inspected against a plan before use.', 20),
  ('quarantine_release',     'Quarantine and release', 'Stock lands in quarantine and is released under named authority.', 21),
  ('recall_management',      'Recall management',      'A batch can be traced forward and recovered.', 22),
  ('multi_entity',           'Multi-entity',           'More than one legal entity on one deployment.', 30),
  ('intercompany_trading',   'Intercompany trading',   'Entities trade with each other, with matched postings on both sides.', 31),
  ('multi_currency',         'Multi-currency',         'Transactions and ledgers in more than one currency.', 32),
  ('landed_cost',            'Landed cost',            'Freight, duty and handling are absorbed into stock value.', 33),
  ('consignment_stock',      'Consignment stock',      'Stock held but not owned, or owned but not held.', 40),
  ('third_party_custody',    'Third-party custody',    'Stock in the physical custody of a logistics provider.', 41),
  ('contract_manufacturing', 'Contract manufacturing', 'Production performed by somebody else on material you own.', 42),
  ('production',             'Production',             'Works orders, bills of material and shop-floor execution.', 50),
  ('planning_mrp',           'Planning and MRP',       'Requirements planning across demand and supply.', 51),
  ('forecasting',            'Forecasting',            'Statistical demand forecasts feeding planning.', 52),
  ('release_areas',          'Release areas',          'Stock is staged into release areas before picking.', 60),
  ('wave_picking',           'Wave picking',           'Orders are grouped into waves for picking.', 61),
  ('cycle_counting',         'Cycle counting',         'Counting runs continuously rather than freezing operations.', 62),
  ('credit_control',         'Credit control',         'Customer credit limits are checked and enforced.', 70),
  ('prepaid_settlement',     'Prepaid settlement',     'Orders settled before despatch, through a clearing account.', 71),
  ('returns',                'Returns',                'Customer and supplier returns with disposition.', 72),
  ('print_orchestration',    'Print orchestration',    'Documents and labels are produced and routed automatically.', 80),
  ('automated_order_intake', 'Automated order intake', 'Orders arrive from an upstream system rather than a person.', 81),
  ('project_accounting',     'Project accounting',     'Cost and revenue analysed by project.', 90),
  ('fixed_assets',           'Fixed assets',           'Capitalised assets with depreciation.', 91)
on conflict (code) do update set
  title = excluded.title, description = excluded.description, seq = excluded.seq;

-- §2.1's three worked examples, plus the ones that follow from them by the same
-- reasoning. Each says why, because a dependency without a reason is a rule
-- somebody will delete the first time it is inconvenient.
insert into erp_ref.capability_dependency (capability_code, requires_code, rationale) values
  ('expiry_control', 'batch_control',
   'An expiry date belongs to a batch. Without batch identity there is nothing to carry it.'),
  ('recall_management', 'batch_control',
   'A recall is scoped by batch; without one there is no way to say what is affected.'),
  ('recall_management', 'quarantine_release',
   'Recovered stock has to land somewhere it cannot be picked from, and be released back deliberately.'),
  ('contract_manufacturing', 'consignment_stock',
   'Contract manufacturing separates ownership from custody, which is what consignment models.'),
  ('contract_manufacturing', 'production',
   'It is production performed elsewhere; without production there is no works order to place.'),
  ('intercompany_trading', 'multi_entity',
   'There has to be more than one entity before two of them can trade.'),
  ('quarantine_release', 'quality_inspection',
   'Release under named authority is the decision an inspection produces.'),
  ('planning_mrp', 'production',
   'MRP explodes requirements through bills of material, which production owns.'),
  ('forecasting', 'planning_mrp',
   'A forecast is an input to planning; on its own it is a number nobody consumes.'),
  ('wave_picking', 'release_areas',
   'A wave stages stock into a release area; without one there is nowhere for it to go.'),
  ('third_party_custody', 'consignment_stock',
   'Custody without ownership is the consignment model applied to a provider.')
on conflict (capability_code, requires_code) do update set rationale = excluded.rationale;

-- §2.2: what makes disabling a lie rather than a choice.
insert into erp_ref.capability_guard (capability_code, table_name, rationale) values
  ('batch_control',        'batch',
   'Batches exist. Switching batch control off would leave them unmaintained by the rules that keep them correct.'),
  ('serialisation',        'serial',
   'Serial numbers are in issue and are referenced by despatched documents.'),
  ('container_identity',   'container',
   'Containers exist and hold stock; the identity is how that stock is found.'),
  ('quality_inspection',   'inspection',
   'Inspections have been raised, and their dispositions decide what may be used.'),
  ('production',           'works_order',
   'Works orders exist; disabling production would strand them mid-flight.'),
  ('planning_mrp',         'planned_order',
   'Planned orders exist and are being converted.'),
  ('release_areas',        'release_area',
   'Release areas are configured and staged stock is sitting in them.'),
  ('recall_management',    'recall',
   'A recall is a regulatory clock. It cannot be switched off part-way through.')
-- project_accounting has no guard, and that is a finding rather than an
-- omission: §2.1 lists it as a capability but nothing in this schema stores a
-- project. Cost is analysed by dimension (erp.dimension_value), which is not
-- project-specific, so there is no table whose rows would make disabling a lie.
-- Naming erp.project here would have been a guard against nothing, and
-- erp.assert_capabilities_sound() would have failed the build for it.
on conflict (capability_code, schema_name, table_name) do update set rationale = excluded.rationale;

-- ── §2.3 Three presets, then adjust ──────────────────────────────────────────

insert into erp_ref.preset (code, title, description, seq) values
  ('minimal', 'Minimal',
   'Master data, purchasing, stock, sales, basic finance. The smallest set that lets an organisation buy, hold and sell.', 10),
  ('standard', 'Standard',
   'Minimal plus batch and expiry control, counting, approval routing, quality inspection, landed cost and release areas.', 20),
  ('full', 'Full',
   'Standard plus production, planning and MRP, forecasting, quality management and recall, multi-entity and intercompany, serialisation, container identity and project accounting.', 30)
on conflict (code) do update set
  title = excluded.title, description = excluded.description, seq = excluded.seq;

-- Minimal selects nothing: buying, holding and selling is the base pack, not a
-- capability. Saying that in a comment beats leaving a reader to wonder whether
-- a row is missing.
insert into erp_ref.preset_capability (preset_code, capability_code)
select 'standard', c from unnest(array[
  'batch_control','expiry_control','cycle_counting','quality_inspection',
  'quarantine_release','landed_cost','release_areas','returns','credit_control'
]) c
union all
select 'full', c from unnest(array[
  'batch_control','expiry_control','cycle_counting','quality_inspection',
  'quarantine_release','landed_cost','release_areas','returns','credit_control',
  'production','planning_mrp','forecasting','recall_management','multi_entity',
  'intercompany_trading','serialisation','container_identity','project_accounting'
]) c
on conflict (preset_code, capability_code) do nothing;

-- ── Asking ───────────────────────────────────────────────────────────────────
--
-- The single answer. Everything that gates on a capability asks this, so
-- "switched off is not merely hidden: its rules do not run" is one function
-- rather than a convention each caller reimplements.

create or replace function erp.capability_enabled(
  p_code text, p_on date default current_date)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select tc.is_enabled
      from erp.tenant_capability tc
     where tc.tenant_id = erp.require_tenant_id()
       and tc.capability_code = p_code
       and daterange(tc.valid_from, tc.valid_to, '[)') @> coalesce(p_on, current_date)
     order by tc.valid_from desc
     limit 1), false)
$$;

comment on function erp.capability_enabled is
  'Whether a capability is on for this organisation on a given date. Dated, so '
  'a document raised before a capability was switched off still reads against '
  'the behaviour that was in force when it happened.';

-- ── Switching ────────────────────────────────────────────────────────────────

create or replace function erp.set_capability(
  p_code text,
  p_enabled boolean,
  p_reason text default null,
  p_valid_from date default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_from   date := coalesce(p_valid_from, current_date);
  c        erp_ref.capability%rowtype;
  r        record;
  v_rows   bigint;
  v_blocked text := '';
  v_missing text := '';
begin
  select * into c from erp_ref.capability where code = p_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_CAPABILITY: % is not a capability this product has',
      p_code using errcode = '23503';
  end if;

  if p_enabled then
    -- §2.1: enabling one offers its prerequisites. Offering them means saying
    -- which, not turning them on silently — a capability nobody chose is a
    -- behaviour nobody expects.
    for r in
      select d.requires_code, d.rationale from erp_ref.capability_dependency d
       where d.capability_code = p_code
         and not erp.capability_enabled(d.requires_code, v_from)
    loop
      v_missing := v_missing || format(E'  %s — %s\n', r.requires_code, r.rationale);
    end loop;

    if v_missing <> '' then
      raise exception E'ERPWARE_CAPABILITY_NEEDS: % requires capabilities that are off\n%',
        p_code, v_missing
        using errcode = '23514',
              hint = 'Enable these first. They are prerequisites, not suggestions.';
    end if;
  else
    -- §2.2: refused, not warned. A warning would leave the rows below
    -- unmaintained by the rules that keep them correct.
    for r in
      select g.schema_name, g.table_name, g.rationale
        from erp_ref.capability_guard g
       where g.capability_code = p_code
       order by g.table_name
    loop
      execute format('select count(*) from %I.%I where tenant_id = $1',
                     r.schema_name, r.table_name)
        into v_rows using v_tenant;
      if v_rows > 0 then
        v_blocked := v_blocked || format(E'  %s.%s holds %s row(s) — %s\n',
                                         r.schema_name, r.table_name, v_rows, r.rationale);
      end if;
    end loop;

    if v_blocked <> '' then
      raise exception E'ERPWARE_CAPABILITY_IN_USE: % cannot be switched off while it has live data\n%',
        p_code, v_blocked
        using errcode = '23514',
              hint = 'Historical records keep the behaviour in force at their time; '
                     'switching off would leave these rows unmaintained instead.';
    end if;

    -- And nothing may depend on it. Disabling one warns what depends on it, and
    -- refusing is the honest form of that warning.
    for r in
      select d.capability_code, d.rationale from erp_ref.capability_dependency d
       where d.requires_code = p_code
         and erp.capability_enabled(d.capability_code, v_from)
    loop
      v_missing := v_missing || format(E'  %s still depends on it — %s\n',
                                       r.capability_code, r.rationale);
    end loop;

    if v_missing <> '' then
      raise exception E'ERPWARE_CAPABILITY_DEPENDED_ON: % is required by capabilities that are on\n%',
        p_code, v_missing using errcode = '23514';
    end if;
  end if;

  -- Close the period in force and open a new one, rather than overwriting. The
  -- history is the point of dating it at all.
  update erp.tenant_capability
     set valid_to = v_from, updated_at = now()
   where tenant_id = v_tenant and capability_code = p_code
     and valid_to is null and valid_from < v_from;

  delete from erp.tenant_capability
   where tenant_id = v_tenant and capability_code = p_code and valid_from = v_from;

  insert into erp.tenant_capability (tenant_id, capability_code, is_enabled, reason, valid_from)
  values (v_tenant, p_code, p_enabled, p_reason, v_from);

  return jsonb_build_object('capability', p_code, 'enabled', p_enabled,
                            'valid_from', v_from);
end;
$$;

-- ── §2.3 a preset is a starting selection, not a tier ────────────────────────

create or replace function erp.apply_preset(p_code text, p_reason text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_applied text[] := '{}';
  r record;
begin
  if not exists (select 1 from erp_ref.preset where code = p_code) then
    raise exception 'ERPWARE_UNKNOWN_PRESET: %', p_code using errcode = '23503';
  end if;

  -- Dependency order, so enabling expiry control after batch control rather
  -- than being refused for the order the rows happen to be in.
  for r in
    with recursive depth as (
      select pc.capability_code, 0 as d
        from erp_ref.preset_capability pc
       where pc.preset_code = p_code
         and not exists (select 1 from erp_ref.capability_dependency x
                          where x.capability_code = pc.capability_code)
      union all
      select pc.capability_code, depth.d + 1
        from erp_ref.preset_capability pc
        join erp_ref.capability_dependency cd on cd.capability_code = pc.capability_code
        join depth on depth.capability_code = cd.requires_code
       where pc.preset_code = p_code and depth.d < 8
    )
    select capability_code, max(d) as d from depth group by 1 order by 2, 1
  loop
    perform erp.set_capability(r.capability_code, true,
      coalesce(p_reason, format('Applied with the %s preset', p_code)));
    v_applied := v_applied || r.capability_code;
  end loop;

  return jsonb_build_object('preset', p_code, 'enabled', to_jsonb(v_applied),
                            'count', cardinality(v_applied));
end;
$$;

comment on function erp.apply_preset is
  'Switches on everything a preset selects, in dependency order. A preset is a '
  'starting selection rather than a tier: anything can be switched individually '
  'afterwards.';

-- ── Reading ──────────────────────────────────────────────────────────────────
--
-- One read, not four. A screen that has to ask three questions to draw one row
-- is a screen that will draw the row wrong once the questions drift apart, so
-- the catalogue carries its own state: what it is, whether it is on, what it
-- needs, what needs it, and — the expensive part — what live data would refuse
-- to let it be switched off right now.

create or replace function erp.capability_catalogue()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_out    jsonb := '[]'::jsonb;
  c        record;
  g        record;
  v_rows   bigint;
  v_holds  jsonb;
begin
  for c in
    select cap.code, cap.title, cap.description, cap.seq,
           erp.capability_enabled(cap.code) as is_enabled
      from erp_ref.capability cap
     order by cap.seq, cap.code
  loop
    v_holds := '[]'::jsonb;
    for g in
      select cg.schema_name, cg.table_name, cg.rationale
        from erp_ref.capability_guard cg
       where cg.capability_code = c.code
       order by cg.table_name
    loop
      execute format('select count(*) from %I.%I where tenant_id = $1',
                     g.schema_name, g.table_name)
        into v_rows using v_tenant;
      if v_rows > 0 then
        v_holds := v_holds || jsonb_build_array(jsonb_build_object(
          'table', g.schema_name || '.' || g.table_name,
          'rows', v_rows, 'rationale', g.rationale));
      end if;
    end loop;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'code', c.code, 'title', c.title, 'description', c.description,
      'seq', c.seq, 'enabled', c.is_enabled,
      'requires', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'code', d.requires_code, 'rationale', d.rationale,
                 'enabled', erp.capability_enabled(d.requires_code))
               order by d.requires_code)
          from erp_ref.capability_dependency d
         where d.capability_code = c.code), '[]'::jsonb),
      'required_by', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'code', d.capability_code, 'rationale', d.rationale,
                 'enabled', erp.capability_enabled(d.capability_code))
               order by d.capability_code)
          from erp_ref.capability_dependency d
         where d.requires_code = c.code), '[]'::jsonb),
      -- Non-empty means switching off would be refused, and this says by what.
      -- The screen can grey the switch and give the reason rather than offering
      -- an action that is going to raise.
      'held_by', v_holds,
      'history', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'enabled', tc.is_enabled, 'reason', tc.reason,
                 'from', tc.valid_from, 'to', tc.valid_to)
               order by tc.valid_from desc)
          from erp.tenant_capability tc
         where tc.tenant_id = v_tenant and tc.capability_code = c.code), '[]'::jsonb)));
  end loop;

  return v_out;
end;
$$;

comment on function erp.capability_catalogue is
  'The whole capability picture for this organisation in one read: state, '
  'prerequisites both ways, and the live data that would refuse a switch-off.';

create or replace function public.erp_capabilities()
returns jsonb
language sql
stable
set search_path = ''
as $$ select erp.capability_catalogue() $$;

create or replace function public.erp_presets()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', p.code, 'title', p.title, 'description', p.description,
           'capabilities', coalesce((
             select jsonb_agg(pc.capability_code order by pc.capability_code)
               from erp_ref.preset_capability pc
              where pc.preset_code = p.code), '[]'::jsonb))
         order by p.seq, p.code), '[]'::jsonb)
    from erp_ref.preset p
$$;

create or replace function public.erp_set_capability(
  p_code text, p_enabled boolean, p_reason text default null,
  p_valid_from date default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp.set_capability(p_code, p_enabled, p_reason, p_valid_from);
end;
$$;

create or replace function public.erp_apply_preset(
  p_code text, p_reason text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp.apply_preset(p_code, p_reason);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_capabilities()',
    'public.erp_presets()',
    'public.erp_set_capability(text, boolean, text, date)',
    'public.erp_apply_preset(text, text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_capability', 'erp.authorise',
   'Switches a capability on or off for this organisation. Volatile because it '
   'writes an effective-dated period; gated on administration.configure because '
   'a capability decides which rules run, not merely what is on screen.'),
  ('erp_apply_preset', 'erp.authorise',
   'Switches on everything a preset selects. Same authority as switching them '
   'one at a time, which is exactly what it does.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- The assertion looks across every organisation, which erp.capability_enabled()
-- deliberately cannot: it answers for the caller's own tenant and nothing else.
-- This is the same lookup with the organisation named, kept in erp rather than
-- public so it is not a door — row security still applies to anyone but the
-- owner, so it widens nothing.
create or replace function erp.capability_on(
  p_tenant_id uuid, p_code text, p_on date default current_date)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select tc.is_enabled
      from erp.tenant_capability tc
     where tc.tenant_id = p_tenant_id
       and tc.capability_code = p_code
       and daterange(tc.valid_from, tc.valid_to, '[)') @> coalesce(p_on, current_date)
     order by tc.valid_from desc
     limit 1), false)
$$;

-- ── The assertion ────────────────────────────────────────────────────────────
--
-- The register states intent; this refuses to let the deployment disagree with
-- it. Five ways it can, and the first is the one that matters most: a guard
-- naming a table that does not exist is a refusal that never fires, which is
-- indistinguishable from having no guard at all until somebody switches batch
-- control off on top of a hundred thousand batches.

create or replace function erp.assert_capabilities_sound()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_detail text := '';
  v_count  integer := 0;
  r        record;
begin
  -- 1. A guard has to be able to look. Not just a table: a table with a
  --    tenant_id, because the guard counts rows for one organisation.
  for r in
    select g.capability_code, g.schema_name, g.table_name,
           to_regclass(g.schema_name || '.' || g.table_name) is null as absent
      from erp_ref.capability_guard g
     order by g.capability_code, g.table_name
  loop
    if r.absent then
      v_detail := v_detail || format(
        E'  %s is guarded by %s.%s, which does not exist — the refusal can never fire\n',
        r.capability_code, r.schema_name, r.table_name);
      v_count := v_count + 1;
    elsif not exists (
      select 1 from pg_catalog.pg_attribute a
       where a.attrelid = to_regclass(r.schema_name || '.' || r.table_name)
         and a.attname = 'tenant_id' and a.attnum > 0 and not a.attisdropped)
    then
      v_detail := v_detail || format(
        E'  %s is guarded by %s.%s, which has no tenant_id — the guard would count every organisation''s rows\n',
        r.capability_code, r.schema_name, r.table_name);
      v_count := v_count + 1;
    end if;
  end loop;

  -- 2. No cycles. erp.set_capability() refuses to enable A before B and B
  --    before A, so a cycle is a pair of capabilities neither of which can ever
  --    be switched on — a dead branch of the catalogue rather than a rule.
  for r in
    with recursive reach(root, code, depth) as (
      select d.capability_code, d.requires_code, 1
        from erp_ref.capability_dependency d
      union all
      select reach.root, d.requires_code, reach.depth + 1
        from reach
        join erp_ref.capability_dependency d on d.capability_code = reach.code
       where reach.depth < 12
    )
    select distinct root from reach where code = root order by root
  loop
    v_detail := v_detail || format(
      E'  %s depends on itself through the dependency graph — it could never be enabled\n', r.root);
    v_count := v_count + 1;
  end loop;

  -- 3. A preset that selects a capability without its prerequisites is a
  --    preset that raises the moment somebody applies it. Better to find that
  --    here than on an organisation's first day.
  for r in
    select pc.preset_code, pc.capability_code, d.requires_code
      from erp_ref.preset_capability pc
      join erp_ref.capability_dependency d on d.capability_code = pc.capability_code
     where not exists (
       select 1 from erp_ref.preset_capability pc2
        where pc2.preset_code = pc.preset_code
          and pc2.capability_code = d.requires_code)
     order by pc.preset_code, pc.capability_code, d.requires_code
  loop
    v_detail := v_detail || format(
      E'  preset %s selects %s but not its prerequisite %s — applying it would be refused\n',
      r.preset_code, r.capability_code, r.requires_code);
    v_count := v_count + 1;
  end loop;

  -- 4. And no organisation may sit in the state the switch refuses to create.
  --    set_capability() cannot produce this; a change set promoting rows in the
  --    wrong order, or a hand edit before go-live, can.
  for r in
    select t.code as tenant_code, d.capability_code, d.requires_code
      from erp.tenant t
      join erp_ref.capability_dependency d on true
     where erp.capability_on(t.id, d.capability_code)
       and not erp.capability_on(t.id, d.requires_code)
     order by t.code, d.capability_code
  loop
    v_detail := v_detail || format(
      E'  %s has %s on with its prerequisite %s off\n',
      r.tenant_code, r.capability_code, r.requires_code);
    v_count := v_count + 1;
  end loop;

  -- 5. Overlapping periods would make erp.capability_enabled() answer by
  --    accident of ordering rather than by fact.
  for r in
    select t.code as tenant_code, a.capability_code, a.valid_from, b.valid_from as other
      from erp.tenant_capability a
      join erp.tenant_capability b
        on b.tenant_id = a.tenant_id and b.capability_code = a.capability_code
       and b.valid_from > a.valid_from
       and daterange(a.valid_from, a.valid_to, '[)')
        && daterange(b.valid_from, b.valid_to, '[)')
      join erp.tenant t on t.id = a.tenant_id
     order by t.code, a.capability_code, a.valid_from
  loop
    v_detail := v_detail || format(
      E'  %s has overlapping %s periods from %s and %s\n',
      r.tenant_code, r.capability_code, r.valid_from, r.other);
    v_count := v_count + 1;
  end loop;

  if v_count > 0 then
    raise exception E'ERPWARE_CAPABILITIES_UNSOUND: % finding(s)\n%', v_count, v_detail
      using errcode = '23514';
  end if;

  return format('capabilities: %s in the catalogue, %s dependencies, %s guards, %s presets',
    (select count(*) from erp_ref.capability),
    (select count(*) from erp_ref.capability_dependency),
    (select count(*) from erp_ref.capability_guard),
    (select count(*) from erp_ref.preset));
end;
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq)
values ('capabilities_sound', 'Capabilities', 'assertion', 'platform',
        'assert_capabilities_sound', '', null, '',
        'Every guard names a real table, no dependency is circular, every preset '
        'carries its prerequisites, and no organisation has a capability on with '
        'its prerequisite off.', true, 20)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb, function_name = excluded.function_name;

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();

select erp.assert_capabilities_sound();
select erp.assert_diagnostics_registered();
select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_audit_coverage();
