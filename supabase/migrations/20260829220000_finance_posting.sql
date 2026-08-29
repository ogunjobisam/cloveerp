-- =============================================================================
-- ERPWare — Part 5.7: making a posted document actually reach the ledger
--
-- The stock bridge fixed half of a problem. This is the other half, and it is
-- larger than it looked.
--
-- B7 built the whole finance structure: ledgers, fiscal calendars, a chart of
-- accounts with control accounts, analytical dimensions, posting rules,
-- journals with a deferred balance constraint, subledgers with a reconciliation
-- assertion. Every one of those tables is correct. Every one of them is also
-- empty in every tenant that has ever existed, because:
--
--   * nothing anywhere creates a ledger, an account or a fiscal period;
--   * erp.posting_rule is written by no code in this repository;
--   * erp.journal is inserted into by no code in this repository;
--   * erp_ref.document_type.affects_finance is declared on six base types and
--     read by nothing.
--
-- So finance was not "partly built". It was a set of structures with no way in
-- — which is the same class of defect as the inert goods receipt, one layer
-- down, and considerably better hidden, because a table that is empty because
-- nobody has posted yet looks exactly like a table that is empty because
-- posting is impossible.
--
-- Three things close it.
--
--   1. Posting rules become promotable configuration. Spec 5.7 calls them
--      "declarative posting rules from operational events"; declarative means
--      configuration, and configuration in this product goes through B6. A
--      rule deciding which account a receipt lands in is precisely the sort of
--      change that should not be a direct write.
--
--   2. erp.post_document() grows a finance half, symmetrical with the stock
--      half: the document type names a posting rule, the rule says which
--      accounts and which side, and the sign comes from the rule rather than
--      from the module. Procurement debits inventory and credits GRNI; sales
--      debits cost of sales and credits inventory; the code is identical.
--
--   3. Commitments are honoured rather than edited away. Product content
--      declares affects_finance on purchase_order and sales_order, which raise
--      no journal in the statutory ledger — an order is a commitment, not a
--      transaction. The temptation was to set those flags false so the new
--      assertion would pass. That would be editing the specification to fit
--      the implementation. Instead they post to a parallel management ledger,
--      which is commitment accounting, is a real practice, and exercises the
--      first bullet of spec 5.7 ("chart of accounts and parallel ledgers")
--      rather than quietly dropping it.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The link a document type needs
-- -----------------------------------------------------------------------------

alter table erp.document_type
  add column if not exists posting_rule_code text;

comment on column erp.document_type.posting_rule_code is
  'Which posting rule this type''s commit invokes. Product content says whether '
  'a type reaches the ledger at all; this says how. Required wherever the base '
  'type declares affects_finance — erp.assert_no_dead_configuration() fails '
  'the build otherwise.';

-- A withdrawn rule keeps its row. B7 already has the status for it, and the
-- reason it must never be deleted is that a journal line records the posting
-- rule and version that produced it: that reference has to stay resolvable for
-- the life of the ledger, which is longer than the life of the rule.

-- -----------------------------------------------------------------------------
-- What a posting rule says
--
-- erp.posting_rule.posting_lines is jsonb, and B7 left the shape open. This
-- fixes it, because a shape nobody has written down is one every reader has to
-- infer from the interpreter:
--
--   [{"account": "1200",              -- account code within the rule's entity
--     "side": "debit" | "credit",
--     "rate": 1.0,                    -- fraction of the document value
--     "description": "…",             -- optional, lands on the journal line
--     "dimensions": {"cost_centre": "OPS"}}]  -- optional
--
-- Amount is round(document value × rate), in minor units. A rate rather than an
-- amount is what lets one rule serve a tax line at 0.2 and a net line at 1.0
-- without arithmetic in the configuration.
--
-- The rule must balance: the debit rates must sum to the credit rates. That is
-- checkable without a document, which means it is checkable at promotion —
-- and a rule that does not balance is otherwise discovered at month end, by
-- the deferred constraint trigger, on a journal somebody needed.
-- -----------------------------------------------------------------------------

create or replace function erp.posting_rule_imbalance(p_posting_lines jsonb)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select coalesce(sum(case when l.value ->> 'side' = 'debit'
                           then coalesce((l.value ->> 'rate')::numeric, 1)
                           else -coalesce((l.value ->> 'rate')::numeric, 1) end), 0)
    from jsonb_array_elements(coalesce(p_posting_lines, '[]'::jsonb)) l
$$;

comment on function erp.posting_rule_imbalance(jsonb) is
  'Debit rates less credit rates. Zero is the only acceptable answer, and it is '
  'answerable without a document — which is why it can be asked at promotion.';

create or replace function erp.assert_posting_rule_balances(
  p_code text, p_version integer)
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_lines  jsonb;
  v_out    numeric;
  v_bad    text;
begin
  select pr.posting_lines into v_lines
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = p_code and pr.version = p_version;

  if v_lines is null or jsonb_array_length(v_lines) = 0 then
    raise exception 'ERPWARE_POSTING_RULE_EMPTY: % v% raises no lines', p_code, p_version
      using errcode = '23514',
            hint = 'A rule that posts nothing is configuration that looks like behaviour.';
  end if;

  -- Every side must be one of two words. A typo here would otherwise read as a
  -- credit, because the interpreter has to treat "not debit" as something.
  select string_agg(distinct l.value ->> 'side', ', ') into v_bad
    from jsonb_array_elements(v_lines) l
   where coalesce(l.value ->> 'side', '') not in ('debit', 'credit');

  if v_bad is not null then
    raise exception 'ERPWARE_POSTING_RULE_SIDE: % v% has line side(s) %',
      p_code, p_version, v_bad using errcode = '23514';
  end if;

  v_out := erp.posting_rule_imbalance(v_lines);

  if v_out <> 0 then
    raise exception
      'ERPWARE_POSTING_RULE_UNBALANCED: % v% is out by % per unit of document value',
      p_code, p_version, v_out
      using errcode = '23514',
            hint = 'Debit rates must sum to credit rates, or every journal this '
                   'rule raises will fail its balance check at commit.';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- B6 learns to promote a posting rule
--
-- Regenerated from the live definition with one branch added, rather than
-- retyped: the function is two hundred and seventy lines of other people's
-- carefully ordered work, and transcribing it to add a case is how a promotion
-- path loses a branch nobody notices for a month.
-- -----------------------------------------------------------------------------
create or replace function erp.apply_change_set_item(p_item_id uuid)
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

        -- Supersede the version in force. Closing it the day before the new
        -- one starts keeps "exactly one rule in force" true without a gap.
        update erp.posting_rule pr
           set status = 'superseded',
               effective_to = least(coalesce(pr.effective_to, v_from), v_from),
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

    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule';
  end case;
end;
$function$;

-- -----------------------------------------------------------------------------
-- Finance, installed
--
-- Two ledgers, a fiscal calendar, a chart of accounts, and the posting rules
-- that connect operational documents to them.
--
-- The accounts and the calendar are written directly; they are master data, not
-- policy, and B6 governs policy. The posting rules go through B6, because which
-- account a receipt lands in is exactly the sort of decision that should not be
-- a direct write by whoever happened to be logged in.
-- -----------------------------------------------------------------------------

create or replace function erp.configure_finance(
  p_fiscal_year integer default null,
  p_currency    char(3) default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
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
            jsonb_build_object('account','1200','side','debit','rate',1,
                               'description','Inventory received'),
            jsonb_build_object('account','2100','side','credit','rate',1,
                               'description','Goods received not invoiced')))),

      -- Delivery: stock leaves and becomes cost. Revenue is not recognised
      -- here — that is the invoice's job, and conflating them is how a
      -- delivery note ends up on a profit and loss account.
      jsonb_build_object('kind','posting_rule','key','delivery','payload',
        jsonb_build_object(
          'code','delivery','name','Delivery','ledger','GL',
          'event_type','document.delivery.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account','5000','side','debit','rate',1,
                               'description','Cost of goods sold'),
            jsonb_build_object('account','1200','side','credit','rate',1,
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
            jsonb_build_object('account','1100','side','debit','rate',1,
                               'description','Trade receivable'),
            jsonb_build_object('account','4000','side','credit','rate',1,
                               'description','Revenue')))),

      -- Commitments, in the parallel ledger. Product content declares
      -- affects_finance on both order types; this is what honouring that
      -- claim looks like rather than editing the claim.
      jsonb_build_object('kind','posting_rule','key','purchase_commitment','payload',
        jsonb_build_object(
          'code','purchase_commitment','name','Purchase commitment','ledger','COMMIT',
          'event_type','document.purchase_order.confirmed',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account','8100','side','debit','rate',1,
                               'description','Committed to a supplier'),
            jsonb_build_object('account','8900','side','credit','rate',1,
                               'description','Commitment offset')))),

      jsonb_build_object('kind','posting_rule','key','sales_commitment','payload',
        jsonb_build_object(
          'code','sales_commitment','name','Sales commitment','ledger','COMMIT',
          'event_type','document.sales_order.confirmed',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account','8900','side','debit','rate',1,
                               'description','Commitment offset'),
            jsonb_build_object('account','8200','side','credit','rate',1,
                               'description','Committed to a customer'))))));

  return v_cs;
end;
$$;

comment on function erp.configure_finance(integer, char) is
  'Gives a tenant a working finance department: two ledgers, a fiscal calendar, '
  'a chart of accounts, and the posting rules that connect documents to them. '
  'Accounts and calendar are master data and written directly; the rules are '
  'policy and go through B6.';

