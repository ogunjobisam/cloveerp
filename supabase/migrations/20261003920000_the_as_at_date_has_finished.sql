-- ═════════════════════════════════════════════════════════════════════════════
-- The as-at date has finished
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_test.migration_cutover_suite() took the first of the current month as
-- its as-at date, loaded opening stock as at it, wrote 105 units off now, and
-- asserted the as-at figure ignored the write-off because it came after. On
-- the first of a month the as-at date is today, the write-off counts, and the
-- stock figure is out by 105 × 250 = 26,250. Not for the first minutes of the
-- day: for the whole of it, UTC — every build on 1 October failed, and the
-- suite was written in September, so this was the first first it met.
--
-- The as-at date is now the first of the month yesterday fell in, which has
-- always finished by today. On 1 January that is 1 December, and the fixture
-- configures only the fiscal year holding today, so the suite opens its
-- year on the as-at month: the year then holds both days, whatever the date.
-- erp_test.cutover_as_at() states the rule once, and the suite's first case
-- walks it over every day of a leap year and either side, so the rule is
-- proved on the days that break it rather than only on the day CI runs.
--
-- The suite also asked for the figure "today" with current_date, which a
-- transaction fixes at its start while the write-off is stamped when it
-- runs; a build that crossed midnight failed the same case (15 September).
-- It now asks for the figure as at the day the write-off is stamped with.
--
-- 20260904460000 and four later migrations end by running the suite, and
-- cannot be edited, so a build from an empty cluster would run the old body
-- on every first. supabase/ci/replay_superseded_calls.txt names those five
-- calls; the catalogue walks the suite as it is now on every build.

set lock_timeout = '30s';

create or replace function erp_test.cutover_as_at(p_today date)
returns date
language sql
immutable
set search_path = ''
as $$
  select date_trunc('month', p_today - 1)::date
$$;

comment on function erp_test.cutover_as_at(date) is
  'The as-at date erp_test.migration_cutover_suite() loads opening balances at: '
  'the first of the month yesterday fell in, which has always finished by '
  'p_today, so a movement made today is after it.';

revoke all on function erp_test.cutover_as_at(date) from public, anon, authenticated;

create or replace function erp_test.migration_cutover_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r        record;
  a1 uuid := gen_random_uuid();   -- loads everything
  a2 uuid := gen_random_uuid();   -- the second administrator, who cuts over
  op uuid := gen_random_uuid();   -- no rights
  csf uuid; csi uuid;
  v_second uuid; v_op uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_bulk uuid; v_cust uuid; v_sup uuid; v_wid uuid; v_gad uuid;
  v_asat date := erp_test.cutover_as_at(current_date);
  v_stock uuid; v_bad uuid; v_sales uuid; v_purch uuid; v_nom uuid; v_stock2 uuid;
  v_n integer; v_ok boolean; v_msg text;
  v_inv uuid; v_rec uuid; v_pay uuid; v_clr text;
  v_journal uuid; v_move bigint;
  v_gl bigint; v_sub bigint;
  v_checks integer; v_passes integer;
  v_written_off_on date; v_bad_days text;
