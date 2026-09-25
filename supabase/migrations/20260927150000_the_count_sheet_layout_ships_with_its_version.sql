set lock_timeout = '30s';

-- =============================================================================
-- 20260927150000  The count sheet's layout ships with its version
-- -----------------------------------------------------------------------------
-- A repair of 20260927100000, which was edited after it was pushed (it is
-- named in supabase/ci/migrations_edited.txt). The first version pushed
-- shipped the count sheet's output template with no version, and a template
-- with no version has nothing to render: erp.assert_output_integrity() says
-- so on the full build. The edit reaches no environment that already ran
-- the file, so the definition is re-applied here.
--
--   * erp.count_sheet_pack_items() ships the template with its version, and
--     version 7 of inventory-operations carries the same four items.
--   * An organisation that installed the sheet without its version is given
--     one.
-- =============================================================================

create or replace function erp.count_sheet_pack_items()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- The count sheet (20260927100000), read by erp.configure_inventory() for a
  -- new install and by the upgrade register for an organisation on version 6,
  -- so the two cannot disagree. In the order a change set applies them: the
  -- lifecycle and the sequence before the type that names them.
  --
  -- The lifecycle is the raise's and the counts', not a person's. Issued by
  -- erp.raise_count_tasks() once every place is on the sheet, asking what
  -- raising asks; closed by erp.close_count_sheet_when_finished() when the
  -- last of its counts is posted or cancelled, derived from
  -- erp.count_sheet_is_finished(). No state is committed: a count sheet
  -- posts nothing, and is not a document posted.
  select jsonb_build_array(
    jsonb_build_object('kind', 'state_machine', 'key', 'count_sheet', 'payload',
      jsonb_build_object(
        'code', 'count_sheet', 'object_type', 'document', 'name', 'Count sheet',
        'states', jsonb_build_array(
          jsonb_build_object('code','draft','name','Draft','is_initial',true,'is_terminal',false,'is_committed',false,'sort_order',10),
          jsonb_build_object('code','issued','name','Issued','is_initial',false,'is_terminal',false,'is_committed',false,'sort_order',20),
          jsonb_build_object('code','closed','name','Closed','is_initial',false,'is_terminal',true,'is_committed',false,'sort_order',30)),
        'transitions', jsonb_build_array(
          jsonb_build_object('code','issue','name','Issue','from','draft','to','issued','required_permission','inventory.count','sort_order',10),
          jsonb_build_object('code','close','name','Close','from','issued','to','closed','required_permission','inventory.count','sort_order',20)))),
    jsonb_build_object('kind', 'numbering_rule', 'key', 'count_sheet', 'payload',
      jsonb_build_object('code','count_sheet','prefix','CNT-','pad_to',6,
                         'reset_period','yearly','next_value',1)),
    jsonb_build_object('kind', 'document_type', 'key', 'count_sheet', 'payload',
      jsonb_build_object('code','count_sheet','base_type','count',
                         'name','Count sheet','numbering_rule','count_sheet',
                         'state_machine','count_sheet',
                         'create_permission','inventory.count')),
    jsonb_build_object('kind', 'output_template', 'key', 'count_sheet', 'payload',
      jsonb_build_object(
        'code','count_sheet','name_key','output.template.count_sheet',
        'kind','document','base_type','count','page','A4',
        'blocks', b.blocks,
        -- The template names the document, its version renders it (§15.2):
        -- a template with no version has nothing to render.
        'version', jsonb_build_object(
          'rendering_engine','pdf','required_permission','inventory.count',
          'blocks', b.blocks))))
    from (select jsonb_build_array(
          jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
          jsonb_build_object('kind','issuer','fields',jsonb_build_array('entity_name')),
          jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','our_reference','line_count')),
          jsonb_build_object('kind','lines','fields',jsonb_build_array(
            'line_no','location','item_code','description','batch',
            'expected_quantity','uom','counted_quantity')),
          jsonb_build_object('kind','signature','label_key','output.block.counted_by')) as blocks) b
$$;

comment on function erp.count_sheet_pack_items() is
  'The count sheet (20260927100000): its lifecycle, numbering rule, document type and output '
  'template, the items erp.configure_inventory() and the inventory-operations upgrade register both read.';

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'inventory-operations', 7, i.value ->> 'kind', i.value ->> 'key', i.value -> 'payload',
       200 + 10 * i.ordinality::integer
  from jsonb_array_elements(erp.count_sheet_pack_items()) with ordinality as i(value, ordinality)
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

-- The version an organisation's count sheet is missing, from the helper. The
-- platform putting right what it shipped, not an organisation changing its
-- configuration, so the live guard comes off for one statement and goes
-- straight back, inside the same transaction (as 20260925700000 did).
alter table erp.output_template_version disable trigger t_output_template_version_live_guard;
insert into erp.output_template_version (
  tenant_id, output_template_id, version, rendering_engine, page, blocks,
  required_permission, status, effective_from, note)
select ot.tenant_id, ot.id, 1, v.value ->> 'rendering_engine', '{}'::jsonb, v.value -> 'blocks',
       v.value ->> 'required_permission', 'active', current_date,
       'Shipped with the count sheet (20260927150000).'
  from erp.output_template ot
  cross join lateral (
    select i.value -> 'payload' -> 'version' as value
      from jsonb_array_elements(erp.count_sheet_pack_items()) i
     where i.value ->> 'kind' = 'output_template') v
 where ot.code = 'count_sheet' and ot.base_type_code = 'count'
   and not exists (select 1 from erp.output_template_version tv
                    where tv.tenant_id = ot.tenant_id and tv.output_template_id = ot.id);
alter table erp.output_template_version enable trigger t_output_template_version_live_guard;

do $check$
begin
  if exists (select 1 from erp.output_template ot
              where ot.code = 'count_sheet'
                and not exists (select 1 from erp.output_template_version tv
                                 where tv.tenant_id = ot.tenant_id and tv.output_template_id = ot.id)) then
    raise exception 'CLOVEERP_OUTPUT_UNSOUND: a count sheet layout is still without its version';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       join jsonb_array_elements(erp.count_sheet_pack_items()) i
         on i.value ->> 'kind' = ui.object_kind and i.value ->> 'key' = ui.object_key
        and i.value -> 'payload' = ui.payload
      where ui.install_code = 'inventory-operations' and ui.to_version = 7) <> 4 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 7 of inventory-operations is not the four items the count sheet ships';
  end if;
end
$check$;

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
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
