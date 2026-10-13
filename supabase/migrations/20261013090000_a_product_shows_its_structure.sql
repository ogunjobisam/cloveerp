-- A product shows its structure.
--
-- Manufacturing depth, part 2 of 4 (theme 3, owner, 13 October 2026). A made
-- product's bill of materials could be defined and withdrawn, and nothing
-- else: nobody could see what a product is made of below its first level,
-- which products use a component, or what a product costs to make.
-- erp.roll_up_standard_cost existed and nothing called it; and it costed
-- labour wrongly whenever a run makes more than one: it took a routing's
-- set-up and one unit's run minutes for the whole run, then divided by what
-- the run makes, so a run of ten carried one unit's run time.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.roll_up_standard_cost costs a run as it is made: the bill's
--      components for the run, and the routing's set-up once plus its run
--      minutes for every unit the run makes, at each operation's cost an hour,
--      over what the run makes and its yield.
--   B. erp.bom_explosion: a product's structure, every level, with what each
--      component takes per parent and for the quantity asked, whether it is
--      made or bought, and what it costs.
--   C. public.erp_product_structure: the structure, the routing's operations
--      for the quantity, the cost per unit split into materials and labour
--      beside what the product costs now, and where the product is itself
--      used. Read on the Manufacturing page's Product structure screen.
--   D. public.erp_adopt_rolled_up_cost: the rolled-up cost made the product's
--      standard, through erp.set_standard_cost and its own rules
--      (finance.configure; standard-costed; no stock on hand to revalue).
--   E. erp_test.product_structure_suite proves A to D, and F.
--   F. A product's bills and routings are numbered across its sites, so a
--      site's own bill, or a routing at a second site, no longer collides
--      with the product's first.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The roll-up, costed as a run is made
-- ─────────────────────────────────────────────────────────────────────────────