begin
  -- Not only today: the rule that picks the as-at date, on every day of a leap
  -- year and either side of it. Each first of the month failed here before.
  select string_agg(d::date::text, ', ' order by d) into v_bad_days
    from generate_series(date '2027-12-31', date '2029-01-01', interval '1 day') d
   where not (erp_test.cutover_as_at(d::date) < d::date
              and d::date < erp_test.cutover_as_at(d::date) + interval '12 months'
              and erp_test.cutover_as_at(d::date) = date_trunc('month', erp_test.cutover_as_at(d::date))::date);
  return query select 'the as-at date is a first of the month before today, in a year that holds today, on every day',
    v_bad_days is null, coalesce('not on ' || left(v_bad_days, 120), '368 days, 1 January and 29 February among them');

  select * into r from erp.provision_tenant(
    'zzmig', 'Migration Cutover', 'admin@zzmig.test', 'Migration Admin');
  insert into auth.users (id, email) values
    (a1, 'admin@zzmig.test'), (a2, 'second@zzmig.test'), (op, 'op@zzmig.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzmig.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  -- The year opens on the as-at date, so it holds both that day and today —
  -- on 1 January too, when the as-at date is in December.
  update erp.entity e set fiscal_year_start_month = extract(month from v_asat)::smallint
   where e.tenant_id = r.tenant_id;

  csf := erp.configure_finance();
  csi := erp.configure_inventory('average');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
  insert into erp.location (tenant_id, site_id, code, name, location_type, status)
  values (r.tenant_id, v_site, 'BULK-01', 'Bulk 01', 'bulk', 'active') returning id into v_bulk;
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'CUST', 'Customer', 'active') returning id into v_cust;
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_wid;
  insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, status)
  values (r.tenant_id, 'GAD', 'Gadget', v_uom, true, 'active') returning id into v_gad;

  select a.id into v_inv from erp.account a
   where a.tenant_id = r.tenant_id and a.code = erp.chart_account_code('inventory');
  select a.id into v_rec from erp.account a
   where a.tenant_id = r.tenant_id and a.code = erp.chart_account_code('trade_receivable');
  select a.id into v_pay from erp.account a
   where a.tenant_id = r.tenant_id and a.code = erp.chart_account_code('trade_payable');
  v_clr := erp.chart_account_code('clearing');

  -- ── The register ──────────────────────────────────────────────────────────

  begin
    v_msg := erp.assert_migration_sound(); v_ok := true;
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 120);
  end;
  return query select 'every migration domain names a loader and a figure the catalogue has',
    v_ok and v_msg like 'migration register: 4 domain(s)%', v_msg;

  -- ── Staging refuses what cannot be reconciled ─────────────────────────────

  begin
    perform erp.stage_opening_balances('fixed_assets', v_asat, '[{"x":1}]'::jsonb, 1);
    v_ok := false; v_msg := 'staged a domain the register does not have';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_UNKNOWN_MIGRATION_DOMAIN%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a domain the register does not name is refused', v_ok, v_msg;

  begin
    perform erp.stage_opening_balances('stock', v_asat, '[{"item":"WID"}]'::jsonb, null);
    v_ok := false; v_msg := 'staged without a control total';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_OPENING_CONTROL_MISSING%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a batch with no control total is refused, because it could not be reconciled', v_ok, v_msg;

  begin
    perform erp.stage_opening_balances('stock', current_date + 1, '[{"item":"WID"}]'::jsonb, 1);
    v_ok := false; v_msg := 'staged as at tomorrow';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_OPENING_DATE_FUTURE%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a date that has not happened is refused', v_ok, v_msg;

  begin
    perform erp.stage_opening_balances('stock', make_date(1990, 1, 1), '[{"item":"WID"}]'::jsonb, 1);
    v_ok := false; v_msg := 'staged outside the calendar';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_OPENING_DATE_OUTSIDE_CALENDAR%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a date outside the ledger''s accounting periods is refused', v_ok, v_msg;

  -- ── Validation finds what a row names wrongly ─────────────────────────────

  v_bad := erp.stage_opening_balances('stock', v_asat, jsonb_build_array(
    jsonb_build_object('item', 'NOPE', 'site', 'MAIN', 'location', 'BULK-01', 'quantity', 5, 'unit_cost_minor', 100),
    jsonb_build_object('item', 'GAD', 'site', 'MAIN', 'location', 'BULK-01', 'quantity', 5, 'unit_cost_minor', 100),
    jsonb_build_object('item', 'WID', 'site', 'MAIN', 'location', 'NOWHERE', 'quantity', 5, 'unit_cost_minor', 100, 'colour', 'red')),
    1500);
  v_n := erp.validate_import(v_bad);
  return query select 'validation rejects an unknown product, a batch-controlled product with no batch, an unknown location and an unknown field',
    v_n = 3
    and (select r2.findings::text from erp.import_row r2 where r2.import_batch_id = v_bad and r2.row_no = 1) like '%no product has the code NOPE%'
    and (select r2.findings::text from erp.import_row r2 where r2.import_batch_id = v_bad and r2.row_no = 2) like '%batch controlled%'
    and (select r2.findings::text from erp.import_row r2 where r2.import_batch_id = v_bad and r2.row_no = 3) like '%no location NOWHERE%'
    and (select r2.findings::text from erp.import_row r2 where r2.import_batch_id = v_bad and r2.row_no = 3) like '%unknown field(s): colour%',
    format('%s rows rejected', v_n);

  perform erp.preview_import(v_bad);
  begin
    perform erp.load_import(v_bad);
    v_ok := false; v_msg := 'loaded a batch with rejected rows';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_IMPORT_HAS_ERRORS%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'and a batch with rejected rows does not load', v_ok, v_msg;

  -- ── Opening stock, as at a date ───────────────────────────────────────────

  v_stock := erp.stage_opening_balances('stock', v_asat, jsonb_build_array(
    jsonb_build_object('item', 'WID', 'site', 'MAIN', 'location', 'BULK-01', 'quantity', 100, 'unit_cost_minor', 250),
    jsonb_build_object('item', 'GAD', 'site', 'MAIN', 'location', 'BULK-01', 'quantity', 40, 'unit_cost_minor', 500,
                       'batch', 'L-2026-01', 'expires_on', (current_date + 365)::text)),
    45000, 140, 'OB-STOCK-1');
  v_n := erp.validate_import(v_stock);

  begin
    perform erp.load_import(v_stock);
    v_ok := false; v_msg := 'loaded before anybody looked';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_IMPORT_NOT_PREVIEWED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'opening balances load only after a preview, like every other import', v_ok and v_n = 0, v_msg;

  perform erp.preview_import(v_stock);
  v_n := erp.load_import(v_stock);
  select m.id into v_move from erp.stock_movement m
   where m.tenant_id = r.tenant_id and m.item_id = v_wid and m.movement_type = 'opening_balance';
  return query select 'opening stock becomes opening_balance movements dated as at, and a released batch',
    v_n = 2
    and (select sum(b.quantity) from erp.stock_balance b
          where b.tenant_id = r.tenant_id and b.item_id = v_wid and b.location_id = v_bulk) = 100
    and (select m.occurred_at::date from erp.stock_movement m where m.id = v_move) = v_asat
    and (select bt.status::text from erp.batch bt
          where bt.tenant_id = r.tenant_id and bt.item_id = v_gad and bt.batch_number = 'L-2026-01') = 'unrestricted'
    and (select c.unit_cost_minor from erp.item_cost c
          where c.tenant_id = r.tenant_id and c.item_id = v_gad) = 500,
    format('%s rows loaded; WID on hand 100, GAD batch released at 500', v_n);

  select b.journal_id into v_journal from erp.import_batch b where b.id = v_stock;
  select coalesce(sum(l.debit_minor - l.credit_minor), 0) into v_gl
    from erp.journal_line l where l.journal_id = v_journal and l.account_id = v_inv;
  select coalesce(sum(s.debit_minor - s.credit_minor), 0) into v_sub
    from erp.subledger_item s where s.journal_id = v_journal and s.control_kind = 'inventory';
  return query select 'the batch posts one journal, stock against migration clearing, dated as at, with stock detail per product',
    (select j.status::text from erp.journal j where j.id = v_journal) = 'posted'
    and (select j.posting_date from erp.journal j where j.id = v_journal) = v_asat
    and (select j.source_code from erp.journal j where j.id = v_journal) = 'manual'
    and v_gl = 45000 and v_sub = 45000
    and erp.migration_clearing_balance() = -45000
    and exists (select 1 from erp.account a where a.tenant_id = r.tenant_id and a.code = v_clr and a.name = 'Migration clearing'),
    format('stock %s, detail %s, clearing %s', v_gl, v_sub, erp.migration_clearing_balance());

  -- ── D31: reconciliation after load ────────────────────────────────────────

  select count(*), count(*) filter (where c.passes) into v_checks, v_passes
    from erp.opening_balance_reconciliation(v_stock) c;
  return query select 'the reconciliation after load passes every check: rows, control total, control quantity, journal, control detail',
    v_checks = 5 and v_passes = 5,
    format('%s of %s checks pass', v_passes, v_checks);

  -- A sales ledger load whose control total disagrees with its rows.
  v_sales := erp.stage_opening_balances('sales_ledger', v_asat, jsonb_build_array(
    jsonb_build_object('party', 'CUST', 'reference', 'INV-9001', 'amount_minor', 20000, 'due_date', (v_asat + 30)::text),
    jsonb_build_object('party', 'CUST', 'reference', 'INV-9002', 'amount_minor', 12000),
    jsonb_build_object('party', 'CUST', 'reference', 'CRN-17', 'amount_minor', -2000)),
    31000, null, 'OB-SALES-1');
  perform erp.validate_import(v_sales); perform erp.preview_import(v_sales);
  v_n := erp.load_import(v_sales);
  select count(*), count(*) filter (where c.passes) into v_checks, v_passes
    from erp.opening_balance_reconciliation(v_sales) c;
  return query select 'a load whose control total disagrees loads, and the reconciliation says by how much',
    v_n = 3 and v_checks = 4 and v_passes = 3
    and exists (select 1 from erp.opening_balance_reconciliation(v_sales) c
                 where c.check_code = 'control_total' and not c.passes and c.difference = -1000)
    and (select b.loaded_total_minor from erp.import_batch b where b.id = v_sales) = 30000
    and erp.migration_figure_sales_ledger(v_asat) = 30000,
    format('%s of %s checks pass; loaded 30000 against a control of 31000', v_passes, v_checks);

  return query select 'the tenant-level report names the batch that does not reconcile',
    (select m.finding from erp.migration_reconciliation_report() m where m.domain_code = 'sales_ledger')
      like 'OB-SALES-1: loaded 30000 against a control total of 31000%'
    and (select m.reconciles from erp.migration_reconciliation_report() m where m.domain_code = 'stock'),
    (select m.finding from erp.migration_reconciliation_report() m where m.domain_code = 'sales_ledger');

  -- ── D32: no evidence, no cutover ──────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  begin
    perform erp.cut_over_domain('sales_ledger');
    v_ok := false; v_msg := 'cut over a domain that does not reconcile';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_CUTOVER_EVIDENCE_MISSING: sales_ledger%does not reconcile%OB-SALES-1%'
            and sqlerrm like '%no parallel-run figure%';
    v_msg := left(sqlerrm, 160);
  end;
  return query select 'a domain whose load does not reconcile is not cut over, and the refusal says why', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- ── Reversal, as a unit ───────────────────────────────────────────────────

  begin
    perform erp.reverse_opening_balances(v_sales, '');
    v_ok := false; v_msg := 'reversed without a reason';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_REVERSAL_NEEDS_REASON%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a reversal needs a reason', v_ok, v_msg;

  v_n := erp.rollback_import(v_sales);
  return query select 'reversing the batch posts a reversing journal and leaves the ledger where it was',
    v_n = 3
    and (select b.status::text from erp.import_batch b where b.id = v_sales) = 'rolled_back'
    and (select j.status::text from erp.journal j where j.id = (select b.journal_id from erp.import_batch b where b.id = v_sales)) = 'reversed'
    and (select j.reverses_journal_id from erp.journal j where j.id = (select b.reversal_journal_id from erp.import_batch b where b.id = v_sales))
        = (select b.journal_id from erp.import_batch b where b.id = v_sales)
    and (select coalesce(sum(l.debit_minor - l.credit_minor), 0) from erp.journal_line l
          join erp.journal j on j.id = l.journal_id
         where l.tenant_id = r.tenant_id and l.account_id = v_rec) = 0
    and (select coalesce(sum(s.debit_minor - s.credit_minor), 0) from erp.subledger_item s
          where s.tenant_id = r.tenant_id and s.control_kind = 'receivable') = 0
    and erp.migration_figure_sales_ledger(v_asat) = 0,
    format('%s rows reversed; receivables nominal 0, detail 0, figure as at 0', v_n);

  v_sales := erp.stage_opening_balances('sales_ledger', v_asat, jsonb_build_array(
    jsonb_build_object('party', 'CUST', 'reference', 'INV-9001', 'amount_minor', 20000, 'due_date', (v_asat + 30)::text),
    jsonb_build_object('party', 'CUST', 'reference', 'INV-9002', 'amount_minor', 12000),
    jsonb_build_object('party', 'CUST', 'reference', 'CRN-17', 'amount_minor', -2000)),
    30000, null, 'OB-SALES-2');
  perform erp.validate_import(v_sales); perform erp.preview_import(v_sales);
  v_n := erp.load_import(v_sales);
  return query select 'reloaded with the right control total, the sales ledger reconciles and the figure counts the load once',
    v_n = 3
    and (select m.reconciles from erp.migration_reconciliation_report() m where m.domain_code = 'sales_ledger')
    and erp.migration_figure_sales_ledger(v_asat) = 30000
    and (select count(*) from erp.subledger_item s where s.tenant_id = r.tenant_id
          and s.control_kind = 'receivable' and s.party_id = v_cust) = 9,
    format('figure %s from nine detail rows, six of them a reversed pair', erp.migration_figure_sales_ledger(v_asat));

  -- Stock that has moved since the load cannot be reversed.
  v_stock2 := erp.stage_opening_balances('stock', v_asat, jsonb_build_array(
    jsonb_build_object('item', 'WID', 'site', 'MAIN', 'location', 'BULK-01', 'quantity', 10, 'unit_cost_minor', 250)),
    2500, 10, 'OB-STOCK-2');
  perform erp.validate_import(v_stock2); perform erp.preview_import(v_stock2);
  perform erp.load_import(v_stock2);
  perform erp.write_off_stock(v_wid, v_site, v_bulk, 105, 'damaged in the move');
  begin
    perform erp.reverse_opening_balances(v_stock2, 'wrong count');
    v_ok := false; v_msg := 'reversed stock that had since moved';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_OPENING_REVERSAL_BLOCKED: row 1 (WID)%'; v_msg := left(sqlerrm, 90);
  end;
  return query select 'an opening stock load is not reversed once the stock has moved', v_ok, v_msg;

  -- The write-off is dated when it happened, which is after as-at, so the
  -- as-at figure is unchanged already. Its own date, not current_date, is the
  -- day it counts from: a build that crosses midnight stamps it tomorrow.
  select max(m.occurred_at)::date into v_written_off_on
    from erp.stock_movement m
   where m.tenant_id = r.tenant_id and m.item_id = v_wid
     and m.from_location_id is not null and m.to_location_id is null;
  return query select 'the as-at stock figure ignores what happened after the date',
    v_written_off_on > v_asat
    and erp.migration_figure_stock(v_asat) = 47500
    and erp.migration_figure_stock(v_written_off_on) = 47500 - 105 * 250,
    format('as at %s: %s; written off on %s: %s', v_asat, erp.migration_figure_stock(v_asat),
           v_written_off_on, erp.migration_figure_stock(v_written_off_on));

  -- ── The parallel run ──────────────────────────────────────────────────────

  res := erp.record_parallel_run_figure('stock', v_asat, 47500, 0, 'stock valuation report, legacy');
  return query select 'a parallel-run figure records what the legacy system said against what this product computes',
    (res ->> 'our_value_minor')::bigint = 47500 and (res ->> 'difference_minor')::bigint = 0
    and (res ->> 'within_tolerance')::boolean,
    format('legacy %s, ours %s', res ->> 'legacy_value_minor', res ->> 'our_value_minor');

  res := erp.record_parallel_run_figure('sales_ledger', v_asat, 30500, 100, 'aged debtors, legacy');
  return query select 'a figure outside tolerance is recorded as such',
    not (res ->> 'within_tolerance')::boolean and (res ->> 'difference_minor')::bigint = -500,
    format('out by %s against a tolerance of %s', res ->> 'difference_minor', res ->> 'tolerance_minor');

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  begin
    perform erp.cut_over_domain('sales_ledger');
    v_ok := false; v_msg := 'cut over outside tolerance';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_CUTOVER_EVIDENCE_MISSING: sales_ledger%out by -500 against a tolerance of 100%';
    v_msg := left(sqlerrm, 120);
  end;
  return query select 'and blocks the cutover by name', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  res := erp.record_parallel_run_figure('sales_ledger', v_asat, 30000, 100, 'aged debtors, legacy, corrected');
  return query select 'recording the figure again for the same date replaces it',
    (res ->> 'within_tolerance')::boolean
    and (select count(*) from erp.parallel_run_figure f
          where f.tenant_id = r.tenant_id and f.domain_code = 'sales_ledger') = 1,
    'one figure per domain and date';

  -- ── Cutover, on evidence, by a second person ──────────────────────────────

  begin
    perform erp.cut_over_domain('stock');
    v_ok := false; v_msg := 'the loader cut over their own load';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_CUTOVER_EVIDENCE_MISSING: stock%somebody other than the person who loaded%';
    v_msg := left(sqlerrm, 120);
  end;
  return query select 'the person who loaded the balances cannot declare them right', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  res := erp.cut_over_domain('stock', 'agreed with the stock valuation report');
  return query select 'a second administrator cuts stock over, and the evidence is kept with the decision',
    res ->> 'status' = 'cut_over'
    and jsonb_array_length(res -> 'evidence' -> 'batches') = 2
    and (res -> 'evidence' -> 'figure' ->> 'our_value_minor')::bigint = 47500
    and erp.domain_is_cut_over('stock')
    and (select m.cutover_status from erp.migration_reconciliation_report() m where m.domain_code = 'stock') = 'cut_over',
    format('%s batch(es) in evidence, figure %s', jsonb_array_length(res -> 'evidence' -> 'batches'),
           res -> 'evidence' -> 'figure' ->> 'our_value_minor');

  begin
    perform erp.stage_opening_balances('stock', v_asat, '[{"item":"WID"}]'::jsonb, 1);
    v_ok := false; v_msg := 'staged over a cut-over domain';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_DOMAIN_CUT_OVER%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a cut-over domain takes no more opening balances', v_ok, v_msg;

  begin
    perform erp.reverse_opening_balances(v_stock, 'second thoughts');
    v_ok := false; v_msg := 'reversed the load a cutover stands on';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_OPENING_BATCH_CUT_OVER%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'and the load it stands on is not reversed', v_ok, v_msg;

  res := erp.cut_over_domain('sales_ledger');
  return query select 'the sales ledger cuts over on its corrected figure',
    res ->> 'status' = 'cut_over', res ->> 'cut_over_at';

  -- ── The nominal ledger cuts over last, when clearing is nothing ───────────

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  -- Clearing so far: stock 47500 credit, sales 30000 credit → 77500 credit.
  -- Trial balance: bank 100000 debit, revenue 157500 credit → net 57500 credit,
  -- so clearing takes 57500 debit and stands at 20000 credit — the purchase
  -- ledger not yet loaded.
  v_nom := erp.stage_opening_balances('nominal', v_asat, jsonb_build_array(
    jsonb_build_object('account', erp.chart_account_code('bank'), 'debit_minor', 100000),
    jsonb_build_object('account', erp.chart_account_code('revenue'), 'credit_minor', 157500),
    jsonb_build_object('account', erp.chart_account_code('trade_receivable'), 'debit_minor', 1)),
    100001, null, 'OB-TB-1');
  v_n := erp.validate_import(v_nom);
  return query select 'a trial balance row on a control account another domain loads is rejected',
    v_n = 1
    and (select r2.findings::text from erp.import_row r2 where r2.import_batch_id = v_nom and r2.row_no = 3)
        like '%receivable control account; its balance is loaded through the sales_ledger domain%',
    (select r2.findings ->> 0 from erp.import_row r2 where r2.import_batch_id = v_nom and r2.row_no = 3);

  v_nom := erp.stage_opening_balances('nominal', v_asat, jsonb_build_array(
    jsonb_build_object('account', erp.chart_account_code('bank'), 'debit_minor', 100000),
    jsonb_build_object('account', erp.chart_account_code('revenue'), 'credit_minor', 157500)),
    100000, null, 'OB-TB-2');
  perform erp.validate_import(v_nom); perform erp.preview_import(v_nom);
  v_n := erp.load_import(v_nom);
  return query select 'the trial balance loads to the nominal accounts it names, bank detail included, net to clearing',
    v_n = 2
    and (select m.reconciles from erp.migration_reconciliation_report() m where m.domain_code = 'nominal')
    and erp.migration_clearing_balance() = -20000
    and (select count(*) from erp.subledger_item s where s.tenant_id = r.tenant_id and s.control_kind = 'bank') = 1,
    format('clearing %s', erp.migration_clearing_balance());

  perform erp.record_parallel_run_figure('nominal', v_asat, erp.migration_figure_nominal(v_asat), 0);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  begin
    perform erp.cut_over_domain('nominal');
    v_ok := false; v_msg := 'cut the nominal ledger over with clearing carrying a balance';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_CUTOVER_EVIDENCE_MISSING: nominal%migration clearing carries -20000%';
    v_msg := left(sqlerrm, 140);
  end;
  return query select 'the nominal ledger is not cut over while migration clearing carries a balance', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  v_purch := erp.stage_opening_balances('purchase_ledger', v_asat, jsonb_build_array(
    jsonb_build_object('party', 'SUP', 'reference', 'PI-441', 'amount_minor', 25000, 'due_date', (v_asat + 45)::text),
    jsonb_build_object('party', 'SUP', 'reference', 'DN-3', 'amount_minor', -5000)),
    20000, null, 'OB-PURCH-1');
  perform erp.validate_import(v_purch); perform erp.preview_import(v_purch);
  v_n := erp.load_import(v_purch);
  return query select 'the purchase ledger loads, credits payables, and clearing nets to nothing',
    v_n = 2
    and erp.migration_figure_purchase_ledger(v_asat) = 20000
    and (select coalesce(sum(l.credit_minor - l.debit_minor), 0) from erp.journal_line l
          where l.tenant_id = r.tenant_id and l.account_id = v_pay) = 20000
    and erp.migration_clearing_balance() = 0,
    format('payables %s, clearing %s', erp.migration_figure_purchase_ledger(v_asat), erp.migration_clearing_balance());

  perform erp.record_parallel_run_figure('purchase_ledger', v_asat, 20000, 0);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.cut_over_domain('purchase_ledger');
  res := erp.cut_over_domain('nominal', 'trial balance agreed');
  return query select 'with the four domains agreeing, the nominal ledger cuts over and every domain reads cut over',
    res ->> 'status' = 'cut_over'
    and (res -> 'evidence' ->> 'clearing_balance_minor')::bigint = 0
    and (select count(*) from erp.migration_reconciliation_report() m where m.cutover_status = 'cut_over') = 4
    and (select count(*) from erp.migration_reconciliation_report() m where m.finding is not null) = 0,
    'four of four cut over, no finding';

  -- ── Reverting, with a reason ──────────────────────────────────────────────

  begin
    perform erp.revert_cutover('purchase_ledger', '');
    v_ok := false; v_msg := 'reverted without a reason';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_REVERT_NEEDS_REASON%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a cutover is not reverted without a reason', v_ok, v_msg;

  res := erp.revert_cutover('purchase_ledger', 'supplier statements disagree; reloading');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  v_n := erp.reverse_opening_balances(v_purch, 'reloading from corrected statements');
  return query select 'a reverted domain takes reversals and loads again',
    res ->> 'status' = 'reverted' and v_n = 2
    and not erp.domain_is_cut_over('purchase_ledger')
    and erp.migration_figure_purchase_ledger(v_asat) = 0
    and (select m.finding from erp.migration_reconciliation_report() m where m.domain_code = 'purchase_ledger') = 'no opening balances loaded',
    format('%s rows reversed; purchase ledger back to nothing', v_n);

  -- ── The doors say the same, to the people allowed to read them ────────────

  res := public.erp_migration_domains();
  return query select 'the domains door carries the register and the organisation''s standing per domain',
    jsonb_array_length(res) = 4
    and (select x ->> 'cutover_status' from jsonb_array_elements(res) x where x ->> 'domain_code' = 'stock') = 'cut_over'
    and (select x ->> 'name' from jsonb_array_elements(res) x where x ->> 'domain_code' = 'sales_ledger') = 'Sales ledger'
    and (select jsonb_array_length(x -> 'row_keys') from jsonb_array_elements(res) x where x ->> 'domain_code' = 'stock') = 7,
    format('%s domain(s)', jsonb_array_length(res));

  res := public.erp_opening_batches();
  return query select 'the batches door carries every opening load with its checks',
    jsonb_array_length(res) = 8
    and (select jsonb_array_length(x -> 'checks') from jsonb_array_elements(res) x where x ->> 'code' = 'OB-STOCK-1') = 5,
    format('%s batch(es)', jsonb_array_length(res));

  res := public.erp_invite_principal('op@zzmig.test', 'No rights');
  v_op := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.claim_invitation(v_tok);
  begin
    perform public.erp_cut_over_domain('purchase_ledger');
    v_ok := false; v_msg := 'somebody with no rights cut a domain over';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_PERMISSION_DENIED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a person without administration.configure may not cut over', v_ok, v_msg;
  begin
    perform public.erp_stage_opening_balances('stock', v_asat, '[{"item":"WID"}]'::jsonb, 1);
    v_ok := false; v_msg := 'somebody with no rights staged a load';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_PERMISSION_DENIED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor stage opening balances', v_ok, v_msg;

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  -- The loads posted journals, and the journal-balance check is a deferred
  -- constraint trigger. Fire it now, while the lines it checks still exist,
  -- rather than at commit after the organisation has gone.
  set constraints all immediate;
  perform set_config('erp.purge_tenant_id', r.tenant_id::text, true);
  delete from erp.tenant where id = r.tenant_id;
  perform set_config('erp.purge_tenant_id', '', true);
  delete from auth.users where id in (a1, a2, op);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id)
    and not exists (select 1 from auth.users u where u.id in (a1, a2, op))
    and not exists (select 1 from erp.parallel_run_figure f where f.tenant_id = r.tenant_id)
    and not exists (select 1 from erp.domain_cutover c where c.tenant_id = r.tenant_id),
    'loads, figures and cutovers go with the organisation';
end;
$$;

revoke all on function erp_test.migration_cutover_suite() from public, anon, authenticated;

-- The generators, which are idempotent and run at the end of every migration.
select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_migration_cutover_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
