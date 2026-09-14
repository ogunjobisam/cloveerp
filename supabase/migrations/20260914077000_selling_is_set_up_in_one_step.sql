-- =============================================================================
-- Selling is set up in one step
--
-- On 14 September the platform owner opened the console to build a quote and
-- found a card about "price items, approval chains and output templates" that
-- ended at "No organisation is designated yet, so nobody has a price book".
-- Behind it were four more steps nobody had written down: install the
-- commercial module, open a price book, add every price item, and set a rate
-- and a cost beside each. The same morning the owner set the price list:
--
--   Starter £395, Standard £1,095 and Enterprise from £2,750 a month, billed
--   annually, with 5, 15 and 40 full users included; extra full users at £45,
--   £49 and £45 and light users at £9, £9 and £6 a month; an extra company at
--   £150 and an extra site at £75 a month; Guided onboarding £2,500, Standard
--   implementation £7,500 and a 30-day pilot at £500; Priority support at 10%
--   of the subscription and never less than £150 a month. Month-to-month adds
--   15%; a multi-year term saves 10%.
--
-- This migration makes that list one call.
--
--   1. The Standard plan carries manufacturing. The list sells Standard to
--      manufacturers, and the plan register gave production, planning and
--      forecasting to Enterprise alone.
--   2. A user a plan does not include is a price item of its own, full or
--      light, priced for one plan; a plan tier says how many full users its
--      price includes; and a quote refuses users beyond what its plan allows.
--   3. Cost is per year. The cost model was always measured per year and a
--      monthly rate was set beside it undivided, so every monthly rate showed a
--      loss. Margin now compares like with like.
--   4. erp_set_up_selling(): in the platform's organisation, installs the
--      commercial module, opens the CLOVE-LIST price book and fills in every
--      item on the list with its rates and costs. It adds what is missing and
--      changes nothing already there, so it can be pressed twice.
--   5. The console reads where selling stands, so it can say what is left.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The Standard plan carries manufacturing
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Production, planning and MRP, forecasting and recall. Every one of their
-- prerequisites (batch control, quarantine and release, and production itself
-- for planning) is already on the plan or in this list. Multi-company,
-- intercompany trading, serialisation, container identity and project
-- accounting stay with Enterprise.

insert into erp_meta.plan_capability (plan_code, capability_code)
select 'standard', c
  from unnest(array['production', 'planning_mrp', 'forecasting', 'recall_management']) as c
on conflict do nothing;

update erp_meta.plan
   set description = 'Several sites and up to three companies: the Standard preset, plus manufacturing, planning and MRP, forecasting and recall, for manufacturers and distributors running more than one site.'
 where code = 'standard';

-- erp_test.commercial_contract_suite proves a feature neither the plan nor
-- the contract sold is refused, using production on a Standard plan. Production
-- is on Standard now; project accounting is on neither.
do $contract_suite$
declare
  v_sig    constant text := 'erp_test.commercial_contract_suite()';
  v_def    text := pg_get_functiondef('erp_test.commercial_contract_suite()'::regprocedure);
  v_needle constant text := 'perform erp.require_capability_on_plan(''production'');';
  v_new    constant text := 'perform erp.require_capability_on_plan(''project_accounting'');';
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not test production against the plan exactly once', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$contract_suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Users a plan does not include
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.price_item drop constraint if exists price_item_kind_known;
alter table erp.price_item add constraint price_item_kind_known check (kind in
  ('plan_tier', 'capability_addon', 'user_band', 'company_band', 'site_band', 'volume_band',
   'storage_band', 'retention_band', 'environment', 'support_tier', 'service', 'legislation_pack',
   'full_user', 'light_user'));

alter table erp.price_item drop constraint if exists price_item_names_its_object;
alter table erp.price_item add constraint price_item_names_its_object check (
  (kind = 'plan_tier' and plan_code is not null)
  or (kind = 'capability_addon' and capability_code is not null)
  or (kind in ('user_band', 'company_band', 'site_band', 'volume_band', 'storage_band', 'retention_band', 'environment')
      and entitlement_code is not null and band_to is not null)
  or (kind = 'support_tier' and support_severity_code is not null)
  or (kind = 'legislation_pack' and legislation_pack_code is not null)
  or (kind in ('full_user', 'light_user') and plan_code is not null)
  or (kind = 'service'));

