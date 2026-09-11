set lock_timeout = '30s';

-- The books get their analysis.
--
-- Three gaps closed together: a chart that stops short of a balance sheet, a
-- company with no account determination at all, and a posting that carries no
-- analysis because nothing ever defined a cost centre.

insert into erp.account (
  tenant_id, entity_id, code, name, account_type, control_kind,
  is_postable, currency, status)
select e.tenant_id, e.id, p.default_code, p.name, p.account_type, p.control_kind,
       true, e.base_currency, 'active'
  from erp.entity e
  cross join erp_ref.chart_account_purpose p
 where e.status = 'active'
on conflict (tenant_id, entity_id, code) do nothing;

insert into erp.account_determination (
  tenant_id, transaction_type, entity_id, account_id, note, valid_from, status)
select a.tenant_id, p.purpose, a.entity_id, a.id,
       'Seeded from the reference chart so every transaction type reaches an account.',
       current_date, 'active'
  from erp_ref.chart_account_purpose p
  join erp.account a
    on a.code = p.default_code
   and a.status = 'active'
 where p.purpose in (
         'bank', 'clearing', 'commitment_offset', 'cost_of_sales',
         'freight_variance', 'goods_received_not_invoiced', 'inventory',
         'labour_efficiency_variance', 'material_usage_variance',
         'operating_expenses', 'purchase_commitment', 'purchase_price_variance',
         'retained_earnings', 'revenue', 'sales_commitment', 'suspense',
         'tax_control', 'trade_payable', 'trade_receivable', 'work_in_progress')
   and not exists (
         select 1 from erp.account_determination ad
          where ad.tenant_id = a.tenant_id
            and ad.transaction_type = p.purpose
            and ad.status = 'active'
            and (ad.entity_id is null or ad.entity_id = a.entity_id));

insert into erp.dimension (tenant_id, code, name, derivation, is_mandatory_default)
select distinct e.tenant_id, 'COST_CENTRE', 'Cost centre',
       jsonb_build_object('coalesce', jsonb_build_array(
         jsonb_build_object('var', 'document.attributes.cost_centre'),
         jsonb_build_object('var', 'document.attributes.department'),
         jsonb_build_object('var', 'document.site_code'))),
       false
  from erp.entity e
on conflict (tenant_id, code) do update
  set name = excluded.name,
      derivation = excluded.derivation,
      status = 'active';

insert into erp.dimension_value (tenant_id, dimension_id, code, name)
select s.tenant_id, d.id, s.code, s.name
  from erp.site s
  join erp.dimension d on d.tenant_id = s.tenant_id and d.code = 'COST_CENTRE'
 where s.status = 'active'
on conflict (tenant_id, dimension_id, code) do nothing;

insert into erp.dimension_value (tenant_id, dimension_id, code, name)
select dep.tenant_id, d.id, dep.code, dep.name
  from erp.department dep
  join erp.dimension d on d.tenant_id = dep.tenant_id and d.code = 'COST_CENTRE'
 where dep.status = 'active'
on conflict (tenant_id, dimension_id, code) do nothing;

create or replace function erp.ensure_cost_centre_dimension()
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin
  select d.id into v_id
    from erp.dimension d
   where d.tenant_id = v_tenant and d.code = 'COST_CENTRE';

  if v_id is null then
    insert into erp.dimension (tenant_id, code, name, derivation, is_mandatory_default)
    values (v_tenant, 'COST_CENTRE', 'Cost centre',
            jsonb_build_object('coalesce', jsonb_build_array(
              jsonb_build_object('var', 'document.attributes.cost_centre'),
              jsonb_build_object('var', 'document.attributes.department'),
              jsonb_build_object('var', 'document.site_code'))),
            false)
    returning id into v_id;
  end if;
  return v_id;
end $$;

comment on function erp.ensure_cost_centre_dimension is
  'The cost centre dimension for this organisation, created on first use.';

create or replace function public.erp_cost_centres()
returns jsonb
language plpgsql
stable
set search_path to ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('finance.read');
  select coalesce(jsonb_agg(x order by x ->> 'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
             'cost_centre_id', dv.id,
             'code', dv.code,
             'name', dv.name,
             'parent', (select p.code from erp.dimension_value p
                         where p.tenant_id = dv.tenant_id and p.id = dv.parent_value_id),
             'valid_from', dv.valid_from,
             'valid_to', dv.valid_to,
             'status', dv.status,
             'posted_lines', (
               select count(*) from erp.journal_line l
                where l.tenant_id = dv.tenant_id
                  and l.dimensions ->> 'COST_CENTRE' = dv.code)) as x
      from erp.dimension_value dv
      join erp.dimension d on d.tenant_id = dv.tenant_id and d.id = dv.dimension_id
     where dv.tenant_id = erp.current_tenant_id()
       and d.code = 'COST_CENTRE'
  ) s;
  return v_out;
end $$;

comment on function public.erp_cost_centres is
  'The cost centres of this organisation, with how many posted lines each carries.';

create or replace function public.erp_upsert_cost_centre(
  p_code text,
  p_name text,
  p_parent_code text default null,
  p_valid_from date default null,
  p_valid_to date default null,
  p_status text default 'active'
) returns jsonb
language plpgsql
set search_path to ''
as $$
declare v_id uuid;
begin
  perform erp.authorise('finance.configure', null, null, null, 'dimension', null);

  if p_code is null or btrim(p_code) = '' then
    raise exception 'CLOVEERP_VALIDATION: a cost centre code is required' using errcode = '23514';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'CLOVEERP_VALIDATION: a cost centre name is required' using errcode = '23514';
  end if;

  perform erp.ensure_cost_centre_dimension();

  v_id := erp.upsert_dimension_value(
    'COST_CENTRE', p_code, p_name, p_parent_code, p_valid_from, p_valid_to,
    coalesce(nullif(btrim(coalesce(p_status, '')), ''), 'active'));

  return jsonb_build_object('cost_centre_id', v_id, 'code', upper(btrim(p_code)));
end $$;

comment on function public.erp_upsert_cost_centre is
  'Adds or changes a cost centre. Retiring one is a status of inactive, never a deletion.';

revoke all on function public.erp_cost_centres() from public, anon;
grant execute on function public.erp_cost_centres() to authenticated, service_role;
revoke all on function public.erp_upsert_cost_centre(text, text, text, date, date, text) from public, anon;
grant execute on function public.erp_upsert_cost_centre(text, text, text, date, date, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_upsert_cost_centre', 'erp.authorise',
   'Adds or changes a cost centre under finance.configure.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();
select erp.assert_public_api_safe();