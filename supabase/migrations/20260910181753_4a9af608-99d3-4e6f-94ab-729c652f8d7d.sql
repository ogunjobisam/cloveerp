-- ---------------------------------------------------------------------------
-- A role for the warehouse floor.
--
-- The standard roles were drawn one per module, which is right for an office
-- but wrong for a warehouse: the person who puts stock away also picks it and
-- loads the van, and that crosses inventory, sales and logistics. Naming those
-- three together as one job means a floor account can be made without handing
-- out adjustments, write-offs or prices to get there.
-- ---------------------------------------------------------------------------

create or replace function erp.standard_role_permissions(p_code text)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct p.code order by p.code), '{}')
    from erp_ref.permission p
   where p.module_code = case p_code
                           when 'purchasing'  then 'procurement'
                           when 'despatch'    then 'logistics'
                           when 'master_data' then 'master_data'
                           when 'warehouse'   then null
                           else p_code
                         end
      or p.code = any (case p_code
        when 'inventory'   then array['master_data.read','reporting.read']
        when 'purchasing'  then array['master_data.read','inventory.read','reporting.read']
        when 'sales'       then array['master_data.read','inventory.read','reporting.read']
        when 'finance'     then array['master_data.read','reporting.read','reporting.export']
        when 'production'  then array['inventory.read','master_data.read','reporting.read']
        when 'quality'     then array['inventory.read','production.read','reporting.read']
        when 'despatch'    then array['inventory.read','sales.read','reporting.read']
        when 'planning'    then array['inventory.read','procurement.read','production.read','reporting.read']
        when 'reporting'   then array['master_data.read']
        when 'master_data' then array['reporting.read']
        -- Put away, pick, despatch — and the reading each of those needs.
        -- Not inventory.adjust or inventory.write_off: correcting the books is
        -- somebody else's decision, and that separation is the control.
        when 'warehouse'   then array[
                                'inventory.read','inventory.move','inventory.count',
                                'logistics.read','logistics.despatch',
                                'sales.read','sales.despatch',
                                'master_data.read','reporting.read']
        else '{}'::text[]
      end)
$$;

comment on function erp.standard_role_permissions is
  'What one job needs, by role code. Roles combine, so a person doing two jobs '
  'holds both roles rather than a third role made for the pair.';

create or replace function erp.ensure_standard_roles(p_tenant_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_made  integer := 0;
  v_role  uuid;
  v_code  text;
  v_name  text;
  v_pair  text[];
begin
  foreach v_pair slice 1 in array array[
    array['inventory',   'Inventory'],
    array['warehouse',   'Warehouse staff'],
    array['purchasing',  'Purchasing'],
    array['sales',       'Sales'],
    array['finance',     'Finance'],
    array['production',  'Production'],
    array['quality',     'Quality'],
    array['despatch',    'Despatch'],
    array['planning',    'Planning'],
    array['reporting',   'Reporting'],
    array['master_data', 'Master data']
  ] loop
    v_code := v_pair[1];
    v_name := v_pair[2];

    -- A role already on file belongs to the organisation, however it was
    -- shaped. Seeding never rewrites one.
    if exists (select 1 from erp.role r
                where r.tenant_id = p_tenant_id and r.code = v_code) then
      continue;
    end if;

    insert into erp.role (tenant_id, code, name, description, status)
    values (p_tenant_id, v_code, v_name,
            format('What somebody working in %s needs. Combine it with others: '
                   'a person holds every permission of every role they hold.',
                   lower(v_name)),
            'active')
    returning id into v_role;

    insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
    select p_tenant_id, v_role, perm, '{}'
      from unnest(erp.standard_role_permissions(v_code)) perm;

    v_made := v_made + 1;
  end loop;

  return v_made;
end;
$$;

-- The role must actually be able to do the job it names.
do $$
declare
  v_missing text[];
begin
  select array_agg(want)
    into v_missing
    from unnest(array['inventory.move','logistics.despatch','sales.despatch']) want
   where not (want = any (erp.standard_role_permissions('warehouse')));

  if v_missing is not null then
    raise exception 'CLOVEERP_ROLE_INCOMPLETE: warehouse staff is missing %', v_missing;
  end if;

  if 'inventory.write_off' = any (erp.standard_role_permissions('warehouse'))
     or 'inventory.adjust' = any (erp.standard_role_permissions('warehouse')) then
    raise exception 'CLOVEERP_ROLE_TOO_WIDE: warehouse staff must not correct the books';
  end if;
end;
$$;