alter table erp.price_item add column if not exists included_users integer;
alter table erp.price_item drop constraint if exists price_item_included_users_on_a_plan;
alter table erp.price_item add constraint price_item_included_users_on_a_plan check (
  included_users is null or (kind = 'plan_tier' and included_users >= 0));

comment on column erp.price_item.included_users is
  'For a plan tier: how many full users the plan''s price includes. Users beyond '
  'them are sold as full_user or light_user items priced for the same plan, up '
  'to the plan''s users entitlement.';

-- A full or light user names the plan it is priced for.
do $upsert$
declare
  v_sig    constant text := 'erp.upsert_price_item(text,text,text,text,text,text,numeric,numeric,text,text,text)';
  v_def    text := pg_get_functiondef('erp.upsert_price_item(text,text,text,text,text,text,numeric,numeric,text,text,text)'::regprocedure);
  v_needle constant text := $n$    when 'service' then$n$;
  v_new    constant text := $n$    when 'full_user', 'light_user' then
      -- A user beyond what a plan includes is priced per plan: the Standard
      -- plan's extra user is not the Starter plan's.
      if not exists (select 1 from erp_meta.plan p where p.code = p_plan_code) then
        raise exception 'CLOVEERP_UNKNOWN_PLAN: % is not a plan the product offers', p_plan_code using errcode = '23503';
      end if;
    when 'service' then$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not name the service kind exactly once, so it is not the 20260904590000 body', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$upsert$;

-- A quote carries users only for its own plan, once each, and no more than the
-- plan allows.
do $quote_line$
declare
  v_sig    constant text := 'erp.add_quote_line(uuid,text,numeric,numeric)';
  v_def    text := pg_get_functiondef('erp.add_quote_line(uuid,text,numeric,numeric)'::regprocedure);
  v_needle constant text := E'    else\n      null;\n  end case;';
  v_new    constant text := $n$    when 'full_user', 'light_user' then
      -- Users beyond what the plan includes: sold for that plan, one line of
      -- each kind whose quantity is the number of users, and never past the
      -- plan's users limit unless the quote also sells a users band.
      if v_plan is null then
        raise exception 'CLOVEERP_QUOTE_USERS_BEFORE_PLAN: add the plan before the users beyond it'
          using errcode = '23514';
      end if;
      if v_plan <> pi.plan_code then
        raise exception 'CLOVEERP_QUOTE_USERS_FOR_ANOTHER_PLAN: % is priced for the % plan, and this quote sells %',
          p_item_code, pi.plan_code, v_plan using errcode = '23514';
      end if;
      if exists (select 1 from erp.document_line l
                  join erp.price_item x on x.tenant_id = l.tenant_id and x.item_id = l.item_id
                 where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
                   and x.kind = pi.kind) then
        raise exception 'CLOVEERP_QUOTE_HAS_THESE_USERS: this quote already carries a line of % users', replace(pi.kind, '_', ' ')
          using errcode = '23514';
      end if;
      select pe.limit_value into v_limit from erp_meta.plan_entitlement pe
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
      end if;
    else
      null;
  end case;$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not end its kinds with an empty else exactly once, so it is not the 20260914040000 body', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$quote_line$;

select erp.register_refusal('CLOVEERP_QUOTE_USERS_BEFORE_PLAN',
  'Adding extra or light users to a quote that has no plan on it yet.',
  'Extra users are priced for one plan, and each plan includes a different number of users, so the plan comes first.',
  'Add the plan to the quote, then add the users beyond what it includes.');

select erp.register_refusal('CLOVEERP_QUOTE_USERS_FOR_ANOTHER_PLAN',
  'Adding users priced for one plan to a quote for another.',
  'An extra user costs a different amount on each plan, so a quote only takes the users priced for its own plan.',
  'Choose the users priced for the plan on this quote, or change the plan first.');

select erp.register_refusal('CLOVEERP_QUOTE_HAS_THESE_USERS',
  'Adding a second line of the same kind of users to one quote.',
  'A quote carries one line of full users and one of light users, and the quantity on the line is the number of users.',
  'Remove the line and add it again with the number of users you want.');