-- -----------------------------------------------------------------------------
-- Posting to the ledger
--
-- The mirror of erp.post_document()'s stock half, and deliberately the same
-- shape: the document type names a rule, the rule says which accounts and which
-- side, and neither the sign nor the accounts come from a module name. A
-- receipt debits inventory and a delivery credits it through identical code.
--
-- Two things are decided here rather than configured, on purpose:
--
--   * A line whose account is a control account also writes a subledger item.
--     Making that configurable would make erp.assert_subledger_reconciles()
--     a test of whether somebody remembered, and the whole value of that
--     assertion is that it cannot be forgotten.
--
--   * A document in a currency the ledger does not report in is refused, not
--     translated. There is no rate source configured, and a made-up rate is
--     worse than a refusal because it produces a number that looks right.
-- -----------------------------------------------------------------------------

create or replace function erp.post_document_finance(p_document_id uuid)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  d         erp.document%rowtype;
  dt        erp.document_type%rowtype;
  bt        erp_ref.document_type%rowtype;
  pr        erp.posting_rule%rowtype;
  led       erp.ledger%rowtype;
  acc       erp.account%rowtype;
  v_event   uuid;
  v_journal uuid;
  v_value   bigint;
  v_amount  bigint;
  v_line    jsonb;
  v_no      integer := 0;
  v_ccy     char(3);
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type
   where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  -- Most documents reach no ledger, and a caller should not have to know which.
  if not bt.affects_finance then
    return null;
  end if;

  if exists (select 1 from erp.journal j
              where j.tenant_id = v_tenant and j.document_id = p_document_id) then
    raise exception
      'ERPWARE_ALREADY_JOURNALLED: % already has a journal; reverse it rather '
      'than posting again', d.document_number
      using errcode = '23505';
  end if;

  if dt.posting_rule_code is null then
    raise exception
      'ERPWARE_NO_POSTING_RULE: % reaches the ledger but names no posting rule',
      dt.code
      using errcode = '23502',
      detail = 'erp_ref.document_type.affects_finance is true for base type '
               || dt.base_type_code;
  end if;

  -- The version in force on the document's own posting date, not today's.
  -- A journal raised for a backdated document must use the rule that was in
  -- force when it happened, or the explanation of the figure is wrong.
  select * into pr from erp.posting_rule r
   where r.tenant_id = v_tenant
     and r.code = dt.posting_rule_code
     and r.status = 'active'
     and r.effective_from <= coalesce(d.posting_date, d.document_date, current_date)
     and (r.effective_to is null
          or r.effective_to > coalesce(d.posting_date, d.document_date, current_date))
   order by r.version desc limit 1;

  if not found then
    raise exception
      'ERPWARE_NO_POSTING_RULE_IN_FORCE: no active version of % covers %',
      dt.posting_rule_code, coalesce(d.posting_date, d.document_date, current_date)
      using errcode = '23503',
      hint = 'A rule is promoted with an effective date; a document before that '
             'date has no rule and must not be guessed at.';
  end if;

  select * into led from erp.ledger l
   where l.tenant_id = v_tenant and l.id = pr.ledger_id;

  if not found then
    raise exception 'ERPWARE_POSTING_RULE_HAS_NO_LEDGER: % names no ledger', pr.code
      using errcode = '23503';
  end if;

  v_ccy := coalesce(d.currency, led.currency);

  if v_ccy <> led.currency then
    raise exception
      'ERPWARE_NO_TRANSLATION: % is in % and ledger % reports in %',
      d.document_number, v_ccy, led.code, led.currency
      using errcode = '22000',
      hint = 'No rate source is configured. A translated figure nobody can '
             'trace to a rate is worse than a refusal.';
  end if;

  v_value := erp.document_value_minor(p_document_id);

  if coalesce(v_value, 0) = 0 then
    raise exception 'ERPWARE_ZERO_VALUE: % has no value to post', d.document_number
      using errcode = '23514',
      hint = 'A journal of zeroes balances and says nothing; it is noise in the '
             'ledger and a gap in the audit trail at the same time.';
  end if;

  perform erp.authorise('finance.post', d.entity_id, d.site_id, null,
                        'document', p_document_id);

  -- Spec 4.7: every posting traces to an operational event. B7's own trigger
  -- refuses a machine-generated line without one, so the event is raised here
  -- rather than left for a caller to remember — and it is the event, not the
  -- document id, because a document may be posted to more than one ledger.
  v_event := erp.append_event(
    'document.posted', 'document', p_document_id,
    jsonb_build_object(
      'document_number', d.document_number,
      'document_type', dt.code,
      'posting_rule', pr.code,
      'posting_rule_version', pr.version,
      'ledger', led.code,
      'value_minor', v_value,
      'currency', v_ccy),
    d.entity_id, d.site_id);

  insert into erp.journal (
    tenant_id, entity_id, ledger_id, source_code, source_event_id, document_id,
    posting_date, description, status)
  values (
    v_tenant, d.entity_id, led.id, pr.event_type, v_event, p_document_id,
    coalesce(d.posting_date, d.document_date, current_date),
    format('%s %s', dt.name, d.document_number),
    'draft')
  returning id into v_journal;

  for v_line in select * from jsonb_array_elements(pr.posting_lines)
  loop
    select * into acc from erp.account a
     where a.tenant_id = v_tenant
       and a.entity_id = d.entity_id
       and a.code = (v_line ->> 'account')
       and a.status = 'active';

    if not found then
      raise exception 'ERPWARE_UNKNOWN_ACCOUNT: % names account %, which this '
        'entity does not have', pr.code, v_line ->> 'account'
        using errcode = '23503';
    end if;

    v_no := v_no + 1;
    v_amount := round(v_value * coalesce((v_line ->> 'rate')::numeric, 1))::bigint;

    insert into erp.journal_line (
      tenant_id, journal_id, line_no, account_id,
      debit_minor, credit_minor, currency,
      base_debit_minor, base_credit_minor, exchange_rate,
      dimensions, posting_rule_id, posting_rule_version, source_event_id,
      description)
    values (
      v_tenant, v_journal, v_no, acc.id,
      case when v_line ->> 'side' = 'debit'  then v_amount else 0 end,
      case when v_line ->> 'side' = 'credit' then v_amount else 0 end,
      v_ccy,
      case when v_line ->> 'side' = 'debit'  then v_amount else 0 end,
      case when v_line ->> 'side' = 'credit' then v_amount else 0 end,
      1,
      coalesce(v_line -> 'dimensions', '{}'::jsonb),
      pr.id, pr.version, v_event,
      v_line ->> 'description');

    -- A control account carries its detail in a subledger, and the two must
    -- agree at all times. Deriving this from the account rather than from the
    -- rule is what makes that true by construction.
    if acc.control_kind is not null then
      insert into erp.subledger_item (
        tenant_id, entity_id, ledger_id, control_kind, control_account_id,
        party_id, document_id, journal_id, currency,
        debit_minor, credit_minor, due_date, posting_date)
      values (
        v_tenant, d.entity_id, led.id, acc.control_kind, acc.id,
        -- Who owes it, or is owed it. An inventory or bank control account has
        -- no counterparty, and carrying the document's party onto one anyway
        -- would put a customer against a stock balance — detail that looks
        -- like analysis and is noise.
        case when acc.control_kind in ('payable', 'receivable')
             then d.party_id end,
        p_document_id, v_journal, v_ccy,
        case when v_line ->> 'side' = 'debit'  then v_amount else 0 end,
        case when v_line ->> 'side' = 'credit' then v_amount else 0 end,
        d.due_date,
        coalesce(d.posting_date, d.document_date, current_date));
    end if;
  end loop;

  -- Posting is the moment it has to balance. The deferred constraint trigger
  -- checks at commit; this flip is what arms it.
  update erp.journal
     set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;

  return v_journal;
end;
$$;

comment on function erp.post_document_finance(uuid) is
  'Raises the journal a committed document owes the ledger. Accounts and sides '
  'come from the promoted posting rule in force on the document''s posting '
  'date; a control account also writes its subledger detail, derived from the '
  'account rather than configured, so the two cannot drift.';

-- -----------------------------------------------------------------------------
-- The event vocabulary this needs — and a second empty room found on the way
--
-- erp_ref.event_type has never had a row in it. Not "few": none. Which means
-- erp.append_event() — B2's single write path into the event store, with its
-- schema validation, its optimistic concurrency and its outbox — has never
-- successfully run, in any tenant, since it was written. The store was correct
-- and unreachable, exactly like finance, and for the same reason: nobody
-- registered the vocabulary it validates against.
--
-- Posting is the first thing in this product that has to raise an event,
-- because B7's own trigger refuses a machine-generated journal line that
-- cannot name the operational event behind it. So this is where the registry
-- starts, with the events this migration actually raises and no others: a
-- vocabulary of facts nothing states is the same dead configuration again.
-- -----------------------------------------------------------------------------

insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description, payload_schema)
values
  ('document.posted', 1, 'document', 'finance', 'event.document.posted',
   'A document reached the ledger: the journal behind a figure traces to this.',
   jsonb_build_object(
     'type', 'object',
     'required', jsonb_build_array('document_number', 'posting_rule', 'value_minor'),
     'properties', jsonb_build_object(
       'document_number',      jsonb_build_object('type', 'string'),
       'document_type',        jsonb_build_object('type', 'string'),
       'posting_rule',         jsonb_build_object('type', 'string'),
       'posting_rule_version', jsonb_build_object('type', 'integer'),
       'ledger',               jsonb_build_object('type', 'string'),
       'value_minor',          jsonb_build_object('type', 'integer'),
       'currency',             jsonb_build_object('type', 'string'))))
