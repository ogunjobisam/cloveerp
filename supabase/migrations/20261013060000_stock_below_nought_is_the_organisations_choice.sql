-- Stock below nought is the organisation's choice.
--
-- Known issue KI-07 (v1 Gate Assessment, 13 October 2026; the owner asked for
-- it fixed the same day). Whether a movement may take a place below nought was
-- decided by the movement type alone, in erp_ref.movement_type, which the
-- product ships and no organisation can change: a count or stock adjustment
-- and an emergency issue may, nothing else may. An organisation that despatches
-- before its paperwork catches up could not allow it, and one that wants stock
-- never to go below nought could not forbid it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. inventory.negative_stock, a policy for the organisation, a company or a
--      site, in force by the narrowest that says:
--        movement_type  as the product ships it, and the default: a count or
--                       stock adjustment and an emergency issue may take a
--                       place below nought, nothing else may;
--        never          no movement may, adjustments and emergency issues
--                       included;
--        allowed        any movement may, the shortfall made good when the
--                       stock is received.
--   B. erp.apply_stock_movement reads it for the movement's company and site.
--   C. public.erp_propose_negative_stock_policy proposes it as a change, from
--      the Inventory page, approved and promoted like any configuration.
--   D. erp_test.negative_stock_policy_suite proves it.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The policy
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.config_type
  (code, domain, module_code, name_key, description, value_schema,
   max_scope_level, is_singleton, default_value, consequence, cycle_code, clean_path) values
  ('inventory.negative_stock', 'policy', 'inventory',
   'config.inventory.negative_stock',
   'Whether a stock movement may take a place below nought: as each movement type allows (a count or adjustment, '
   'an emergency issue), never, or always.',
   jsonb_build_object('type','object','additionalProperties',false,'required',jsonb_build_array('policy'),
     'properties', jsonb_build_object(
       'policy', jsonb_build_object('type','string','enum',
         jsonb_build_array('movement_type','never','allowed')))),
   'site', true,
   jsonb_build_object('policy', 'movement_type'),
   'never refuses an emergency issue or an adjustment that would leave a place below nought, so stock has to be '
   'received or moved first; allowed lets a despatch go ahead with nothing on the shelf, and the place shows less '
   'than nought until the stock is received.',
   'stock',
   'Stock goes below nought only where a count or adjustment, or an emergency issue, says so: nothing is despatched '
   'that is not there, and nobody has to choose.')
on conflict (code) do nothing;

do $policy_type$
begin
  if (select ct.default_value from erp_ref.config_type ct where ct.code = 'inventory.negative_stock')
     is distinct from '{"policy": "movement_type"}'::jsonb then
    raise exception 'CLOVEERP_ANCHOR_MOVED: inventory.negative_stock is declared already, and not as 20261013060000 declares it';
  end if;
end
$policy_type$;

insert into erp_ref.resource (key, locale, value, description) values
  ('config.inventory.negative_stock', 'en', 'Stock below nought',
   'The name of the inventory.negative_stock configuration type.'),
  ('config.inventory.negative_stock', 'de', 'Bestand unter null',
   'Der Name des Konfigurationstyps inventory.negative_stock.')
on conflict (key, locale) do nothing;

create or replace function erp.negative_stock_policy(p_entity_id uuid default null, p_site_id uuid default null)
returns text
language sql
stable
set search_path = ''
as $$
  -- The policy in force at a company and site (20261013060000), layered as
  -- the count posting policy is: the product's default, then the
  -- organisation's, then its company's, then its site's.
  select (coalesce(ct.default_value, '{}'::jsonb)
          || coalesce(erp.config_value('inventory.negative_stock', null, null, null, null), '{}'::jsonb)
          || case when p_entity_id is null then '{}'::jsonb
                  else coalesce(erp.config_value('inventory.negative_stock', null, null, p_entity_id, null), '{}'::jsonb) end
          || case when p_site_id is null then '{}'::jsonb
                  else coalesce(erp.config_value('inventory.negative_stock', null, null, p_entity_id, p_site_id), '{}'::jsonb) end)
         ->> 'policy'
    from erp_ref.config_type ct
   where ct.code = 'inventory.negative_stock'
