create or replace function erp.seed_demo_operations()
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor uuid := erp.current_principal_id();
  v_site uuid; v_entity uuid; v_notes jsonb := '[]'::jsonb;
  v_supplier uuid; v_customer uuid; v_rm uuid; v_fg uuid;
  v_po uuid; v_receipt uuid; v_so uuid; v_line uuid; v_wo uuid;
  v_bulk uuid; v_bom uuid; v_uom uuid; v_prog text; v_n integer;
begin
  perform erp.authorise('master_data.write', null, null, null, 'tenant', v_tenant);

  select s.id, s.entity_id into v_site, v_entity
    from erp.site s where s.tenant_id = v_tenant and s.status = 'active'::erp.record_status
   order by s.code limit 1;
  if v_site is null then
    return jsonb_build_object('ok', false, 'notes',
      jsonb_build_array('There is no active site yet, so no operational history could be built.'));
  end if;

  begin
    perform erp.seed_demo_master_data(v_tenant, v_actor);
    v_notes := v_notes || to_jsonb('Demo master data is in place.'::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Master data could not be seeded: ' || sqlerrm)::text);
  end;

  insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, created_by, updated_by)
  select v_tenant, v_site, x.code, x.name, x.lt::erp.location_type, x.pickable, v_actor, v_actor
    from (values ('RECV','Goods in','receiving',false),('BULK','Bulk store','bulk',false),
                 ('PICK','Pick face','pick',true),('QC','Quarantine','quarantine',false),
                 ('DESP','Despatch bay','despatch',false)) as x(code,name,lt,pickable)
   where not exists (select 1 from erp.location l
                      where l.tenant_id = v_tenant and l.site_id = v_site and l.code = x.code);

  select id into v_bulk from erp.location where tenant_id = v_tenant and site_id = v_site and code = 'BULK';

  select p.id into v_supplier from erp.party p
    join erp.party_role r on r.tenant_id = p.tenant_id and r.party_id = p.id
   where p.tenant_id = v_tenant and r.role_kind = 'supplier' order by p.code limit 1;
  select p.id into v_customer from erp.party p
    join erp.party_role r on r.tenant_id = p.tenant_id and r.party_id = p.id
   where p.tenant_id = v_tenant and r.role_kind = 'customer' order by p.code limit 1;

  select id into v_rm from erp.item
   where tenant_id = v_tenant and status = 'active'::erp.record_status
   order by (code not like 'RM-%'), code limit 1;
  select id into v_fg from erp.item
   where tenant_id = v_tenant and status = 'active'::erp.record_status
     and (v_rm is null or id <> v_rm)
   order by (code not like 'FG-%'), code limit 1;
  v_fg := coalesce(v_fg, v_rm);

  if v_supplier is null or v_customer is null or v_rm is null then
    return jsonb_build_object('ok', false, 'notes', v_notes
      || to_jsonb('A supplier, a customer and at least one item are needed before history can be built.'::text));
  end if;

  -- A works order needs to know what the item is made of.
  begin
    if v_fg <> v_rm and not exists (select 1 from erp.bom b
                                     where b.tenant_id = v_tenant and b.item_id = v_fg
                                       and b.status = 'active'::erp.record_status) then
      select uom_id into v_uom from erp.item where tenant_id = v_tenant and id = v_rm;
      insert into erp.bom (tenant_id, code, item_id, site_id, version, name, output_quantity,
                           status, effective_from, created_by, updated_by)
      values (v_tenant, 'DEMO-BOM', v_fg, v_site, 1, 'Demo bill of materials', 1,
              'active'::erp.record_status, current_date - 30, v_actor, v_actor)
      returning id into v_bom;
      insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id,
                                created_by, updated_by)
      values (v_tenant, v_bom, 10, v_rm, 2, v_uom, v_actor, v_actor);
      v_notes := v_notes || to_jsonb('Created a demo bill of materials.'::text);
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(('Bill of materials was skipped: ' || sqlerrm)::text);
  end;

  -- Dates are today's, because posting rules take effect from a date and a
  -- backdated demo document would land before any rule was in force.
  begin
    v_po := erp.create_document('purchase_order', v_entity, v_site, v_supplier, current_date + 7);
    perform erp.add_document_line(v_po, v_rm, 500, 1250, 'Demo raw material order');
    perform erp.transition_document(v_po, 'submit');
    perform erp.transition_document(v_po, 'approve');
    perform erp.transition_document(v_po, 'send');
    v_notes := v_notes || to_jsonb('Raised and sent a purchase order for 500 units.'::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Purchase order was skipped: ' || sqlerrm)::text);
  end;

  if v_po is not null then
    begin
      v_receipt := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date);
      select dl.id into v_line from erp.document_line dl where dl.document_id = v_po order by dl.line_no limit 1;
      perform erp.receive_against(v_receipt, v_line, 500);
      perform erp.transition_document(v_receipt, 'post');
      v_notes := v_notes || to_jsonb('Received 500 units into stock.'::text);
    exception when others then
      v_notes := v_notes || to_jsonb(('Receipt was skipped: ' || sqlerrm)::text);
    end;
  end if;

  begin
    v_n := erp.raise_putaway_tasks(v_site);
    v_notes := v_notes || to_jsonb((v_n || ' putaway task(s) raised.')::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Putaway was skipped: ' || sqlerrm)::text);
  end;

  begin
    v_wo := erp.raise_works_order(v_fg, v_site, 50, 'assembly'::erp.works_order_kind, current_date + 7);
    perform erp.release_works_order(v_wo, true);
    perform erp.issue_to_works_order(v_wo, v_rm, 100, null, v_bulk);
    perform erp.receive_works_order_output(v_wo, 40, null, v_bulk);
    v_notes := v_notes || to_jsonb('Ran a works order for 50, received 40 so far.'::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Production history was skipped: ' || sqlerrm)::text);
  end;

  begin
    v_so := erp.create_document('sales_order', v_entity, v_site, v_customer, current_date + 5);
    perform erp.add_document_line(v_so, v_fg, 20, 9900, 'Demo customer order', current_date + 5);
    perform erp.transition_document(v_so, 'submit');
    perform erp.transition_document(v_so, 'approve');
    v_notes := v_notes || to_jsonb('Confirmed a customer order for 20 units.'::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Sales history was skipped: ' || sqlerrm)::text);
  end;

  begin
    select code into v_prog from erp.count_programme
     where tenant_id = v_tenant and status = 'active'::erp.record_status order by code limit 1;
    if v_prog is null then
      v_notes := v_notes || to_jsonb('No counting programme is configured, so no counts were raised.'::text);
    else
      v_n := erp.raise_count_tasks(v_prog);
      v_notes := v_notes || to_jsonb((v_n || ' count task(s) raised from ' || v_prog || '.')::text);
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(('Counting was skipped: ' || sqlerrm)::text);
  end;

  begin
    perform erp.run_planning(v_site, 90);
    v_notes := v_notes || to_jsonb('Planning run completed for the next 90 days.'::text);
  exception when others then
    v_notes := v_notes || to_jsonb(('Planning was skipped: ' || sqlerrm)::text);
  end;

  return jsonb_build_object('ok', true, 'site', v_site, 'notes', v_notes);
end $$;

revoke all on function erp.seed_demo_operations() from public, anon, authenticated;
