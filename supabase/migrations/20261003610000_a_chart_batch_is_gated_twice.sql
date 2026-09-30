-- ═════════════════════════════════════════════════════════════════════════════
-- A chart batch is gated twice
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Review of 20261003600000, which ships in the same release:
--
--   1. erp.validate_import, erp.load_import and erp.rollback_import hand a
--      registered import object to its own functions before the pipeline's
--      gate runs, so the account functions authorised finance.configure
--      alone. A person holding finance.configure without master_data.import
--      could load or roll back a chart somebody else staged. Each now
--      authorises master_data.import first, then finance.configure.
--
--   2. Marking a legacy account as a control account refused a code that was
--      not a receivable, payable or inventory control account, but not one
--      that was withdrawn or not postable, which mapping already refused.
--
-- Same signatures and return types, so the grants and the register stand.
-- erp_test.import_crosswalk_suite() proves the chart still maps, marks,
-- creates, loads and rolls back as before.

set lock_timeout = '30s';

create or replace function erp.validate_account_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_entity uuid;
  v_find   jsonb;
  v_errors integer := 0;
  v_key    text;
  v_action text;
  v_code   text;
  v_bad    text;
  acc      erp.account%rowtype;
  v_seen   text[] := '{}';
  v_made   text[] := '{}';
begin
  select * into b from erp.import_batch x where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);
  perform erp.authorise('finance.configure', null, null, null, 'import_batch', p_batch_id);

  if b.status not in ('received', 'validated', 'previewed') then
    raise exception 'CLOVEERP_IMPORT_NOT_VALIDATABLE: % is %', b.code, b.status
      using errcode = '23514', hint = 'Stage a new batch; a loaded or rolled-back one is not validated again.';
  end if;

  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  for r in select * from erp.import_row x where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id order by x.row_no loop
    v_find := '[]'::jsonb;
    v_action := r.raw ->> 'action';
    v_code := btrim(coalesce(r.raw ->> 'code', ''));
    v_key := lower(coalesce(nullif(btrim(r.raw ->> 'legacy_code'), ''), btrim(r.raw ->> 'legacy_name'), ''));

    select string_agg(k, ', ') into v_bad
      from jsonb_object_keys(r.raw) k
     where k not in ('source', 'legacy_code', 'legacy_name', 'action', 'code', 'name', 'account_type');
    if v_bad is not null then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('unknown field(s): %s', v_bad));
    end if;
    if coalesce(r.raw ->> 'source', '') not in ('xero', 'unleashed') then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'source is xero or unleashed');
    end if;
    if v_key = '' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'legacy_code or legacy_name names the legacy account, and both are missing');
    elsif v_key = any (v_seen) then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('the legacy account %s is on an earlier row', v_key));
    else
      v_seen := v_seen || v_key;
    end if;
    if v_code = '' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'code is the Clove account, and it is missing');
    end if;

    acc := null;
    if v_code <> '' then
      select * into acc from erp.account a
       where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = v_code;
    end if;

    if v_action = 'map' then
      if acc.id is null or acc.status <> 'active' then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('no active account has the code %s to map to', v_code));
      elsif not acc.is_postable then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('%s is a heading, not a postable account', v_code));
      elsif acc.control_kind in ('receivable', 'payable', 'inventory') then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is the %s control account; mark the legacy account as control rather than mapping balances to it', v_code, acc.control_kind));
      end if;
    elsif v_action = 'control' then
      if acc.id is null or acc.control_kind is null or acc.control_kind not in ('receivable', 'payable', 'inventory') then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is not a receivable, payable or inventory control account', coalesce(nullif(v_code, ''), 'the code')));
      elsif acc.status <> 'active' or not acc.is_postable then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is a control account that is withdrawn or not postable; mark the active one', v_code));
      end if;
    elsif v_action = 'create' then
      if acc.id is not null then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is already %s; map to it, or create under a code that is free', v_code, acc.name));
      elsif v_code = any (v_made) then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('%s is created by an earlier row', v_code));
      elsif v_code <> '' then
        v_made := v_made || v_code;
      end if;
      if coalesce(btrim(r.raw ->> 'name'), '') = '' then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'a new account needs a name');
      end if;
      if coalesce(r.raw ->> 'account_type', '') not in ('asset', 'liability', 'equity', 'income', 'expense') then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('account_type is asset, liability, equity, income or expense, not %s', coalesce(r.raw ->> 'account_type', 'nothing')));
      end if;
    else
      v_find := v_find || jsonb_build_object('severity', 'error', 'message',
        format('action is map, control or create, not %s', coalesce(v_action, 'nothing')));
    end if;

    update erp.import_row
       set findings = v_find, target_id = null,
           action = case when jsonb_array_length(v_find) > 0 then 'reject'
                         when v_action = 'create' then 'insert' else 'skip' end,
           updated_at = now()
     where id = r.id;
    if jsonb_array_length(v_find) > 0 then v_errors := v_errors + 1; end if;
  end loop;

  update erp.import_batch set status = 'validated', error_count = v_errors, updated_at = now()
   where id = p_batch_id;
  return v_errors;
