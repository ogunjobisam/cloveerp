-- =============================================================================
-- §8.1's chart, as an alternative rather than a renumbering
--
-- The decision left open said: every account the finance, inventory and
-- production installers create sits in a range §8.1 assigns to something else,
-- the posting rules reach them by literal code, and renumbering is a migration
-- for every organisation that has posted anything.
--
-- All of that is still true, and none of it is changed here. What is added is
-- a second chart an organisation can CHOOSE, before it has one — the eleven
-- accounts renumbered into §8.1's bands, the four accounts §8.1 implies and
-- nothing creates, and the posting rules rewritten to reach them. Accounts and
-- the rules that name them travel as one pack, because the two are only
-- correct together: erp.post_document() resolves a posting line's account as a
-- literal code and raises ERPWARE_UNKNOWN_ACCOUNT if it is not there, so a
-- chart shipped without its rules would be a chart no document can post
-- against.
--
-- An organisation that has already posted keeps the chart it has. The decision
-- about renumbering those is still open and still theirs.
--
-- Three things fell out of trying to write a §8.1-conformant chart, and each
-- is a fix rather than a workaround:
--
--   * erp.upsert_account() had no way to set reconciliation_required or
--     close_blocking, added with §9.1's suspense job — so a pack could ship a
--     GRNI account and not the fact that it blocks a close.
--
--   * erp.chart_of_accounts_divergence_report() derives the expected band from
--     the account TYPE, and §8.1's 9000 band is a PURPOSE — suspense and
--     clearing, whatever type the account is. A conformant chart failed the
--     report meant to measure conformance.
--
--   * The commitment accounts post to the COMMIT ledger, not GL. §8.1
--     describes the statutory chart, so they are outside it, and the report
--     was flagging them as diverging from ranges that were never about them.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The capability, because an alternative chart is a choice and every other
-- choice in this product is one of these
-- -----------------------------------------------------------------------------

insert into erp_ref.capability (code, title, description, module_code, seq)
values ('statutory_chart_8_1', 'Statutory chart (§8.1 ranges)',
        'Ships a chart of accounts numbered by §8.1''s bands — current assets '
        'in the 2000s, current liabilities including GRNI and tax control in '
        'the 3000s, cost of sales and its variances in the 6000s, suspense and '
        'clearing in the 9000s — together with the posting rules that reach '
        'it. Chosen before an organisation has a chart; an organisation that '
        'has already posted keeps the one it has.',
        'finance', 32)
on conflict (code) do update set
  title = excluded.title, description = excluded.description,
  module_code = excluded.module_code, seq = excluded.seq;

-- Switching it off once documents have posted against the chart would leave
-- every posting rule naming an account nobody can find. The guard says so
-- before it happens rather than after.
insert into erp_ref.capability_guard
  (capability_code, schema_name, table_name, rationale)
values ('statutory_chart_8_1', 'erp', 'journal_line',
        'This organisation has posted against the §8.1 chart. Switching it off '
        'would leave the posting rules naming accounts that are no longer '
        'there, and the postings already made pointing at accounts the chart '
        'no longer explains.')
on conflict (capability_code, schema_name, table_name) do update set
  rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- The correspondence, stated once
--
-- Three things need to agree about which account a purpose reaches: the pack
-- that ships the chart, the report that explains what choosing it would
-- change, and the module installers whose posting rules name an account by
-- literal code. Written out three times they would agree until somebody edited
-- one of them.
--
-- This is NOT the account-determination mechanism, and does not touch the
-- decision to keep both and watch them. erp.post_document_finance() still
-- resolves a posting line to an account by literal code at posting time,
-- unchanged. What changes is only what the installer WRITES into the rule when
-- it builds it — a build-time lookup, not a runtime selection.
-- -----------------------------------------------------------------------------

create table if not exists erp_ref.chart_account_purpose (
  purpose         text primary key,
  name            text not null,
  account_type    erp.account_type not null,
  control_kind    erp.control_account_kind,
  -- What the module installers have always created.
  default_code    text not null,
  -- Where §8.1 puts the same thing.
  statutory_code  text not null,
  reconciliation_required boolean not null default false,
  close_blocking  boolean not null default false,
  -- Whether an installer creates it at all. §8.1 names four things nothing
  -- created — freight variance, equity, operating expenses, and a suspense
  -- account §13 clause 7 asks to be empty at a close.
  installer_creates boolean not null default true,
  note            text not null,
  seq             integer not null default 100
);

comment on table erp_ref.chart_account_purpose is
  'What each account in the product is FOR, and the code it wears under each '
  'chart. Read by the chart_8_1 pack, by erp.chart_alternative_report(), and '
  'by erp.chart_account_code() which the module installers use to write their '
  'posting rules against whichever chart the organisation chose.';

select erp_meta.register_table('erp_ref', 'chart_account_purpose', 'product_content',
  'Each account''s purpose, and its code under the default and §8.1 charts.');

insert into erp_ref.chart_account_purpose
  (purpose, name, account_type, control_kind, default_code, statutory_code,
   reconciliation_required, close_blocking, installer_creates, note, seq)
values
  ('bank', 'Bank', 'asset', 'bank', '1000', '2100', false, false, true,
   '§8.1 puts current assets in the 2000 band.', 10),
  ('trade_receivable', 'Trade receivables', 'asset', 'receivable', '1100', '2200', false, false, true,
   '§8.1 puts current assets in the 2000 band.', 20),
  ('inventory', 'Inventory', 'asset', 'inventory', '1200', '2300', false, false, true,
   '§8.1 puts current assets in the 2000 band.', 30),
  ('work_in_progress', 'Work in progress', 'asset', null, '5100', '2400', false, false, true,
   'The installers put work in progress at 5100, an expense code. It is stock that has been started.', 40),
  ('trade_payable', 'Trade payables', 'liability', 'payable', '2000', '3100', false, false, true,
   '§8.1 puts current liabilities in the 3000 band.', 50),
  ('goods_received_not_invoiced', 'Goods received not invoiced', 'liability', null, '2100', '3200', true, true, true,
   '§8.1 names GRNI in the current liabilities band. A balance here is a receipt nobody has been invoiced for, so it is reconciled before a period closes.', 60),
  ('tax_control', 'Tax control', 'liability', 'tax', '2200', '3300', true, true, true,
   '§8.1 names tax control in the same band. A tax control account that does not agree with the return is a close nobody should sign.', 70),
  ('retained_earnings', 'Retained earnings', 'equity', null, '4100', '4100', false, false, false,
   '§8.1 puts equity in the 4000 band and nothing created any.', 80),
  ('revenue', 'Revenue', 'income', null, '4000', '5100', false, false, true,
   '§8.1 gives the 4000 band to equity and revenue to the 5000 band.', 90),
  ('cost_of_sales', 'Cost of goods sold', 'expense', null, '5000', '6100', false, false, true,
   '§8.1 gives the 5000 band to revenue and cost of sales to the 6000 band.', 100),
  ('purchase_price_variance', 'Purchase price variance', 'expense', null, '9100', '6200', false, false, true,
   '§8.1 lists purchase price variance inside the cost of sales band.', 110),
  ('material_usage_variance', 'Material usage variance', 'expense', null, '9200', '6300', false, false, true,
   '§8.1 lists usage variance inside the cost of sales band.', 120),
  ('labour_efficiency_variance', 'Labour efficiency variance', 'expense', null, '9300', '6400', false, false, true,
   '§8.1 lists yield variance inside the cost of sales band.', 130),
  ('freight_variance', 'Freight variance', 'expense', null, '6500', '6500', false, false, false,
   '§8.1 lists freight variance inside cost of sales, and nothing created one.', 140),
  ('operating_expenses', 'Operating expenses', 'expense', null, '7100', '7100', false, false, false,
   '§8.1 gives the 7000 band to operating expenses, dimension-analysed, and nothing used it.', 150),
  -- The parallel commitment ledger. Same codes under both charts, because
  -- §8.1 describes the statutory chart and these post to COMMIT.
  ('purchase_commitment', 'Purchase commitments', 'statistical', null, '8100', '8100', false, false, true,
   'The parallel commitment ledger, which posts to COMMIT rather than GL, so §8.1''s statutory bands are not about it.', 160),
  ('sales_commitment', 'Sales commitments', 'statistical', null, '8200', '8200', false, false, true,
   'The parallel commitment ledger, which posts to COMMIT rather than GL, so §8.1''s statutory bands are not about it.', 170),
  ('commitment_offset', 'Commitment offset', 'statistical', null, '8900', '8900', false, false, true,
   'The parallel commitment ledger, which posts to COMMIT rather than GL, so §8.1''s statutory bands are not about it.', 180),
  ('suspense', 'Suspense', 'asset', null, '9000', '9000', true, true, false,
   '§13 clause 7 asks to close a period with suspense empty, and until this no chart the product shipped had a suspense account at all.', 190),
  ('clearing', 'Clearing', 'asset', null, '9900', '9900', true, false, false,
   '§8.1 puts clearing beside suspense in the 9000 band.', 200)
on conflict (purpose) do update set
  name = excluded.name, account_type = excluded.account_type,
  control_kind = excluded.control_kind, default_code = excluded.default_code,
  statutory_code = excluded.statutory_code,
  reconciliation_required = excluded.reconciliation_required,
  close_blocking = excluded.close_blocking,
  installer_creates = excluded.installer_creates,
  note = excluded.note, seq = excluded.seq;

