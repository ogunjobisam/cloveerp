set lock_timeout = '30s';

-- =============================================================================
-- 20261002200000  A VAT disagreement says what its journal did
-- -----------------------------------------------------------------------------
-- The deploy of 20261002100000 brought the live demonstration up to today for
-- the first time since 27 September, and its proof then refused:
--
--   demo-cbb10384: erp.assert_vat_agrees_with_ledger() — CLOVEERP_VAT_DISAGREES_WITH_LEDGER: 1 finding(s)
--   the tax determined is not the tax the ledger carries [INV-000432]
--   INV-000432 determined 49773 and journal GL-2026-001049 moved tax control by 0
--
-- INV-000432 was made by today's catch-up, so this is not the residue
-- 20261001500000 withdrew: something still makes it. And "moved tax control by
-- 0" reads only journal lines on accounts whose control_kind is 'tax'
-- (erp.vat_entries()), so it says one of two different things:
--
--   * the journal charged no tax, and the determination came after it; or
--   * the journal charged the tax to an account not marked as tax control.
--
-- The two want opposite repairs, and a fresh demonstration built in the build
-- does not show either (supabase/ci/demonstration_catch_up.sh, re-run with the
-- VAT agreement: it reconciles). Only the live one's journal can say which.
-- Nothing may reach production but through the deploy, so this asks there.
--
-- ── WHAT THIS DOES ───────────────────────────────────────────────────────────
--
--   * erp.describe_vat_disagreements(): read-only. For every document a
--     blocking VAT finding names, in the organisation it is called in: the
--     document's dates, its moves in order, its lines with their tax and
--     each line's determination and when it was made, and each of its
--     document journals with every line's account, the account's
--     control_kind, and the amounts. It changes nothing.
--   * This migration prints it for every organisation that is not live, as
--     warnings in the deploy's log, which is the record. It repairs nothing:
--     the repair follows once the log says which of the two it is.
-- =============================================================================

create or replace function erp.describe_vat_disagreements()
returns jsonb
language sql
stable
set search_path = ''
as $$
  with docs as (
    select distinct d.id, d.document_number
      from erp.vat_exceptions(null, null, null) x
      join erp.document d
        on d.tenant_id = erp.require_tenant_id()
       and d.document_number = x.reference
     where x.blocks
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'document', d.document_number,
    'document_date', d.document_date, 'tax_point', d.tax_point,
    'posting_date', d.posting_date, 'created_at', d.created_at,
    'their_reference', d.their_reference,
    'moves', (select coalesce(jsonb_agg(jsonb_build_object(
                'at', l.occurred_at, 'move', l.transition_code,
                'from', l.from_state_code, 'to', l.to_state_code) order by l.occurred_at, l.id), '[]'::jsonb)
                from erp.state_transition_log l
               where l.tenant_id = d.tenant_id and l.object_type = 'document' and l.object_id = d.id),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                'line', dl.line_no, 'net', dl.net_minor, 'tax', dl.tax_minor,
                'cancelled', dl.is_cancelled, 'updated_at', dl.updated_at,
                'determined', (select jsonb_build_object(
                                  'tax', td.tax_minor, 'rate', td.rate_pct, 'rule', td.rule_code,
                                  'treatment', td.treatment, 'at', td.created_at,
                                  'journal_line', td.journal_line_id)
                                 from erp.tax_determination td
                                where td.tenant_id = dl.tenant_id and td.document_line_id = dl.id))
                order by dl.line_no), '[]'::jsonb)
                from erp.document_line dl
               where dl.tenant_id = d.tenant_id and dl.document_id = d.id),
    'journals', (select coalesce(jsonb_agg(jsonb_build_object(
                   'journal', j.journal_number, 'source', j.source_code, 'status', j.status,
                   'posted_at', j.posted_at, 'reverses', j.reverses_journal_id is not null,
                   'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                               'account', a.code, 'name', a.name, 'control_kind', a.control_kind,
                               'debit', jl.base_debit_minor, 'credit', jl.base_credit_minor)
                               order by jl.line_no), '[]'::jsonb)
                               from erp.journal_line jl
                               join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
                              where jl.tenant_id = j.tenant_id and jl.journal_id = j.id))
                   order by j.posted_at), '[]'::jsonb)
                   from erp.journal j
                  where j.tenant_id = d.tenant_id and j.document_id = d.id)
    ) order by d.document_number), '[]'::jsonb)
    from docs x
    join erp.document d on d.tenant_id = erp.require_tenant_id() and d.id = x.id
$$;

revoke all on function erp.describe_vat_disagreements() from public, anon, authenticated;

comment on function erp.describe_vat_disagreements() is
  'Read-only: for each document a blocking VAT finding names, its dates, moves, lines with their '
  'determinations, and its journals line by line with each account''s control_kind (20261002200000). '
  'Says which of the two a disagreement is: tax the journal never charged, or tax charged to an account '
  'not marked as tax control.';

do $describe$
declare
  r   record;
  v   jsonb;
  v_n integer := 0;
begin
  for r in select tn.id, tn.code from erp.tenant tn where tn.deleted_at is null order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    if erp.environment_is_live() then
      continue;
    end if;
    v := erp.describe_vat_disagreements();
    if jsonb_array_length(v) > 0 then
      raise warning 'vat disagreements in %: %', r.code, jsonb_pretty(v);
      v_n := v_n + jsonb_array_length(v);
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
  raise warning 'vat disagreements described: % document(s)', v_n;
end
$describe$;

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