on conflict (code, version) do update
  set payload_schema = excluded.payload_schema,
      description = excluded.description;

-- Without this the build fails on erp.assert_resource_coverage('en'), which is
-- the intended behaviour: a fact the product can record and cannot name in
-- words is a fact nobody can read in an audit trail.
insert into erp_ref.resource (key, locale, value) values
  ('event.document.posted', 'en', 'Document posted to the ledger')
on conflict (key, locale) do nothing;

-- -----------------------------------------------------------------------------
-- Stock posting, unchanged, under a name that says which half it is
-- -----------------------------------------------------------------------------
create or replace function erp.post_document_stock(p_document_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  d          erp.document%rowtype;
  dt         erp.document_type%rowtype;
  bt         erp_ref.document_type%rowtype;
  mt         erp_ref.movement_type%rowtype;
  ln         record;
  v_location uuid;
  v_count    integer := 0;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type
   where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  -- Nothing to do is not an error: most document types move no stock, and the
  -- caller should not have to know which.
  if not bt.affects_stock then
    return 0;
  end if;

  -- Posting twice would double the stock. The ledger is append-only, so there
  -- is no undoing it — a receipt is corrected by reversing it, never by
  -- posting it again.
  if exists (select 1 from erp.stock_movement m
              where m.tenant_id = v_tenant and m.document_id = p_document_id) then
    raise exception
      'ERPWARE_ALREADY_POSTED: % has already moved stock; reverse it rather '
      'than posting again', d.document_number
      using errcode = '23505';
  end if;

  if dt.stock_movement_type is null then
    raise exception
      'ERPWARE_NO_MOVEMENT_TYPE: % moves stock but names no movement type',
      dt.code
      using errcode = '23502',
      detail = 'erp_ref.document_type.affects_stock is true for base type '
               || dt.base_type_code;
  end if;

  select * into mt from erp_ref.movement_type where code = dt.stock_movement_type;

  if d.site_id is null then
    raise exception 'ERPWARE_NO_SITE: % moves stock but names no site', d.document_number
      using errcode = '23502';
  end if;

  perform erp.authorise(
    case when mt.direction = 'in' then 'procurement.receive' else 'sales.despatch' end,
    d.entity_id, d.site_id, null, 'document', p_document_id);

  for ln in
    select l.* from erp.document_line l
     where l.tenant_id = v_tenant and l.document_id = p_document_id
       and not l.is_cancelled and l.quantity > 0
     order by l.line_no
  loop
    v_location := coalesce(ln.location_id,
                           erp.default_posting_location(d.site_id, mt.direction));

    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id,
      batch_id, serial_id, container_id,
      -- One expression, both directions. B7's trigger reads these to decide
      -- which side of the balance to touch, so 'in' fills the destination and
      -- 'out' fills the source; a transfer would fill both.
      from_location_id, from_status, to_location_id, to_status,
      quantity, uom_id, unit_cost_minor, currency,
      document_id, document_line_id)
    values (
      v_tenant, d.entity_id, d.site_id, mt.code, ln.item_id,
      ln.batch_id, ln.serial_id, ln.container_id,
      case when mt.direction in ('out', 'transfer') then v_location end,
      case when mt.direction in ('out', 'transfer') then 'available'::erp.stock_status end,
      case when mt.direction in ('in',  'transfer') then v_location end,
      case when mt.direction in ('in',  'transfer') then 'available'::erp.stock_status end,
      ln.quantity,
      coalesce(ln.uom_id, (select i.stock_uom_id from erp.item i where i.id = ln.item_id)),
      ln.unit_price_minor, coalesce(ln.currency, d.currency),
      p_document_id, ln.id);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function erp.post_document_stock(uuid) is
  'The stock half of posting. Unchanged from the bridge that introduced it; '
  'renamed only because there are now two halves and "post_document" is the '
  'thing that does both.';

-- -----------------------------------------------------------------------------
-- Posting, whole
--
-- Stock then finance, in that order and for a reason: the finance rule values
-- the document, and a stock movement that is going to be refused (nothing on
-- hand, no location, no movement type) should refuse before a journal exists
-- rather than after. Both run in the caller's transaction, so either the
-- document moved stock and reached the ledger or it did neither.
-- -----------------------------------------------------------------------------