create or replace function erp.chart_account_code(p_purpose text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_row erp_ref.chart_account_purpose%rowtype;
begin
  select * into v_row from erp_ref.chart_account_purpose where purpose = p_purpose;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_ACCOUNT_PURPOSE: %', p_purpose using errcode = '23503';
  end if;
  return case
    when erp.capability_on(erp.require_tenant_id(), 'statutory_chart_8_1', current_date)
      then v_row.statutory_code
    else v_row.default_code
  end;
end;
$$;

comment on function erp.chart_account_code is
  'The code an account wears in THIS organisation''s chart, for a purpose. '
  'Called by the module installers while they build a posting rule, so the '
  'rule they write names the chart the organisation actually chose. Posting '
  'itself is unchanged: erp.post_document_finance() still resolves a line to '
  'an account by the literal code the rule carries.';

-- -----------------------------------------------------------------------------
-- The two functions the flags and the report needed, dumped and patched
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION erp.upsert_account(p_entity_code text, p_code text, p_name text, p_account_type erp.account_type, p_control_kind erp.control_account_kind DEFAULT NULL::erp.control_account_kind, p_group_code text DEFAULT NULL::text, p_is_postable boolean DEFAULT true, p_requires_dimensions text[] DEFAULT '{}'::text[], p_currency character DEFAULT NULL::bpchar, p_parent_code text DEFAULT NULL::text, p_reconciliation_required boolean DEFAULT false, p_close_blocking boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid; v_parent uuid; v_id uuid;
begin
  select id into v_entity from erp.entity
   where tenant_id = v_tenant and code = p_entity_code;
  if v_entity is null then
    raise exception 'ERPWARE_UNKNOWN_ENTITY: %', p_entity_code using errcode = '23503';
  end if;
  if p_parent_code is not null then
    select id into v_parent from erp.account
     where tenant_id = v_tenant and entity_id = v_entity and code = p_parent_code;
    if v_parent is null then
      raise exception 'ERPWARE_UNKNOWN_ACCOUNT: parent % is not in %''s chart',
        p_parent_code, p_entity_code using errcode = '23503';
    end if;
  end if;

  insert into erp.account
    (tenant_id, entity_id, code, name, account_type, parent_account_id,
     group_code, control_kind, is_postable, requires_dimensions, currency,
     reconciliation_required, close_blocking)
  values (v_tenant, v_entity, p_code, p_name, p_account_type, v_parent,
          p_group_code, p_control_kind, p_is_postable, p_requires_dimensions,
          coalesce(p_currency, (select e.base_currency from erp.entity e where e.id = v_entity)),
          p_reconciliation_required, p_close_blocking)
  on conflict (tenant_id, entity_id, code) do update set
    name = excluded.name, account_type = excluded.account_type,
    parent_account_id = excluded.parent_account_id,
    group_code = excluded.group_code, control_kind = excluded.control_kind,
    is_postable = excluded.is_postable,
    requires_dimensions = excluded.requires_dimensions,
    -- Added with §9.1's suspense job in 20260904100000 and unreachable from a
    -- pack until now: a GRNI account whose whole point is that it blocks a
    -- close could be shipped without the fact that it does.
    reconciliation_required = excluded.reconciliation_required,
    close_blocking = excluded.close_blocking,
    status = 'active', updated_at = now()
  returning id into v_id;
  return v_id;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.apply_change_set_item(p_item_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant  uuid := erp.require_tenant_id();
  i         erp.change_set_item%rowtype;
  p         jsonb;
  v_entity  uuid;
  v_site    uuid;
  v_from    date;
  v_obj     uuid;
  v_ver     uuid;
  v_vnum    integer;
  r         record;
  v_state   uuid;
begin
  select * into i from erp.change_set_item where tenant_id = v_tenant and id = p_item_id;
  p := i.payload;

  -- Codes to local ids. A change set built elsewhere knows nothing of our keys.
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.code = (p ->> 'entity');
  select s.id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.code = (p ->> 'site');
  v_from := coalesce(i.effective_from, (p ->> 'effective_from')::date, current_date);

  if (p ? 'entity') and (p ->> 'entity') is not null and v_entity is null then
    raise exception 'ERPWARE_PROMOTION_UNKNOWN_ENTITY: this environment has no entity %',
      p ->> 'entity' using errcode = '23503';
  end if;

  case i.object_kind

    when 'config' then
      if i.operation = 'remove' then
        update erp.config_object co set status = 'inactive', updated_at = now()
         where co.tenant_id = v_tenant
           and co.config_type_code = (p ->> 'config_type')
           and co.code is not distinct from (p ->> 'code')
           and co.entity_id is not distinct from v_entity
           and co.site_id is not distinct from v_site;
      else
        perform erp.set_config_value(
          p ->> 'config_type', p -> 'value', p ->> 'code', v_from,
          v_entity, v_site, 'promoted');
      end if;

    when 'terminology' then
      if i.operation = 'remove' then
        update erp.resource_override ro set status = 'inactive', updated_at = now()
         where ro.tenant_id = v_tenant and ro.key = (p ->> 'key')
           and ro.locale = (p ->> 'locale') and ro.entity_id is not distinct from v_entity;
      else
        insert into erp.resource_override (tenant_id, key, locale, value, entity_id)
        values (v_tenant, p ->> 'key', p ->> 'locale', p ->> 'value', v_entity)
        on conflict (tenant_id, key, locale,
                     coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid))
          do update set value = excluded.value, status = 'active', updated_at = now();
      end if;

    when 'legislation_binding' then
      if i.operation = 'remove' then
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack');
      else
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack') and b.status = 'active';
        insert into erp.entity_legislation_binding (
          tenant_id, entity_id, pack_code, pack_version, effective_from, effective_to)
        values (v_tenant, v_entity, p ->> 'pack', (p ->> 'pack_version')::integer,
                v_from, (p ->> 'effective_to')::date);
      end if;

    when 'event_subscription' then
      if i.operation = 'remove' then
        update erp.event_subscription es set status = 'inactive', updated_at = now()
         where es.tenant_id = v_tenant and es.consumer_code = (p ->> 'consumer')
           and es.event_pattern = (p ->> 'pattern');
      else
        insert into erp.event_subscription (
          tenant_id, consumer_code, event_pattern, module_code, max_attempts)
        values (v_tenant, p ->> 'consumer', p ->> 'pattern', p ->> 'module',
                coalesce((p ->> 'max_attempts')::smallint, 8))
        on conflict (tenant_id, consumer_code, event_pattern) do update
          set module_code = excluded.module_code,
              max_attempts = excluded.max_attempts,
              status = 'active', updated_at = now();
      end if;

    when 'role' then
      if i.operation = 'remove' then
        update erp.role r set status = 'inactive', updated_at = now()
         where r.tenant_id = v_tenant and r.code = (p ->> 'code');
      else
        insert into erp.role (tenant_id, code, name, name_key, from_template)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'name_key', p ->> 'from_template')
        on conflict (tenant_id, code) do update
          set name = excluded.name, name_key = excluded.name_key,
              status = 'active', updated_at = now()
        returning id into v_obj;

        -- The grant set is replaced wholesale: a promoted role is the role the
        -- change set describes, not a merge with whatever was here before.
        delete from erp.role_permission rp
         where rp.tenant_id = v_tenant and rp.role_id = v_obj;

        insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
        select v_tenant, v_obj, e.value ->> 'permission',
               coalesce((select array_agg(dc #>> '{}')
                           from jsonb_array_elements(e.value -> 'data_classes') dc),
                        '{}'::text[])
          from jsonb_array_elements(coalesce(p -> 'permissions', '[]'::jsonb)) e;
      end if;

    when 'rule_set' then
      if i.operation = 'remove' then
        update erp.rule_set rs set status = 'inactive', updated_at = now()
         where rs.tenant_id = v_tenant
           and rs.decision_point_code = (p ->> 'decision_point')
           and rs.code = (p ->> 'code');
      else
        insert into erp.rule_set (tenant_id, decision_point_code, code, name, entity_id, site_id)
        values (v_tenant, p ->> 'decision_point', p ->> 'code', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, decision_point_code, code) do update
          set name = excluded.name, status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.rule_set_version v
         where v.tenant_id = v_tenant and v.rule_set_id = v_obj;

        insert into erp.rule_set_version (
          tenant_id, rule_set_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.rule (
          tenant_id, rule_set_version_id, seq, code, name, condition, outcome,
          stop_on_match, is_active)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', e.value -> 'condition', e.value -> 'outcome',
               coalesce((e.value ->> 'stop_on_match')::boolean, true),
               coalesce((e.value ->> 'is_active')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'rules', '[]'::jsonb)) e;

        -- Activation runs the linter, so a promotion cannot introduce a rule
        -- that can never match.
        perform erp.activate_rule_set_version(v_ver, v_from);
      end if;

    when 'state_machine' then
      if i.operation = 'remove' then
        update erp.state_machine sm set status = 'inactive', updated_at = now()
         where sm.tenant_id = v_tenant and sm.code = (p ->> 'code');
      else
        insert into erp.state_machine (tenant_id, code, object_type, name, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'object_type', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, code) do update
          set object_type = excluded.object_type, name = excluded.name,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.state_machine_version v
         where v.tenant_id = v_tenant and v.state_machine_id = v_obj;

        insert into erp.state_machine_version (
          tenant_id, state_machine_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.state (
          tenant_id, state_machine_version_id, code, name, is_initial, is_terminal,
          is_committed, sort_order, on_enter, on_exit)
        select v_tenant, v_ver, e.value ->> 'code', e.value ->> 'name',
               coalesce((e.value ->> 'is_initial')::boolean, false),
               coalesce((e.value ->> 'is_terminal')::boolean, false),
               coalesce((e.value ->> 'is_committed')::boolean, false),
               coalesce((e.value ->> 'sort_order')::integer, 100),
               coalesce(e.value -> 'on_enter', '[]'::jsonb),
               coalesce(e.value -> 'on_exit', '[]'::jsonb)
          from jsonb_array_elements(coalesce(p -> 'states', '[]'::jsonb)) e;

        -- Transitions come second because they reference states by code.
        for r in select e.value as tr
                   from jsonb_array_elements(coalesce(p -> 'transitions', '[]'::jsonb)) e
        loop
          insert into erp.transition (
            tenant_id, state_machine_version_id, code, name, from_state_id, to_state_id,
            guard, effects, required_permission, is_automatic, sort_order)
          select v_tenant, v_ver, r.tr ->> 'code', r.tr ->> 'name',
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'from'),
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'to'),
                 coalesce(r.tr -> 'guard', 'true'::jsonb),
                 coalesce(r.tr -> 'effects', '[]'::jsonb),
                 r.tr ->> 'required_permission',
                 coalesce((r.tr ->> 'is_automatic')::boolean, false),
                 coalesce((r.tr ->> 'sort_order')::integer, 100);
        end loop;

        -- Activation runs the graph validation, so a promotion cannot
        -- introduce a state a document could enter and never leave.
        perform erp.activate_state_machine_version(v_ver, v_from);
      end if;

    when 'approval_chain' then
      if i.operation = 'remove' then
        update erp.approval_chain ac set status = 'inactive', updated_at = now()
         where ac.tenant_id = v_tenant and ac.code = (p ->> 'code');
      else
        insert into erp.approval_chain (
          tenant_id, code, name, object_type, applies_when, priority, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'object_type',
                coalesce(p -> 'applies_when', 'true'::jsonb),
                coalesce((p ->> 'priority')::integer, 100), v_entity, v_site)
        on conflict (tenant_id, code) do update
          set name = excluded.name, object_type = excluded.object_type,
              applies_when = excluded.applies_when, priority = excluded.priority,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.approval_chain_version v
         where v.tenant_id = v_tenant and v.approval_chain_id = v_obj;

        insert into erp.approval_chain_version (
          tenant_id, approval_chain_id, version, status, effective_from,
          material_fields, value_field, tolerance_pct, tolerance_absolute, note)
        values (
          v_tenant, v_obj, v_vnum, 'draft', v_from,
          coalesce((select array_agg(f #>> '{}')
                      from jsonb_array_elements(coalesce(p -> 'material_fields', '[]'::jsonb)) f),
                   '{}'::text[]),
          p ->> 'value_field',
          (p ->> 'tolerance_pct')::numeric,
          (p ->> 'tolerance_absolute')::numeric,
          'promoted')
        returning id into v_ver;

        insert into erp.approval_step (
          tenant_id, approval_chain_version_id, seq, code, name, approver_kind,
          role_id, app_user_id, min_approvals, condition, escalate_after, allow_delegation)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', (e.value ->> 'approver_kind')::erp.approver_kind,
               (select ro.id from erp.role ro
                 where ro.tenant_id = v_tenant and ro.code = e.value ->> 'role'),
               (select u.id from erp.app_user u
                 where u.tenant_id = v_tenant and u.email = e.value ->> 'user'),
               coalesce((e.value ->> 'min_approvals')::smallint, 1),
               coalesce(e.value -> 'condition', 'true'::jsonb),
               (e.value ->> 'escalate_after')::interval,
               coalesce((e.value ->> 'allow_delegation')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'steps', '[]'::jsonb)) e;

        -- Activation refuses a chain with no steps, so a promotion cannot
        -- install one that approves everything unchecked.
        perform erp.activate_approval_chain_version(v_ver, v_from);
      end if;

    -- Spec 5.7: "declarative posting rules from operational events". Declarative
    -- means configuration, and configuration in this product is promoted rather
    -- than edited — otherwise the rule that decides which account a receipt
    -- lands in would be the one thing in finance nobody had to get approved.
    --
    -- Rules are versioned in place: a new version supersedes the last rather
    -- than replacing it, because a journal line records the rule version that
    -- produced it and that reference must stay resolvable for ever.
    when 'posting_rule' then
      if i.operation = 'remove' then
        update erp.posting_rule pr set status = 'withdrawn', updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code')
           and pr.status = 'active';
      else
        select coalesce(max(pr.version), 0) + 1 into v_vnum
          from erp.posting_rule pr
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code');

        -- Supersede the version in force, and only move its end date if it
        -- actually started earlier.
        --
        -- This is the defect 0019 found in every other activation path,
        -- arriving here through a door that did not exist when 0019 was
        -- written. Setting effective_to = v_from on a version that started on
        -- the same day produces an empty window, which posting_rule_range
        -- refuses. Invisible in normal use, because changes are made on later
        -- days than the versions they replace — and immediate the moment two
        -- change sets touch the same rule in one sitting, which is exactly
        -- what installing finance and then inventory does.
        update erp.posting_rule pr
           set status = 'superseded',
               effective_to = case when pr.effective_from < v_from then v_from
                                   else pr.effective_to end,
               updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code')
           and pr.status = 'active';

        insert into erp.posting_rule (
          tenant_id, code, name, entity_id, ledger_id, event_type, condition,
          posting_lines, version, status, effective_from, legislation_pack_code)
        values (
          v_tenant, p ->> 'code', p ->> 'name', v_entity,
          (select l.id from erp.ledger l
            where l.tenant_id = v_tenant and l.code = (p ->> 'ledger')
              and (v_entity is null or l.entity_id = v_entity)
            order by l.code limit 1),
          p ->> 'event_type',
          coalesce(p -> 'condition', 'true'::jsonb),
          coalesce(p -> 'posting_lines', '[]'::jsonb),
          v_vnum, 'active', v_from, p ->> 'legislation_pack');

        -- A rule that does not balance would raise a journal that cannot post,
        -- and it would do so at month end rather than here. Refusing at
        -- promotion is the whole point of promoting it.
        perform erp.assert_posting_rule_balances(p ->> 'code', v_vnum);
      end if;

    -- Spec 5.1: what a good record looks like is a tenant's opinion, and an
    -- opinion that decides whether a record is fit to trade on belongs in the
    -- same promotion pipeline as everything else. Replaced rather than
    -- versioned: nothing records "the quality rule version that scored this",
    -- so a superseded version would be a row nobody could ever read.
    when 'data_quality_rule' then
      if i.operation = 'remove' then
        update erp.data_quality_rule q set status = 'inactive', updated_at = now()
         where q.tenant_id = v_tenant
           and q.object_type = (p ->> 'object_type')
           and q.code = (p ->> 'code');
      else
        insert into erp.data_quality_rule (
          tenant_id, object_type, code, name, kind, condition, weight,
          severity, message, entity_id, status)
        values (v_tenant, p ->> 'object_type', p ->> 'code', p ->> 'name',
                coalesce(p ->> 'kind', 'completeness'),
                coalesce(p -> 'condition', 'true'::jsonb),
                coalesce((p ->> 'weight')::integer, 1),
                coalesce(p ->> 'severity', 'warning'),
                coalesce(p ->> 'message', p ->> 'name'),
                v_entity, 'active')
        on conflict (tenant_id, object_type, code) do update
          set name = excluded.name, kind = excluded.kind,
              condition = excluded.condition, weight = excluded.weight,
              severity = excluded.severity, message = excluded.message,
              status = 'active', updated_at = now();
      end if;

    -- Which fields cannot change without somebody agreeing. Promoted for the
    -- same reason the approval chains themselves are: a control that its own
    -- subject can switch off is not a control.
    when 'field_approval_rule' then
      if i.operation = 'remove' then
        update erp.field_approval_rule f set status = 'inactive', updated_at = now()
         where f.tenant_id = v_tenant
           and f.object_type = (p ->> 'object_type')
           and f.field_name = (p ->> 'field_name');
      else
        if not exists (select 1 from erp_meta.maintainable_field m
                        where m.object_type = (p ->> 'object_type')
                          and m.column_name = (p ->> 'field_name')) then
          raise exception
            'ERPWARE_PROMOTION_UNGOVERNABLE_FIELD: %.% is not a maintainable field',
            p ->> 'object_type', p ->> 'field_name'
            using errcode = '23503',
                  hint = 'A rule guarding a field nothing can change is a control '
                         'that will never fire.';
        end if;

        insert into erp.field_approval_rule (
          tenant_id, object_type, field_name, condition, approval_chain_code,
          sensitivity, reason_required, status)
        values (v_tenant, p ->> 'object_type', p ->> 'field_name',
                coalesce(p -> 'condition', 'true'::jsonb),
                p ->> 'approval_chain',
                coalesce((p ->> 'sensitivity')::integer, 100),
                coalesce((p ->> 'reason_required')::boolean, false),
                'active')
        on conflict (tenant_id, object_type, field_name) do update
          set condition = excluded.condition,
              approval_chain_code = excluded.approval_chain_code,
              sensitivity = excluded.sensitivity,
              reason_required = excluded.reason_required,
              status = 'active', updated_at = now();
      end if;

    -- Which stock is valued how. Promoted rather than written, because
    -- switching an item from FIFO to average changes what every future issue
    -- costs and therefore what the accounts say.
    when 'costing_policy' then
      if i.operation = 'remove' then
        update erp.costing_policy c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.costing_policy (
          tenant_id, code, name, method, item_class, entity_id, site_id,
          variance_account_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                (p ->> 'method')::erp.costing_method,
                p ->> 'item_class', v_entity, v_site,
                p ->> 'variance_account', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, method = excluded.method,
              item_class = excluded.item_class,
              variance_account_code = excluded.variance_account_code,
              status = 'active', updated_at = now();
      end if;

    -- What gets counted, how often, and how wrong a count may be before
    -- somebody has to look at it. A tolerance a warehouse can set for itself
    -- is not a tolerance.
    when 'count_programme' then
      if i.operation = 'remove' then
        update erp.count_programme c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.count_programme (
          tenant_id, code, name, site_id, kind, selector,
          tolerance_absolute, tolerance_pct, approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', v_site,
                (p ->> 'kind')::erp.count_programme_kind,
                coalesce(p -> 'selector', 'true'::jsonb),
                coalesce((p ->> 'tolerance_absolute')::numeric, 0),
                coalesce((p ->> 'tolerance_pct')::numeric, 0),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, kind = excluded.kind,
              selector = excluded.selector,
              tolerance_absolute = excluded.tolerance_absolute,
              tolerance_pct = excluded.tolerance_pct,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- How much more than was ordered may arrive, and what to do with it.
    when 'receipt_tolerance' then
      if i.operation = 'remove' then
        update erp.receipt_tolerance t set status = 'inactive', updated_at = now()
         where t.tenant_id = v_tenant and t.code = (p ->> 'code');
      else
        insert into erp.receipt_tolerance (
          tenant_id, code, name, item_class, over_pct, under_pct, over_action, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce((p ->> 'over_pct')::numeric, 0),
                coalesce((p ->> 'under_pct')::numeric, 100),
                coalesce(p ->> 'over_action', 'accept'), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              over_pct = excluded.over_pct, under_pct = excluded.under_pct,
              over_action = excluded.over_action,
              status = 'active', updated_at = now();
      end if;

    -- How far an invoice may differ from the receipt before somebody looks.
    -- The most contested numbers in a finance function, and therefore exactly
    -- the ones that should be promoted rather than typed.
    when 'match_tolerance' then
      if i.operation = 'remove' then
        update erp.match_tolerance t set status = 'inactive', updated_at = now()
         where t.tenant_id = v_tenant and t.code = (p ->> 'code');
      else
        insert into erp.match_tolerance (
          tenant_id, code, name, item_class, quantity_pct, price_pct,
          price_absolute_minor, approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce((p ->> 'quantity_pct')::numeric, 0),
                coalesce((p ->> 'price_pct')::numeric, 0),
                coalesce((p ->> 'price_absolute_minor')::bigint, 0),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              quantity_pct = excluded.quantity_pct, price_pct = excluded.price_pct,
              price_absolute_minor = excluded.price_absolute_minor,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- What may be spent, and what happens when it would be exceeded.
    when 'budget' then
      if i.operation = 'remove' then
        update erp.budget b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.code = (p ->> 'code');
      else
        insert into erp.budget (
          tenant_id, entity_id, code, name, fiscal_year, selector, amount_minor,
          currency, on_exceed, approval_chain_code, status)
        select v_tenant,
               coalesce(v_entity, (select e.id from erp.entity e
                                    where e.tenant_id = v_tenant and e.status = 'active'
                                    order by e.code limit 1)),
               p ->> 'code', p ->> 'name',
               coalesce((p ->> 'fiscal_year')::integer,
                        extract(year from v_from)::integer),
               coalesce(p -> 'selector', 'true'::jsonb),
               (p ->> 'amount_minor')::bigint,
               coalesce(p ->> 'currency',
                        (select e.base_currency from erp.entity e
                          where e.tenant_id = v_tenant limit 1)),
               coalesce(p ->> 'on_exceed', 'block'),
               p ->> 'approval_chain', 'active'
        on conflict (tenant_id, code, fiscal_year) do update
          set name = excluded.name, selector = excluded.selector,
              amount_minor = excluded.amount_minor,
              on_exceed = excluded.on_exceed,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- How much risk of running out is acceptable, how far ahead the plan is
    -- fixed, and how orders are sized. Every one of those is a number a
    -- business argues about for a fortnight and then nobody revisits, which is
    -- precisely what promotion is for.
    when 'planning_policy' then
      if i.operation = 'remove' then
        update erp.planning_policy pp set status = 'inactive', updated_at = now()
         where pp.tenant_id = v_tenant and pp.code = (p ->> 'code');
      else
        insert into erp.planning_policy (
          tenant_id, code, name, reorder_method, safety_stock_basis,
          service_level_pct, lot_sizing, fixed_lot_size, rounding_multiple,
          demand_time_fence_days, planning_time_fence_days, sourcing_rules, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce((p ->> 'reorder_method')::erp.reorder_method, 'reorder_point'),
                coalesce(p ->> 'safety_stock_basis', 'statistical'),
                coalesce((p ->> 'service_level_pct')::numeric, 95),
                coalesce(p ->> 'lot_sizing', 'lot_for_lot'),
                (p ->> 'fixed_lot_size')::numeric,
                (p ->> 'rounding_multiple')::numeric,
                coalesce((p ->> 'demand_time_fence_days')::integer, 0),
                coalesce((p ->> 'planning_time_fence_days')::integer, 0),
                coalesce(p -> 'sourcing_rules', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, reorder_method = excluded.reorder_method,
              safety_stock_basis = excluded.safety_stock_basis,
              service_level_pct = excluded.service_level_pct,
              lot_sizing = excluded.lot_sizing,
              fixed_lot_size = excluded.fixed_lot_size,
              rounding_multiple = excluded.rounding_multiple,
              demand_time_fence_days = excluded.demand_time_fence_days,
              planning_time_fence_days = excluded.planning_time_fence_days,
              sourcing_rules = excluded.sourcing_rules,
              status = 'active', updated_at = now();
      end if;

    -- The margin floor, and whether anybody may go under it. Promoted because
    -- it is the number a sales force will ask to have moved.
    when 'pricing_policy' then
      if i.operation = 'remove' then
        update erp.pricing_policy pp set status = 'inactive', updated_at = now()
         where pp.tenant_id = v_tenant and pp.code = (p ->> 'code');
      else
        insert into erp.pricing_policy (
          tenant_id, code, name, entity_id, min_margin_pct, allow_below_cost,
          approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', v_entity,
                coalesce((p ->> 'min_margin_pct')::numeric, 0),
                coalesce((p ->> 'allow_below_cost')::boolean, false),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name,
              min_margin_pct = excluded.min_margin_pct,
              allow_below_cost = excluded.allow_below_cost,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- What is inspected and how much of it. Promoted because a sampling rule
    -- is exactly the sort of thing that gets loosened quietly under delivery
    -- pressure and should have to be argued for.
    when 'inspection_plan' then
      if i.operation = 'remove' then
        update erp.inspection_plan ip set status = 'inactive', updated_at = now()
         where ip.tenant_id = v_tenant and ip.code = (p ->> 'code');
      else
        insert into erp.inspection_plan (
          tenant_id, code, name, item_class, trigger_point, sampling_rule,
          characteristics, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce(p ->> 'trigger_point', 'receipt'),
                coalesce(p -> 'sampling_rule', '{}'::jsonb),
                coalesce(p -> 'characteristics', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              trigger_point = excluded.trigger_point,
              sampling_rule = excluded.sampling_rule,
              characteristics = excluded.characteristics,
              status = 'active', updated_at = now();
      end if;

    -- Which carriers may be used and what they charge. A tariff that anybody
    -- can edit is one where the cheapest carrier is whoever last touched it.
    when 'carrier' then
      if i.operation = 'remove' then
        update erp.carrier c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.carrier (tenant_id, code, name, services, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce(p -> 'services', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, services = excluded.services,
              status = 'active', updated_at = now();
      end if;

    -- What has to be true before a period closes. Promoted, because a close
    -- checklist that the people being checked can shorten is not a control.
    when 'close_task' then
      if i.operation = 'remove' then
        update erp.close_task_template ct set status = 'inactive', updated_at = now()
         where ct.tenant_id = v_tenant and ct.code = (p ->> 'code');
      else
        insert into erp.close_task_template (
          tenant_id, code, name, seq, depends_on, blocking_check,
          owner_role_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce((p ->> 'seq')::integer, 100),
                coalesce((select array_agg(d #>> '{}')
                            from jsonb_array_elements(coalesce(p -> 'depends_on',
                                                               '[]'::jsonb)) d),
                         '{}'::text[]),
                p ->> 'blocking_check', p ->> 'owner_role', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, seq = excluded.seq,
              depends_on = excluded.depends_on,
              blocking_check = excluded.blocking_check,
              owner_role_code = excluded.owner_role_code,
              status = 'active', updated_at = now();
      end if;

    -- When a customer is chased and when they stop being sold to. The second
    -- is a commercial decision that finance owns and sales will ask to move,
    -- which is exactly what promotion is for.
    when 'dunning_policy' then
      if i.operation = 'remove' then
        update erp.dunning_policy dp set status = 'inactive', updated_at = now()
         where dp.tenant_id = v_tenant and dp.code = (p ->> 'code');
      else
        insert into erp.dunning_policy (tenant_id, code, name, levels, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce(p -> 'levels', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, levels = excluded.levels,
              status = 'active', updated_at = now();
      end if;


    -- ── Addendum B configuration surfaces ───────────────────────────────────
    --
    -- Each resolves the codes a change set carries to this environment's own
    -- ids, then calls the erp.* mechanism extracted in 20260901120000. None of
    -- them authorises: promotion authorised once, at the change set, which is
    -- what lets a promote-only principal promote somebody else's work.

    when 'department' then
      if i.operation = 'remove' then
        update erp.department d set status = 'inactive', updated_at = now()
         where d.tenant_id = v_tenant and d.code = upper(p ->> 'code');
      else
        perform erp.upsert_department(
          p ->> 'code', p ->> 'name',
          (select u.id from erp.app_user u
            where u.tenant_id = v_tenant and lower(u.email) = lower(p ->> 'manager_email')),
          (select d2.id from erp.department d2
            where d2.tenant_id = v_tenant and d2.code = upper(p ->> 'parent')),
          p ->> 'default_cost_centre', v_entity, v_from);
      end if;

    when 'approval_band' then
      declare
        v_dept uuid;
      begin
        select d.id into v_dept from erp.department d
         where d.tenant_id = v_tenant and d.code = upper(p ->> 'department');
        if v_dept is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_DEPARTMENT: this environment has no department %',
            p ->> 'department' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.approval_band ab set status = 'inactive', updated_at = now()
           where ab.tenant_id = v_tenant and ab.department_id = v_dept
             and ab.object_type = (p ->> 'object_type')
             and ab.seq = (p ->> 'seq')::integer;
        else
          perform erp.upsert_approval_band(
            v_dept, p ->> 'object_type', (p ->> 'seq')::integer,
            (p ->> 'upper_bound_minor')::bigint,
            coalesce((p ->> 'lower_bound_minor')::bigint, 0),
            (select u.id from erp.app_user u
              where u.tenant_id = v_tenant and lower(u.email) = lower(p ->> 'approver_email')),
            p ->> 'approver_role',
            coalesce((p ->> 'use_line_manager')::boolean, false),
            coalesce(p ->> 'currency', 'GBP'),
            coalesce((p ->> 'is_parallel')::boolean, false),
            coalesce((p ->> 'rerun_lower_bands')::boolean, true),
            (p ->> 'escalate_after_hours')::integer,
            coalesce(p ->> 'vacancy', 'hold_and_raise'),
            (p ->> 'tolerance_pct')::numeric);
        end if;
      end;

    when 'posting_class' then
      if i.operation = 'remove' then
        update erp.posting_class pc set status = 'inactive', updated_at = now()
         where pc.tenant_id = v_tenant
           and pc.kind = (p ->> 'kind')::erp.posting_class_kind
           and pc.code = (p ->> 'code');
      else
        perform erp.upsert_posting_class(
          p ->> 'kind', p ->> 'code', p ->> 'name', p ->> 'description', v_from);
      end if;

    -- The one that decides which ledger account a posting hits. §5 refuses a
    -- default-to-suspense, so an unresolved account is an exception rather
    -- than a quiet landing place — which is exactly why this belongs behind
    -- promotion rather than a direct write on a live organisation.
    when 'account_determination' then
      declare
        v_account uuid;
      begin
        select a.id into v_account from erp.account a
         where a.tenant_id = v_tenant and a.code = (p ->> 'account');
        if v_account is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_ACCOUNT: this environment has no account %',
            p ->> 'account' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.account_determination ad set status = 'inactive', updated_at = now()
           where ad.tenant_id = v_tenant
             and ad.transaction_type = (p ->> 'transaction_type')
             and ad.account_id = v_account;
        else
          perform erp.upsert_account_determination(
            p ->> 'transaction_type', v_account,
            (select pc.id from erp.posting_class pc
              where pc.tenant_id = v_tenant and pc.kind = 'item'
                and pc.code = (p ->> 'item_class')),
            (select pc.id from erp.posting_class pc
              where pc.tenant_id = v_tenant and pc.kind = 'party'
                and pc.code = (p ->> 'party_class')),
            v_site, v_entity,
            (select l.id from erp.ledger l
              where l.tenant_id = v_tenant and l.code = (p ->> 'ledger')),
            p ->> 'reason_code', p ->> 'legislation_pack',
            p -> 'dimensions', p ->> 'note', v_from);
        end if;
      end;

    when 'classification_axis' then
      if i.operation = 'remove' then
        update erp.classification_axis ca set status = 'inactive', updated_at = now()
         where ca.tenant_id = v_tenant and ca.code = upper(p ->> 'code');
      else
        perform erp.upsert_classification_axis(
          p ->> 'code', p ->> 'name',
          coalesce((p ->> 'is_mandatory')::boolean, false),
          p ->> 'item_classes',
          coalesce((p ->> 'seq')::integer, 100),
          p ->> 'name_key');
      end if;

    when 'classification_value' then
      declare
        v_axis uuid;
      begin
        select ca.id into v_axis from erp.classification_axis ca
         where ca.tenant_id = v_tenant and ca.code = upper(p ->> 'axis');
        if v_axis is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_AXIS: this environment has no classification axis %',
            p ->> 'axis' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.classification_value cv set status = 'inactive', updated_at = now()
           where cv.tenant_id = v_tenant and cv.axis_id = v_axis
             and cv.code = upper(p ->> 'code');
        else
          perform erp.upsert_classification_value(
            v_axis, p ->> 'code', p ->> 'name', p ->> 'abbreviation',
            (select cv2.id from erp.classification_value cv2
              where cv2.tenant_id = v_tenant and cv2.axis_id = v_axis
                and cv2.code = upper(p ->> 'parent')),
            p ->> 'name_key');
        end if;
      end;

    when 'code_template' then
      if i.operation = 'remove' then
        update erp.code_template ct set status = 'inactive', updated_at = now()
         where ct.tenant_id = v_tenant and ct.code = upper(p ->> 'code');
      else
        perform erp.upsert_code_template(
          p ->> 'code', p ->> 'name',
          coalesce(p -> 'segments', '[]'::jsonb),
          p ->> 'item_classes',
          coalesce(p ->> 'casing', 'upper'),
          v_entity);
      end if;

    when 'release_area' then
      declare
        v_ra_site uuid;
      begin
        v_ra_site := coalesce(v_site,
          (select s2.id from erp.site s2
            where s2.tenant_id = v_tenant and s2.status = 'active'
            order by s2.code limit 1));
        if v_ra_site is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_SITE: a release area needs a site and this '
            'environment has none' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.release_area ra set status = 'inactive', updated_at = now()
           where ra.tenant_id = v_tenant and ra.site_id = v_ra_site
             and ra.code = upper(p ->> 'code');
        else
          perform erp.upsert_release_area(
            v_ra_site, p ->> 'code', p ->> 'name',
            (select l.id from erp.location l
              where l.tenant_id = v_tenant and l.site_id = v_ra_site
                and l.code = (p ->> 'location')),
            coalesce(p ->> 'replenishment_mode', 'pull'),
            p ->> 'channel', p ->> 'order_type', p ->> 'item_classes',
            (p ->> 'min_quantity')::numeric,
            (p ->> 'max_quantity')::numeric,
            coalesce((p ->> 'ageing_hours')::integer, 72),
            coalesce((p ->> 'gate_printing')::boolean, true));
        end if;
      end;

    -- approver_assignment carries a named approver rather than a band, and
    -- both subject and approver are people. Promoting a rule that names a
    -- person only works where that person exists in the target, so the
    -- subject and approver are carried by email and resolved here.
    when 'approver_assignment' then
      declare
        v_subject  uuid;
        v_approver uuid;
      begin
        select u.id into v_approver from erp.app_user u
         where u.tenant_id = v_tenant and lower(u.email) = lower(p ->> 'approver_email');
        if v_approver is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_APPROVER: this environment has no principal %',
            p ->> 'approver_email' using errcode = '23503';
        end if;

        v_subject := case (p ->> 'subject_kind')
          when 'department' then (select d.id from erp.department d
                                   where d.tenant_id = v_tenant
                                     and d.code = upper(p ->> 'subject'))
          else (select u.id from erp.app_user u
                 where u.tenant_id = v_tenant and lower(u.email) = lower(p ->> 'subject'))
        end;
        if v_subject is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_SUBJECT: this environment has no % %',
            p ->> 'subject_kind', p ->> 'subject' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.approver_assignment aa set status = 'inactive', updated_at = now()
           where aa.tenant_id = v_tenant and aa.subject_id = v_subject
             and aa.object_type = (p ->> 'object_type')
             and aa.approver_user_id = v_approver;
        else
          perform erp.assign_named_approver(
            p ->> 'subject_kind', v_subject, p ->> 'object_type', v_approver,
            coalesce(p ->> 'mode', 'prepends'),
            (p ->> 'lower_bound_minor')::bigint,
            (p ->> 'upper_bound_minor')::bigint,
            p ->> 'reason', v_from, (p ->> 'valid_to')::date);
        end if;
      end;

    -- ── Starter Content Packs: eleven kinds a pack installs ─────────────────

    -- §2.1: "switched through a change set like any other configuration".
    when 'capability' then
      if i.operation = 'remove' then
        perform erp.set_capability(p ->> 'code', false,
          coalesce(p ->> 'reason', 'Removed by change set'), v_from);
      else
        perform erp.set_capability(p ->> 'code',
          coalesce((p ->> 'enabled')::boolean, true),
          coalesce(p ->> 'reason', 'Promoted by change set'), v_from);
      end if;

    when 'uom' then
      if i.operation = 'remove' then
        update erp.uom u set status = 'inactive', updated_at = now()
         where u.tenant_id = v_tenant and u.code = upper(p ->> 'code');
      else
        perform erp.upsert_uom(
          p ->> 'code', p ->> 'name',
          coalesce(p ->> 'uom_class', 'quantity')::erp.uom_class,
          coalesce((p ->> 'decimals')::smallint, 0::smallint),
          coalesce((p ->> 'is_base')::boolean, false));
        if p ? 'converts_to' then
          perform erp.upsert_uom_conversion(
            p ->> 'code', p ->> 'converts_to', (p ->> 'factor')::numeric,
            p ->> 'item');
        end if;
      end if;

    when 'reason_code' then
      if i.operation = 'remove' then
        perform erp.set_reason_code_status(p ->> 'category', p ->> 'code', false);
      else
        perform erp.upsert_reason_code(
          p ->> 'category', p ->> 'code', p ->> 'name',
          coalesce((p ->> 'requires_note')::boolean, false),
          coalesce((p ->> 'requires_approval')::boolean, false),
          coalesce((p ->> 'seq')::integer, 100));
      end if;

    when 'calendar' then
      if i.operation = 'remove' then
        update erp.calendar c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = upper(p ->> 'code');
      else
        perform erp.upsert_calendar(
          p ->> 'code', p ->> 'name', coalesce(p ->> 'timezone', 'UTC'),
          coalesce((select array_agg(x::boolean order by ord)
                      from jsonb_array_elements_text(p -> 'working_days')
                             with ordinality y(x, ord)),
                   '{t,t,t,t,t,f,f}'::boolean[]));
        -- Exceptions travel with the calendar rather than as their own kind: a
        -- public holiday without the calendar it falls in is not a thing.
        if p ? 'exceptions' then
          for r in select value from jsonb_array_elements(p -> 'exceptions') loop
            perform erp.upsert_calendar_exception(
              p ->> 'code', (r.value ->> 'date')::date,
              coalesce((r.value ->> 'is_working')::boolean, false),
              r.value ->> 'description');
          end loop;
        end if;
      end if;

    when 'sod_rule' then
      if i.operation = 'remove' then
        update erp.sod_rule sr set status = 'inactive', updated_at = now()
         where sr.tenant_id = v_tenant and sr.code = upper(p ->> 'code');
      else
        perform erp.upsert_sod_rule(
          p ->> 'code', p ->> 'name',
          string_to_array(p ->> 'permissions_a', ','),
          string_to_array(p ->> 'permissions_b', ','),
          coalesce(p ->> 'severity', 'material')::erp.sod_severity,
          p ->> 'description', p ->> 'mitigation');
      end if;

    when 'numbering_rule' then
      if i.operation = 'remove' then
        update erp.numbering_rule nr set status = 'inactive', updated_at = now()
         where nr.tenant_id = v_tenant and nr.code = (p ->> 'code');
      else
        perform erp.upsert_numbering_rule(
          p ->> 'code', p ->> 'prefix', p ->> 'entity', p ->> 'site',
          p ->> 'suffix',
          coalesce((p ->> 'pad_to')::smallint, 6::smallint),
          coalesce(p ->> 'reset_period', 'yearly')::erp.number_reset,
          coalesce((p ->> 'next_value')::bigint, 1));
      end if;

    when 'document_type' then
      -- The other half of the spine. A document type is configuration by every
      -- test the product applies to the word: it names a lifecycle, a chain, a
      -- sequence, a movement type and a posting rule, and changing any of them
      -- changes what happens when somebody presses a button. It was outside
      -- promotion only because the sequence it needs was.
      if i.operation = 'remove' then
        update erp.document_type dt set status = 'inactive', updated_at = now()
         where dt.tenant_id = v_tenant and dt.code = (p ->> 'code');
      else
        perform erp.upsert_document_type(
          p ->> 'code', p ->> 'base_type', p ->> 'name',
          p ->> 'numbering_rule', p ->> 'entity', p ->> 'site',
          p ->> 'state_machine', p ->> 'approval_chain',
          p ->> 'stock_movement_type', p ->> 'posting_rule',
          p ->> 'create_permission');
      end if;

    when 'notification_template' then
      if i.operation = 'remove' then
        delete from erp.notification_template nt
         where nt.tenant_id = v_tenant and nt.code = (p ->> 'code');
      else
        perform erp.upsert_notification_template(
          p ->> 'code',
          coalesce(p ->> 'channel_kind', 'in_app')::erp.notification_channel_kind,
          p ->> 'body_key', p ->> 'subject_key');
      end if;

    when 'kpi' then
      if i.operation = 'remove' then
        delete from erp.kpi k where k.tenant_id = v_tenant and k.code = (p ->> 'code');
      else
        perform erp.upsert_kpi(
          p ->> 'code', p ->> 'name', p ->> 'unit',
          coalesce((p ->> 'higher_is_better')::boolean, true),
          p ->> 'description', p ->> 'module_code',
          coalesce((p ->> 'currency_scoped')::boolean, false),
          p ->> 'name_key');
      end if;

    when 'report' then
      if i.operation = 'remove' then
        update erp.report rp set status = 'inactive', updated_at = now()
         where rp.tenant_id = v_tenant and rp.code = (p ->> 'code');
      else
        perform erp.upsert_report(
          p ->> 'code', p ->> 'name', p ->> 'description', p ->> 'module_code',
          coalesce(string_to_array(nullif(p ->> 'kpi_codes', ''), ','), '{}'),
          coalesce(string_to_array(nullif(p ->> 'audience_role_codes', ''), ','), '{}'),
          p ->> 'name_key');
      end if;

    when 'account' then
      if i.operation = 'remove' then
        update erp.account a set status = 'inactive', updated_at = now()
         where a.tenant_id = v_tenant and a.entity_id = v_entity
           and a.code = (p ->> 'code');
      else
        -- A tenant-neutral pack cannot know an organisation's company codes,
        -- so an item that names none lands on the primary company — the same
        -- fallback the budget and release_area branches already use for the
        -- same reason. Refusing instead would make the account kind
        -- unreachable from a pack, which is the one place it is most wanted.
        perform erp.upsert_account(
          coalesce(nullif(p ->> 'entity', ''),
                   (select e.code from erp.entity e
                     where e.tenant_id = v_tenant and e.status = 'active'
                     order by e.code limit 1)),
          p ->> 'code', p ->> 'name',
          (p ->> 'account_type')::erp.account_type,
          nullif(p ->> 'control_kind', '')::erp.control_account_kind,
          p ->> 'group_code',
          coalesce((p ->> 'is_postable')::boolean, true),
          coalesce(string_to_array(nullif(p ->> 'requires_dimensions', ''), ','), '{}'),
          nullif(p ->> 'currency', '')::character(3),
          nullif(p ->> 'parent', ''),
          coalesce((p ->> 'reconciliation_required')::boolean, false),
          coalesce((p ->> 'close_blocking')::boolean, false));
      end if;

    -- §9.1's scheduled jobs. erp.upsert_job() exists and erp.run_due_jobs()
    -- runs them; what was missing was a way for a pack to carry one.
    when 'job' then
      if i.operation = 'remove' then
        update erp.job j set is_enabled = false, updated_at = now()
         where j.tenant_id = v_tenant and j.code = (p ->> 'code');
      else
        perform erp.upsert_job(
          p ->> 'code', p ->> 'name', p ->> 'handler_code',
          coalesce(p ->> 'schedule_kind', 'interval'),
          (p ->> 'interval_seconds')::integer,
          (p ->> 'at_time')::time,
          p ->> 'days_of_week',
          (p ->> 'day_of_month')::integer,
          coalesce(p ->> 'timezone', 'UTC'),
          coalesce(p -> 'parameters', '{}'::jsonb),
          (p ->> 'timeout_seconds')::integer,
          (p ->> 'max_silence_seconds')::integer,
          -- §9.1: "Shipped disabled, enabled per tenant." A pack that switched
          -- on eleven jobs on an organisation's first day would be a pack that
          -- starts doing work nobody asked for.
          coalesce((p ->> 'is_enabled')::boolean, false));
      end if;

    when 'location' then
      declare
        v_loc_site uuid;
      begin
        v_loc_site := coalesce(v_site,
          (select s2.id from erp.site s2
            where s2.tenant_id = v_tenant and s2.status = 'active'
            order by s2.code limit 1));
        if v_loc_site is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_SITE: a location needs a site and this environment has none'
            using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.location l set status = 'inactive', updated_at = now()
           where l.tenant_id = v_tenant and l.site_id = v_loc_site
             and l.code = upper(p ->> 'code');
        else
          perform erp.upsert_location(
            (select s3.code from erp.site s3 where s3.id = v_loc_site),
            p ->> 'code', p ->> 'name', p ->> 'location_type',
            nullif(p ->> 'parent', ''), nullif(p ->> 'count_class', ''),
            (p ->> 'is_pickable')::boolean,
            case when p ? 'storage_conditions' then p -> 'storage_conditions' end);
        end if;
      end;

    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule, data_quality_rule, field_approval_rule, costing_policy, count_programme, receipt_tolerance, match_tolerance, budget, planning_policy, pricing_policy, inspection_plan, carrier, close_task, dunning_policy, department, approval_band, approver_assignment, posting_class, account_determination, classification_axis, classification_value, code_template, release_area, capability, uom, reason_code, calendar, sod_rule, numbering_rule, notification_template, kpi, report, account, location, job';
  end case;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.chart_of_accounts_divergence_report(p_tenant_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(tenant_code text, finding text, reference text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with band(lo, hi, meaning) as (values
    (1000, 1999, 'non-current assets'),
    (2000, 2999, 'current assets'),
    (3000, 3999, 'current liabilities, including GRNI and tax control'),
    (4000, 4999, 'non-current liabilities and equity'),
    (5000, 5999, 'revenue by category'),
    (6000, 6999, 'cost of sales, including purchase price, usage, yield and freight variances'),
    (7000, 7999, 'operating expenses, dimension-analysed'),
    (8000, 8999, 'other income and expense'),
    (9000, 9999, 'suspense and clearing')
  ),
  -- What §8.1's range says an account of this type should be, and what the
  -- account actually is. A mismatch is not automatically wrong — an
  -- organisation may have its own chart — but it is what §8.1 would change.
  -- lo is the first band the type may occupy; see the upper bound below for
  -- why "the band" is not always one thousand wide.
  expected(account_type, lo) as (values
    ('asset',     2000),
    ('liability', 3000),
    ('equity',    4000),
    ('income',    5000),
    ('expense',   6000)
  )
  select t.code,
         format('%s %s is %s, and §8.1 puts %s in the %s range (%s)',
                a.code, a.name, a.account_type, a.account_type, e.lo, b.meaning),
         a.code
    from erp.account a
    join erp.tenant t on t.id = a.tenant_id
    join expected e on e.account_type = a.account_type::text
    join band b on b.lo = e.lo
   where (p_tenant_id is null or a.tenant_id = p_tenant_id)
     and a.status = 'active'
     -- Statistical accounts are the parallel commitment ledger, which posts to
     -- COMMIT rather than GL. §8.1 describes the statutory chart, so its
     -- ranges were never about them; the report was flagging them against
     -- bands that do not apply.
     and a.account_type <> 'statistical'
     and a.code ~ '^[0-9]{4}$'
     and (a.code::integer < e.lo
          -- §8.1 gives EXPENSES three bands, not one: 6000 cost of sales,
          -- 7000 operating expenses dimension-analysed, 8000 other income and
          -- expense. A single type-to-band map called an operating expense at
          -- 7100 a divergence from §8.1 while §8.1 was the thing that put it
          -- there. The upper bound follows the type rather than assuming every
          -- type owns exactly one thousand.
          or a.code::integer > (case when e.account_type = 'expense'
                                     then 8999 else e.lo + 999 end))
     -- 9000 is a PURPOSE band — "suspense and clearing" — and a suspense
     -- account has to be some type, every one of which §8.1 assigns a
     -- different band. Deriving the expectation from the type alone made a
     -- conformant chart fail the report meant to measure conformance.
     and a.code::integer < 9000
     -- And the 8000 band is "other income and expense", which is likewise a
     -- purpose rather than a type.
     and not (a.code::integer between 8000 and 8999)
   order by t.code, a.code
$function$;

-- -----------------------------------------------------------------------------
-- The pack
--
-- Accounts and the posting rules that name them, in one pack, because the two
-- are only correct together. The rules that post to the COMMIT ledger are NOT
-- here: erp.post_document() resolves them against the same chart, but §8.1
-- describes the statutory chart and the commitment accounts are a parallel
-- ledger, so their codes are left where the installers put them.
-- -----------------------------------------------------------------------------

insert into erp_ref.content_pack
  (code, name, description, kind, version, requires_capability, provenance, seq)
values ('chart_8_1', 'Statutory chart (§8.1)',
        'A chart of accounts numbered by §8.1''s bands, and the posting rules '
        'that reach it. For an organisation choosing its chart rather than '
        'renumbering one it has already posted against.',
        'profile', '1.0', 'statutory_chart_8_1',
        'Starter Content Packs §8.1, shipped as an alternative rather than a '
        'renumbering — see erp_meta.policy_decision chart_of_accounts_ranges.',
        70)
on conflict (code) do update set
  name = excluded.name, description = excluded.description,
  kind = excluded.kind, requires_capability = excluded.requires_capability,
  seq = excluded.seq;

-- The chart, derived from erp_ref.chart_account_purpose rather than listed
-- again. Control kinds carry across unchanged — a receivables control account
-- is one whatever number it wears — and the two flags §9.1's suspense job
-- reads reach a pack for the first time here.
insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'chart_8_1', 'account', cp.statutory_code,
       jsonb_strip_nulls(jsonb_build_object(
         'code', cp.statutory_code, 'name', cp.name,
         'account_type', cp.account_type::text,
         'control_kind', cp.control_kind::text, 'is_postable', true,
         'reconciliation_required', cp.reconciliation_required,
         'close_blocking', cp.close_blocking)),
       cp.note, cp.seq
  from erp_ref.chart_account_purpose cp
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- Anything left over from a hand-written earlier shape of this pack. Harmless
-- on a build from empty; the register is the only source of these items now.
delete from erp_ref.pack_item pi
 where pi.pack_code = 'chart_8_1'
   and pi.object_kind in ('account', 'account_determination')
   and not exists (select 1 from erp_ref.chart_account_purpose cp
                    where (pi.object_kind = 'account' and cp.statutory_code = pi.object_key)
                       or (pi.object_kind = 'account_determination' and cp.purpose = pi.object_key));

-- The rules that reach it are NOT here, and that is the whole point of the
-- register.
--
-- The first shape of this pack shipped four rewritten posting rules beside the
-- chart. Two refusals from the product killed that idea, both of them right:
-- erp.promote_change_set() refuses a change set introducing a rule that names
-- an account the company does not have, and it refuses one naming no ledger —
-- and the ledger is created by erp.configure_finance(), which runs after. So
-- the pack would have had to land between two halves of the finance
-- installer.
--
-- With erp.chart_account_code() the installers write §8.1's codes themselves
-- while they build their rules, so there is nothing left for the pack to
-- rewrite. The pack ships the chart; the rules follow it.

-- The determination matrix.
--
-- erp.determine_account() has existed since B7 and answers "which account does
-- this transaction reach, and why", and on a configured organisation there
-- were zero rows for it to answer from — because posting rules name accounts
-- by literal code and nothing consults determination at posting time. That
-- mechanism is unchanged and the decision to keep both and watch them stands.
-- What this adds is the missing half of the explain layer: with these rows,
-- erp.determine_account() can say which account a purpose reaches, which is
-- what the /finance/account-determination screen asks it.
insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, provenance, seq)
select 'chart_8_1', 'account_determination', cp.purpose,
       -- No ledger: the pack lands before erp.configure_finance() creates
       -- one, and a determination by purpose is the same answer in either.
       jsonb_build_object('transaction_type', cp.purpose,
                          'account', cp.statutory_code,
                          'note', cp.name),
       cp.note, 300 + cp.seq
  from erp_ref.chart_account_purpose cp
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, provenance = excluded.provenance, seq = excluded.seq;

-- -----------------------------------------------------------------------------
-- The three installers that seed a chart
--
-- Dumped and patched at one condition each. Everything else is the definition
-- that was already running.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION erp.configure_finance(p_fiscal_year integer DEFAULT NULL::integer, p_currency character DEFAULT NULL::bpchar)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_ccy    char(3);
  v_year   integer := coalesce(p_fiscal_year, extract(year from current_date)::integer);
  v_gl     uuid;
  v_commit uuid;
  v_cs     uuid;
  m        integer;
begin
  perform erp.authorise('finance.configure', null, null, null, 'ledger', null);

  select e.id, coalesce(p_currency, e.base_currency, 'GBP')
    into v_entity, v_ccy
    from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active'
   order by e.code limit 1;

  if v_entity is null then
    raise exception 'ERPWARE_NO_ENTITY: configure an entity before finance'
      using errcode = '23503';
  end if;

  -- The statutory ledger, and a parallel management ledger for commitments.
  -- Spec 5.7 opens with "chart of accounts and parallel ledgers"; a product
  -- with one ledger has not implemented that sentence, it has implemented the
  -- half of it that needs no thought.
  insert into erp.ledger (tenant_id, entity_id, code, name, ledger_kind, currency, is_primary, status)
  values (v_tenant, v_entity, 'GL', 'General ledger', 'statutory', v_ccy, true, 'active')
  on conflict (tenant_id, entity_id, code) do update set status = 'active'
  returning id into v_gl;

  insert into erp.ledger (tenant_id, entity_id, code, name, ledger_kind, currency, is_primary, status)
  values (v_tenant, v_entity, 'COMMIT', 'Commitments', 'management', v_ccy, false, 'active')
  on conflict (tenant_id, entity_id, code) do update set status = 'active'
  returning id into v_commit;

  -- Twelve calendar months, open. A period that does not exist refuses the
  -- posting rather than inventing one, so the calendar is not optional.
  foreach m in array array[1,2,3,4,5,6,7,8,9,10,11,12] loop
    insert into erp.fiscal_period (
      tenant_id, ledger_id, code, fiscal_year, period_number,
      starts_on, ends_on, status)
    select v_tenant, l.id, format('%s-%s', v_year, lpad(m::text, 2, '0')),
           v_year, m::smallint,
           make_date(v_year, m, 1),
           (make_date(v_year, m, 1) + interval '1 month - 1 day')::date,
           'open'
      from (values (v_gl), (v_commit)) as l(id)
    on conflict (tenant_id, ledger_id, fiscal_year, period_number) do nothing;
  end loop;

  -- The chart. Small, but every account here is reached by a rule below —
  -- an account nothing posts to is the same dead configuration one table over.
  -- §8.1's chart is an alternative, and an alternative is only one if the
  -- installers stop insisting on theirs. With statutory_chart_8_1 on, the
  -- chart_8_1 pack ships the accounts and the posting rules that reach them;
  -- seeding these as well would leave an organisation holding two charts, one
  -- of which nothing posts to.
  if not erp.capability_on(v_tenant, 'statutory_chart_8_1', current_date) then
    insert into erp.account (
      tenant_id, entity_id, code, name, account_type, control_kind,
      is_postable, currency, status)
    select v_tenant, v_entity, a.code, a.name, a.kind::erp.account_type,
           a.control::erp.control_account_kind, true, v_ccy, 'active'
      from (values
        ('1000', 'Bank',                        'asset',       'bank'),
        ('1100', 'Trade receivables',           'asset',       'receivable'),
        ('1200', 'Inventory',                   'asset',       'inventory'),
        ('2000', 'Trade payables',              'liability',   'payable'),
        ('2100', 'Goods received not invoiced', 'liability',   null),
        ('2200', 'Tax payable',                 'liability',   'tax'),
        ('4000', 'Revenue',                     'income',      null),
        ('5000', 'Cost of goods sold',          'expense',     null),
        ('8100', 'Purchase commitments',        'statistical', null),
        ('8200', 'Sales commitments',           'statistical', null),
        ('8900', 'Commitment offset',           'statistical', null)
      ) as a(code, name, kind, control)
    on conflict (tenant_id, entity_id, code) do update
      set name = excluded.name, status = 'active';
  end if;

  v_cs := erp.install_module_config(
    'finance-posting', 'Finance posting rules',
    'Which accounts each operational document reaches, and on which side. '
    'Promoted rather than written, because this is the configuration that '
    'decides what the accounts say.',
    jsonb_build_array(
      -- Receipt: the goods are ours and we owe for them, but no invoice has
      -- arrived — which is what a goods-received-not-invoiced account is for.
      jsonb_build_object('kind','posting_rule','key','goods_receipt','payload',
        jsonb_build_object(
          'code','goods_receipt','name','Goods receipt','ledger','GL',
          'event_type','document.goods_receipt.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('inventory'),'side','debit','rate',1,
                               'description','Inventory received'),
            jsonb_build_object('account', erp.chart_account_code('goods_received_not_invoiced'),'side','credit','rate',1,
                               'description','Goods received not invoiced')))),

      -- Delivery: stock leaves and becomes cost. Revenue is not recognised
      -- here — that is the invoice's job, and conflating them is how a
      -- delivery note ends up on a profit and loss account.
      jsonb_build_object('kind','posting_rule','key','delivery','payload',
        jsonb_build_object(
          'code','delivery','name','Delivery','ledger','GL',
          'event_type','document.delivery.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('cost_of_sales'),'side','debit','rate',1,
                               'description','Cost of goods sold'),
            jsonb_build_object('account', erp.chart_account_code('inventory'),'side','credit','rate',1,
                               'description','Inventory despatched')))),

      -- Invoice: the receivable and the revenue. One rule, two lines, and the
      -- receivable is a control account — so posting it writes a subledger
      -- item without anybody configuring that, which is what keeps
      -- erp.assert_subledger_reconciles() true by construction.
      jsonb_build_object('kind','posting_rule','key','sales_invoice','payload',
        jsonb_build_object(
          'code','sales_invoice','name','Sales invoice','ledger','GL',
          'event_type','document.invoice.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('trade_receivable'),'side','debit','rate',1,
                               'description','Trade receivable'),
            jsonb_build_object('account', erp.chart_account_code('revenue'),'side','credit','rate',1,
                               'description','Revenue')))),

      -- Commitments, in the parallel ledger. Product content declares
      -- affects_finance on both order types; this is what honouring that
      -- claim looks like rather than editing the claim.
      jsonb_build_object('kind','posting_rule','key','purchase_commitment','payload',
        jsonb_build_object(
          'code','purchase_commitment','name','Purchase commitment','ledger','COMMIT',
          'event_type','document.purchase_order.confirmed',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('purchase_commitment'),'side','debit','rate',1,
                               'description','Committed to a supplier'),
            jsonb_build_object('account', erp.chart_account_code('commitment_offset'),'side','credit','rate',1,
                               'description','Commitment offset')))),

      jsonb_build_object('kind','posting_rule','key','sales_commitment','payload',
        jsonb_build_object(
          'code','sales_commitment','name','Sales commitment','ledger','COMMIT',
          'event_type','document.sales_order.confirmed',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('commitment_offset'),'side','debit','rate',1,
                               'description','Commitment offset'),
            jsonb_build_object('account', erp.chart_account_code('sales_commitment'),'side','credit','rate',1,
                               'description','Committed to a customer'))))));

  return v_cs;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.configure_inventory(p_method erp.costing_method DEFAULT 'average'::erp.costing_method, p_approver_role text DEFAULT 'administrator'::text, p_tolerance_absolute numeric DEFAULT 2, p_tolerance_pct numeric DEFAULT 1)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  if not exists (select 1 from erp.ledger l
                  where l.tenant_id = v_tenant and l.status = 'active') then
    raise exception
      'ERPWARE_NO_LEDGER: this tenant has no chart of accounts, and inventory '
      'valuation reconciles to one'
      using errcode = '23503',
            hint = 'Run erp.configure_finance() first.';
  end if;

  -- The variance account standard costing needs. Added here rather than in the
  -- finance chart because it only exists if somebody chose standard costing,
  -- and an account nothing posts to is dead configuration in the ledger too.
  -- §8.1's chart is an alternative, and an alternative is only one if the
  -- installers stop insisting on theirs. With statutory_chart_8_1 on, the
  -- chart_8_1 pack ships the accounts and the posting rules that reach them;
  -- seeding these as well would leave an organisation holding two charts, one
  -- of which nothing posts to.
  if not erp.capability_on(v_tenant, 'statutory_chart_8_1', current_date) then
    insert into erp.account (
      tenant_id, entity_id, code, name, account_type, is_postable, currency, status)
    select v_tenant, e.id, '9100', 'Purchase price variance', 'expense', true,
           e.base_currency, 'active'
      from erp.entity e where e.tenant_id = v_tenant and e.status = 'active'
    on conflict (tenant_id, entity_id, code) do update set status = 'active';
  end if;

  v_cs := erp.install_module_config(
    'inventory-operations', 'Inventory operations',
    'How stock is valued, how it is counted, and what the ledger is told about '
    'both.',
    jsonb_build_array(
      jsonb_build_object('kind','costing_policy','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default costing','method', p_method::text,
          'variance_account','9100')),

      jsonb_build_object('kind','count_programme','key','cycle_a','payload',
        jsonb_build_object(
          'code','cycle_a','name','Cycle count — fast movers','kind','cycle',
          -- Every item with stock. A real tenant narrows this by class or by
          -- value band; the point of the selector is that narrowing it needs no
          -- code.
          'selector','true',
          'tolerance_absolute', p_tolerance_absolute,
          'tolerance_pct', p_tolerance_pct,
          'approval_chain','count_variance')),

      jsonb_build_object('kind','approval_chain','key','count_variance','payload',
        jsonb_build_object(
          'code','count_variance','name','Count variance approval',
          'object_type','count_task',
          'applies_when','true'::jsonb,
          'priority',100,
          'material_fields', jsonb_build_array('variance','counted'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','stock_controller','name','Stock controller',
              'approver_kind','role','role',p_approver_role,'min_approvals',1)))),

      -- The posting rules, restated on the right basis. A receipt debits
      -- inventory at cost and credits the supplier at what was invoiced; under
      -- standard costing those differ and the balancing line is the variance.
      jsonb_build_object('kind','posting_rule','key','goods_receipt','payload',
        jsonb_build_object(
          'code','goods_receipt','name','Goods receipt','ledger','GL',
          'event_type','document.goods_receipt.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('inventory'),'side','debit','basis','stock_cost','rate',1,
                               'description','Inventory received, at cost'),
            jsonb_build_object('account', erp.chart_account_code('goods_received_not_invoiced'),'side','credit','basis','document_value','rate',1,
                               'description','Goods received not invoiced, at invoice value'),
            jsonb_build_object('account', erp.chart_account_code('purchase_price_variance'),'side','debit','balancing',true,
                               'description','Purchase price variance')))),

      -- And the one this migration exists to correct.
      jsonb_build_object('kind','posting_rule','key','delivery','payload',
        jsonb_build_object(
          'code','delivery','name','Delivery','ledger','GL',
          'event_type','document.delivery.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('cost_of_sales'),'side','debit','basis','stock_cost','rate',1,
                               'description','Cost of goods sold'),
            jsonb_build_object('account', erp.chart_account_code('inventory'),'side','credit','basis','stock_cost','rate',1,
                               'description','Inventory despatched, at cost'))))));

  return v_cs;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.configure_production(p_issue_method erp.issue_method DEFAULT 'backflush'::erp.issue_method)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_entity_code text;
  v_cs     uuid;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'works_order', null);

  select e.id, e.code into v_entity, v_entity_code from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  -- The variance accounts. Split, because the split is the point of measuring.
  -- §8.1's chart is an alternative, and an alternative is only one if the
  -- installers stop insisting on theirs. With statutory_chart_8_1 on, the
  -- chart_8_1 pack ships the accounts and the posting rules that reach them;
  -- seeding these as well would leave an organisation holding two charts, one
  -- of which nothing posts to.
  if not erp.capability_on(v_tenant, 'statutory_chart_8_1', current_date) then
    insert into erp.account (
      tenant_id, entity_id, code, name, account_type, is_postable, currency, status)
    select v_tenant, v_entity, a.code, a.name, 'expense'::erp.account_type, true,
           e.base_currency, 'active'
      from (values
        ('5100', 'Work in progress'),
        ('9200', 'Material usage variance'),
        ('9300', 'Labour efficiency variance')
      ) as a(code, name)
      join erp.entity e on e.id = v_entity
    on conflict (tenant_id, entity_id, code) do update set status = 'active';
  end if;

  v_cs := erp.install_module_config(
    'production', 'Production',
    'How works orders consume material and how the difference between what '
    'they should have cost and what they did is accounted for.',
    jsonb_build_array(
      -- The sequence goes through the change set like everything else the
      -- module installs. It used to be written directly, above, which on a
      -- live organisation meant half the module landed before anybody had
      -- approved the other half.
      jsonb_build_object('kind','numbering_rule','key','works_order','payload',
        jsonb_build_object(
          'code','works_order', 'entity', v_entity_code, 'prefix','WO-',
          'pad_to', 6, 'reset_period','yearly', 'next_value', 1)),
      jsonb_build_object('kind','config','key','production.issue_method','payload',
        jsonb_build_object(
          'config_type','production.issue_method',
          'value', to_jsonb(p_issue_method::text)))));

  return v_cs;