select erp.register_refusal('CLOVEERP_QUOTE_USERS_BEYOND_PLAN',
  'Adding more users to a quote than its plan allows.',
  'Every plan has a most users figure, and a customer quoted past it would be refused the users they paid for.',
  'Quote fewer users, choose a larger plan, or add a users band that raises the limit.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Cost is per year
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.term_unit_cost(p_item_id uuid, p_currency char(3), p_term_kind text)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- The cost model is measured per year. An annual or multi-year rate is per
  -- year too; a monthly rate is per month, so it is set beside a twelfth.
  select case when p_term_kind = 'monthly' then round(c / 12.0)::bigint else c end
    from (select erp.unit_cost_for(p_item_id, p_currency) as c) x
$$;

comment on function erp.term_unit_cost is
  'The unit cost set beside a rate of a given term: the yearly cost model for an '
  'annual or multi-year rate, a twelfth of it for a monthly one.';

do $margin$
declare
  v_sig    constant text := 'erp.quote_margin(uuid)';
  v_def    text := pg_get_functiondef('erp.quote_margin(uuid)'::regprocedure);
  v_needle constant text := 'erp.unit_cost_for(l.item_id, q.currency) as cost_unit_minor';
  v_new    constant text := 'erp.term_unit_cost(l.item_id, q.currency, q.term_kind) as cost_unit_minor';
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not read the unit cost exactly once', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$margin$;

do $book$
declare
  v_sig     constant text := 'erp.price_book_report()';
  v_def     text := pg_get_functiondef('erp.price_book_report()'::regprocedure);
  v_cost    constant text := 'erp.unit_cost_for(i.id, p.currency)';
  v_termed  constant text := 'erp.term_unit_cost(i.id, p.currency, split_part(p.price_list_code, ''/'', 2))';
  v_desc    constant text := $n$'description', pi.description,$n$;
  v_desc2   constant text := $n$'description', pi.description, 'included_users', pi.included_users,$n$;
begin
  if (length(v_def) - length(replace(v_def, v_cost, ''))) / length(v_cost) <> 3
     or (length(v_def) - length(replace(v_def, v_desc, ''))) / length(v_desc) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260904590000 body', v_sig;
  end if;
  execute replace(replace(v_def, v_cost, v_termed), v_desc, v_desc2);
end
$book$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The list, in one call
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.set_up_selling()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_book      constant text := 'CLOVE-LIST';
  v_installed boolean := false;
  v_opened    boolean := false;
  v_added     integer := 0;
  v_waiting   text[] := array[]::text[];
  v_version   integer;
  i           record;
begin
  perform erp.require_platform_organisation();
  perform erp.authorise('sales.price', null, null, null, 'price_book', null);

  -- The module: the quote lifecycle, discount approval above 10%, the order
  -- form and the expiry job. Once the organisation is live its change set
  -- waits for a second administrator, and the list waits with it.
  if not exists (select 1 from erp.state_machine m
                  where m.tenant_id = v_tenant and m.code = 'commercial_quote' and m.status = 'active') then
    if exists (select 1 from erp.change_set cs
                where cs.tenant_id = v_tenant and cs.code = 'commercial'
                  and cs.status in ('draft', 'ready', 'approved', 'promoting')) then
      v_waiting := array_append(v_waiting, 'The commercial module is waiting for a second administrator to approve it under Configuration.'::text);
    else
      perform erp.configure_commercial(10, 'administrator');
      if exists (select 1 from erp.state_machine m
                  where m.tenant_id = v_tenant and m.code = 'commercial_quote' and m.status = 'active') then
        v_installed := true;
      else
        v_waiting := array_append(v_waiting, 'The commercial module is waiting for a second administrator to approve it under Configuration.'::text);
      end if;
    end if;
  end if;

  select b.version into v_version from erp.price_book_in_force(v_book) b;
  if v_version is null then
    if exists (select 1 from erp.change_set cs
                where cs.tenant_id = v_tenant and cs.code like 'price-book-' || v_book || '-%'
                  and cs.status in ('draft', 'ready', 'approved', 'promoting')) then
      v_waiting := array_append(v_waiting, 'The price book is waiting for a second administrator to approve it under Configuration.'::text);
    else
      perform erp.open_price_book(v_book, 'Clove ERP list prices', array['GBP'], current_date,
        'The list set on 14 September 2026. Annual and multi-year rates are per year, multi-year 10% lower; monthly rates are per month and 15% higher. Costs are per year.');
      select b.version into v_version from erp.price_book_in_force(v_book) b;
      if v_version is null then
        v_waiting := array_append(v_waiting, 'The price book is waiting for a second administrator to approve it under Configuration.'::text);
      else
        v_opened := true;
      end if;
    end if;
  end if;

  if cardinality(v_waiting) = 0 then
    -- Pounds a month at list, billed annually. A recurring item's annual rate
    -- is twelve months, its monthly rate 15% more, its multi-year rate 10%
    -- less; a one-off item costs the same on any term it is sold on, and is
    -- not sold month-to-month. Costs are per year for recurring items and per
    -- sale for one-off ones: estimates, marked as such, to be replaced with
    -- real hosting and support figures.
    for i in
      select * from (values
        ('PLAN-STARTER', 'Starter plan', 'plan_tier', 'starter', 5, null::text, 39500, false, 60000, 90000, 12000,
         'One company and one site, with five full users included.'),
        ('PLAN-STANDARD', 'Standard plan', 'plan_tier', 'standard', 15, null, 109500, false, 180000, 240000, 30000,
         'Up to three companies and ten sites, with manufacturing and planning, and fifteen full users included.'),
        ('PLAN-ENTERPRISE', 'Enterprise plan', 'plan_tier', 'enterprise', 40, null, 275000, false, 480000, 600000, 60000,
         'Every feature and no limit on companies or sites, with forty full users included. The starting price for a group.'),
        ('USER-STARTER', 'Extra full user, Starter', 'full_user', 'starter', null, null, 4500, false, 6000, 12000, 0,
         'Each full user beyond the five the Starter plan includes.'),
        ('USER-STANDARD', 'Extra full user, Standard', 'full_user', 'standard', null, null, 4900, false, 6000, 12000, 0,
         'Each full user beyond the fifteen the Standard plan includes.'),
        ('USER-ENTERPRISE', 'Extra full user, Enterprise', 'full_user', 'enterprise', null, null, 4500, false, 6000, 12000, 0,
         'Each full user beyond the forty the Enterprise plan includes.'),
        ('LIGHT-STARTER', 'Light user, Starter', 'light_user', 'starter', null, null, 900, false, 2400, 2400, 0,
         'Somebody who only approves, reads reports or uses the scanner.'),
        ('LIGHT-STANDARD', 'Light user, Standard', 'light_user', 'standard', null, null, 900, false, 2400, 2400, 0,
         'Somebody who only approves, reads reports or uses the scanner.'),
        ('LIGHT-ENTERPRISE', 'Light user, Enterprise', 'light_user', 'enterprise', null, null, 600, false, 2400, 2400, 0,
         'Somebody who only approves, reads reports or uses the scanner.'),
        ('COMPANY-EXTRA', 'Extra company', 'service', null, null, null, 15000, false, 24000, 36000, 0,
         'Each company beyond what the plan includes.'),
        ('SITE-EXTRA', 'Extra site', 'service', null, null, null, 7500, false, 12000, 18000, 0,
         'Each site beyond what the plan includes.'),
        ('SUPPORT-PRIORITY', 'Priority support', 'support_tier', null, null, 'sev2', 15000, false, 0, 90000, 0,
         'Four-hour response and a named contact. Ten per cent of the subscription, and never less than this.'),
        ('ONBOARD-GUIDED', 'Guided onboarding', 'service', null, null, null, 250000, true, 0, 150000, 0,
         'One-off. The set-up interview, products and partners imported, opening balances and two training sessions.'),
        ('ONBOARD-STANDARD', 'Standard implementation', 'service', null, null, null, 750000, true, 0, 450000, 0,
         'One-off. Guided onboarding, plus warehouse layout, approval limits, document templates and five days of support.'),
        ('PILOT-30', 'Thirty-day pilot', 'service', null, null, null, 50000, true, 0, 30000, 0,
         'One-off. Thirty days on the customer''s own data, credited against the first year.')
      ) as v(code, name, kind, plan_code, included_users, severity, list_minor, one_off,
             infrastructure_minor, support_minor, pass_through_minor, description)
    loop
      -- What is already on the book is the organisation's to change, not this.
      continue when exists (select 1 from erp.item x
                              join erp.price_item pi on pi.tenant_id = x.tenant_id and pi.item_id = x.id
                             where x.tenant_id = v_tenant and x.code = i.code);

      perform erp.upsert_price_item(
        i.code, i.name, i.kind,
        case when i.kind in ('plan_tier', 'full_user', 'light_user') then i.plan_code end,
        null, null, null, null, null, i.severity, i.description);
      if i.included_users is not null then
        update erp.price_item pi set included_users = i.included_users, updated_at = now()
          from erp.item x
         where x.tenant_id = v_tenant and x.code = i.code
           and pi.tenant_id = x.tenant_id and pi.item_id = x.id;
      end if;

      if i.one_off then
        perform erp.set_rate(v_book, i.code, 'GBP', i.list_minor, 'annual');
        perform erp.set_rate(v_book, i.code, 'GBP', i.list_minor, 'multi_year');
      else
        perform erp.set_rate(v_book, i.code, 'GBP', i.list_minor * 12, 'annual');
        perform erp.set_rate(v_book, i.code, 'GBP', round(i.list_minor * 1.15)::bigint, 'monthly');
        perform erp.set_rate(v_book, i.code, 'GBP', round(i.list_minor * 12 * 0.9)::bigint, 'multi_year');
      end if;
      perform erp.set_cost_model(i.code, 'GBP', i.infrastructure_minor, i.support_minor, i.pass_through_minor,
        case when i.one_off then 'Estimate per sale, set with the list on 14 September 2026. Replace with real figures.'
             else 'Estimate per year, set with the list on 14 September 2026. Replace with real figures.' end);
      v_added := v_added + 1;
    end loop;
  end if;

  return jsonb_build_object(
    'price_book', v_book,
    'version', v_version,
    'installed_now', v_installed,
    'opened_now', v_opened,
    'items_added', v_added,
    'items_on_book', (select count(*) from erp.price_item pi where pi.tenant_id = v_tenant),
    'waiting_for', to_jsonb(v_waiting));
end;
$$;

comment on function erp.set_up_selling is
  'In the platform''s organisation: installs the commercial module, opens the '
  'CLOVE-LIST price book in pounds and fills in the price list the platform '
  'owner set on 14 September 2026 — plans, extra and light users, extra '
  'companies and sites, onboarding, the pilot and Priority support — each with '
  'annual, monthly and multi-year rates and a cost. Adds what is missing and '
  'changes nothing already on the book. Once the organisation is live, a '
  'module or book awaiting a second administrator is named and the list waits.';

create or replace function public.erp_set_up_selling()
returns jsonb
language sql
volatile
set search_path = ''
as $$ select erp.set_up_selling(); $$;

revoke all on function public.erp_set_up_selling() from public, anon;
grant execute on function public.erp_set_up_selling() to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_up_selling', 'erp.set_up_selling',
   'Installs the commercial module, opens the platform''s price book and fills in its price list. Refused outside the platform''s organisation; sales.price to run it, and administration.configure inside the module and price book installers.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/commercial/price-book', array['erp_set_up_selling']);