-- What one unit of a product costs to make at a site, split: the materials
-- (each component's own cost, rolled up where it is made), and the labour of
-- its routing. A bought product's is its cost at the site, all materials.
create or replace function erp.made_cost(p_item_id uuid, p_site_id uuid, p_depth integer default 0)
returns table(materials_minor numeric, labour_minor numeric, made boolean)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_bom    erp.bom%rowtype;
  v_rout   erp.routing%rowtype;
  v_mat    numeric := 0;
  v_lab    numeric := 0;
  r        record;
  c        record;
  v_run    numeric;
begin
  if p_depth > 10 then
    raise exception 'CLOVEERP_BILL_TOO_DEEP: more than ten levels, which is a cycle rather than a product'
      using errcode = '23514', hint = 'Look for a component that is, a level or more down, made of the product itself.';
  end if;

  select * into v_bom from erp.bom b
   where b.tenant_id = v_tenant and b.item_id = p_item_id and b.status = 'active'
     and (b.site_id is null or b.site_id = p_site_id)
   order by (b.site_id is not null) desc, b.version desc limit 1;
  if v_bom.id is null then
    return query select coalesce(erp.unit_cost_at(p_item_id, p_site_id), 0)::numeric, 0::numeric, false;
    return;
  end if;

  v_run := coalesce(nullif(v_bom.output_quantity, 0), 1);
  for r in
    select bl.component_item_id, bl.quantity, bl.scrap_factor
      from erp.bom_line bl
     where bl.tenant_id = v_tenant and bl.bom_id = v_bom.id and not bl.is_alternate
  loop
    select * into c from erp.made_cost(r.component_item_id, p_site_id, p_depth + 1);
    v_mat := v_mat + (c.materials_minor + c.labour_minor) * r.quantity * (1 + coalesce(r.scrap_factor, 0));
  end loop;

  select * into v_rout from erp.routing rt
   where rt.tenant_id = v_tenant and rt.item_id = p_item_id and rt.status = 'active'
     and (rt.site_id is null or rt.site_id = p_site_id)
   order by (rt.site_id is not null) desc, rt.version desc limit 1;
  if v_rout.id is not null then
    select coalesce(sum((coalesce(ro.setup_minutes, 0) + coalesce(ro.run_minutes_per_unit, 0) * v_run)
                        / 60.0 * coalesce(ro.cost_rate_minor_per_hour, 0)), 0)
      into v_lab
      from erp.routing_operation ro
     where ro.tenant_id = v_tenant and ro.routing_id = v_rout.id;
  end if;

  return query select v_mat / v_run / coalesce(nullif(v_bom.yield_factor, 0), 1),
                      v_lab / v_run / coalesce(nullif(v_bom.yield_factor, 0), 1),
                      true;
end;
$$;
revoke all on function erp.made_cost(uuid, uuid, integer) from public, anon;

create or replace function erp.roll_up_standard_cost(p_item_id uuid, p_site_id uuid, p_depth integer default 0)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- One unit's cost to make, rolled up through every level, labour costed as
  -- the run is made (20261013090000).
  select round(m.materials_minor + m.labour_minor)::bigint from erp.made_cost(p_item_id, p_site_id, p_depth) m
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The structure, every level
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.bom_explosion(p_item_id uuid, p_site_id uuid, p_quantity numeric default 1)
returns table(level integer, path text, parent_item_id uuid, item_id uuid, code text, name text,
              quantity_per numeric, quantity numeric, uom text, made boolean, phantom boolean,
              unit_cost_minor numeric, cost_minor numeric)
language sql
stable
set search_path = ''
as $$
  -- Each level's components (20261013090000): what one of the parent takes,
  -- scaled by the bill's run and its scrap, and what the quantity asked takes
  -- in all; a component made here is opened in turn. Ten levels at most, as
  -- the roll-up allows.
  with recursive bill as (
    select distinct on (b.item_id) b.*
      from erp.bom b
     where b.tenant_id = erp.require_tenant_id() and b.status = 'active'
       and (b.site_id is null or b.site_id = p_site_id)
     order by b.item_id, (b.site_id is not null) desc, b.version desc
  ), tree as (
    select 1 as level, lpad(bl.seq::text, 4, '0') as path, bl.bom_id, b.item_id as parent_item_id,
           bl.component_item_id as item_id,
           bl.quantity * (1 + coalesce(bl.scrap_factor, 0)) / coalesce(nullif(b.output_quantity, 0), 1)
             / coalesce(nullif(b.yield_factor, 0), 1) as quantity_per,
           coalesce(p_quantity, 1) * bl.quantity * (1 + coalesce(bl.scrap_factor, 0))
             / coalesce(nullif(b.output_quantity, 0), 1) / coalesce(nullif(b.yield_factor, 0), 1) as quantity,
           bl.is_phantom
      from bill b
      join erp.bom_line bl on bl.tenant_id = b.tenant_id and bl.bom_id = b.id and not bl.is_alternate
     where b.item_id = p_item_id
    union all
    select t.level + 1, t.path || '.' || lpad(bl.seq::text, 4, '0'), bl.bom_id, b.item_id, bl.component_item_id,
           bl.quantity * (1 + coalesce(bl.scrap_factor, 0)) / coalesce(nullif(b.output_quantity, 0), 1)
             / coalesce(nullif(b.yield_factor, 0), 1),
           t.quantity * bl.quantity * (1 + coalesce(bl.scrap_factor, 0))
             / coalesce(nullif(b.output_quantity, 0), 1) / coalesce(nullif(b.yield_factor, 0), 1),
           bl.is_phantom
      from tree t
      join bill b on b.item_id = t.item_id
      join erp.bom_line bl on bl.tenant_id = b.tenant_id and bl.bom_id = b.id and not bl.is_alternate
     where t.level < 10
  )
  select t.level, t.path, t.parent_item_id, t.item_id, i.code, i.name, t.quantity_per, t.quantity, u.code,
         m.made, coalesce(t.is_phantom, false),
         m.materials_minor + m.labour_minor,
         t.quantity * (m.materials_minor + m.labour_minor)
    from tree t
    join erp.item i on i.tenant_id = erp.require_tenant_id() and i.id = t.item_id
    left join erp.uom u on u.tenant_id = i.tenant_id and u.id = i.stock_uom_id
    cross join lateral erp.made_cost(t.item_id, p_site_id) m
   order by t.path
$$;
revoke all on function erp.bom_explosion(uuid, uuid, numeric) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. What the screen reads
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_product_structure(p_item_id uuid, p_site_id uuid, p_quantity numeric default 1)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_qty    numeric := greatest(coalesce(p_quantity, 1), 0.000001);
  m        record;
  v_bom    erp.bom%rowtype;
  v_rout   erp.routing%rowtype;
begin
  -- A read, scoped by row security like the page's other lists.
  if not exists (select 1 from erp.item i where i.tenant_id = v_tenant and i.id = p_item_id) then
    raise exception 'CLOVEERP_UNKNOWN_ITEM: % is not a product here', p_item_id
      using errcode = '23503', hint = 'Choose a product from the list.';
  end if;
  select * into m from erp.made_cost(p_item_id, p_site_id);
  select * into v_bom from erp.bom b
   where b.tenant_id = v_tenant and b.item_id = p_item_id and b.status = 'active'
     and (b.site_id is null or b.site_id = p_site_id)
   order by (b.site_id is not null) desc, b.version desc limit 1;
  select * into v_rout from erp.routing rt
   where rt.tenant_id = v_tenant and rt.item_id = p_item_id and rt.status = 'active'
     and (rt.site_id is null or rt.site_id = p_site_id)
   order by (rt.site_id is not null) desc, rt.version desc limit 1;

  return jsonb_build_object(
    'item', (select jsonb_build_object('item_id', i.id, 'code', i.code, 'name', i.name)
               from erp.item i where i.tenant_id = v_tenant and i.id = p_item_id),
    'quantity', v_qty,
    'currency', (select e.base_currency from erp.site s join erp.entity e on e.tenant_id = s.tenant_id and e.id = s.entity_id
                  where s.tenant_id = v_tenant and s.id = p_site_id),
    'bom', case when v_bom.id is not null then jsonb_build_object('code', v_bom.code, 'version', v_bom.version,
                                                                  'output_quantity', v_bom.output_quantity) end,
    'routing', case when v_rout.id is not null then jsonb_build_object('code', v_rout.code, 'version', v_rout.version) end,
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
                                 'level', x.level, 'path', x.path, 'item_id', x.item_id, 'code', x.code, 'name', x.name,
                                 'quantity_per', round(x.quantity_per, 6), 'quantity', round(x.quantity, 6), 'uom', x.uom,
                                 'made', x.made, 'phantom', x.phantom,
                                 'unit_cost_minor', round(x.unit_cost_minor), 'cost_minor', round(x.cost_minor))
                                 order by x.path)
                         from erp.bom_explosion(p_item_id, p_site_id, v_qty) x), '[]'::jsonb),
    'operations', coalesce((select jsonb_agg(jsonb_build_object(
                                      'seq', ro.seq, 'name', ro.name, 'work_centre', ro.work_centre_code,
                                      'minutes', round(coalesce(ro.setup_minutes, 0) + coalesce(ro.run_minutes_per_unit, 0) * v_qty, 2),
                                      'cost_minor', round((coalesce(ro.setup_minutes, 0) + coalesce(ro.run_minutes_per_unit, 0) * v_qty)
                                                          / 60.0 * coalesce(ro.cost_rate_minor_per_hour, 0)))
                                      order by ro.seq)
                              from erp.routing_operation ro
                             where ro.tenant_id = v_tenant and ro.routing_id = v_rout.id), '[]'::jsonb),
    'made', m.made,
    'materials_minor', round(m.materials_minor),
    'labour_minor', round(m.labour_minor),
    'rolled_up_minor', round(m.materials_minor + m.labour_minor),
    'current_cost_minor', erp.unit_cost_at(p_item_id, p_site_id),
    'costing_method', erp.costing_method_for(p_item_id, p_site_id)::text,
    'where_used', coalesce((select jsonb_agg(distinct jsonb_build_object(
                                      'item_id', pi.id, 'code', pi.code, 'name', pi.name, 'bom', b.code,
                                      'quantity_per', round(bl.quantity / coalesce(nullif(b.output_quantity, 0), 1), 6)))
                              from erp.bom_line bl
                              join erp.bom b on b.tenant_id = bl.tenant_id and b.id = bl.bom_id and b.status = 'active'
                              join erp.item pi on pi.tenant_id = b.tenant_id and pi.id = b.item_id
                             where bl.tenant_id = v_tenant and bl.component_item_id = p_item_id), '[]'::jsonb));