end;
$function$;


-- -----------------------------------------------------------------------------
-- What choosing it would change
--
-- The migration path made readable, account by account. This is the thing an
-- organisation with an existing chart actually needs in order to decide, and
-- the decision to renumber stays theirs.
-- -----------------------------------------------------------------------------

drop function if exists erp.chart_alternative_report(uuid);

create or replace function erp.chart_alternative_report(p_tenant_id uuid default null)
returns table (purpose text, installer_code text, statutory_code text,
               name text, present boolean, note text)
language sql
stable
set search_path = ''
as $$
  select cp.purpose,
         case when cp.installer_creates then cp.default_code end,
         cp.statutory_code,
         cp.name,
         exists (select 1 from erp.account a
                  where a.tenant_id = coalesce(p_tenant_id, erp.current_tenant_id())
                    and a.status = 'active' and a.code = cp.statutory_code),
         cp.note
    from erp_ref.chart_account_purpose cp
   order by cp.seq
$$;

comment on function erp.chart_alternative_report is
  'Account by account, what choosing §8.1''s chart would change and which of '
  'its accounts this organisation already has. The commitment accounts are '
  'absent on purpose: they post to the parallel COMMIT ledger and §8.1 '
  'describes the statutory chart.';

create or replace function public.erp_chart_alternative()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'purpose', r.purpose, 'installer_code', r.installer_code,
           'statutory_code', r.statutory_code, 'name', r.name,
           'present', r.present, 'note', r.note) order by r.statutory_code), '[]'::jsonb)
    from erp.chart_alternative_report() r;
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq)
values ('chart_alternative', 'Statutory chart, if chosen', 'report', 'tenant',
        'chart_alternative_report', '', null, '',
        'What choosing §8.1''s chart would change, account by account, and '
        'which of its accounts this organisation already has.', false, 32)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  function_name = excluded.function_name, kind = excluded.kind, scope = excluded.scope;