create or replace function erp.post_document(p_document_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_moves   integer;
  v_journal uuid;
  v_lines   integer := 0;
begin
  v_moves := erp.post_document_stock(p_document_id);
  v_journal := erp.post_document_finance(p_document_id);

  if v_journal is not null then
    select count(*) into v_lines from erp.journal_line l
     where l.tenant_id = v_tenant and l.journal_id = v_journal;
  end if;

  return v_moves + v_lines;
end;
$$;

comment on function erp.post_document(uuid) is
  'Both halves of posting: the movements a document owes the stock ledger and '
  'the journal it owes the general ledger. Returns the number of ledger rows '
  'written, which is zero for the many document types that owe neither.';

-- -----------------------------------------------------------------------------
-- The lifecycle posts both ledgers
--
-- Same function as before with the posting block widened. A caller that has to
-- remember to raise a journal after transitioning is a caller that will forget,
-- and the month it forgets is the month the accounts are wrong.
-- -----------------------------------------------------------------------------

create or replace function erp.transition_document(
  p_document_id    uuid,
  p_transition_code text,
  p_reason         text default null
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_ctx    jsonb;
  v_to     text;
  v_committed boolean;
  v_total  bigint;
  v_discount numeric;
  v_limit  bigint;
  v_exposure bigint;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  v_total := erp.document_value_minor(p_document_id);

  select coalesce(max(l.discount_pct), 0) into v_discount
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled;

  -- The customer's limit, from their customer role. Absent means no limit was
  -- set, and an absent limit must not read as a limit of zero — that would put
  -- every order through credit release.
  select coalesce((pr.attributes ->> 'credit_limit_minor')::bigint, 9223372036854775807)
    into v_limit
    from erp.party_role pr
   where pr.tenant_id = v_tenant and pr.party_id = d.party_id
     and pr.role_kind = 'customer' and pr.status = 'active'
   limit 1;

  -- Everything already committed for this customer and not yet invoiced or
  -- finished, excluding this document so the sum below is not doubled.
  select coalesce(sum(erp.document_value_minor(d2.id)), 0) into v_exposure
    from erp.document d2
    join erp.document_type dt2 on dt2.tenant_id = d2.tenant_id and dt2.id = d2.document_type_id
    join erp.object_state os2 on os2.tenant_id = d2.tenant_id
                             and os2.object_type = 'document' and os2.object_id = d2.id
    join erp.state s2 on s2.id = os2.current_state_id
   where d2.tenant_id = v_tenant
     and d2.party_id = d.party_id
     and dt2.base_type_code = 'sales_order'
     and s2.is_committed and not s2.is_terminal
     and d2.id <> p_document_id
     and not d2.is_cancelled;

  v_ctx := jsonb_build_object(
    'document_type', dt.code,
    'document_number', d.document_number,
    'total_minor', v_total,
    'currency', d.currency,
    'party_id', d.party_id,
    'entity_id', d.entity_id,
    'transition', p_transition_code,
    'max_discount_pct', v_discount,
    'credit_limit_minor', coalesce(v_limit, 9223372036854775807),
    'exposure_after_minor', v_exposure + v_total);

  if p_transition_code = 'submit' and dt.approval_chain_code is not null then
    perform erp.request_approval('document', p_document_id, v_ctx, 1,
                                 d.entity_id, d.site_id);
  end if;

  v_to := erp.perform_transition('document', p_document_id, p_transition_code,
                                 v_ctx, p_reason);

  select s.is_committed into v_committed
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id;

  -- Committed means the outside world now believes this, and both ledgers have
  -- to agree at that moment.
  --
  -- Each half is asked separately, because a sales order passes through three
  -- committed states and only the first of them should raise anything. Asking
  -- "has this already posted?" of each ledger is what makes the second and
  -- third transitions quiet instead of a duplicate-posting error.
  if coalesce(v_committed, false) then
    if bt.affects_stock
       and not exists (select 1 from erp.stock_movement m
                        where m.tenant_id = v_tenant and m.document_id = p_document_id)
    then
      perform erp.post_document_stock(p_document_id);
    end if;

    if bt.affects_finance
       and not exists (select 1 from erp.journal j
                        where j.tenant_id = v_tenant and j.document_id = p_document_id)
    then
      perform erp.post_document_finance(p_document_id);
    end if;
  end if;

  return v_to;
end;
$$;

-- -----------------------------------------------------------------------------
-- The assertions that keep the finance link honest
--
-- Six new rules, all of the same family as the two the stock bridge added: a
-- claim the configuration makes that nothing can honour is a build failure, not
-- a surprise in a month-end close.
-- -----------------------------------------------------------------------------

create or replace function erp.dead_configuration_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'a transition declares effects that nothing executes',
         format('%s.%s', m.code, t.code),
         'erp.perform_transition() does not run transition effects, so this '
         'configuration would be stored and silently ignored'
    from erp.transition t
    join erp.state_machine_version v on v.id = t.state_machine_version_id
    join erp.state_machine m on m.id = v.state_machine_id
   where jsonb_array_length(coalesce(t.effects, '[]'::jsonb)) > 0
  union all
  select 'a state declares entry or exit actions that nothing executes',
         format('%s.%s', m.code, s.code),
         'on_enter and on_exit are stored and never read'
    from erp.state s
    join erp.state_machine_version v on v.id = s.state_machine_version_id
    join erp.state_machine m on m.id = v.state_machine_id
   where jsonb_array_length(coalesce(s.on_enter, '[]'::jsonb)) > 0
      or jsonb_array_length(coalesce(s.on_exit, '[]'::jsonb)) > 0
  union all
  select 'a document type names a state machine that does not exist',
         dt.code, format('state_machine_code = %s', dt.state_machine_code)
    from erp.document_type dt
   where dt.status = 'active'
     and dt.state_machine_code is not null
     and not exists (
       select 1 from erp.state_machine m
        where m.tenant_id = dt.tenant_id and m.code = dt.state_machine_code
          and m.status = 'active')
  union all
  -- The new one. A type whose base declares affects_stock but which names no
  -- movement would commit, look posted, and move nothing — which is exactly
  -- the state procurement's goods receipt shipped in.
  select 'a document type moves stock but names no movement type',
         dt.code,
         format('base type %s declares affects_stock', dt.base_type_code)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'
     and bt.affects_stock
     and dt.stock_movement_type is null
  union all
  -- And the reverse: a movement bound to a type that does not move stock would
  -- never fire, which reads as configured behaviour and is not.
  select 'a document type names a movement type but moves no stock',
         dt.code,
         format('stock_movement_type = %s, but base type %s declares '
                'affects_stock false', dt.stock_movement_type, dt.base_type_code)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'
     and not bt.affects_stock
     and dt.stock_movement_type is not null
  union all
  -- The finance mirror of the movement-type rule, and the reason this migration
  -- exists: affects_finance was declared on five configured types and read by
  -- nothing at all.
  select 'a document type reaches the ledger but names no posting rule',
         dt.code,
         format('base type %s declares affects_finance', dt.base_type_code)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'
     and bt.affects_finance
     and dt.posting_rule_code is null
  union all
  select 'a document type names a posting rule but reaches no ledger',
         dt.code,
         format('posting_rule_code = %s, but base type %s declares '
                'affects_finance false', dt.posting_rule_code, dt.base_type_code)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'
     and not bt.affects_finance
     and dt.posting_rule_code is not null
  union all
  -- A rule named and never promoted. The document would commit, look posted,
  -- and refuse at the ledger — which is a better failure than a wrong number,
  -- but it belongs at build time rather than at month end.
  select 'a document type names a posting rule that has no active version',
         dt.code, format('posting_rule_code = %s', dt.posting_rule_code)
    from erp.document_type dt
   where dt.status = 'active'
     and dt.posting_rule_code is not null
     and not exists (
       select 1 from erp.posting_rule pr
        where pr.tenant_id = dt.tenant_id and pr.code = dt.posting_rule_code
          and pr.status = 'active')
  union all
  -- Statically answerable, so there is no excuse for finding it dynamically.
  select 'a posting rule does not balance',
         format('%s v%s', pr.code, pr.version),
         format('debits less credits is %s per unit of document value',
                erp.posting_rule_imbalance(pr.posting_lines))
    from erp.posting_rule pr
   where pr.status = 'active'
     and erp.posting_rule_imbalance(pr.posting_lines) <> 0
  union all
  select 'a posting rule names an account the entity does not have',
         format('%s v%s', pr.code, pr.version),
         format('account %s', l.value ->> 'account')
    from erp.posting_rule pr
    cross join lateral jsonb_array_elements(pr.posting_lines) l
   where pr.status = 'active'
     and not exists (
       select 1 from erp.account a
        where a.tenant_id = pr.tenant_id
          and a.code = (l.value ->> 'account')
          and a.status = 'active'
          and (pr.entity_id is null or a.entity_id = pr.entity_id))
  union all
  -- A ledger with no calendar refuses every posting, and it refuses it at the
  -- moment somebody needed the posting rather than at the moment it was built.
  select 'a ledger has no fiscal period covering today',
         l.code,
         format('ledger %s of entity %s', l.code, e.code)
    from erp.ledger l
    join erp.entity e on e.tenant_id = l.tenant_id and e.id = l.entity_id
   where l.status = 'active'
     and not exists (
       select 1 from erp.fiscal_period p
        where p.tenant_id = l.tenant_id and p.ledger_id = l.id
          and current_date between p.starts_on and p.ends_on)
$$;

-- -----------------------------------------------------------------------------
-- Both modules, bound to the ledger
--
-- The same two installers, one column wider. What each document type says about
-- itself is now complete: whether it moves stock, whether it reaches a ledger,
-- and which movement and which rule if so — with the build failing on any type
-- whose answer disagrees with its base type in either direction.
-- -----------------------------------------------------------------------------

create or replace function erp.configure_procurement(
  p_approval_threshold_minor bigint default 1000000,
  p_approver_role text default 'administrator'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_cs     uuid;
begin
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
  if v_entity is null then
    raise exception 'ERPWARE_NO_ENTITY: configure an entity before a module'
      using errcode = '23503';
  end if;

  if not exists (select 1 from erp.ledger l
                  where l.tenant_id = v_tenant and l.status = 'active') then
    raise exception
      'ERPWARE_NO_LEDGER: this tenant has no chart of accounts, and procurement '
      'documents reach one'
      using errcode = '23503',
            hint = 'Run erp.configure_finance() first. The dependency is real: '
                   'a receipt that cannot be accounted for is not a receipt.';
  end if;

  v_cs := erp.install_module_config(
    'procurement-lifecycle', 'Procurement lifecycle',
    'Requisition, purchase order and receipt: their states, the transitions '
    'between them, and the approval a purchase order needs above a threshold.',
    jsonb_build_array(
      jsonb_build_object('kind','state_machine','key','requisition','payload',
        jsonb_build_object(
          'code','requisition','object_type','document','name','Requisition',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','submitted','name','Submitted','sort_order',20),
            jsonb_build_object('code','approved','name','Approved','sort_order',30),
            jsonb_build_object('code','ordered','name','Ordered','is_terminal',true,'is_committed',true,'sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit','from','draft','to','submitted','required_permission','procurement.requisition'),
            jsonb_build_object('code','approve','name','Approve','from','submitted','to','approved','required_permission','procurement.approve'),
            jsonb_build_object('code','reject','name','Reject','from','submitted','to','draft','required_permission','procurement.approve'),
            jsonb_build_object('code','order','name','Convert to order','from','approved','to','ordered','required_permission','procurement.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.requisition'),
            jsonb_build_object('code','cancel_submitted','name','Cancel','from','submitted','to','cancelled','required_permission','procurement.approve')))),

      jsonb_build_object('kind','state_machine','key','purchase_order','payload',
        jsonb_build_object(
          'code','purchase_order','object_type','document','name','Purchase order',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','pending_approval','name','Pending approval','sort_order',20),
            jsonb_build_object('code','approved','name','Approved','sort_order',30),
            jsonb_build_object('code','sent','name','Sent to supplier','is_committed',true,'sort_order',40),
            jsonb_build_object('code','partially_received','name','Partially received','is_committed',true,'sort_order',50),
            jsonb_build_object('code','received','name','Received','is_committed',true,'sort_order',60),
            jsonb_build_object('code','closed','name','Closed','is_terminal',true,'is_committed',true,'sort_order',70),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit for approval','from','draft','to','pending_approval','required_permission','procurement.order'),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','approved','required_permission','procurement.approve'),
            jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','procurement.approve'),
            jsonb_build_object('code','send','name','Send to supplier','from','approved','to','sent','required_permission','procurement.order'),
            jsonb_build_object('code','receive_partial','name','Receive part','from','sent','to','partially_received','required_permission','procurement.receive'),
            jsonb_build_object('code','receive_rest','name','Receive remainder','from','partially_received','to','received','required_permission','procurement.receive'),
            jsonb_build_object('code','receive_all','name','Receive in full','from','sent','to','received','required_permission','procurement.receive'),
            jsonb_build_object('code','close','name','Close','from','received','to','closed','required_permission','procurement.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.order'),
            jsonb_build_object('code','cancel_approved','name','Cancel','from','approved','to','cancelled','required_permission','procurement.approve')))),

      jsonb_build_object('kind','state_machine','key','goods_receipt','payload',
        jsonb_build_object(
          'code','goods_receipt','object_type','document','name','Goods receipt',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','posted','name','Posted','is_terminal',true,'is_committed',true,'sort_order',20),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','post','name','Post','from','draft','to','posted','required_permission','procurement.receive'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.receive')))),

      jsonb_build_object('kind','approval_chain','key','purchase_order_value','payload',
        jsonb_build_object(
          'code','purchase_order_value','name','Purchase order value approval',
          'object_type','document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','document_type'),'purchase_order')),
          'value_field','total_minor','priority',100,
          'material_fields', jsonb_build_array('total_minor','party_id'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','buyer_manager','name','Buying manager',
              'approver_kind','role','role',p_approver_role,'min_approvals',1),
            jsonb_build_object('seq',2,'code','finance','name','Finance',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','total_minor'), p_approval_threshold_minor))))))));

  insert into erp.numbering_rule (tenant_id, code, entity_id, prefix, pad_to, reset_period, next_value)
  values (v_tenant, 'requisition', v_entity, 'REQ-', 6, 'yearly', 1),
         (v_tenant, 'purchase_order', v_entity, 'PO-', 6, 'yearly', 1),
         (v_tenant, 'goods_receipt', v_entity, 'GRN-', 6, 'yearly', 1)
  on conflict (tenant_id, code) do nothing;

  insert into erp.document_type (
    tenant_id, code, base_type_code, name, entity_id,
    state_machine_code, approval_chain_code, numbering_rule_id,
    stock_movement_type, posting_rule_code)
  select v_tenant, x.code, x.base, x.name, v_entity, x.machine, x.chain, n.id,
         x.movement, x.posting
    from (values
      -- A requisition asks; it neither moves stock nor reaches a ledger, and
      -- product content says so. The nulls are the honest answer rather than an
      -- omission: erp.assert_no_dead_configuration() fails the build if a base
      -- type disagrees with them in either direction.
      ('requisition',    'requisition',    'Requisition',    'requisition',    null::text, null::text, null::text),
      -- An order commits. Nothing has moved and nothing is owed yet, so the
      -- entry belongs in the parallel commitment ledger, not the statutory one.
      ('purchase_order', 'purchase_order', 'Purchase order', 'purchase_order', 'purchase_order_value', null, 'purchase_commitment'),
      -- A receipt is the first point at which both ledgers have something to say.
      ('goods_receipt',  'receipt',        'Goods receipt',  'goods_receipt',  null, 'goods_receipt', 'goods_receipt')
    ) as x(code, base, name, machine, chain, movement, posting)
    join erp.numbering_rule n on n.tenant_id = v_tenant and n.code = x.code
  on conflict (tenant_id, code) do update
    set state_machine_code = excluded.state_machine_code,
        approval_chain_code = excluded.approval_chain_code,
        numbering_rule_id = excluded.numbering_rule_id,
        stock_movement_type = excluded.stock_movement_type,
        posting_rule_code = excluded.posting_rule_code;

  return v_cs;
end;
$$;

create or replace function erp.configure_sales(
  p_discount_threshold_pct numeric default 15,
  p_approver_role text default 'administrator'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_cs     uuid;
begin
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
  if v_entity is null then
    raise exception 'ERPWARE_NO_ENTITY: configure an entity before a module'
      using errcode = '23503';
  end if;

  if not exists (select 1 from erp.ledger l
                  where l.tenant_id = v_tenant and l.status = 'active') then
    raise exception
      'ERPWARE_NO_LEDGER: this tenant has no chart of accounts, and sales '
      'documents reach one'
      using errcode = '23503',
            hint = 'Run erp.configure_finance() first. The dependency is real: '
                   'a receipt that cannot be accounted for is not a receipt.';
  end if;

  v_cs := erp.install_module_config(
    'sales-lifecycle', 'Sales lifecycle',
    'Quotation, sales order and delivery: their states, the approvals a '
    'discount and a credit exposure require, and the despatch that moves stock.',
    jsonb_build_array(
      jsonb_build_object('kind','state_machine','key','quotation','payload',
        jsonb_build_object(
          'code','quotation','object_type','document','name','Quotation',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','sent','name','Sent','sort_order',20),
            jsonb_build_object('code','accepted','name','Accepted','is_terminal',true,'sort_order',30),
            jsonb_build_object('code','expired','name','Expired','is_terminal',true,'sort_order',40),
            jsonb_build_object('code','declined','name','Declined','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','send','name','Send','from','draft','to','sent','required_permission','sales.order'),
            jsonb_build_object('code','accept','name','Accept','from','sent','to','accepted','required_permission','sales.order'),
            jsonb_build_object('code','decline','name','Decline','from','sent','to','declined','required_permission','sales.order'),
            jsonb_build_object('code','expire','name','Expire','from','sent','to','expired','required_permission','sales.order')))),

      jsonb_build_object('kind','state_machine','key','sales_order','payload',
        jsonb_build_object(
          'code','sales_order','object_type','document','name','Sales order',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','pending_approval','name','Pending approval','sort_order',20),
            jsonb_build_object('code','confirmed','name','Confirmed','is_committed',true,'sort_order',30),
            jsonb_build_object('code','picking','name','Picking','is_committed',true,'sort_order',40),
            jsonb_build_object('code','despatched','name','Despatched','is_committed',true,'sort_order',50),
            jsonb_build_object('code','invoiced','name','Invoiced','is_committed',true,'sort_order',60),
            jsonb_build_object('code','closed','name','Closed','is_terminal',true,'is_committed',true,'sort_order',70),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit','from','draft','to','pending_approval','required_permission','sales.order'),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','confirmed','required_permission','sales.order'),
            jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','sales.order'),
            jsonb_build_object('code','pick','name','Start picking','from','confirmed','to','picking','required_permission','sales.despatch'),
            jsonb_build_object('code','despatch','name','Despatch','from','picking','to','despatched','required_permission','sales.despatch'),
            jsonb_build_object('code','invoice','name','Invoice','from','despatched','to','invoiced','required_permission','sales.invoice'),
            jsonb_build_object('code','close','name','Close','from','invoiced','to','closed','required_permission','sales.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.order'),
            jsonb_build_object('code','cancel_confirmed','name','Cancel','from','confirmed','to','cancelled','required_permission','sales.order')))),

      -- An invoice is raised, issued, and either paid or credited. It moves no
      -- stock; what it does is turn a despatch into a receivable, which is why
      -- it is the only document type here that reaches a ledger and not a
      -- warehouse.
      jsonb_build_object('kind','state_machine','key','sales_invoice','payload',
        jsonb_build_object(
          'code','sales_invoice','object_type','document','name','Sales invoice',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','issued','name','Issued','is_committed',true,'sort_order',20),
            jsonb_build_object('code','paid','name','Paid','is_terminal',true,'is_committed',true,'sort_order',30),
            jsonb_build_object('code','credited','name','Credited','is_terminal',true,'is_committed',true,'sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','issue','name','Issue','from','draft','to','issued','required_permission','sales.invoice'),
            jsonb_build_object('code','settle','name','Record payment','from','issued','to','paid','required_permission','finance.post'),
            jsonb_build_object('code','credit','name','Credit','from','issued','to','credited','required_permission','sales.invoice'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.invoice')))),

      -- The mirror of goods receipt, and the whole point of the stock bridge:
      -- same shape, opposite direction, same posting code.
      jsonb_build_object('kind','state_machine','key','delivery','payload',
        jsonb_build_object(
          'code','delivery','object_type','document','name','Delivery',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','posted','name','Posted','is_terminal',true,'is_committed',true,'sort_order',20),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','post','name','Post','from','draft','to','posted','required_permission','sales.despatch'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.despatch')))),

      -- Two bands on one chain. A discount above the threshold needs someone
      -- who may approve discounts; an order that takes the customer past their
      -- credit limit needs someone who may release credit. Either can fire
      -- alone, both can fire together, and neither is expressed in a second
      -- rule language — both are JsonLogic over the same context.
      jsonb_build_object('kind','approval_chain','key','sales_order_terms','payload',
        jsonb_build_object(
          'code','sales_order_terms','name','Sales order terms approval',
          'object_type','document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','document_type'),'sales_order')),
          'value_field','total_minor','priority',100,
          'material_fields', jsonb_build_array('total_minor','party_id','max_discount_pct'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','sales_manager','name','Sales manager',
              'approver_kind','role','role',p_approver_role,'min_approvals',1),
            jsonb_build_object('seq',2,'code','discount','name','Discount approval',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','max_discount_pct'), p_discount_threshold_pct))),
            jsonb_build_object('seq',3,'code','credit','name','Credit release',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              -- The sum is computed into the context rather than in the rule,
              -- so the interpreter needs no arithmetic and the configured rule
              -- stays one readable comparison.
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','exposure_after_minor'),
                jsonb_build_object('var','credit_limit_minor')))))))));

  insert into erp.numbering_rule (tenant_id, code, entity_id, prefix, pad_to, reset_period, next_value)
  values (v_tenant, 'quotation', v_entity, 'QUO-', 6, 'yearly', 1),
         (v_tenant, 'sales_order', v_entity, 'SO-', 6, 'yearly', 1),
         (v_tenant, 'delivery', v_entity, 'DN-', 6, 'yearly', 1),
         (v_tenant, 'sales_invoice', v_entity, 'INV-', 6, 'yearly', 1)
  on conflict (tenant_id, code) do nothing;

  insert into erp.document_type (
    tenant_id, code, base_type_code, name, entity_id,
    state_machine_code, approval_chain_code, numbering_rule_id,
    stock_movement_type, posting_rule_code)
  select v_tenant, x.code, x.base, x.name, v_entity, x.machine, x.chain, n.id,
         x.movement, x.posting
    from (values
      ('quotation',     'quotation',         'Quotation',     'quotation',     null::text, null::text, null::text),
      -- The mirror of the purchase order: same parallel ledger, sides reversed,
      -- and nothing about that reversal is in code.
      ('sales_order',   'sales_order',       'Sales order',   'sales_order',   'sales_order_terms', null, 'sales_commitment'),
      ('delivery',      'delivery',          'Delivery',      'delivery',      null, 'despatch', 'delivery'),
      -- The sales order lifecycle has always had an `invoice` transition into an
      -- `invoiced` state, and there was no invoice for it to raise. Spec 5.6
      -- asks for "invoicing derived from validated delivery with role separation
      -- enforced" — the separation being that despatching and invoicing are
      -- different permissions, which the lifecycle already required and nothing
      -- could exercise.
      ('sales_invoice', 'invoice_reference', 'Sales invoice', 'sales_invoice', null, null, 'sales_invoice')
    ) as x(code, base, name, machine, chain, movement, posting)
    join erp.numbering_rule n on n.tenant_id = v_tenant and n.code = x.code
  on conflict (tenant_id, code) do update
    set state_machine_code = excluded.state_machine_code,
        approval_chain_code = excluded.approval_chain_code,
        numbering_rule_id = excluded.numbering_rule_id,
        stock_movement_type = excluded.stock_movement_type,
        posting_rule_code = excluded.posting_rule_code;

  return v_cs;
end;
$$;

-- -----------------------------------------------------------------------------
-- The public surface
-- -----------------------------------------------------------------------------

create or replace function public.erp_configure_finance(
  p_fiscal_year integer default null,
  p_currency    char(3) default null
) returns uuid
language sql
volatile
security invoker
set search_path = ''
as $$ select erp.configure_finance(p_fiscal_year, p_currency) $$;

create or replace function public.erp_trial_balance()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x ->> 'ledger', x ->> 'account'), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'ledger', led.code,
               'account', a.code,
               'name', a.name,
               'account_type', a.account_type,
               'currency', l.currency,
               'debit_minor', sum(l.debit_minor),
               'credit_minor', sum(l.credit_minor),
               'balance_minor', sum(l.debit_minor) - sum(l.credit_minor)) as x
        from erp.journal_line l
        join erp.journal j on j.id = l.journal_id and j.status = 'posted'
        join erp.ledger led on led.id = j.ledger_id
        join erp.account a on a.id = l.account_id
       where l.tenant_id = erp.current_tenant_id()
       group by led.code, a.code, a.name, a.account_type, l.currency
    ) s