end;
$$;
revoke all on function public.erp_product_structure(uuid, uuid, numeric) from public, anon;
grant execute on function public.erp_product_structure(uuid, uuid, numeric) to authenticated, service_role;
comment on function public.erp_product_structure(uuid, uuid, numeric) is
  'A product''s structure at a site, every level, with its routing''s operations, its cost per unit to make split into '
  'materials and labour beside what it costs now, and where it is used (20261013090000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The rolled-up cost made the standard
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.adopt_rolled_up_cost(p_item_id uuid, p_site_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cost bigint;
  v_was  bigint;
begin
  perform erp.authorise('finance.configure', null, p_site_id, null, 'item_cost', p_item_id, null);
  v_was := erp.unit_cost_at(p_item_id, p_site_id);
  if not exists (select 1 from erp.bom b where b.tenant_id = erp.require_tenant_id() and b.item_id = p_item_id
                                         and b.status = 'active' and (b.site_id is null or b.site_id = p_site_id)) then
    raise exception 'CLOVEERP_NOT_MADE_HERE: the product has no bill of materials in force here, so nothing rolls up'
      using errcode = '23514', hint = 'Define its bill of materials, and its routing, first.';
  end if;
  v_cost := erp.roll_up_standard_cost(p_item_id, p_site_id);
  -- erp.set_standard_cost authorises finance.configure and refuses a product
  -- not standard-costed, or with stock on hand it would revalue.
  perform erp.set_standard_cost(p_item_id, p_site_id, v_cost, null);
  return jsonb_build_object('item_id', p_item_id, 'was_minor', v_was, 'standard_minor', v_cost);
end;
$$;
revoke all on function erp.adopt_rolled_up_cost(uuid, uuid) from public, anon;

create or replace function public.erp_adopt_rolled_up_cost(p_item_id uuid, p_site_id uuid)
returns jsonb
language sql
set search_path = ''
as $$ select erp.adopt_rolled_up_cost(p_item_id, p_site_id) $$;
revoke all on function public.erp_adopt_rolled_up_cost(uuid, uuid) from public, anon;
grant execute on function public.erp_adopt_rolled_up_cost(uuid, uuid) to authenticated, service_role;
comment on function public.erp_adopt_rolled_up_cost(uuid, uuid) is
  'Makes a made product''s rolled-up cost its standard at a site, through erp.set_standard_cost (20261013090000). '
  'Authorises finance.configure.';

-- ─────────────────────────────────────────────────────────────────────────────
-- F. A product's bills and routings numbered across its sites
-- ─────────────────────────────────────────────────────────────────────────────

-- A bill or routing's code is BOM-<product>-V<n> or RT-<product>-V<n>, unique
-- in the organisation, but its version was counted within its site: a site's
-- own bill for a product with a general one, or a product routed at a second
-- site, came out V1 again and was refused with a duplicate key. The version
-- is now counted across the product's sites; superseding stays within one.
do $number$
declare
  r      record;
  v_def  text;
  v_hits integer;
begin
  for r in
    select * from (values
      ('erp.create_bom(uuid,uuid,text,numeric,date,jsonb)',
       $o$  select coalesce(max(b.version), 0) + 1 into v_version
    from erp.bom b
   where b.tenant_id = v_tenant and b.item_id = p_item_id
     and ((b.site_id is null and p_site_id is null) or b.site_id = p_site_id);$o$,
       $n$  -- Counted across the product's sites, so the code is unique (20261013090000).
  select coalesce(max(b.version), 0) + 1 into v_version
    from erp.bom b
   where b.tenant_id = v_tenant and b.item_id = p_item_id;$n$),
      ('erp.define_routing(uuid,uuid,text,jsonb,date)',
       $o$  select coalesce(max(r.version), 0) + 1 into v_version
    from erp.routing r where r.tenant_id = v_tenant and r.item_id = p_item_id and r.site_id = p_site_id;$o$,
       $n$  -- Counted across the product's sites, so the code is unique (20261013090000).
  select coalesce(max(r.version), 0) + 1 into v_version
    from erp.routing r where r.tenant_id = v_tenant and r.item_id = p_item_id;$n$)
    ) t(sig, old, new)
  loop
    v_def := pg_get_functiondef(r.sig::regprocedure);
    continue when position('20261013090000' in v_def) > 0;
    v_hits := (length(v_def) - length(replace(v_def, r.old, ''))) / length(r.old);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % version anchor found % time(s)', r.sig, v_hits;
    end if;
    execute replace(v_def, r.old, r.new);
  end loop;
end
$number$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Governance
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_adopt_rolled_up_cost', 'erp.adopt_rolled_up_cost',
   'Makes a made product''s rolled-up cost its standard, through erp.set_standard_cost; authorises finance.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_NOT_MADE_HERE',
  'Adopting a rolled-up cost for a product with no bill of materials in force at the site.',
  'A cost rolls up from what a product is made of; a bought product has nothing to roll up.',
  'Define its bill of materials, and its routing, first.');

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('nav.production_structure', 'en', 'Product structure', 'production', 'The product structure screen (20261013090000).'),
  ('nav.production_structure', 'de', 'Produktstruktur', 'production', 'Produktstruktur (20261013090000).')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The product structure screen (20261013090000).'
  from (values
    ('Adopt as standard cost'),
    ('Bill of materials'),
    ('Bought, not made here'),
    ('Choose a made product to see its structure and its cost.'),
    ('Costs now'),
    ('Each takes'),
    ('In all'),
    ('Labour, one'),
    ('Made'),
    ('made'),
    ('Made of'),
    ('Materials, one'),
    ('None yet'),
    ('Opening the structure…'),
    ('phantom'),
    ('Product structure'),
    ('Refused while stock is on hand at the old standard.'),
    ('Rolled up, one'),
    ('The rolled-up cost is now the product''s standard.'),
    ('Used in'),
    ('What a made product is made of at every level, how long its routing takes, and what one costs to make.')) v(text)