-- The product surface is for signed-in principals. erp.assert_public_api_safe()
-- caught this one before it shipped, which is what it is for.
do $$
begin
  execute 'revoke all on function public.erp_chart_alternative() from public, anon';
  execute 'grant execute on function public.erp_chart_alternative() to authenticated';
end $$;

select erp.assert_public_api_safe();

-- -----------------------------------------------------------------------------
-- The suite
--
-- An alternative chart is only an alternative if something can post against
-- it. So the suite builds an organisation that chose it, installs the modules,
-- applies the pack, and then reads the product's own checks: no dead
-- configuration, every posting rule reaching an account that exists, and the
-- §8.1 divergence report — the one that measures conformance — reporting none.
-- -----------------------------------------------------------------------------

create or replace function erp_test.chart_alternative_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  a1 uuid := gen_random_uuid();
  v_t uuid; res jsonb; v_cs uuid; n integer; v_ok boolean; v_msg text;
begin
  insert into auth.users (id, email) values (a1, 'chart@zzchart.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.onboard_tenant('Chart', 'zzchart');
  v_t := erp.require_tenant_id();

  -- The choice, made before there is a chart. Direct rather than through a
  -- change set because the organisation is inside its bootstrap window, which
  -- is the only moment this choice can be made.
  perform erp.set_capability('statutory_chart_8_1', true, 'chose §8.1''s chart');

  return query select 'the choice is a capability like every other choice',
    erp.capability_on(v_t, 'statutory_chart_8_1', current_date),
    'not a flag on erp.tenant and not a migration argument — it appears on the '
    'features screen beside the rest';

  -- ── The chart first, then the modules ───────────────────────────────────
  --
  -- Order matters and the product enforces it. erp.promote_change_set()
  -- refuses a change set that introduces a posting rule naming an account the
  -- company does not have — C1's determination-coverage gate — so installing a
  -- module before the chart it posts to is refused rather than discovered at a
  -- month end. That refusal is what found this ordering.

  res := erp.apply_content_pack('chart_8_1');
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);

  return query select 'the pack brings the whole chart',
    (select count(*) from erp.account a where a.tenant_id = v_t) = 20,
    format('%s accounts, including the four §8.1 names that nothing created — '
           'freight variance, equity, operating expenses and suspense',
      (select count(*) from erp.account a where a.tenant_id = v_t));

  return query select 'the chart it ships conforms to §8.1''s own ranges',
    (select count(*) from erp.chart_of_accounts_divergence_report(v_t)) = 0,
    format('%s divergences from the report that measures §8.1 conformance',
      (select count(*) from erp.chart_of_accounts_divergence_report(v_t)));

  perform erp.configure_finance();
  perform erp.configure_procurement();
  perform erp.configure_inventory();
  perform erp.configure_production();
  perform erp.configure_sales();
  perform erp.configure_procurement_controls();

  return query select 'the installers create no chart of their own',
    (select count(*) from erp.account a where a.tenant_id = v_t) = 20,
    format('still %s accounts after six installers, because the pack owns the '
           'chart and they defer to it',
      (select count(*) from erp.account a where a.tenant_id = v_t));

  return query select 'and their posting rules reach the chart that is actually there',
    (select count(*) from erp.dead_configuration_report()) = 0,
    'erp.chart_account_code() gives the installer the code for the chart in '
    'force while it builds the rule; posting still resolves a literal, '
    'unchanged';

  return query select 'so a purchase invoice clears GRNI at §8.1''s code',
    exists (
      select 1 from erp.posting_rule pr, lateral jsonb_array_elements(pr.posting_lines) l
       where pr.tenant_id = v_t and pr.code = 'purchase_invoice'
         and pr.status = 'active'
         and l ->> 'side' = 'debit' and l ->> 'account' = '3200'),
    'the same rule on the default chart debits 2100';

  -- ── The flags §9.1's job reads ──────────────────────────────────────────

  return query select 'GRNI, tax control and suspense block a close',
    (select count(*) from erp.account a
      where a.tenant_id = v_t and a.close_blocking) = 3
    and (select count(*) from erp.account a
          where a.tenant_id = v_t and a.reconciliation_required) = 4,
    format('%s close-blocking, %s needing reconciliation',
      (select count(*) from erp.account a where a.tenant_id = v_t and a.close_blocking),
      (select count(*) from erp.account a where a.tenant_id = v_t and a.reconciliation_required));

  return query select 'and §9.1''s suspense job now has a suspense account to report on',
    exists (select 1 from erp.account a
             where a.tenant_id = v_t and a.code = '9000' and a.close_blocking),
    '§13 clause 7 asks to close a period with suspense empty, and until this '
    'no chart the product shipped had one';

  -- ── The determination matrix ────────────────────────────────────────────

  select count(*) into n from erp.account_determination ad where ad.tenant_id = v_t;
  return query select 'erp.determine_account() has something to answer from',
    n = 20,
    format('%s determinations, one per purpose, where a configured '
           'organisation had none at all', n);

  -- ── Falsification: the guard on switching it back off ───────────────────

  return query select 'switching the chart off is guarded once anything has posted',
    exists (select 1 from erp_ref.capability_guard g
             where g.capability_code = 'statutory_chart_8_1'
               and g.table_name = 'journal_line'),
    'the postings would be left pointing at accounts the chart no longer '
    'explains, and the rules at accounts nobody can find';

  -- ── Clean up ────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_t);
  delete from erp.tenant where id = v_t;
  perform erp.end_tenant_purge();
  delete from auth.users where id = a1;

  return query select 'and the suite removes the organisation it built',
    not exists (select 1 from erp.account a where a.tenant_id = v_t),
    'the chart cascades with the tenant, as every tenant-scoped table does';