$$;

comment on function public.erp_trial_balance() is
  'Every posted balance, by ledger and account. Read-only, invoker rights, and '
  'therefore only ever this tenant''s.';

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_configure_finance(integer, char)',
    'public.erp_trial_balance()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

-- erp_configure_finance writes, so it needs naming in the write allow-list.
-- The gate is the function it delegates to, one hop down, which is what rule 3b
-- checks: an allow-listed wrapper whose delegate authorises nothing would be a
-- hole with a rationale attached to it.
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_finance', 'erp.configure_finance',
   'Installs a tenant''s ledgers, calendar, chart of accounts and posting '
   'rules. Authorises finance.configure, and the rules themselves are submitted '
   'as a B6 change set that the caller cannot approve.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- -----------------------------------------------------------------------------
-- The suite
--
-- The cases that matter are the ones that read the ledger. "post_document()
-- raised no error" would have passed on the day affects_finance was read by
-- nothing at all, because a function that returns without doing anything does
-- not raise either.
-- -----------------------------------------------------------------------------

create or replace function erp_test.finance_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; css uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid; v_desp uuid;
  v_sup uuid; v_cust uuid; v_item uuid;
  v_po uuid; v_grn uuid; v_dn uuid; v_so uuid; v_inv uuid;
  v_j uuid; v_rule uuid;
  n_dr bigint; n_cr bigint; b_inv bigint; b_cogs bigint; b_grni bigint;
  b_commit bigint; b_rec bigint; b_rev bigint;
  v_ok boolean; v_msg text; v_count integer;