update erp_ref.help_topic
   set next_action = 'Load Clove ERP''s price list, then change any rate or cost that has moved.'
 where screen_path = '/commercial/price-book';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Where selling stands, for the console
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_platform_commercial_state()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v          erp_meta.platform_staff;
  v_platform uuid;
begin
  v := erp_meta.require_platform('support');
  select po.tenant_id into v_platform from erp_meta.platform_organisation po;
  return jsonb_build_object(
    'platform_organisation', (select jsonb_build_object(
        'tenant_id', po.tenant_id, 'tenant_code', po.tenant_code,
        'name', (select t.name from erp.tenant t where t.id = po.tenant_id),
        'designated_at', po.designated_at, 'designated_by', po.designated_by, 'reason', po.reason,
        'status', (select t.status::text from erp.tenant t where t.id = po.tenant_id))
      from erp_meta.platform_organisation po),
    -- Demonstration organisations are marked, because nobody sells from one.
    'candidates', coalesce((select jsonb_agg(jsonb_build_object(
                                     'code', t.code, 'name', t.name,
                                     'is_demonstration', erp.tenant_is_demonstration(t.id))
                                   order by t.name)
                              from erp.tenant t where t.status::text = 'active'), '[]'::jsonb),
    'price_items', (select count(*) from erp.price_item pi where pi.tenant_id = v_platform),
    'selling', case when v_platform is null then null else jsonb_build_object(
        'installed', exists (select 1 from erp.state_machine m
                              where m.tenant_id = v_platform and m.code = 'commercial_quote' and m.status = 'active'),
        'price_book', (select jsonb_build_object('code', co.code, 'name', cv.value ->> 'name',
                                                 'version', cv.version, 'effective_from', cv.effective_from)
                         from erp.config_object co
                         join erp.config_version cv on cv.tenant_id = co.tenant_id and cv.config_object_id = co.id
                        where co.tenant_id = v_platform and co.config_type_code = 'commercial.price_book'
                          and co.status = 'active' and cv.status = 'active'
                          and cv.effective_from <= current_date
                          and (cv.effective_to is null or cv.effective_to > current_date)
                        order by co.code = 'CLOVE-LIST' desc, cv.version desc
                        limit 1),
        'rates', (select count(*) from erp.item_price p
                   where p.tenant_id = v_platform and p.price_kind = 'sales_list' and p.price_list_code like '%/%'),
        'waiting', exists (select 1 from erp.change_set cs
                            where cs.tenant_id = v_platform
                              and (cs.code = 'commercial' or cs.code like 'price-book-%')
                              and cs.status in ('draft', 'ready', 'approved', 'promoting')))
      end,
    'findings', coalesce((select jsonb_agg(jsonb_build_object('finding', f.finding, 'reference', f.reference, 'detail', f.detail))
                            from erp.commercial_report() f), '[]'::jsonb));
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The words on the price book screen
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). The price book''s way to load the platform''s price list in one step.'
  from (values
    ('Start from Clove ERP''s price list'),
    ('The plans, extra and light users, extra companies and sites, onboarding, the pilot and Priority support, each with an annual, monthly and multi-year rate and a cost beside it. You can change any of them afterwards.'),
    ('Load the price list'),
    ('Adds every item on the list that is not on the book yet, installs quoting if it is not installed, and opens the CLOVE-LIST price book in pounds. Nothing already on the book is changed.'),
    ('full users included')
) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.selling_setup_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record; r2 record;
  ad uuid := gen_random_uuid(); ow uuid := gen_random_uuid(); ad2 uuid := gen_random_uuid();
  v_tenant uuid; v_code text := 'zzsell-' || substr(md5(random()::text), 1, 6);
  v_other uuid; v_other_code text := 'zzsello-' || substr(md5(random()::text), 1, 6);
  v_ok boolean; v_msg text; res jsonb; res2 jsonb; v_q uuid; v_state text; v_item uuid;
  v_prior erp_meta.platform_organisation;
