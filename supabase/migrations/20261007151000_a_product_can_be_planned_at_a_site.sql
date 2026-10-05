set lock_timeout = '30s';

-- =============================================================================
-- 20261007151000  A product can be planned at a site
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-23). "Work out what
-- to order" ran, raised nothing, and said "Nothing at that site runs short
-- within the horizon" while open sales orders at that site wanted products
-- with no stock. erp.run_planning reads only the products planned at the site
-- (a row of erp.item_site), and nothing on any screen writes that row: the
-- product import does, and "Adopt the calculated policy" only changes one
-- that is there already, refusing CLOVEERP_NOT_STOCKED_HERE otherwise. So a
-- product with open orders and no planning row was never looked at, and the
-- run said nothing. That bites any organisation that installs Planning. The
-- demonstration has not installed it (decision 6), which is why it has none.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Three refusals: no policy of that code, no policy that orders, and
--      CLOVEERP_NOT_STOCKED_HERE, which was raised and never registered, now
--      naming what to do. "Adopt the calculated policy" says it itself, with
--      that next step, before it works anything out.
--   B. erp.plan_item_at_site(item, site, policy) and its door
--      public.erp_plan_item_at_site. It authorises planning.run at the site,
--      as running planning and adopting a calculated policy do, and plans the
--      product there under the policy named, or the standard one when none is
--      named: a new planning row, or the one there stocked and active again.
--   C. erp.run_planning: a product that open orders or the forecast want at
--      the site, and that nothing plans there, is an exception of the run
--      (no supply source), as a component the bills want already is. A
--      product somebody chose not to stock there, or to plan with a policy
--      that never orders, is that choice and is not reported.
--   D. The door's write allowance, its place in the Planning screen's help,
--      and the words of its action.
--   E. erp_test.plan_item_at_site_suite.
--
-- The screen's half is in src/lib/modules.tsx ("Plan a product at a site",
-- on Planning's actions, with no step of its own, so the planning flow and
-- its budget are unchanged) and src/lib/plain-words.ts, where a run that
-- raised nothing now says only what it counted.
--
-- On production: a function, its door and their registrations are added, and
-- erp.run_planning and erp.apply_calculated_policy are restated. No table is altered and no row of any
-- organisation is changed. The next planning run in an organisation with
-- open orders for unplanned products reports them as exceptions.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_NOT_STOCKED_HERE',
  'Working out or adopting a stocking policy for a product that is not planned at that site.',
  'Planning keeps a product''s ordering figures for each site, and this product has none at this site yet.',
  'Plan the product at this site first, with Plan a product at a site in Planning, then ask again.');

select erp.register_refusal('CLOVEERP_UNKNOWN_PLANNING_POLICY',
  'Planning a product with a planning policy the organisation does not have, or no longer uses.',
  'The policy decides when the run orders a product and how much, so it has to be one in use.',
  'Leave the policy empty to use the standard one, or type the code of a policy in use, such as standard.');