begin
  select * into r from erp.provision_tenant('zzfin','Finance Suite','a@zzfin.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzfin.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  csf := erp.configure_finance();
  csp := erp.configure_procurement(1000000);
  css := erp.configure_sales(15);

  return query select 'a tenant gets two ledgers, not one',
    (select count(*) from erp.ledger l
      where l.tenant_id = r.tenant_id and l.status='active') = 2
    and (select count(*) from erp.ledger l
          where l.tenant_id = r.tenant_id and l.ledger_kind='management') = 1,
    'spec 5.7 opens with "chart of accounts and parallel ledgers"';

  return query select 'the calendar covers both ledgers for the whole year',
    (select count(*) from erp.fiscal_period p
      where p.tenant_id = r.tenant_id) = 24,
    'twelve periods each; a ledger without a calendar refuses every posting';

  -- Posting rules are configuration, so before promotion they do not exist.
  -- This is the case that would have caught a rule written directly.
  return query select 'posting rules do not exist until they are promoted',
    (select count(*) from erp.posting_rule pr where pr.tenant_id = r.tenant_id) = 0,
    'submitted as a change set the author may not approve';

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
  perform erp.approve_change_set(css); perform erp.promote_change_set(css);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'promotion installs five posting rules',
    (select count(*) from erp.posting_rule pr
      where pr.tenant_id = r.tenant_id and pr.status = 'active') = 5,
    'receipt, delivery, invoice, and a commitment rule for each order type';

  return query select 'every configured document type answers for itself',
    (select count(*) from erp.dead_configuration_report()) = 0,
    'no type claims an effect nothing can honour, in either direction';

  -- Fixtures.
  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'RECV','Receiving','receiving','active') returning id into v_recv;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'DESP','Despatch','despatch','active') returning id into v_desp;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_sup;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'CUST','Customer','active') returning id into v_cust;
  insert into erp.party_role (tenant_id,party_id,role_kind,attributes,status)
  values (r.tenant_id,v_cust,'customer', jsonb_build_object('credit_limit_minor', 100000000),'active');
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;

  -- ---------------------------------------------------------------------------
  -- Inbound: a receipt debits inventory and credits GRNI.
  -- ---------------------------------------------------------------------------
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 500, 1000, 'inbound');
  perform erp.transition_document(v_grn,'post');

  select j.id into v_j from erp.journal j
   where j.tenant_id = r.tenant_id and j.document_id = v_grn;

  select sum(l.debit_minor), sum(l.credit_minor) into n_dr, n_cr
    from erp.journal_line l where l.journal_id = v_j;

  return query select 'a posted receipt raises a balanced journal',
    v_j is not null and n_dr = 500000 and n_cr = 500000,
    format('debits %s, credits %s on 500 at 1000 minor', n_dr, n_cr);

  select sum(l.debit_minor) - sum(l.credit_minor) into b_inv
    from erp.journal_line l join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '1200';
  select sum(l.credit_minor) - sum(l.debit_minor) into b_grni
    from erp.journal_line l join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '2100';

  return query select 'the receipt lands on inventory and goods-received-not-invoiced',
    b_inv = 500000 and b_grni = 500000,
    format('1200 debit %s, 2100 credit %s — from configuration, not from code',
           b_inv, b_grni);

  -- ---------------------------------------------------------------------------
  -- Outbound: the same function, the opposite side of the same account.
  -- ---------------------------------------------------------------------------
  v_dn := erp.open_document('delivery', v_cust, null, v_site);
  perform erp.add_document_line(v_dn, v_item, 200, 2500, 'outbound');
  update erp.document_line set location_id = v_recv where document_id = v_dn;
  perform erp.transition_document(v_dn,'post');

  select j.id into v_j from erp.journal j
   where j.tenant_id = r.tenant_id and j.document_id = v_dn;
  select sum(l.debit_minor) into b_cogs
    from erp.journal_line l join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '5000';
  select sum(l.credit_minor) into b_inv
    from erp.journal_line l join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '1200';

  return query select 'a delivery credits the account the receipt debited',
    b_cogs = 500000 and b_inv = 500000,
    format('5000 debit %s, 1200 credit %s — same erp.post_document_finance()',
           b_cogs, b_inv);

  -- ---------------------------------------------------------------------------
  -- The parallel ledger. This is the case that decides whether affects_finance
  -- on an order type was honoured or edited away.
  -- ---------------------------------------------------------------------------
  v_so := erp.open_document('sales_order', v_cust, null, v_site);
  perform erp.add_document_line(v_so, v_item, 100, 2500, 'ordered');
  perform erp.transition_document(v_so,'submit');
  perform erp.transition_document(v_so,'approve');

  select sum(l.credit_minor) - sum(l.debit_minor) into b_commit
    from erp.journal_line l
    join erp.journal j on j.id = l.journal_id
    join erp.ledger led on led.id = j.ledger_id
    join erp.account a on a.id = l.account_id
   where j.document_id = v_so and led.code = 'COMMIT' and a.code = '8200';

  return query select 'a confirmed order posts a commitment to the parallel ledger',
    b_commit = 250000,
    format('8200 credit %s in COMMIT, nothing in GL', b_commit);

  return query select 'the commitment stays out of the statutory ledger',
    not exists (select 1 from erp.journal j
                 join erp.ledger led on led.id = j.ledger_id
                where j.document_id = v_so and led.code = 'GL'),
    'an order is a commitment, not a transaction';

  -- A sales order passes through three committed states. Only the first posts.
  perform erp.transition_document(v_so,'pick');
  perform erp.transition_document(v_so,'despatch');
  select count(*) into v_count from erp.journal j where j.document_id = v_so;

  return query select 'three committed states raise one journal, not three',
    v_count = 1,
    format('%s journal(s) after confirm, pick and despatch', v_count);

  -- ---------------------------------------------------------------------------
  -- The invoice, and the subledger that has to agree with it.
  -- ---------------------------------------------------------------------------
  v_inv := erp.open_document('sales_invoice', v_cust, null, v_site);
  perform erp.add_document_line(v_inv, v_item, 200, 2500, 'invoiced');
  perform erp.transition_document(v_inv,'issue');

  select j.id into v_j from erp.journal j
   where j.tenant_id = r.tenant_id and j.document_id = v_inv;
  select sum(l.debit_minor) into b_rec
    from erp.journal_line l join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '1100';
  select sum(l.credit_minor) into b_rev
    from erp.journal_line l join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '4000';

  return query select 'an issued invoice raises a receivable and revenue',
    b_rec = 500000 and b_rev = 500000,
    format('1100 debit %s, 4000 credit %s', b_rec, b_rev);

  -- Control accounts carry their detail. Derived from the account, so it cannot
  -- be forgotten by configuration.
  select coalesce(sum(s.debit_minor - s.credit_minor), 0) into b_rec
    from erp.subledger_item s
    join erp.account a on a.id = s.control_account_id
   where s.tenant_id = r.tenant_id and a.code = '1100';

  return query select 'posting a control account writes its subledger detail',
    b_rec = 500000
    and (select count(*) from erp.subledger_item s
          join erp.account a on a.id = s.control_account_id
         where s.tenant_id = r.tenant_id and a.code = '1100'
           and s.party_id = v_cust) = 1,
    format('receivable subledger %s, against the customer', b_rec);

  -- Inventory is a control account as well, so the receipt and the delivery
  -- each wrote one — with no party on it, because stock is owed to nobody.
  return query select 'a control account with no counterparty carries none',
    (select count(*) from erp.subledger_item s
      join erp.account a on a.id = s.control_account_id
     where s.tenant_id = r.tenant_id and a.code = '1200') = 2
    and not exists (
      select 1 from erp.subledger_item s
       join erp.account a on a.id = s.control_account_id
      where s.tenant_id = r.tenant_id and a.code = '1200' and s.party_id is not null),
    'a customer against a stock balance is noise dressed as analysis';

  return query select 'the subledger and its control account agree',
    (select count(*) from erp.subledger_reconciliation_report()) = 0,
    'the month-end discovery nobody wants, asserted continuously';

  -- ---------------------------------------------------------------------------
  -- Negative controls.
  -- ---------------------------------------------------------------------------
  begin
    perform erp.post_document_finance(v_inv);
    v_ok := false; v_msg := 'a document was journalled twice';
  exception when sqlstate '23505' then v_ok := true; v_msg := left(sqlerrm,58); end;
  return query select 'a document cannot be journalled twice', v_ok, v_msg;

  -- A rule that does not balance is refusable without a document, so it is
  -- refused at promotion rather than at month end.
  -- Break the rule first and read the static report, THEN provoke the raise.
  -- The other way round passes for the wrong reason: a PL/pgSQL exception block
  -- is a subtransaction, so the failing assertion rolls the broken fixture back
  -- with it and the report that follows is looking at a rule that is fine.
  update erp.posting_rule
     set posting_lines = jsonb_build_array(
           jsonb_build_object('account','1200','side','debit','rate',1),
           jsonb_build_object('account','2100','side','credit','rate',0.5))
   where tenant_id = r.tenant_id and code = 'goods_receipt';

  return query select 'an unbalanced rule fails the build statically',
    (select count(*) from erp.dead_configuration_report()
      where finding = 'a posting rule does not balance') = 1,
    'answerable without a document, so it is answered at promotion';

  begin
    perform erp.assert_posting_rule_balances('goods_receipt', 1);
    v_ok := false; v_msg := 'an unbalanced rule was accepted';
  exception when others then
    v_ok := (sqlerrm like '%POSTING_RULE_UNBALANCED%'); v_msg := left(sqlerrm,58);
  end;
  return query select 'and promotion refuses it by name', v_ok, v_msg;

  update erp.posting_rule
     set posting_lines = jsonb_build_array(
           jsonb_build_object('account','1200','side','debit','rate',1),
           jsonb_build_object('account','2100','side','credit','rate',1))
   where tenant_id = r.tenant_id and code = 'goods_receipt';

  -- A type that reaches the ledger and names no rule.
  update erp.document_type set posting_rule_code = null
   where tenant_id = r.tenant_id and code = 'delivery';

  return query select 'a type that reaches a ledger and names no rule fails the build',
    (select count(*) from erp.dead_configuration_report()
      where finding = 'a document type reaches the ledger but names no posting rule'
        and reference = 'delivery') = 1,
    'exactly what affects_finance was before this migration';

  update erp.document_type set posting_rule_code = 'delivery'
   where tenant_id = r.tenant_id and code = 'delivery';

  -- Spec 4.7: every posting traces to an operational event and the rule version
  -- that produced it. B7 enforces it; this asserts the bridge satisfies it.
  return query select 'every posted line names its event and its rule version',
    not exists (
      select 1 from erp.journal_line l
       join erp.journal j on j.id = l.journal_id
      where l.tenant_id = r.tenant_id and j.source_code <> 'manual'
        and (l.source_event_id is null or l.posting_rule_version is null)),
    'spec 4.7, and the reason the event store finally has rows in it';

  return query select 'and those events are real events in the store',
    (select count(*) from erp.event e
      where e.tenant_id = r.tenant_id and e.event_type = 'document.posted') = 4,
    'receipt, delivery, order commitment and invoice';

  -- The journal balance triggers are DEFERRABLE INITIALLY DEFERRED, so they
  -- fire at commit — which is after this suite has deleted its own tenant, and
  -- they would then look for the lines of a journal that no longer exists and
  -- report an empty journal. Firing them here checks the thing they are for,
  -- against data that is still there, and clears the queue.
  set constraints all immediate;

  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_finance_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 21;