$$;
revoke all on function erp.negative_stock_policy(uuid, uuid) from public, anon;
comment on function erp.negative_stock_policy(uuid, uuid) is
  'inventory.negative_stock at a company and site, over its default (20261013060000): movement_type, never or allowed. '
  'Read by erp.apply_stock_movement().';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The movement reads it
-- ─────────────────────────────────────────────────────────────────────────────

do $apply$
declare
  v_sig  constant text := 'erp.apply_stock_movement()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    from erp_ref.movement_type mt where mt.code = new.movement_type;$o$;
  v_new  constant text := $n$    from erp_ref.movement_type mt where mt.code = new.movement_type;

  -- The movement type says what the product allows; the organisation, its
  -- company or its site may say never, or always (20261013060000).
  v_allows_negative := case erp.negative_stock_policy(new.entity_id, new.site_id)
                         when 'never' then false
                         when 'allowed' then true
                         else v_allows_negative
                       end;$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if position('negative_stock_policy' in v_def) > 0 then
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % movement type anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$apply$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Proposed as a change
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.propose_negative_stock_policy(
  p_entity_code text, p_site_code text, p_policy text, p_change_set_id uuid default null)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity text := p_entity_code;
  v_cs     uuid := p_change_set_id;
begin
  perform erp.authorise('administration.configure', null, null, null, 'change_set', p_change_set_id);

  if coalesce(p_policy, '') not in ('movement_type', 'never', 'allowed') then
    raise exception 'CLOVEERP_POLICY_VALUE_INVALID: stock below nought is as each movement type allows, never, or always'
      using errcode = '22023',
            hint = 'Choose as each kind of movement allows, never, or always.';
  end if;

  if p_site_code is not null then
    select e.code into v_entity
      from erp.site s join erp.entity e on e.id = s.entity_id
     where s.tenant_id = v_tenant and s.code = p_site_code;
    if v_entity is null then
      raise exception 'CLOVEERP_UNKNOWN_SITE: % is not a site of this organisation', p_site_code
        using errcode = '23503', hint = 'Choose one of the organisation''s sites; a site''s policy belongs to its company.';
    end if;
    if p_entity_code is not null and p_entity_code is distinct from v_entity then
      raise exception 'CLOVEERP_POLICY_SCOPE_DISAGREES: % belongs to %, not to %', p_site_code, v_entity, p_entity_code
        using errcode = '22023', hint = 'Name the site alone, or the site with its own company.';
    end if;
  elsif p_entity_code is not null and not exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.code = p_entity_code) then
    raise exception 'CLOVEERP_UNKNOWN_ENTITY: % is not a company of this organisation', p_entity_code
      using errcode = '23503', hint = 'Choose one of the organisation''s companies.';
  end if;

  if v_cs is null then
    v_cs := erp.create_change_set(
      'negative-stock-policy-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US'),
      'Stock below nought',
      'Whether a stock movement may take a place below nought: as each kind of movement allows, never, or always.');
  end if;

  return erp.add_change_set_item(v_cs, 'config',
    format('inventory.negative_stock|%s|%s', coalesce(v_entity, '*'), coalesce(p_site_code, '*')),
    jsonb_strip_nulls(jsonb_build_object(
      'config_type', 'inventory.negative_stock', 'value', jsonb_build_object('policy', p_policy),
      'entity', v_entity, 'site', p_site_code)),
    'upsert', null, 'proposed from the Inventory page');
end;
$$;
revoke all on function erp.propose_negative_stock_policy(text, text, text, uuid) from public, anon;

create or replace function public.erp_propose_negative_stock_policy(
  p_entity_code text, p_site_code text, p_policy text, p_change_set_id uuid default null)
