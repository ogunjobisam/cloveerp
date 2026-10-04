set lock_timeout = '30s';

-- =============================================================================
-- 20261005150000  Old bills' residue is cleared before the generators run
-- -----------------------------------------------------------------------------
-- 20261005200000 failed on live on 4 October:
--
--   ERROR: cannot ALTER TABLE "journal" because it has pending trigger events
--
-- Its call of erp.clear_bill_price_residue() posted the demonstration's
-- journal, and the journal's balance check is a deferred constraint trigger,
-- so its event waited for the end of the transaction. The generators that end
-- every migration then altered erp.journal, which Postgres refuses while an
-- event on it is pending. The build never met it: a built database holds no
-- organisation that is not live with a residue, so nothing was posted there.
-- The migration rolled back whole; nothing of it is on live.
--
-- 20261005200000 is on main and is not edited. This version sorts before it,
-- and the deploy applies with --include-all, so on live it runs first: it
-- declares what 20261005200000 declares, the event, its words and the
-- function, word for word, calls it in each organisation, and fires the
-- checks the call left pending there (set constraints all immediate) while
-- still in that organisation, before its own generators. When
-- 20261005200000 follows, the journal it would post is there, so it posts
-- nothing, nothing is pending, and its generators run.
--
-- Where 20261005200000 has already run (every build), this runs after it and
-- changes nothing: the declarations are the same, and the call finds the
-- journal, or no residue at all.
--
-- Proof: erp_test.bill_price_residue_suite (20261005200000), and this file
-- applied before 20261005200000 to a database holding a residue.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.finance.bill_price_residue_cleared', 'en', 'Bill price residue cleared', 'finance',
   'Event raised when what old bills cleared off goods received not invoiced beyond the order price is moved to purchase price variance.'),
  ('event.finance.bill_price_residue_cleared', 'de', 'Preisabweichung alter Rechnungen umgebucht', 'finance',
   'Ereignis, wenn der über den Bestellpreis hinaus ausgebuchte Wareneingang auf die Preisabweichung umgebucht wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('finance.bill_price_residue_cleared', 1, 'journal', 'finance', 'event.finance.bill_price_residue_cleared',
        'What bills cleared off goods received not invoiced beyond the order price was moved to purchase price variance.',
        '{"type":"object","required":["value_minor","bills"],"properties":{"value_minor":{"type":"integer"},"bills":{"type":"integer"},"currency":{"type":"string"}}}'::jsonb,
        true)
on conflict do nothing;

do $event$
begin
  if not exists (select 1 from erp_ref.event_type et
                  where et.code = 'finance.bill_price_residue_cleared' and et.version = 1 and et.is_current
                    and et.aggregate_type = 'journal') then
    raise exception 'CLOVEERP_ANCHOR_MOVED: finance.bill_price_residue_cleared is declared already, and not as 20261005200000 declares it';
  end if;
end
$event$;

create or replace function erp.clear_bill_price_residue()
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_grni    text := erp.tenant_account_code('goods_received_not_invoiced');
  v_ppv     text := erp.tenant_account_code('purchase_price_variance');
  v_total   bigint := 0;
  r         record;
  v_grni_id uuid;
  v_ppv_id  uuid;
  v_rule    uuid;
  v_version integer;
  v_event   uuid;
  v_journal uuid;
  v_amount  bigint;