begin
  create temporary table if not exists zz_finance_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_finance_result;
  insert into zz_finance_result select * from erp_test.finance_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
                    filter (where not passed)
    into v_pass, v_total, v_detail
    from zz_finance_result;

  -- The count is asserted, not reported. A suite that silently loses a case
  -- reports success, which is the failure mode this whole discipline exists
  -- to catch.
  if v_total <> c_expected then
    raise exception 'ERPWARE_FINANCE_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;

  if v_pass < v_total then
    raise exception E'ERPWARE_FINANCE_SUITE_FAILED: %/%\n%', v_pass, v_total, v_detail
      using errcode = 'P0001';
  end if;

  return format('finance: %s/%s', v_pass, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_isolation();

-- -----------------------------------------------------------------------------
-- The two suites this migration changed the world under
--
-- Both modules now reach a ledger, so both suites need one — and both raise
-- journals, so both have to fire the deferred balance checks before purging the
-- tenant those journals belong to. Neither change weakens a case: the sales
-- suite's lifecycle count goes from six to seven because sales gained the
-- invoice its own state machine had been promising since it was written.
-- -----------------------------------------------------------------------------

create or replace function erp_test.procurement_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r        record;
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  cs_fin   uuid;
  v_cs uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_party uuid; v_item uuid;
  v_req uuid; v_po uuid; v_lo uuid; t record;
  v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant(
    'zzproc', 'Procurement Suite', 'admin@zzproc.test', 'Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  res := public.erp_invite_principal('second@zzproc.test', 'Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  -- Procurement reaches a ledger now, so it needs one. The dependency is real
  -- rather than a test artefact: erp.configure_procurement() refuses without it.
  cs_fin := erp.configure_finance();
  v_cs := erp.configure_procurement(1000000);
  return query select 'installing procurement authors a change set, unapproved',
    (select c.status::text from erp.change_set c where c.id = v_cs) = 'ready',
    'B6 will not let its author wave it through';

  begin
    perform erp.approve_change_set(v_cs);
    v_ok := false; v_msg := 'the author approved their own change set';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm, 60); end;
  return query select 'the author of a change set cannot approve it', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(cs_fin);
  perform erp.promote_change_set(cs_fin);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'promotion installs three lifecycles',
    (select count(*) from erp.state_machine m
      where m.tenant_id = r.tenant_id and m.status = 'active'
        and m.code in ('requisition','purchase_order','goods_receipt')) = 3,
    'requisition, purchase order and goods receipt';

  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_party;
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;

  -- Requisition through to its terminal state.
  v_req := erp.open_document('requisition', v_party);
  perform erp.add_document_line(v_req, v_item, 10, 50000, 'Ten widgets');
  return query select 'a document is numbered from its own rule',
    (select d.document_number like 'REQ-%' from erp.document d where d.id = v_req),
    (select d.document_number from erp.document d where d.id = v_req);

  return query select 'the value is derived from the lines, not stored',
    erp.document_value_minor(v_req) = 500000,
    format('%s minor', erp.document_value_minor(v_req));

  perform erp.transition_document(v_req, 'submit');
  perform erp.transition_document(v_req, 'approve');
  return query select 'a requisition reaches its terminal state',
    erp.transition_document(v_req, 'order') = 'ordered', 'draft to ordered';

  begin
    perform erp.transition_document(v_req, 'submit');
    v_ok := false; v_msg := 'a transition out of a terminal state was allowed';
  exception when others then v_ok := true; v_msg := left(sqlerrm, 60); end;
  return query select 'a terminal state has no way out', v_ok, v_msg;

  -- The purchase order must run its OWN machine, which is the defect this
  -- module found: start_lifecycle() chose by object_type alone, and every
  -- document type shares object_type 'document'.
  v_po := erp.open_document('purchase_order', v_party, null, v_site);
  perform erp.add_document_line(v_po, v_item, 500, 50000, 'Five hundred');
  return query select 'a document follows the lifecycle its type names',
    (select m.code from erp.object_state os
       join erp.state_machine_version v on v.id = os.state_machine_version_id
       join erp.state_machine m on m.id = v.state_machine_id
      where os.object_id = v_po) = 'purchase_order',
    'not whichever machine shares its object_type';

  perform erp.link_documents(v_req, v_po, 'fulfils');
  return query select 'lineage is navigable in both directions',
    (select count(*) from erp.document_lineage(v_req)) >= 2
    and (select count(*) from erp.document_lineage(v_po)) >= 2,
    'spec 4.5';

  -- The band, measured by status rather than by counting rows.
  perform erp.transition_document(v_po, 'submit');
  -- The caller's own task, not whichever came first: a step with two eligible
  -- approvers raises a task each, and deciding somebody else's is refused.
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_po and tk.status = 'pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  return query select 'above the threshold, the second approval step opens',
    exists (select 1 from erp.approval_task tk
              join erp.approval_request q on q.id = tk.approval_request_id
             where q.object_id = v_po and tk.step_code = 'finance'
               and tk.status = 'pending'),
    'value 25000000 against a threshold of 1000000';

  v_lo := erp.open_document('purchase_order', v_party, null, v_site);
  perform erp.add_document_line(v_lo, v_item, 1, 500000, 'Small');
  perform erp.transition_document(v_lo, 'submit');
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_lo and tk.status = 'pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  return query select 'below the threshold, it is skipped and recorded as skipped',
    exists (select 1 from erp.approval_task tk
              join erp.approval_request q on q.id = tk.approval_request_id
             where q.object_id = v_lo and tk.step_code = 'finance'
               and tk.status = 'skipped'),
    'omitting it would leave no evidence it was considered';

  -- Committed documents.
  perform erp.transition_document(v_po, 'approve');
  perform erp.transition_document(v_po, 'send');
  begin
    perform erp.add_document_line(v_po, v_item, 1, 1, 'sneak');
    v_ok := false; v_msg := 'a committed document accepted a new line';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm, 60); end;
  return query select 'a committed document cannot gain a line', v_ok, v_msg;

  return query select 'a purchase order runs its full lifecycle',
    erp.transition_document(v_po, 'receive_all') = 'received', 'sent to received';

  -- Journals are checked by DEFERRABLE INITIALLY DEFERRED triggers, which fire
  -- at commit — after this suite has deleted its own tenant. Firing them here
  -- checks them against data that still exists.
  set constraints all immediate;

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.sales_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  cs0 uuid; cs1 uuid; cs2 uuid; v_second uuid; v_tok text; res jsonb; t record;
  v_uom uuid; v_site uuid; v_recv uuid; v_desp uuid;
  v_sup uuid; v_cust uuid; v_item uuid;
  v_grn uuid; v_dn uuid; v_so uuid; v_quo uuid; v_dn2 uuid;
  q0 numeric; q1 numeric; q2 numeric;
  v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant('zzsales','Sales Suite','a@zzsales.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzsales.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  cs0 := erp.configure_finance();
  cs1 := erp.configure_procurement(1000000);
  cs2 := erp.configure_sales(15);

  return query select 'two modules install through one shared installer',
    cs1 is not null and cs2 is not null and cs1 <> cs2,
    'erp.install_module_config() authored both';

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(cs0); perform erp.promote_change_set(cs0);
  perform erp.approve_change_set(cs1); perform erp.promote_change_set(cs1);
  perform erp.approve_change_set(cs2); perform erp.promote_change_set(cs2);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'promotion installs seven lifecycles across both modules',
    (select count(*) from erp.state_machine m
      where m.tenant_id = r.tenant_id and m.status='active') = 7,
    'requisition, purchase order, goods receipt, quotation, sales order, '
    'delivery, sales invoice';

  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'RECV','Receiving','receiving','active') returning id into v_recv;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'DESP','Despatch','despatch','active') returning id into v_desp;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_sup;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'CUST','Customer','active') returning id into v_cust;
  insert into erp.party_role (tenant_id,party_id,role_kind,attributes,status)
  values (r.tenant_id,v_cust,'customer', jsonb_build_object('credit_limit_minor', 1000000),'active');
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;

  select coalesce(sum(quantity),0) into q0 from erp.stock_balance
   where tenant_id=r.tenant_id and item_id=v_item;

  -- Inbound.
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 500, 1000, 'inbound');
  perform erp.transition_document(v_grn,'post');
  select coalesce(sum(quantity),0) into q1 from erp.stock_balance
   where tenant_id=r.tenant_id and item_id=v_item;

  return query select 'a posted receipt raises an inbound movement and on-hand rises',
    q1 - q0 = 500 and exists (select 1 from erp.stock_movement m
      where m.document_id = v_grn and m.movement_type = 'goods_receipt'
        and m.to_location_id is not null and m.from_location_id is null),
    format('%s to %s', q0, q1);

  -- Outbound, through the same function.
  v_dn := erp.open_document('delivery', v_cust, null, v_site);
  perform erp.add_document_line(v_dn, v_item, 200, 2500, 'outbound');
  update erp.document_line set location_id = v_recv where document_id = v_dn;
  perform erp.transition_document(v_dn,'post');
  select coalesce(sum(quantity),0) into q2 from erp.stock_balance
   where tenant_id=r.tenant_id and item_id=v_item;

  return query select 'a posted delivery raises an outbound movement and on-hand falls',
    q2 - q1 = -200 and exists (select 1 from erp.stock_movement m
      where m.document_id = v_dn and m.movement_type = 'despatch'
        and m.from_location_id is not null and m.to_location_id is null),
    format('%s to %s, same erp.post_document() as the receipt', q1, q2);

  return query select 'the ledger and the cached balance agree after both',
    (select count(*) from erp.stock_reconciliation_report()) = 0,
    'a movement inserted but not reflected is not a movement';

  -- Posting twice would double the stock, and the ledger is append-only.
  begin
    perform erp.post_document(v_dn);
    v_ok := false; v_msg := 'a document posted twice';
  exception when sqlstate '23505' then v_ok := true; v_msg := left(sqlerrm,58); end;
  return query select 'a document cannot post twice', v_ok, v_msg;

  -- B7's own balance guard, reached through the bridge.
  v_dn2 := erp.open_document('delivery', v_cust, null, v_site);
  perform erp.add_document_line(v_dn2, v_item, 99999, 2500, 'more than exists');
  update erp.document_line set location_id = v_recv where document_id = v_dn2;
  begin
    perform erp.transition_document(v_dn2,'post');
    v_ok := false; v_msg := 'despatched more than was on hand';
  exception when others then
    v_ok := (sqlerrm like '%NEGATIVE_STOCK%'); v_msg := left(sqlerrm,58);
  end;
  return query select 'despatching more than is on hand is refused', v_ok, v_msg;

  -- Lineage across the module boundary.
  v_quo := erp.open_document('quotation', v_cust);
  perform erp.add_document_line(v_quo, v_item, 10, 2500, 'quoted');
  v_so := erp.open_document('sales_order', v_cust, null, v_site);
  perform erp.add_document_line(v_so, v_item, 10, 2500, 'ordered');
  perform erp.link_documents(v_quo, v_so, 'fulfils');
  return query select 'lineage runs quotation to order, both ways',
    (select count(*) from erp.document_lineage(v_quo)) >= 2,
    'spec 4.5';

  -- The discount band. 20% is above the 15% threshold.
  update erp.document_line set discount_pct = 20 where document_id = v_so;
  perform erp.transition_document(v_so,'submit');
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_so and tk.status='pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  return query select 'a discount above the threshold opens the discount step',
    exists (select 1 from erp.approval_task tk
              join erp.approval_request q on q.id = tk.approval_request_id
             where q.object_id = v_so and tk.step_code='discount'
               and tk.status = 'pending'),
    '20 per cent against a threshold of 15';

  -- The credit band, on the same chain and from the same context. It cannot be
  -- read until the discount step is decided — sequences open one at a time —
  -- and asserting it earlier is asserting something that cannot yet be true.
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_so and tk.status='pending'
              and tk.step_code = 'discount'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  -- 25,000 against a limit of 1,000,000, so credit is skipped — and the skip
  -- is what proves the context carried the customer's own limit and the
  -- comparison actually ran, rather than the step simply never opening.
  return query select 'the credit step reads the customer''s limit and is skipped under it',
    exists (select 1 from erp.approval_task tk
              join erp.approval_request q on q.id = tk.approval_request_id
             where q.object_id = v_so and tk.step_code='credit'
               and tk.status = 'skipped'),
    'exposure 25000 against a credit limit of 1000000';

  -- Dead configuration, both directions.
  begin
    update erp.document_type set stock_movement_type = null
     where tenant_id = r.tenant_id and code = 'delivery';
    perform erp.assert_no_dead_configuration();
    v_ok := false; v_msg := 'a stock-moving type with no movement passed';
  exception when others then
    v_ok := (sqlerrm like '%DEAD_CONFIGURATION%'); v_msg := left(sqlerrm,52);
  end;
  update erp.document_type set stock_movement_type = 'despatch'
   where tenant_id = r.tenant_id and code = 'delivery';
  return query select 'a type that moves stock but names no movement fails the build',
    v_ok, v_msg;

  begin
    update erp.document_type set stock_movement_type = 'despatch'
     where tenant_id = r.tenant_id and code = 'quotation';
    perform erp.assert_no_dead_configuration();
    v_ok := false; v_msg := 'a movement bound to a type that moves nothing passed';
  exception when others then
    v_ok := (sqlerrm like '%DEAD_CONFIGURATION%'); v_msg := left(sqlerrm,52);
  end;
  update erp.document_type set stock_movement_type = null
   where tenant_id = r.tenant_id and code = 'quotation';
  return query select 'a movement bound to a type that moves no stock fails the build',
    v_ok, v_msg;

  -- Journals are checked by DEFERRABLE INITIALLY DEFERRED triggers, which fire
  -- at commit — after this suite has deleted its own tenant. Firing them here
  -- checks them against data that still exists.
  set constraints all immediate;

  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;