end $$;

create or replace function erp_test.assert_chart_alternative_suite()
returns text
language plpgsql
set search_path to ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- One on the choice, two on the pack, three on the installers deferring to
  -- it, two on the flags, one on determination, one on the guard, cleanup.
  c_expected constant integer := 11;
begin
  create temporary table if not exists zz_chart_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_chart_result;
  insert into zz_chart_result select * from erp_test.chart_alternative_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_pass, v_total, v_detail from zz_chart_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_SUITE_SHRANK: %/% cases ran, % expected',
      v_pass, v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_CHART_ALTERNATIVE_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('chart alternative: %s/%s', v_pass, v_total);
end $$;

-- The two remaining installers whose posting rules name an account by code.
-- Dumped and patched at those literals only.

CREATE OR REPLACE FUNCTION erp.configure_procurement_controls(p_approver_role text DEFAULT 'administrator'::text, p_over_receipt_pct numeric DEFAULT 5, p_price_variance_pct numeric DEFAULT 2, p_price_variance_minor bigint DEFAULT 100)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  v_cs := erp.install_module_config(
    'procurement-controls', 'Procurement controls',
    'What may be received against an order, what may be invoiced against a '
    'receipt, and who has to look when neither agrees.',
    jsonb_build_array(
      jsonb_build_object('kind','approval_chain','key','match_exception','payload',
        jsonb_build_object(
          'code','match_exception','name','Invoice match exception',
          'object_type','match_exception',
          'applies_when','true'::jsonb, 'priority',100,
          'material_fields', jsonb_build_array('quantity_variance','price_variance_minor'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','buyer','name','Buyer',
              'approver_kind','role','role',p_approver_role,'min_approvals',1)))),

      jsonb_build_object('kind','receipt_tolerance','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default receipt tolerance',
          'over_pct', p_over_receipt_pct,
          -- Under-delivery is not an error: the rest is still outstanding, and
          -- that is what the outstanding quantity is for.
          'under_pct', 100,
          'over_action','accept')),

      jsonb_build_object('kind','match_tolerance','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default match tolerance',
          'quantity_pct', 0,
          'price_pct', p_price_variance_pct,
          'price_absolute_minor', p_price_variance_minor,
          'approval_chain','match_exception')),

      -- The purchase invoice, which procurement has been missing since it was
      -- built. Without it there is no third document to match against and, more
      -- pointedly, nothing ever debits goods-received-not-invoiced: the finance
      -- bridge credits 2100 on every receipt and the balance grows for ever.
      jsonb_build_object('kind','state_machine','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice','object_type','document','name','Purchase invoice',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','registered','name','Registered','is_committed',true,'sort_order',20),
            jsonb_build_object('code','paid','name','Paid','is_terminal',true,'is_committed',true,'sort_order',30),
            jsonb_build_object('code','disputed','name','Disputed','sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','register','name','Register','from','draft','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','dispute','name','Dispute','from','registered','to','disputed','required_permission','procurement.match'),
            jsonb_build_object('code','resolve','name','Resolve','from','disputed','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','pay','name','Record payment','from','registered','to','paid','required_permission','finance.post'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.match')))),

      -- Registering the invoice is what clears GRNI: the receipt credited it,
      -- and this debits it and credits the supplier instead.
      jsonb_build_object('kind','posting_rule','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice','name','Purchase invoice','ledger','GL',
          'event_type','document.purchase_invoice.registered',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('goods_received_not_invoiced'),'side','debit','rate',1,
                               'description','Clearing goods received not invoiced'),
            jsonb_build_object('account', erp.chart_account_code('trade_payable'),'side','credit','rate',1,
                               'description','Trade payable')))),

      -- The spine, in the change set. This installer took its document type's
      -- entity from the sequence rather than resolving one itself;
      -- erp.upsert_document_type() keeps that by inheriting the rule's entity
      -- when the payload names none, so no entity is stated here either.
      jsonb_build_object('kind','numbering_rule','key','purchase_invoice','payload',
        jsonb_build_object('code','purchase_invoice',
          'entity', (select e.code from erp.entity e
                      where e.tenant_id = v_tenant and e.status = 'active'
                      order by e.code limit 1),
          'prefix','PINV-','pad_to',6,'reset_period','yearly','next_value',1)),
      -- Base invoice_reference carries sales.invoice, which is right for
      -- sales_invoice and wrong here: every transition on this lifecycle wants
      -- procurement.match, so raising one must too.
      jsonb_build_object('kind','document_type','key','purchase_invoice','payload',
        jsonb_build_object('code','purchase_invoice',
          'base_type','invoice_reference','name','Purchase invoice',
          'numbering_rule','purchase_invoice','state_machine','purchase_invoice',
          'posting_rule','purchase_invoice',
          'create_permission','procurement.match'))));

  return v_cs;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.configure_receivables(p_first_reminder_days integer DEFAULT 7, p_final_days integer DEFAULT 45, p_stop_days integer DEFAULT 90)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_cs uuid;