end;
$$;

revoke all on function erp.validate_account_import(uuid) from public, anon, authenticated;

create or replace function erp.load_account_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_entity uuid;
  v_id     uuid;
  v_n      integer := 0;
begin
  select * into b from erp.import_batch x where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);
  perform erp.authorise('finance.configure', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'previewed' then
    raise exception 'CLOVEERP_IMPORT_NOT_PREVIEWED: % is %, and a staged load happens after somebody has looked at it', b.code, b.status
      using errcode = '23514', hint = 'Validate, preview, then load.';
  end if;
  if b.error_count > 0 then
    raise exception 'CLOVEERP_IMPORT_HAS_ERRORS: % rows in % are rejected; fix the file rather than loading the good half', b.error_count, b.code
      using errcode = '23514', hint = 'The findings on each row say what is wrong.';
  end if;

  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  for r in select * from erp.import_row x
            where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id and x.action in ('insert', 'skip')
            order by x.row_no loop
    if r.action = 'insert' then
      insert into erp.account (tenant_id, entity_id, code, name, account_type, is_postable, currency)
      values (v_tenant, v_entity, btrim(r.raw ->> 'code'), btrim(r.raw ->> 'name'),
              (r.raw ->> 'account_type')::erp.account_type, true,
              (select e.base_currency from erp.entity e where e.id = v_entity))
      returning id into v_id;
    else
      select a.id into v_id from erp.account a
       where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = btrim(r.raw ->> 'code');
    end if;

    insert into erp.import_crosswalk
      (tenant_id, import_batch_id, source_system, object_type, legacy_key, legacy_name, clove_code, resolution)
    values (v_tenant, p_batch_id, r.raw ->> 'source', 'account',
            coalesce(nullif(btrim(r.raw ->> 'legacy_code'), ''), btrim(r.raw ->> 'legacy_name')),
            nullif(btrim(r.raw ->> 'legacy_name'), ''), btrim(r.raw ->> 'code'), r.raw ->> 'action');

    update erp.import_row
       set target_id = v_id, loaded = true, before_snapshot = null,
           loaded_ref = jsonb_build_object('account_id', v_id, 'created', r.action = 'insert'),
           updated_at = now()
     where id = r.id;
    v_n := v_n + 1;
  end loop;

  update erp.import_batch
     set status = 'loaded', loaded_at = now(), loaded_by = erp.current_principal_id(), updated_at = now()
   where id = p_batch_id;
  return v_n;
end;
$$;

revoke all on function erp.load_account_import(uuid) from public, anon, authenticated;

create or replace function erp.rollback_account_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  v_ids    uuid[];
  v_n      integer := 0;
begin
  select * into b from erp.import_batch x where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);
  perform erp.authorise('finance.configure', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'loaded' then
    raise exception 'CLOVEERP_IMPORT_NOT_LOADED: % is %', b.code, b.status
      using errcode = '23514', hint = 'Only a loaded batch is rolled back.';
  end if;

  select coalesce(array_agg((r.loaded_ref ->> 'account_id')::uuid), '{}') into v_ids
    from erp.import_row r
   where r.tenant_id = v_tenant and r.import_batch_id = p_batch_id
     and r.loaded and (r.loaded_ref ->> 'created')::boolean;

  begin
    delete from erp.account a where a.tenant_id = v_tenant and a.id = any (v_ids);
    get diagnostics v_n = row_count;
  exception when foreign_key_violation then
    raise exception 'CLOVEERP_ACCOUNT_IMPORT_IN_USE: an account % created is already used, so the batch stands', b.code
      using errcode = '23503',
            hint = 'Reverse what posted to or hangs from the account first, or leave the chart and map differently in a new batch.';
  end;

  update erp.import_row set loaded = false, target_id = null, updated_at = now()
   where tenant_id = v_tenant and import_batch_id = p_batch_id;
  update erp.import_batch set status = 'rolled_back', rolled_back_at = now(), updated_at = now()
   where id = p_batch_id;
  return v_n;
end;
$$;

revoke all on function erp.rollback_account_import(uuid) from public, anon, authenticated;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