begin
  -- The deployment's own designation, put back at the end: this suite runs
  -- where the platform may already sell.
  select po.* into v_prior from erp_meta.platform_organisation po;

  select * into r from erp.provision_tenant(v_code, 'Clove Platform Selling', 'admin@zzsell.test', 'Platform Admin');
  v_tenant := r.tenant_id;
  select * into r2 from erp.provision_tenant(v_other_code, 'A Customer', 'admin@zzsello.test', 'Customer Admin');
  v_other := r2.tenant_id;
  insert into auth.users (id, email) values (ad, 'admin@zzsell.test'), (ow, 'owner@zzsell.test'), (ad2, 'admin@zzsello.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzsell.test', ow, 'Platform Owner', 'owner');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ad2)::text, true);
  perform erp.claim_invitation(r2.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  perform erp.designate_platform_organisation(v_code, 'the selling setup suite');

  -- ── Only the platform's organisation sells ───────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ad2)::text, true);
  begin
    perform public.erp_set_up_selling();
    v_ok := false; v_msg := 'a customer organisation loaded the price list';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_NOT_THE_PLATFORM_ORGANISATION%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'another organisation cannot load the platform''s price list', v_ok, v_msg;

  -- ── One call ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp_test.reopen_bootstrap_window(v_tenant);
  res := public.erp_set_up_selling();
  perform erp_test.close_bootstrap_window(v_tenant);

  return query select 'one call installs quoting, opens the price book and fills in the list',
    (res ->> 'items_added')::integer = 15 and (res ->> 'installed_now')::boolean and (res ->> 'opened_now')::boolean
    and jsonb_array_length(res -> 'waiting_for') = 0
    and exists (select 1 from erp.state_machine m where m.tenant_id = v_tenant and m.code = 'commercial_quote' and m.status = 'active')
    and (select b.version from erp.price_book_in_force('CLOVE-LIST') b) = 1
    and erp.quote_discount_threshold() = 10,
    res::text;

  select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.code = 'PLAN-STANDARD';
  return query select 'the Standard plan is £1,095 a month billed annually, 15% more monthly and 10% less over several years',
    erp.rate_for(v_item, 'CLOVE-LIST', 'annual', 'GBP') = 1314000
    and erp.rate_for(v_item, 'CLOVE-LIST', 'monthly', 'GBP') = 125925
    and erp.rate_for(v_item, 'CLOVE-LIST', 'multi_year', 'GBP') = 1182600
    and (select pi.included_users from erp.price_item pi where pi.tenant_id = v_tenant and pi.item_id = v_item) = 15,
    format('annual %s, monthly %s, multi-year %s',
      erp.rate_for(v_item, 'CLOVE-LIST', 'annual', 'GBP'), erp.rate_for(v_item, 'CLOVE-LIST', 'monthly', 'GBP'),
      erp.rate_for(v_item, 'CLOVE-LIST', 'multi_year', 'GBP'));

  return query select 'a one-off item costs the same on any term, and is not sold month-to-month',
    erp.rate_for((select i.id from erp.item i where i.tenant_id = v_tenant and i.code = 'ONBOARD-GUIDED'), 'CLOVE-LIST', 'annual', 'GBP') = 250000
    and erp.rate_for((select i.id from erp.item i where i.tenant_id = v_tenant and i.code = 'ONBOARD-GUIDED'), 'CLOVE-LIST', 'multi_year', 'GBP') = 250000
    and erp.rate_for((select i.id from erp.item i where i.tenant_id = v_tenant and i.code = 'ONBOARD-GUIDED'), 'CLOVE-LIST', 'monthly', 'GBP') is null,
    'Guided onboarding £2,500';

  return query select 'every rate has a cost beside it, so the book has no findings',
    not exists (select 1 from erp.commercial_report()), coalesce((select string_agg(f.finding || ' ' || f.reference, '; ') from erp.commercial_report() f), 'none');

  res2 := erp.price_book_report();
  return query select 'a monthly rate is set beside a twelfth of the yearly cost',
    (select (rt ->> 'unit_cost_minor')::bigint
       from jsonb_array_elements(res2 -> 'items') x
       cross join jsonb_array_elements(x -> 'rates') rt
      where x ->> 'code' = 'PLAN-STANDARD' and rt ->> 'term_kind' = 'monthly') = 37500
    and (select (rt ->> 'margin_pct')::numeric
       from jsonb_array_elements(res2 -> 'items') x
       cross join jsonb_array_elements(x -> 'rates') rt
      where x ->> 'code' = 'PLAN-STANDARD' and rt ->> 'term_kind' = 'monthly') > 0
    and (select (x ->> 'included_users')::integer from jsonb_array_elements(res2 -> 'items') x where x ->> 'code' = 'PLAN-STANDARD') = 15,
    'cost 450,000 a year, 37,500 a month';

  -- ── Pressed twice ────────────────────────────────────────────────────────

  perform erp.set_rate('CLOVE-LIST', 'PLAN-STARTER', 'GBP', 400000, 'annual');
  res := public.erp_set_up_selling();
  return query select 'pressed twice, it adds nothing and leaves a changed rate alone',
    (res ->> 'items_added')::integer = 0 and (res ->> 'items_on_book')::integer = 15
    and erp.rate_for((select i.id from erp.item i where i.tenant_id = v_tenant and i.code = 'PLAN-STARTER'), 'CLOVE-LIST', 'annual', 'GBP') = 400000,
    res::text;

  -- ── The Standard plan carries manufacturing ──────────────────────────────

  return query select 'the Standard plan carries production, planning, forecasting and recall; Starter does not',
    (select count(*) from erp_meta.plan_capability pc
      where pc.plan_code = 'standard'
        and pc.capability_code in ('production', 'planning_mrp', 'forecasting', 'recall_management')) = 4
    and not exists (select 1 from erp_meta.plan_capability pc where pc.plan_code = 'starter' and pc.capability_code = 'production')
    and not exists (select 1 from erp_meta.plan_capability pc where pc.plan_code = 'standard' and pc.capability_code = 'project_accounting'),
    'Enterprise keeps multi-company, intercompany, serials, containers and projects';

  -- ── Users on a quote ─────────────────────────────────────────────────────

  v_q := erp.open_commercial_quote('ACME', 'Acme Foods', 'CLOVE-LIST', 'annual', 12, 'GBP', 30);
  begin
    perform erp.add_quote_line(v_q, 'USER-STANDARD', 3);
    v_ok := false; v_msg := 'users were added before a plan';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_QUOTE_USERS_BEFORE_PLAN%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'users beyond a plan need the plan first', v_ok, v_msg;

  perform erp.add_quote_line(v_q, 'PLAN-STANDARD');
  begin
    perform erp.add_quote_line(v_q, 'USER-STARTER', 3);
    v_ok := false; v_msg := 'Starter users went onto a Standard quote';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_QUOTE_USERS_FOR_ANOTHER_PLAN%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a quote takes only the users priced for its own plan', v_ok, v_msg;

  perform erp.add_quote_line(v_q, 'USER-STANDARD', 80);
  begin
    perform erp.add_quote_line(v_q, 'USER-STANDARD', 1);
    v_ok := false; v_msg := 'a second line of full users';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_QUOTE_HAS_THESE_USERS%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'one line of each kind of user, its quantity the number of users', v_ok, v_msg;

  begin
    perform erp.add_quote_line(v_q, 'LIGHT-STANDARD', 6);
    v_ok := false; v_msg := '15 included, 80 full and 6 light went past the plan''s 100';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_QUOTE_USERS_BEYOND_PLAN%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a quote refuses users beyond what its plan allows', v_ok, v_msg;

  perform erp.add_quote_line(v_q, 'LIGHT-STANDARD', 5);
  perform erp.add_quote_line(v_q, 'ONBOARD-GUIDED');
  v_state := erp.submit_quote(v_q);
  return query select 'up to the limit it is a quote, and at list it approves itself',
    v_state = 'approved'
    and (erp.quote_margin(v_q) -> 'totals' ->> 'quoted_minor')::bigint = 1314000 + 80 * 58800 + 5 * 10800 + 250000
    and (erp.quote_margin(v_q) -> 'totals' ->> 'below_cost_lines')::integer = 0,
    format('%s, %s', v_state, erp.quote_margin(v_q) -> 'totals' ->> 'quoted_minor');

  -- ── The console's view ───────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  res := public.erp_platform_commercial_state();
  return query select 'the console reads that selling is set up: installed, a book in force, rates on it',
    (res -> 'selling' ->> 'installed')::boolean
    and res -> 'selling' -> 'price_book' ->> 'code' = 'CLOVE-LIST'
    and (res -> 'selling' ->> 'rates')::integer = 12 * 3 + 3 * 2
    and not (res -> 'selling' ->> 'waiting')::boolean
    and res -> 'platform_organisation' ->> 'name' = 'Clove Platform Selling',
    (res -> 'selling')::text;

  -- ── Clean up ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.platform_organisation where tenant_id = v_tenant;
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(v_other);
  delete from erp.tenant where id = v_other;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzsell.test';
  delete from auth.users where id in (ad, ow, ad2);
  if v_prior.tenant_id is not null then
    insert into erp_meta.platform_organisation (tenant_id, tenant_code, designated_at, designated_by, reason)
    values (v_prior.tenant_id, v_prior.tenant_code, v_prior.designated_at, v_prior.designated_by, v_prior.reason);
  end if;
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id in (v_tenant, v_other))
    and not exists (select 1 from erp_meta.platform_organisation po where po.tenant_id = v_tenant)
    and (v_prior.tenant_id is null
         or exists (select 1 from erp_meta.platform_organisation po where po.tenant_id = v_prior.tenant_id)),
    'organisations and staff gone, and any designation that was there before is back';
end;
$$;

create or replace function erp_test.assert_selling_setup_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _selling_setup_result on commit drop as
    select * from erp_test.selling_setup_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _selling_setup_result;
  if v_passed < v_total then
    raise exception E'CLOVEERP_SELLING_SETUP_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('selling setup: %s/%s', v_passed, v_total);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_commercial_sound();
select erp.assert_commercial_quotes_sound();
select erp.assert_resource_coverage('en');
select erp.assert_guidance_sound();
-- Only this migration's own suite runs here. The commercial suites that came
-- before it designate an organisation of their own and delete the designation
-- afterwards, which on the live database would take the platform's away; the
-- build runs them.
select erp_test.assert_selling_setup_suite();