begin
  v_cs := erp.install_module_config(
    'receivables', 'Receivables',
    'When a customer is chased, how, and at what point they stop being sold to.',
    jsonb_build_array(
      -- Cash application is a posting, and B7 refuses a machine-generated
      -- journal line that cannot name the rule that produced it. That refusal
      -- is right: a line nobody can trace to a rule is a line nobody can
      -- explain. So the rule exists, and is promoted like every other.
      jsonb_build_object('kind','posting_rule','key','cash_application','payload',
        jsonb_build_object(
          'code','cash_application','name','Cash application','ledger','GL',
          'event_type','cash.applied',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('bank'),'side','debit','rate',1,
                               'description','Cash received'),
            jsonb_build_object('account', erp.chart_account_code('trade_receivable'),'side','credit','rate',1,
                               'description','Applied to the receivable')))),

      jsonb_build_object('kind','dunning_policy','key','standard','payload',
        jsonb_build_object(
          'code','standard','name','Standard dunning',
          'levels', jsonb_build_array(
            jsonb_build_object('code','reminder','after_days',p_first_reminder_days,
                               'action','statement and reminder','blocks_trading',false),
            jsonb_build_object('code','final','after_days',p_final_days,
                               'action','final demand','blocks_trading',false),
            jsonb_build_object('code','stop','after_days',p_stop_days,
                               'action','account stopped and passed to collection',
                               'blocks_trading',true))))));

  return v_cs;