on conflict do nothing;

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/production/structure', 'nav.production_structure', 'production',
   'What a made product is made of at every level, how long its routing takes, what one costs to make in materials and labour beside what it costs now, and which products use it.',
   '["Choose the product and the site.","Read its structure: each level''s components, what one takes and what the quantity takes in all.","Read its operations and what they cost for the quantity.","Compare the rolled-up cost with its cost now; adopt it as the standard where the product is standard-costed."]',
   'Choose a made product to see its structure and its cost.',
   '{erp_product_structure,erp_adopt_rolled_up_cost}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code, summary = excluded.summary,
  steps = excluded.steps, next_action = excluded.next_action, actions = excluded.actions;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.product_structure_suite()
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
  v_site   uuid;
  v_site2  uuid;
  v_uom    uuid;
  v_fg     uuid;
  v_sub    uuid;
  v_rm     uuid;
  v_pk     uuid;
  x        jsonb;
  v_ok     boolean;
  v_msg    text;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzpst' || v_tag, 'Product Structure Suite',
      'admin@demo-zzpst' || v_tag || '.test', 'Structure Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzpst' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;

    v_step := 'a product made of a sub-assembly made of steel, and a box';
    select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (v_tenant, 'ZPSFG' || v_tag, 'Structure Widget', v_uom, 'active') returning id into v_fg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (v_tenant, 'ZPSSA' || v_tag, 'Structure Frame', v_uom, 'active') returning id into v_sub;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (v_tenant, 'ZPSRM' || v_tag, 'Structure Steel', v_uom, 'active') returning id into v_rm;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (v_tenant, 'ZPSPK' || v_tag, 'Structure Box', v_uom, 'active') returning id into v_pk;
    -- Bought costs: steel £2.00, a box £0.50.
    insert into erp.item_cost (tenant_id, item_id, site_id, method, unit_cost_minor, currency, quantity_on_hand, value_minor)
    values (v_tenant, v_rm, v_site, 'average', 200, 'GBP', 0, 0),
           (v_tenant, v_pk, v_site, 'average', 50, 'GBP', 0, 0);
    -- A frame takes 3 steel; a widget takes 2 frames and a box. A run of ten widgets.
    perform public.erp_create_bom(v_sub, null, null, 1, null,
      jsonb_build_array(jsonb_build_object('component_item_id', v_rm, 'quantity', 3)));
    perform public.erp_create_bom(v_fg, null, null, 10, null,
      jsonb_build_array(jsonb_build_object('component_item_id', v_sub, 'quantity', 20),
                        jsonb_build_object('component_item_id', v_pk, 'quantity', 10)));
    -- Assembly: 60 minutes' set-up, then 6 minutes a widget, at £30 an hour.
    perform public.erp_define_work_centre(v_site, 'ASM-1', 'Assembly', 8, 5, 100, 3000);
    perform public.erp_define_routing(v_fg, v_site, null,
      '[{"name":"Assemble","work_centre_code":"ASM-1","setup_minutes":60,"run_minutes_per_unit":6}]'::jsonb);

    -- ── 1. Labour costed as the run is made ─────────────────────────────────
    v_cases := v_cases + 1;
    x := public.erp_product_structure(v_fg, v_site, 1);
    -- Materials a widget: 2 frames × 3 steel × £2 = £12, and a £0.50 box.
    -- Labour a run of ten: (60 + 6 × 10) minutes at £30 an hour = £60; a widget £6.
    case_name := 'a widget costs its materials through every level, and the run''s labour shared across the ten it makes';
    passed := v_state is null
          and (x ->> 'materials_minor')::numeric = 1250
          and (x ->> 'labour_minor')::numeric = 600
          and (x ->> 'rolled_up_minor')::numeric = 1850
          and erp.roll_up_standard_cost(v_fg, v_site) = 1850;
    detail := coalesce(v_state, format('materials %s labour %s', x ->> 'materials_minor', x ->> 'labour_minor'));
    return next;

    -- ── 2. Every level ──────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    x := public.erp_product_structure(v_fg, v_site, 5);
    case_name := 'the structure opens every level, with what one takes and what the quantity takes in all';
    passed := v_state is null
          and jsonb_array_length(x -> 'lines') = 3
          and exists (select 1 from jsonb_array_elements(x -> 'lines') l
                       where l ->> 'code' = 'ZPSSA' || v_tag and (l ->> 'level')::integer = 1 and (l ->> 'made')::boolean
                         and (l ->> 'quantity_per')::numeric = 2 and (l ->> 'quantity')::numeric = 10)
          and exists (select 1 from jsonb_array_elements(x -> 'lines') l
                       where l ->> 'code' = 'ZPSRM' || v_tag and (l ->> 'level')::integer = 2 and not (l ->> 'made')::boolean
                         and (l ->> 'quantity')::numeric = 30 and (l ->> 'cost_minor')::numeric = 6000)
          and (x -> 'operations' -> 0 ->> 'minutes')::numeric = 90;
    detail := coalesce(v_state, left((x -> 'lines')::text, 300));
    return next;

    -- ── 3. Where used ───────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    x := public.erp_product_structure(v_sub, v_site, 1);
    case_name := 'a sub-assembly says which products use it';
    passed := v_state is null
          and jsonb_array_length(x -> 'where_used') = 1
          and x -> 'where_used' -> 0 ->> 'code' = 'ZPSFG' || v_tag
          and (x -> 'where_used' -> 0 ->> 'quantity_per')::numeric = 2;
    detail := coalesce(v_state, (x -> 'where_used')::text);
    return next;

    -- ── 4. Adopted only where it may be ─────────────────────────────────────
    v_step := 'adopting the roll-up';
    begin
      perform public.erp_adopt_rolled_up_cost(v_rm, v_site);
      v_ok := false; v_msg := 'a bought product adopted a roll-up';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_NOT_MADE_HERE%'; v_msg := left(sqlerrm, 90);
    end;
    begin
      perform public.erp_adopt_rolled_up_cost(v_fg, v_site);
      v_ok := false; v_msg := v_msg || ' | an average-costed product given a standard';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_NOT_STANDARD_COSTED%'; v_msg := v_msg || ' | ' || left(sqlerrm, 60);
    end;
    -- Made standard-costed, it is adopted at what it rolls up to.
    insert into erp.costing_policy (tenant_id, code, method, item_id)
    values (v_tenant, 'ZPS-STD', 'standard', v_fg);
    x := public.erp_adopt_rolled_up_cost(v_fg, v_site);
    v_ok := v_ok and (x ->> 'standard_minor')::bigint = 1850 and erp.unit_cost_at(v_fg, v_site) = 1850;
    v_msg := v_msg || ' | ' || x::text;
    v_cases := v_cases + 1;
    case_name := 'a roll-up is adopted as the standard of a made product that is standard-costed, and of no other';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 5. A site's own bill ─────────────────────────────────────────────
    v_step := 'a frame made here of four steel';
    perform public.erp_create_bom(v_sub, v_site, null, 1, null,
      jsonb_build_array(jsonb_build_object('component_item_id', v_rm, 'quantity', 4)));
    x := public.erp_product_structure(v_fg, v_site, 1);
    -- 2 frames × 4 steel × £2 = £16, a £0.50 box, £6 labour.
    v_cases := v_cases + 1;
    case_name := 'a site''s own bill is the one its structure and its cost are read from';
    passed := v_state is null
          and (x ->> 'rolled_up_minor')::numeric = 2250
          and exists (select 1 from jsonb_array_elements(x -> 'lines') l
                       where l ->> 'code' = 'ZPSRM' || v_tag and (l ->> 'quantity')::numeric = 8);
    detail := coalesce(v_state, format('rolled up %s', x ->> 'rolled_up_minor'));
    return next;

    -- ── 6. A second site's routing ──────────────────────────────────────────
    v_step := 'the widget routed at a second site';
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    select v_tenant, s.entity_id, 'ZPS2' || upper(v_tag), 'Structure Second Site', 'production', 'active'
      from erp.site s where s.id = v_site
    returning id into v_site2;
    perform public.erp_define_work_centre(v_site2, 'ASM-1', 'Assembly', 8, 5, 100, 3000);
    perform public.erp_define_routing(v_fg, v_site2, null,
      '[{"name":"Assemble","work_centre_code":"ASM-1","setup_minutes":30,"run_minutes_per_unit":6}]'::jsonb);
    v_cases := v_cases + 1;
    case_name := 'a site''s own bill and a second site''s routing take the product''s next version, not its first again';
    passed := v_state is null
          and (select count(distinct b.code) from erp.bom b where b.tenant_id = v_tenant and b.item_id = v_sub) = 2
          and (select count(distinct r.code) from erp.routing r where r.tenant_id = v_tenant and r.item_id = v_fg) = 2
          and (select count(*) from erp.routing r where r.tenant_id = v_tenant and r.item_id = v_fg and r.status = 'active') = 2;
    detail := coalesce(v_state, (select string_agg(r.code || ' ' || r.status, ', ') from erp.routing r
                                  where r.tenant_id = v_tenant and r.item_id = v_fg));
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
    raise exception 'CLOVEERP_PRODUCT_STRUCTURE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.product_structure_suite() from public, anon, authenticated;

create or replace function erp_test.assert_product_structure_suite()
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
  create temp table if not exists _product_structure on commit drop as
    select * from erp_test.product_structure_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _product_structure;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_PRODUCT_STRUCTURE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_PRODUCT_STRUCTURE_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('product structure: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_product_structure_suite() from public, anon, authenticated;

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_write_only_columns();