begin
  -- What posted bills took off goods received not invoiced beyond what the
  -- order lines they bill put on it, moved to purchase price variance
  -- (20261005200000). Version 1 of purchase_invoice cleared the account at
  -- the bill's price; version 2 clears it at the receipt's and posts the rest
  -- as a variance. Nothing in a live organisation, whose accountant decides.
  if erp.tenant_is_live() then
    return 0;
  end if;

  for r in
    with cleared as (
      select j.entity_id, j.ledger_id, j.document_id, max(j.posting_date) as on_date,
             sum(l.debit_minor - l.credit_minor) as grni
        from erp.journal j
        join erp.journal_line l on l.tenant_id = j.tenant_id and l.journal_id = j.id
        join erp.account a on a.id = l.account_id and a.code = v_grni
        join erp.document d on d.tenant_id = j.tenant_id and d.id = j.document_id
        join erp.document_type dt on dt.id = d.document_type_id
       where j.tenant_id = v_tenant and j.status = 'posted' and dt.code = 'purchase_invoice'
       group by 1, 2, 3
    ),
    at_order as (
      select rel.from_document_id as document_id,
             sum(round(rel.quantity * ol.unit_price_minor)) as ordered
        from erp.document_relation rel
        join erp.document_line ol on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
        join erp.document od on od.tenant_id = ol.tenant_id and od.id = ol.document_id
        join erp.document_type odt on odt.id = od.document_type_id and odt.base_type_code = 'purchase_order'
       where rel.tenant_id = v_tenant and rel.relation_kind = 'invoices'
       group by 1
    )
    select c.entity_id, c.ledger_id, e.code as entity_code, e.base_currency,
           sum(c.grni - o.ordered)::bigint as residue,
           count(*) filter (where c.grni <> o.ordered) as bills,
           max(c.on_date) filter (where c.grni <> o.ordered) as on_date
      from cleared c
      join at_order o using (document_id)
      join erp.entity e on e.id = c.entity_id
     group by 1, 2, 3, 4
  loop
    v_amount := abs(r.residue);
    continue when v_amount = 0;
    continue when exists (
      select 1 from erp.journal j
       where j.tenant_id = v_tenant and j.entity_id = r.entity_id
         and j.source_code = 'finance.bill_price_residue_cleared' and j.status = 'posted');

    select a.id into v_grni_id from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = r.entity_id and a.code = v_grni and a.status = 'active';
    select a.id into v_ppv_id from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = r.entity_id and a.code = v_ppv and a.status = 'active';
    if v_grni_id is null or v_ppv_id is null then
      raise warning 'bill price residue: % in company % is not cleared; it has no % or no %',
        r.residue, r.entity_code, v_grni, v_ppv;
      continue;
    end if;

    -- The rule in force, which posts the variance this is.
    select pr.id, pr.version into v_rule, v_version
      from erp.posting_rule pr
     where pr.tenant_id = v_tenant and pr.code = 'purchase_invoice' and pr.status = 'active'
       and (pr.entity_id is null or pr.entity_id = r.entity_id)
     order by pr.version desc limit 1;

    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date, description, status)
    values (v_tenant, r.entity_id, r.ledger_id, 'finance.bill_price_residue_cleared', r.on_date,
            format('What %s bill(s) cleared off goods received not invoiced beyond the order price, '
                   'to purchase price variance', r.bills), 'draft')
    returning id into v_journal;

    v_event := erp.append_event(
      'finance.bill_price_residue_cleared', 'journal', v_journal,
      jsonb_build_object('value_minor', r.residue, 'bills', r.bills, 'currency', r.base_currency),
      r.entity_id, null);
    update erp.journal set source_event_id = v_event where id = v_journal;

    -- Cleared too much: the account is owed it back and the variance takes
    -- it. Too little, the other way round.
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate,
                                  posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, 1, case when r.residue > 0 then v_ppv_id else v_grni_id end,
            v_amount, 0, r.base_currency, v_amount, 0, 1, v_rule, v_version, v_event,
            case when r.residue > 0 then 'Purchase price variance the bills'' rule did not post'
                 else 'Goods received not invoiced the bills did not clear' end),
           (v_tenant, v_journal, 2, case when r.residue > 0 then v_grni_id else v_ppv_id end,
            0, v_amount, r.base_currency, 0, v_amount, 1, v_rule, v_version, v_event,
            case when r.residue > 0 then 'Goods received not invoiced the bills cleared beyond the order price'
                 else 'Purchase price variance the bills'' rule did not post' end);

    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
     where id = v_journal;

    v_total := v_total + r.residue;
  end loop;

  return v_total;
end;
$$;

revoke all on function erp.clear_bill_price_residue() from public, anon;

comment on function erp.clear_bill_price_residue() is
  'Moves what posted bills cleared off goods received not invoiced beyond the order price to purchase price '
  'variance, once per company, in an organisation that is not live (20261005200000). Called by this migration.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Cleared where it is, and said
-- ─────────────────────────────────────────────────────────────────────────────

do $clear$
declare
  r       record;
  v_n     bigint;
begin
  for r in select tn.id, tn.code from erp.tenant tn where tn.deleted_at is null order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.clear_bill_price_residue();
    -- The checks its journal left waiting, fired while still in the
    -- organisation they read, so the generators below can alter erp.journal.
    set constraints all immediate;
    if v_n <> 0 then
      raise warning 'bill price residue: % moved from goods received not invoiced to purchase price variance in %', v_n, r.code;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$clear$;

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
select erp.assert_personal_data_register_sound();