select erp.register_refusal('CLOVEERP_NO_PLANNING_POLICY',
  'Planning a product when the organisation has no planning policy that orders.',
  'Without a policy that orders, the run would look at the product and never order it.',
  'Install Planning, which sets up the standard planning policies, then plan the product.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The routine and its door
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.plan_item_at_site(p_item_id uuid, p_site_id uuid, p_policy_code text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_code   text := nullif(btrim(coalesce(p_policy_code, '')), '');
  v_item   text;
  v_site   text;
  pp       erp.planning_policy%rowtype;
  v_id     uuid;
  v_added  boolean;
begin
  -- A product planned at a site (20261007151000): the row erp.run_planning
  -- reads, which no screen wrote. Under the policy named, or the standard
  -- one, the policy that orders by the reorder point, when none is named.
  perform erp.authorise('planning.run', null, p_site_id, null, 'item', p_item_id);

  select it.code into v_item from erp.item it where it.tenant_id = v_tenant and it.id = p_item_id;
  if v_item is null then
    raise exception 'CLOVEERP_UNKNOWN_ITEM: no product %', p_item_id
      using errcode = '23503', hint = 'Choose the product from the list.';
  end if;
  select s.code into v_site from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id;
  if v_site is null then
    raise exception 'CLOVEERP_UNKNOWN_SITE: no site %', p_site_id
      using errcode = '23503', hint = 'Choose the site from the list.';
  end if;

  if v_code is not null then
    select * into pp from erp.planning_policy x
     where x.tenant_id = v_tenant and x.code = v_code and x.status = 'active';
    if not found then
      raise exception 'CLOVEERP_UNKNOWN_PLANNING_POLICY: no planning policy % in use', v_code
        using errcode = '23503',
              hint = 'Leave the policy empty to use the standard one, or type the code of a policy in use, such as standard.';
    end if;
  else
    select * into pp from erp.planning_policy x
     where x.tenant_id = v_tenant and x.status = 'active' and x.reorder_method <> 'none'
     order by (x.code = 'standard') desc, x.code
     limit 1;
    if not found then
      raise exception 'CLOVEERP_NO_PLANNING_POLICY: this organisation has no planning policy that orders'
        using errcode = '23514',
              hint = 'Install Planning, which sets up the standard planning policies, then plan the product.';
    end if;
  end if;

  insert into erp.item_site (tenant_id, item_id, site_id, is_stocked, planning_policy_code, status)
  values (v_tenant, p_item_id, p_site_id, true, pp.code, 'active')
  on conflict (tenant_id, item_id, site_id) do update
     set planning_policy_code = excluded.planning_policy_code,
         is_stocked = true, status = 'active', updated_at = now()
  returning id, (xmax = 0) into v_id, v_added;

  return jsonb_build_object('item_site_id', v_id, 'item', v_item, 'site', v_site,
                            'policy', pp.code, 'added', v_added);
end;
$$;

revoke all on function erp.plan_item_at_site(uuid, uuid, text) from public, anon;

comment on function erp.plan_item_at_site(uuid, uuid, text) is
  'Plans a product at a site under a planning policy, the standard one when none is named, so planning runs order it '
  '(20261007151000). Writes or restores the erp.item_site row; authorises planning.run at the site.';

create or replace function public.erp_plan_item_at_site(p_item_id uuid, p_site_id uuid, p_policy_code text default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.plan_item_at_site(p_item_id, p_site_id, p_policy_code) $$;

revoke all on function public.erp_plan_item_at_site(uuid, uuid, text) from public, anon;
grant execute on function public.erp_plan_item_at_site(uuid, uuid, text) to authenticated, service_role;

comment on function public.erp_plan_item_at_site(uuid, uuid, text) is
  'Plans a product at a site, so planning runs order it (20261007151000). Authorises planning.run.';

-- Adopting a calculated policy for a product not planned at the site said
-- only "this item is not planned at this site", from erp.calculate_policy.
-- The door now says it first, and what to do.
do $adopt$
declare
  v_sig  constant text := 'erp.apply_calculated_policy(uuid,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  perform erp.authorise('planning.run', null, p_site_id, null, 'item', p_item_id);
$o$;
  v_new  constant text := $n$  perform erp.authorise('planning.run', null, p_site_id, null, 'item', p_item_id);

  -- Nothing to adopt for a product not planned here, and a way to plan it
  -- (20261007151000).
  if not exists (select 1 from erp.item_site x
                  where x.tenant_id = v_tenant and x.item_id = p_item_id and x.site_id = p_site_id) then
    raise exception 'CLOVEERP_NOT_STOCKED_HERE: this product is not planned at this site'
      using errcode = '23503',
            hint = 'Plan the product at this site first, with Plan a product at a site in Planning, then ask again.';
  end if;
$n$;
begin
  if strpos(v_src, '20261007151000') > 0 then
    raise notice '% already says a product is not planned here; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'c1b477f2a495d18c35f3f7f3ebbefc46' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007151000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$adopt$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The run reports a product it wants and nothing plans
-- ─────────────────────────────────────────────────────────────────────────────

do $planning$
declare
  v_sig  constant text := 'erp.run_planning(uuid,integer,uuid,text,jsonb,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- A component the bills demand that nothing plans at this site. The demand
  -- is recorded above; leaving it there without a word is how a works order
  -- discovers a shortage on the day it is released.
$o$;
  v_new  constant text := $n$  -- A product that open orders or the forecast want at this site and that
  -- nothing plans here (20261007151000). The loop above reads only the
  -- products planned at the site, so this one was never looked at and the run
  -- said nothing. A product somebody chose not to stock here, or to plan with
  -- a policy that never orders, is that choice and is not reported.
  for c in
    select w.item_id, sum(dm.quantity * v_mult) as quantity, min(dm.due_on) as required_by
      from (
        select dln.item_id
          from erp.document_line dln
          join erp.document doc on doc.id = dln.document_id
          join erp.document_type dt on dt.id = doc.document_type_id
         where dln.tenant_id = v_tenant and doc.tenant_id = v_tenant
           and doc.site_id = p_site_id and dt.base_type_code = 'sales_order'
           and dln.item_id is not null
           and not dln.is_cancelled and not doc.is_cancelled
           and dln.quantity > coalesce(dln.quantity_fulfilled, 0)
        union
        select fl.item_id
          from erp.forecast_line fl
          join erp.forecast_version fv on fv.id = fl.forecast_version_id
         where fl.tenant_id = v_tenant and fl.site_id = p_site_id and fl.quantity > 0
           and (p_forecast_version_id is null and fv.status = 'active'
                or fv.id = p_forecast_version_id)
      ) w
     cross join lateral erp.scheduled_demand(w.item_id, p_site_id, current_date,
                                             current_date + p_horizon_days,
                                             p_forecast_version_id, null::uuid) dm
     where dm.source in ('sales_order', 'forecast')
       and dm.due_on is not null
       and dm.due_on <= current_date + p_horizon_days
       and not exists (
         select 1 from erp.item_site x
           left join erp.planning_policy pol on pol.tenant_id = x.tenant_id
                                           and pol.code = x.planning_policy_code
                                           and pol.status = 'active'
          where x.tenant_id = v_tenant and x.item_id = w.item_id and x.site_id = p_site_id
            and (not x.is_stocked or x.status <> 'active' or pol.id is not null))
     group by w.item_id
  loop
    select coalesce(sum(b.quantity), 0) into v_on_hand
      from erp.stock_balance b
     where b.tenant_id = v_tenant and b.item_id = c.item_id and b.site_id = p_site_id;

    insert into erp.planning_exception (
      tenant_id, entity_id, site_id, item_id, exception_kind, severity, message, detail,
      planning_run_id)
    values (v_tenant, v_entity, p_site_id, c.item_id, 'no_supply_source',
            case when v_on_hand < c.quantity then 'high' else 'medium' end,
            format('open orders or the forecast want %s of this product here by %s, with %s in '
                   'stock, and nothing plans it at this site; plan it here, then work out what '
                   'to order again', trim_scale(c.quantity), c.required_by, trim_scale(v_on_hand)),
            jsonb_build_object('quantity', c.quantity, 'required_by', c.required_by,
                               'on_hand', v_on_hand, 'planning_run_id', v_run),
            v_run);
    v_excs := v_excs + 1;
  end loop;

  -- A component the bills demand that nothing plans at this site. The demand
  -- is recorded above; leaving it there without a word is how a works order
  -- discovers a shortage on the day it is released.
$n$;
begin
  if strpos(v_src, '20261007151000') > 0 then
    raise notice '% already reports a product nothing plans; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '1baec729f9433fb4ac740ba0864bde4b' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007151000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$planning$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Its registrations and its words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_plan_item_at_site', 'erp.plan_item_at_site',
   'Plans a product at a site under a planning policy, writing or restoring its erp.item_site row so planning runs order it; authorises planning.run at the site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/planning', array['erp_plan_item_at_site']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Planning a product at a site (20261007151000).'
  from (values
    ('Plan a product at a site'),
    ('Planning orders only the products planned at a site. Plan one here, and the next run orders it when open orders or the forecast need it.'),
    ('Planning policy'),
    ('Leave empty for the standard policy.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.plan_item_at_site_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  s_buy    uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  csl      uuid;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_fc uuid; v_ver uuid;
  v_new uuid; v_nopol uuid; v_notst uuid; v_planned uuid;
  v_run1 uuid; v_run2 uuid;
  v_out  jsonb; v_out2 jsonb;
  v_err  text; v_err2 text; v_err3 text; v_err4 text; v_hint text;
begin
  begin
    -- ── The fixture: Planning installed, four products wanted at one site ───
    v_step := 'an organisation with Planning installed, a buyer, and a forecast at one site';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzpis-' || v_tag, 'Plan Item At Site Suite',
      'admin@zzpis-' || v_tag || '.test', 'Planning Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzpis-' || v_tag || '.test'),
           (a2, 'second@zzpis-' || v_tag || '.test'),
           (s_buy, 'buyer@zzpis-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    res := public.erp_invite_principal('second@zzpis-' || v_tag || '.test', 'Second Admin');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('buyer@zzpis-' || v_tag || '.test', 'Bea Buyer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    csl := erp.configure_planning(95, 7);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp_test.promote_if_pending(csl);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (rb.tenant_id, 'ZPISEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZPISMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZPISNEW', 'Nobody plans it', v_uom, 'active') returning id into v_new;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZPISNOPOL', 'Stocked with no policy', v_uom, 'active') returning id into v_nopol;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZPISNOTST', 'Not stocked here', v_uom, 'active') returning id into v_notst;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZPISPLAN', 'Planned already', v_uom, 'active') returning id into v_planned;
    insert into erp.item_site (tenant_id, item_id, site_id, is_stocked, planning_policy_code, status)
    values (rb.tenant_id, v_nopol, v_site, true, null, 'active'),
           (rb.tenant_id, v_notst, v_site, false, null, 'active'),
           (rb.tenant_id, v_planned, v_site, true, 'standard', 'active');

    -- The demand: a forecast in force, wanting each of the four in a month.
    insert into erp.forecast (tenant_id, code, name, entity_id, site_id, bucket, status)
    values (rb.tenant_id, 'ZPIS-M', 'Plan item monthly', rb.entity_id, v_site, 'month', 'active')
    returning id into v_fc;
    insert into erp.forecast_version (tenant_id, forecast_id, version, method, parameters, status,
                                      horizon_from, horizon_to, note)
    values (rb.tenant_id, v_fc, 1, 'manual', '{}'::jsonb, 'active', current_date, current_date + 180,
            'written by the plan item at site suite')
    returning id into v_ver;
    insert into erp.forecast_line (tenant_id, forecast_version_id, item_id, site_id, bucket_start, quantity, uom_id)
    select rb.tenant_id, v_ver, i, v_site, current_date + 30, 10, v_uom
      from unnest(array[v_new, v_nopol, v_notst, v_planned]) i;

    -- ── 1. Its registers ────────────────────────────────────────────────────
    v_step := 'reading the registers';
    v_cases := v_cases + 1;
    case_name := 'the door is allowed to write, gated, in the Planning screen''s help, and its three refusals and four words are registered';
    passed := v_state is null
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_plan_item_at_site' and a.gate = 'erp.plan_item_at_site')
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/planning' and 'erp_plan_item_at_site' = any (h.actions))
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_NOT_STOCKED_HERE', 'CLOVEERP_UNKNOWN_PLANNING_POLICY',
                                 'CLOVEERP_NO_PLANNING_POLICY')
                  and coalesce(f.next_action, '') <> '') = 3
          and (select count(*) from erp_ref.resource x
                where x.locale = 'en'
                  and x.key in (erp_ref.ui_key('Plan a product at a site'), erp_ref.ui_key('Planning policy'),
                                erp_ref.ui_key('Leave empty for the standard policy.'),
                                erp_ref.ui_key('Planning orders only the products planned at a site. Plan one here, and the next run orders it when open orders or the forecast need it.'))) = 4;
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. Wanted and planned by nothing, it is an exception of the run ─────
    v_step := 'a planning run at the site';
    v_run1 := public.erp_run_planning(v_site);
    begin perform public.erp_apply_calculated_policy(v_new, v_site); v_err := 'adopted';
    exception when others then
      v_err := sqlerrm;
      get stacked diagnostics v_hint = pg_exception_hint;
    end;
    v_cases := v_cases + 1;
    case_name := 'a product the forecast wants at a site and nothing plans there is an exception of the run, counted, and not ordered; adopting its policy says to plan it';
    passed := v_state is null
          and exists (select 1 from erp.planning_exception e
                       where e.planning_run_id = v_run1 and e.item_id = v_new
                         and e.exception_kind = 'no_supply_source' and e.severity = 'high'
                         and (e.detail ->> 'quantity')::numeric = 10
                         and e.message like 'open orders or the forecast want 10 of this product here%')
          and not exists (select 1 from erp.planned_order po where po.planning_run_id = v_run1 and po.item_id = v_new)
          and exists (select 1 from erp.planned_order po where po.planning_run_id = v_run1 and po.item_id = v_planned)
          and (select pr.exceptions_raised from erp.planning_run pr where pr.id = v_run1)
              = (select count(*) from erp.planning_exception e where e.planning_run_id = v_run1)
          and v_err like 'CLOVEERP_NOT_STOCKED_HERE%'
          and coalesce(v_hint, '') like '%Plan a product at a site%';
    detail := coalesce(v_state, format('%s exception(s); adopting its policy: %s (%s)',
      (select count(*) from erp.planning_exception e where e.planning_run_id = v_run1), v_err, v_hint));
    return next;

    -- ── 3. No policy is reported; not stocking it here is a choice ──────────
    v_cases := v_cases + 1;
    case_name := 'a product stocked here with no planning policy is reported too, and one somebody chose not to stock here is not';
    passed := v_state is null
          and exists (select 1 from erp.planning_exception e
                       where e.planning_run_id = v_run1 and e.item_id = v_nopol
                         and e.exception_kind = 'no_supply_source')
          and not exists (select 1 from erp.planning_exception e
                           where e.planning_run_id = v_run1 and e.item_id in (v_notst, v_planned));
    detail := coalesce(v_state, (select string_agg(it.code, ', ' order by it.code)
                                   from erp.planning_exception e join erp.item it on it.id = e.item_id
                                  where e.planning_run_id = v_run1));
    return next;

    -- ── 4. Planned at the site, the next run orders it ──────────────────────
    v_step := 'planning the product at the site, then running again';
    v_out := public.erp_plan_item_at_site(v_new, v_site);
    v_run2 := public.erp_run_planning(v_site);
    v_cases := v_cases + 1;
    case_name := 'planned at the site under the standard policy when none is named, the next run orders it and reports it no more';
    passed := v_state is null
          and (v_out ->> 'added')::boolean and v_out ->> 'policy' = 'standard'
          and exists (select 1 from erp.item_site x
                       where x.tenant_id = rb.tenant_id and x.item_id = v_new and x.site_id = v_site
                         and x.is_stocked and x.status = 'active' and x.planning_policy_code = 'standard')
          and exists (select 1 from erp.planned_order po
                       join erp.planned_order_peg pg on pg.planned_order_id = po.id
                      where po.planning_run_id = v_run2 and po.item_id = v_new and pg.demand_kind = 'forecast')
          and not exists (select 1 from erp.planning_exception e
                           where e.planning_run_id = v_run2 and e.item_id = v_new);
    detail := coalesce(v_state, left(v_out::text, 300));
    return next;

    -- ── 5. Asked again, the same row changes ────────────────────────────────
    v_step := 'planning the same product again under the fixed lot policy';
    v_out2 := public.erp_plan_item_at_site(v_new, v_site, ' fixed_lot ');
    v_err := null;
    begin perform erp.calculate_policy(v_new, v_site); v_err := 'calculated';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'planned again, the same row takes the policy named, and its stocking policy can now be worked out';
    passed := v_state is null
          and not (v_out2 ->> 'added')::boolean
          and v_out2 ->> 'item_site_id' = v_out ->> 'item_site_id'
          and (select count(*) from erp.item_site x
                where x.tenant_id = rb.tenant_id and x.item_id = v_new and x.site_id = v_site) = 1
          and (select x.planning_policy_code from erp.item_site x
                where x.tenant_id = rb.tenant_id and x.item_id = v_new and x.site_id = v_site) = 'fixed_lot'
          and v_err not like 'CLOVEERP_NOT_STOCKED_HERE%';
    detail := coalesce(v_state, concat_ws(' / ', left(v_out2::text, 200), v_err));
    return next;

    -- ── 6. Not with a policy nobody has, and not by a buyer ─────────────────
    v_step := 'planning with a policy nobody has, and as a buyer';
    begin perform public.erp_plan_item_at_site(v_notst, v_site, 'no-such-policy'); v_err2 := 'planned';
    exception when others then v_err2 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    begin perform public.erp_plan_item_at_site(v_notst, v_site); v_err3 := 'planned';
    exception when others then v_err3 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a policy nobody has is refused, and so is somebody who may not run planning; the product stays unstocked there';
    passed := v_state is null
          and v_err2 like 'CLOVEERP_UNKNOWN_PLANNING_POLICY%'
          and v_err3 like 'CLOVEERP_PERMISSION_DENIED%'
          and exists (select 1 from erp.item_site x
                       where x.tenant_id = rb.tenant_id and x.item_id = v_notst and x.site_id = v_site
                         and not x.is_stocked and x.planning_policy_code is null);
    detail := coalesce(v_state, concat_ws(' / ', v_err2, v_err3));
    return next;

    -- ── 7. With no policy that orders, it says what to do ───────────────────
    v_step := 'planning when no policy in use orders';
    update erp.planning_policy set status = 'inactive' where tenant_id = rb.tenant_id;
    begin perform public.erp_plan_item_at_site(v_nopol, v_site); v_err4 := 'planned';
    exception when others then v_err4 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'with no planning policy that orders, planning a product is refused and says to install Planning';
    passed := v_state is null
          and v_err4 like 'CLOVEERP_NO_PLANNING_POLICY%'
          and (select x.planning_policy_code from erp.item_site x
                where x.tenant_id = rb.tenant_id and x.item_id = v_nopol and x.site_id = v_site) is null;
    detail := coalesce(v_state, v_err4);
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
    raise exception 'CLOVEERP_PLAN_ITEM_AT_SITE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.plan_item_at_site_suite() from public, anon;

comment on function erp_test.plan_item_at_site_suite() is
  'A product can be planned at a site (20261007151000): a product wanted and planned by nothing is an exception of '
  'the run; planned by the door, the next run orders it; a policy nobody has, a buyer and no policy that orders are refused.';

create or replace function erp_test.assert_plan_item_at_site_suite()
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
    from erp_test.plan_item_at_site_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PLAN_ITEM_AT_SITE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A product could not be planned at a site, or a run said nothing of a product it wants. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_PLAN_ITEM_AT_SITE_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('plan item at site: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_plan_item_at_site_suite() from public, anon;

comment on function erp_test.assert_plan_item_at_site_suite() is
  'A product wanted at a site that nothing plans is reported by the run, and can be planned there by somebody who may run planning (20261007151000).';

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