end;
$function$;


-- ── The decision this closes ─────────────────────────────────────────────────

update erp_meta.policy_decision set
  title = '§8.1''s chart ships as an alternative, and renumbering an existing '
          'chart stays the organisation''s decision',
  decision =
    'Taken as an alternative, not a renumbering. An organisation choosing its '
    'chart before it has one can switch on statutory_chart_8_1 and install the '
    'chart_8_1 pack: twenty accounts in §8.1''s bands, including the four §8.1 '
    'names that nothing created — freight variance, equity, operating expenses '
    'and a suspense account §13 clause 7 asks to be empty at a close. An '
    'organisation that has already posted keeps the chart it has, and '
    'erp.chart_alternative_report() shows account by account what choosing the '
    'other one would change.',
  rationale =
    'The obstacle recorded was that posting rules reach accounts by literal '
    'code, so a renumbered chart would strand every rule. That is still true '
    'at posting time and is deliberately unchanged — the decision to keep both '
    'account-selection mechanisms and watch them stands. What changed is what '
    'the installer WRITES: erp.chart_account_code(purpose) reads '
    'erp_ref.chart_account_purpose and the capability, and the four installers '
    'that name an account by code now ask it while they build the rule. A '
    'build-time lookup, not a runtime selection. The correspondence between a '
    'purpose and its code under each chart is stated once in that register, '
    'and the pack, the report and the installers all read it rather than '
    'agreeing by hand.',
  evidence =
    'erp_test.chart_alternative_suite() builds an organisation that chose it, '
    'installs six modules over it, and finds twenty accounts, no dead '
    'configuration, no divergence from the report that measures §8.1 '
    'conformance, and a purchase invoice clearing GRNI at 3200 where the '
    'default chart uses 2100. The ordering was found by refusal rather than '
    'by design: erp.promote_change_set() rejects a change set introducing a '
    'posting rule that names an account the company lacks, and again one that '
    'names no ledger — so the pack ships the chart and the installers'' own '
    'rules follow it, which is fewer moving parts than the four rewritten '
    'rules the first attempt carried.',
  status = 'accepted', decided_at = now()
 where code = 'chart_of_accounts_ranges';

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_capabilities_sound();
select erp.assert_packs_installable();
select erp.assert_diagnostics_registered();
select erp.assert_public_api_safe();
select erp_test.assert_chart_alternative_suite();