returns uuid
language sql
set search_path = ''
as $$ select erp.propose_negative_stock_policy(p_entity_code, p_site_code, p_policy, p_change_set_id) $$;
revoke all on function public.erp_propose_negative_stock_policy(text, text, text, uuid) from public, anon;
grant execute on function public.erp_propose_negative_stock_policy(text, text, text, uuid) to authenticated, service_role;
comment on function public.erp_propose_negative_stock_policy(text, text, text, uuid) is
  'Proposes whether a stock movement may take a place below nought — as each movement type allows, never, or always — '
  'for the organisation, a company or a site, as an item of a change set (20261013060000). Authorises administration.configure.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_propose_negative_stock_policy', 'erp.propose_negative_stock_policy',
   'Proposes whether stock may go below nought, for the organisation, a company or a site, as a change-set item; authorises administration.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/inventory', array['erp_propose_negative_stock_policy']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Whether stock may go below nought, on the Inventory page (20261013060000).'
  from (values
    ('Propose whether stock may go below nought'),
    ('Whether a stock movement may take a place below nought, for the organisation, a company or one of its sites. As shipped, only a count or stock adjustment and an emergency issue may. Proposed as a change like any other configuration.'),
    ('Stock below nought'),
    ('As each kind of movement allows'),
    ('Never'),
    ('Always'),
    ('Never refuses even an adjustment or an emergency issue that would leave a place below nought. Always lets a despatch go ahead with nothing on the shelf; the place shows less than nought until stock is received.'),
    ('Leave unchosen to set the policy for the whole organisation.'),
    ('Leave unchosen to apply the policy across the whole company.')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.negative_stock_policy_suite()
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
  v_ent    uuid;
  v_ent_code text;
  v_site   uuid;
  v_site_code text;
  v_loc    uuid;
  v_uom    uuid;
  v_item   uuid;
  v_ok     boolean;
  v_msg    text;
  v_cs     uuid;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzneg' || v_tag, 'Negative Stock Suite',
      'admin@demo-zzneg' || v_tag || '.test', 'Stock Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzneg' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;

    v_step := 'a site, a place, and a product with ten on the shelf';
    select e.id, e.code into v_ent, v_ent_code from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    select s.id, s.code into v_site, v_site_code from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select l.id into v_loc from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site order by l.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZNEG' || v_tag, 'Negative Stock Widget', v_uom, 'active') returning id into v_item;
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
                                    to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency)
    values (v_tenant, v_ent, v_site, 'goods_receipt', v_item, v_loc, 'available', 10, v_uom, 100, 'GBP');

    -- ── 1. As shipped ───────────────────────────────────────────────────────
    v_step := 'as shipped';
    begin
      insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
                                      from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency)
      values (v_tenant, v_ent, v_site, 'despatch', v_item, v_loc, 'available', 12, v_uom, 100, 'GBP');
      v_ok := false; v_msg := 'a despatch of 12 from 10 went through';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_NEGATIVE_STOCK%'; v_msg := left(sqlerrm, 90);
    end;
    begin
      insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
                                      from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
      values (v_tenant, v_ent, v_site, 'emergency_issue', v_item, v_loc, 'available', 12, v_uom, 100, 'GBP', 'EMERGENCY');
      raise exception 'CLOVEERP_SUITE_STEP_BACK';
    exception when others then
      v_ok := v_ok and sqlerrm = 'CLOVEERP_SUITE_STEP_BACK';
      v_msg := v_msg || ' | ' || left(sqlerrm, 60);
    end;
    v_cases := v_cases + 1;
    case_name := 'as shipped, a despatch below nought is refused and an emergency issue is allowed';
    passed := v_state is null and v_ok and erp.negative_stock_policy(v_ent, v_site) = 'movement_type';
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 2. Never ────────────────────────────────────────────────────────────
    v_step := 'never, for the organisation';
    perform erp.set_config_value('inventory.negative_stock', '{"policy": "never"}'::jsonb,
                                 null, current_date, null, null, 'negative stock suite');
    begin
      insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
                                      from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
      values (v_tenant, v_ent, v_site, 'emergency_issue', v_item, v_loc, 'available', 12, v_uom, 100, 'GBP', 'EMERGENCY');
      v_ok := false; v_msg := 'an emergency issue below nought went through';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_NEGATIVE_STOCK%'; v_msg := left(sqlerrm, 90);
    end;
    v_cases := v_cases + 1;
    case_name := 'never refuses even an emergency issue below nought';
    passed := v_state is null and v_ok and erp.negative_stock_policy(v_ent, v_site) = 'never';
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 3. A site that allows it ────────────────────────────────────────────
    v_step := 'allowed, at the site';
    perform erp.set_config_value('inventory.negative_stock', '{"policy": "allowed"}'::jsonb,
                                 null, current_date, v_ent, v_site, 'negative stock suite');
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
                                    from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency)
    values (v_tenant, v_ent, v_site, 'despatch', v_item, v_loc, 'available', 12, v_uom, 100, 'GBP');
    v_cases := v_cases + 1;
    case_name := 'a site that allows it despatches with too little on the shelf, over the organisation''s never';
    passed := v_state is null and erp.negative_stock_policy(v_ent, v_site) = 'allowed'
          and erp.negative_stock_policy(v_ent, null) = 'never'
          and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_item) = -2;
    detail := coalesce(v_state, (select sum(b.quantity)::text from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_item));
    return next;

    -- ── 4. Received again ───────────────────────────────────────────────────
    v_step := 'the shortfall made good';
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
                                    to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency)
    values (v_tenant, v_ent, v_site, 'goods_receipt', v_item, v_loc, 'available', 5, v_uom, 100, 'GBP');
    v_cases := v_cases + 1;
    case_name := 'stock received makes the shortfall good';
    passed := v_state is null
          and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_item) = 3;
    detail := coalesce(v_state, (select sum(b.quantity)::text from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_item));
    return next;

    -- ── 5. Proposed as a change ─────────────────────────────────────────────
    v_step := 'proposed from the screen';
    v_cs := public.erp_propose_negative_stock_policy(v_ent_code, v_site_code, 'movement_type', null);
    v_cs := (select ci.change_set_id from erp.change_set_item ci where ci.id = v_cs);
    v_cases := v_cases + 1;
    case_name := 'the policy is proposed as a change for a site, naming its company';
    passed := v_state is null and v_cs is not null
          and exists (select 1 from erp.change_set_item ci
                       where ci.change_set_id = v_cs
                         and ci.payload ->> 'config_type' = 'inventory.negative_stock'
                         and ci.payload -> 'value' ->> 'policy' = 'movement_type'
                         and ci.payload ->> 'site' = v_site_code and ci.payload ->> 'entity' = v_ent_code);
    detail := coalesce(v_state, coalesce(v_cs::text, 'no change set'));
    return next;

    -- ── 6. Refused ──────────────────────────────────────────────────────────
    v_step := 'a policy that is not one';
    begin
      perform public.erp_propose_negative_stock_policy(null, null, 'sometimes', null);
      v_ok := false; v_msg := 'sometimes was proposed';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_POLICY_VALUE_INVALID%'; v_msg := left(sqlerrm, 90);
    end;
    begin
      perform public.erp_propose_negative_stock_policy('NOPE' || v_tag, null, 'never', null);
      v_ok := false; v_msg := v_msg || ' | an unknown company';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_UNKNOWN_ENTITY%';
    end;
    v_cases := v_cases + 1;
    case_name := 'a policy that is not one, and a company the organisation does not have, are refused';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
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
    raise exception 'CLOVEERP_NEGATIVE_STOCK_POLICY_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.negative_stock_policy_suite() from public, anon, authenticated;

create or replace function erp_test.assert_negative_stock_policy_suite()
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
  create temp table if not exists _negative_stock_policy on commit drop as
    select * from erp_test.negative_stock_policy_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _negative_stock_policy;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_NEGATIVE_STOCK_POLICY_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_NEGATIVE_STOCK_POLICY_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('negative stock policy: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_negative_stock_policy_suite() from public, anon, authenticated;

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
