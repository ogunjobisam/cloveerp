-- Goods received not invoiced is checked at the close (PR12 M1, F2).
--
-- The close's "Goods received not invoiced reviewed" was a tick. It is now a
-- check: erp.assert_grni_reconciles() asks whether three figures that ought to
-- be one agree to the penny —
--
--   * the tile's, erp.grni_report(): receipts not yet billed, today, at the
--     order line's price;
--   * the reconciliation's ledger figure, erp.grni_reconciliation(): every
--     posted line on the account, whenever it was dated;
--   * the balance sheet's, erp.statement_lines(): the statutory ledgers as at
--     today.
--
-- It is stamped on the task as a close raises it, by code, the way
-- 20260918400000 stamps the four ties, so no organisation's configuration is
-- written and an organisation configured before this carries the check from
-- its next opened close. It stays waivable with a reason (D1): a difference
-- somebody understands — the residue bills left before procurement-controls v4,
-- say — costs one press with the difference recorded, not a locked month.
--
-- It is not in the deploy's whole-database gate (D2). That gate runs every
-- tenant-scoped assertion in erp_meta.diagnostic_check over every
-- organisation, and one live organisation carrying a residue would stop every
-- deploy. It is registered as a report the diagnostics screen can run, and
-- supabase/ops/20260929_grni_residue.sql lists, outside the build, the lines on the
-- account that erp.grni_report() cannot explain.
--
-- The tile that read "open on the balance sheet" said something true only
-- while nothing parted the figures. It now says which question it answers.
--
-- Proved by erp_test.period_close_suite.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The check
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.assert_grni_reconciles()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_code   text;
  v_ledger bigint;
  v_open   bigint;
  v_sheet  bigint;
  v_on     date := current_date;
  v_by     text;
begin
  -- The account by purpose, as the reconciliation asks for it: 2100 under the
  -- default chart, 3200 under §8.1's.
  v_code := erp.tenant_account_code('goods_received_not_invoiced');

  -- The tile's figure. The report is the tile's source, row for row.
  select coalesce(sum(g.open_value_minor), 0)::bigint into v_open
    from erp.grni_report() g;

  -- The reconciliation's. No row is an organisation with no such account,
  -- whose ledger holds nothing on it.
  select coalesce(max(r.ledger_minor), 0)::bigint into v_ledger
    from erp.grni_reconciliation() r;

  -- The balance sheet's: the statutory ledgers, as at today, every centre. By
  -- ledger code, once each, because two companies may both call theirs GL and
  -- the statement already reads every ledger of that code.
  select coalesce(sum(s.credit_minor - s.debit_minor), 0)::bigint into v_sheet
    from (select distinct l.code
            from erp.ledger l
           where l.tenant_id = v_tenant
             and l.ledger_kind = 'statutory'
             and l.status = 'active') lc
   cross join lateral erp.statement_lines(null, v_on, lc.code, null) s
   where s.account_code = v_code;

  if v_ledger = v_open and v_sheet = v_open then
    return format('grni: %s reconciles — open receipts %s, ledger %s, balance sheet at %s %s',
                  v_code, v_open, v_ledger, v_on, v_sheet);
  end if;

  -- What is on the account, by what put it there, so the difference can be
  -- read against the causes the hint names without another query.
  select string_agg(format('%s%s %s (%s line(s))',
                           x.source, coalesce(' v' || x.version, ''),
                           x.amount, x.lines), '; ' order by x.source, x.version)
    into v_by
    from (select coalesce(pr.code, j.source_code, 'unnamed') as source,
                 l.posting_rule_version as version,
                 sum(l.credit_minor - l.debit_minor)::bigint as amount,
                 count(*) as lines
            from erp.journal_line l
            join erp.journal j on j.id = l.journal_id and j.status = 'posted'
            join erp.account a on a.id = l.account_id
            left join erp.posting_rule pr on pr.id = l.posting_rule_id
           where l.tenant_id = v_tenant
             and a.tenant_id = v_tenant
             and a.code = v_code
           group by 1, 2) x;

  raise exception 'CLOVEERP_GRNI_DOES_NOT_RECONCILE: % — open receipts %, ledger % (out by %), balance sheet at % % (out by %); on the account: %',
    v_code, v_open, v_ledger, v_ledger - v_open, v_on, v_sheet, v_sheet - v_open,
    coalesce(v_by, 'nothing posted')
    using errcode = '23514',
          hint = 'Four things part these figures. '
                 '(1) Bills registered before procurement-controls v4 cleared the account at the bill''s price: '
                 'the purchase_invoice lines by version above, cleared with a journal. '
                 '(2) Consignment consumption credits it with no order line behind it: the consignment_consumption lines above. '
                 '(3) An order line re-priced after it was received: select * from erp.grni_report() against the receipts'' journals. '
                 '(4) A posting dated after today: the balance sheet against the ledger. '
                 'supabase/ops/20260929_grni_residue.sql lists the lines erp.grni_report() cannot explain. '
                 'Post the correction, or waive the close task with a reason that says which of these it is.';
end;
$$;

revoke all on function erp.assert_grni_reconciles() from public, anon;

comment on function erp.assert_grni_reconciles() is
  'Goods received not invoiced three ways, to the penny: the receipts still open at order price today '
  '(the purchasing tile, erp.grni_report()), every posted line on the account (erp.grni_reconciliation()), '
  'and the statutory balance sheet as at today (erp.statement_lines()). Refuses naming all three, what '
  'posted to the account by rule and version, and the four causes that part them. The check on the '
  'close''s grni_reviewed task, which stays waivable (20260929000000); a report in the diagnostics '
  'register, not a deploy gate.';

-- The refusal is not registered in erp_ref.refusal. It is raised only by an
-- assert_ routine, which erp.refusal_report() does not count as a raise, so a
-- register row would read as raised nowhere and refuse the migration. Its next
-- action travels as the hint, as erp.assert_ageing_equals_control()'s does
-- (20260918510000).

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The close carries it, and it stays waivable
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.close_shipped_check(p_task_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case lower(btrim(coalesce(p_task_code, '')))
           when 'grni_reviewed' then 'erp.assert_grni_reconciles()'
         end
$$;

revoke all on function erp.close_shipped_check(text) from public, anon;

comment on function erp.close_shipped_check(text) is
  'The blocking check a close task of this code is raised with when it names none of its own, and '
  'which is not a tie: goods received not invoiced (20260929000000). A tie is erp.close_tie_check()''s '
  'and is never waived; this one is stamped the same way, as the task is raised, and stays waivable.';

-- The trigger that stamps the ties stamps this too. On insert only, and only
-- where the row names no check: a task raised before this that is still open
-- is completed as it was raised rather than recorded as checked when nothing
-- ran, and an organisation that gave the task a check of its own keeps it.
do $stamp$
declare
  v_sig constant text := 'erp.set_close_task_tie()';
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if v_tie is not null then
    new.blocking_check := v_tie;
  end if;
$o$;
  v_new constant text := $n$  if v_tie is not null then
    new.blocking_check := v_tie;
  elsif tg_op = 'INSERT' and nullif(btrim(coalesce(new.blocking_check, '')), '') is null then
    -- A check the product ships on a task that is not a tie, stamped as the
    -- task is raised (20260929000000): goods received not invoiced. The
    -- waivable rule below is unchanged, so it can still be waived.
    new.blocking_check := coalesce(erp.close_shipped_check(new.code), new.blocking_check);
  end if;
$n$;
  v_hits integer;
begin
  if position('erp.close_shipped_check(' in v_def) > 0 then
    raise notice '% already stamps the shipped checks; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % tie stamp found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$stamp$;

-- And a new install's template carries it, so the checklist it is shown says
-- what will be asked.
do $template$
declare
  v_sig constant text := 'erp.configure_period_close()';
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$          'code','grni_reviewed','name','Goods received not invoiced reviewed',
          'seq',40, 'depends_on', jsonb_build_array('subledgers_reconcile'))),
$o$;
  v_new constant text := $n$          'code','grni_reviewed','name','Goods received not invoiced reviewed',
          'seq',40, 'depends_on', jsonb_build_array('subledgers_reconcile'),
          'blocking_check','erp.assert_grni_reconciles()')),
$n$;
  v_hits integer;
begin
  if position('erp.assert_grni_reconciles()' in v_def) > 0 then
    raise notice '% already ships the GRNI check; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % grni_reviewed task found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$template$;

comment on function erp.configure_period_close() is
  'The six close tasks the product ships, as one promoted change set. Four of '
  'them carry the four v1 ties and are stamped unwaivable as they land: the '
  'trial balance (20260918400000), the inventory valuation against its control '
  'account, the subledgers against theirs, and the ageing against the debtors '
  'and creditors accounts (20260918500000). Goods received not invoiced carries '
  'erp.assert_grni_reconciles() and stays waivable (20260929000000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Registered for reading, not for the deploy
-- ═════════════════════════════════════════════════════════════════════════════

-- A report, so erp.assert_whole_database_reconciles() and
-- erp.platform_assurance() (both read kind = 'assertion') do not run it over
-- every organisation (D2); tenant-scoped, so erp.ci_check_catalogue() does not
-- run it with no organisation, where it would refuse. The diagnostics screen
-- runs it inside an organisation, and shows the reconciliation when it fails.
insert into erp_meta.diagnostic_check (
  code, title, kind, scope, schema_name, function_name, arguments,
  detail_function, detail_arguments, blurb, runs_in_ci, seq,
  book_tie_name, book_tie_next_action)
values (
  'grni_reconciles', 'Goods received not invoiced reconciles', 'report', 'tenant', 'erp',
  'assert_grni_reconciles', '', 'grni_reconciliation', '',
  'The receipts still open at order price, the ledger balance on the goods received not invoiced '
  'account, and the balance sheet as at today, to the penny. The check on the close''s GRNI task, '
  'where a difference that is understood is waived with a reason; a report here rather than a gate, '
  'because a residue from before procurement-controls v4 is a journal somebody posts, not a build failure.',
  false, 44, null, null)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq,
  book_tie_name = excluded.book_tie_name, book_tie_next_action = excluded.book_tie_next_action;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The tile says which question it answers
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The purchasing tile''s value of what is received and not yet billed, which is the order price of what is open today, not a balance sheet figure (20260929000000).'
  from (values
    ('open receipts at order price, today')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.period_close_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 15;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid; v_entity uuid; v_ledger uuid; v_ccy char(3);
  v_p1 uuid; v_p2 uuid; v_p3 uuid;
  v_uom uuid; v_site uuid; v_sup uuid; v_item uuid;
  v_po uuid; v_pol uuid; v_grn uuid;
  v_grni text; v_grni_id uuid; v_cos uuid;
  v_j uuid; v_on date; v_later date;
  v_tmpl record; v_task record;
  v_t1_sub uuid; v_t1_grni uuid; v_t2_sub uuid; v_t2_grni uuid;
  v_raised integer;
  v_ok text; v_bad text; v_tick text; v_waive text; v_nobody text; v_diag jsonb;
  v_open bigint;
  v_job  text;
  v_owner text := current_user;
begin
  begin
    -- ── The fixture: an organisation that buys, receives and closes ────────
    v_step := 'an organisation with finance, procurement, inventory, controls and the close';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzpcs-' || v_tag, 'Period Close Suite',
      'admin@zzpcs-' || v_tag || '.test', 'Period Close Admin');
    v_tenant := rb.tenant_id;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzpcs-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();
    perform erp.configure_period_close();

    v_step := 'the ledger, its periods and the accounts';
    select l.entity_id, l.id, l.currency into v_entity, v_ledger, v_ccy
      from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
    select fp.id into strict v_p1 from erp.fiscal_period fp
     where fp.tenant_id = v_tenant and fp.ledger_id = v_ledger
       and current_date between fp.starts_on and fp.ends_on;
    select fp.id into strict v_p2 from erp.fiscal_period fp
     where fp.tenant_id = v_tenant and fp.ledger_id = v_ledger and fp.id <> v_p1
     order by fp.starts_on limit 1;
    select fp.id into strict v_p3 from erp.fiscal_period fp
     where fp.tenant_id = v_tenant and fp.ledger_id = v_ledger and fp.id not in (v_p1, v_p2)
     order by fp.starts_on limit 1;
    v_grni := erp.tenant_account_code('goods_received_not_invoiced');
    select a.id into strict v_grni_id from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = v_grni;
    select a.id into strict v_cos from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity
       and a.code = erp.tenant_account_code('cost_of_sales');

    v_step := 'a supplier, a product, and a hundred of them received on a ten-pound order';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = v_tenant and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (v_tenant, 'ZCEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (v_tenant, v_entity, 'ZCSITE', 'Period close suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZC-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZC-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZCSUP', 'Period Close Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZCWID', 'Period Close Suite Widget', v_uom, 'active')
    returning id into v_item;
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred widgets at ten pounds');
    perform erp.transition_document(v_po, 'submit', 'period close suite');
    perform erp_test.approve_document(v_po, 'period close suite');
    perform erp.transition_document(v_po, 'send', 'period close suite');
    v_grn := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 100, null);
    perform erp.transition_document(v_grn, 'post', 'period close suite');
    select coalesce(sum(g.open_value_minor), 0) into v_open from erp.grni_report() g;

    -- ── 1. The checklist carries the check, and it is not a tie ─────────────
    v_step := 'the close raised on this month';
    v_raised := erp.open_period_close(v_p1);
    select ct.blocking_check, ct.is_waivable into v_tmpl
      from erp.close_task_template ct
     where ct.tenant_id = v_tenant and ct.code = 'grni_reviewed';
    select t.id, t.blocking_check, t.is_waivable, t.status into v_task
      from erp.close_task t where t.fiscal_period_id = v_p1 and t.code = 'grni_reviewed';
    v_t1_grni := v_task.id;
    select t.id into v_t1_sub from erp.close_task t
     where t.fiscal_period_id = v_p1 and t.code = 'subledgers_reconcile';

    v_cases := v_cases + 1;
    case_name := 'a raised grni_reviewed carries erp.assert_grni_reconciles() and stays waivable, and the ties are still four';
    passed := v_state is null
          and v_raised = 6
          and v_tmpl.blocking_check = 'erp.assert_grni_reconciles()'
          and v_tmpl.is_waivable
          and v_task.blocking_check = 'erp.assert_grni_reconciles()'
          and v_task.is_waivable
          and v_task.status = 'open'
          and not erp.close_check_is_a_tie(v_task.blocking_check)
          and erp.close_tie_check('grni_reviewed') is null
          and (select count(*) from erp.close_task t
                where t.fiscal_period_id = v_p1 and not t.is_waivable) = 4;
    detail := coalesce(v_state, format('%s raised; template %s (waivable %s); task %s (waivable %s, %s); %s unwaivable',
      v_raised, v_tmpl.blocking_check, v_tmpl.is_waivable, v_task.blocking_check, v_task.is_waivable,
      v_task.status,
      (select count(*) from erp.close_task t where t.fiscal_period_id = v_p1 and not t.is_waivable)),
      'no answer');
    return next;

    -- ── 2. Books that reconcile say so, three ways ─────────────────────────
    v_step := 'the check on books that reconcile';
    v_ok := erp.assert_grni_reconciles();

    v_cases := v_cases + 1;
    case_name := 'on books that reconcile the check passes, naming the account and the tile''s, the ledger''s and the balance sheet''s figure';
    passed := v_state is null
          and v_open = 100000
          and v_ok = format('grni: %s reconciles — open receipts 100000, ledger 100000, balance sheet at %s 100000',
                            v_grni, current_date);
    detail := coalesce(v_state, v_ok, 'no answer');
    return next;

    -- ── 3. A journal nothing received explains ─────────────────────────────
    --
    -- The spec's £957: money on the account with no receipt behind it.
    v_step := 'a journal on the GRNI account that no receipt explains';
    perform erp.complete_close_task(v_t1_sub);
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZPCS-PLANT', 'draft',
            'suite: a credit to GRNI with no receipt behind it')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_cos, 95700, 0, v_ccy, 95700, 0, 1),
           (v_tenant, v_j, 2, v_grni_id, 0, 95700, v_ccy, 0, 95700, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    begin
      v_bad := 'passed: ' || erp.assert_grni_reconciles();
    exception when others then
      v_bad := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'a journal on the account that no receipt explains fails the check, naming the three figures, the difference and what posted it';
    passed := v_state is null
          and v_bad like 'CLOVEERP_GRNI_DOES_NOT_RECONCILE: ' || v_grni || ' — open receipts 100000, ledger 195700 (out by 95700), balance sheet at % 195700 (out by 95700)%'
          and v_bad like '%manual 95700 (1 line(s))%'
          and v_bad like '%goods_receipt v% 100000 (1 line(s))%';
    detail := coalesce(v_state, left(v_bad, 400), 'no answer');
    return next;

    -- ── 4. The close will not tick past it ─────────────────────────────────
    v_step := 'the GRNI task ticked while the account is out';
    begin
      perform erp.complete_close_task(v_t1_grni);
      v_tick := 'the task was ticked over a difference';
    exception when others then
      v_tick := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'the close will not tick the task past the difference, and says what the check said';
    passed := v_state is null
          and v_tick like 'CLOVEERP_CLOSE_CHECK_FAILED: erp.assert_grni_reconciles() — CLOVEERP_GRNI_DOES_NOT_RECONCILE:%out by 95700%'
          and (select t.status from erp.close_task t where t.id = v_t1_grni) = 'open'
          and (select cs.check_passes from erp.close_status(v_p1) cs where cs.code = 'grni_reviewed') is false;
    detail := coalesce(v_state, left(v_tick, 400), 'no answer');
    return next;

    -- ── 5. Waived with a reason ────────────────────────────────────────────
    v_step := 'the GRNI task waived with a reason';
    v_waive := erp.complete_close_task(v_t1_grni, 'Residue from bills before procurement-controls v4; journal next month');
    select t.status, t.waiver_reason, t.check_output into v_task
      from erp.close_task t where t.id = v_t1_grni;

    v_cases := v_cases + 1;
    case_name := 'waived with a reason it passes, and the task records the difference the check found';
    passed := v_state is null
          and v_task.status = 'waived'
          and v_task.waiver_reason like 'Residue from bills%'
          and v_task.check_output like 'FAILED: CLOVEERP_GRNI_DOES_NOT_RECONCILE:%out by 95700%'
          and v_waive = v_task.check_output;
    detail := coalesce(v_state, format('%s: %s', v_task.status, left(v_task.check_output, 300)), 'no answer');
    return next;

    -- ── 6. Reversed, it reconciles again ───────────────────────────────────
    v_step := 'the plant reversed';
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZPCS-REVERSE', 'draft',
            'suite: the correction')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_grni_id, 95700, 0, v_ccy, 95700, 0, 1),
           (v_tenant, v_j, 2, v_cos, 0, 95700, v_ccy, 0, 95700, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    begin
      v_ok := erp.assert_grni_reconciles();
    exception when others then
      v_ok := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'once the correction is posted the three figures agree again';
    passed := v_state is null and v_ok like 'grni: ' || v_grni || ' reconciles — open receipts 100000, ledger 100000,%';
    detail := coalesce(v_state, left(v_ok, 300), 'no answer');
    return next;

    -- ── 7. An organisation configured before this ──────────────────────────
    --
    -- Its template names no check: the product shipped none. Nothing rewrites
    -- it, and its next close raises the task with the check all the same.
    v_step := 'a template from before the check, and its next close';
    update erp.close_task_template set blocking_check = null, updated_at = now()
     where tenant_id = v_tenant and code = 'grni_reviewed';
    select ct.blocking_check, ct.is_waivable into v_tmpl
      from erp.close_task_template ct
     where ct.tenant_id = v_tenant and ct.code = 'grni_reviewed';
    perform erp.open_period_close(v_p2);
    select t.id, t.blocking_check, t.is_waivable, t.status into v_task
      from erp.close_task t where t.fiscal_period_id = v_p2 and t.code = 'grni_reviewed';
    v_t2_grni := v_task.id;
    select t.id into v_t2_sub from erp.close_task t
     where t.fiscal_period_id = v_p2 and t.code = 'subledgers_reconcile';

    v_cases := v_cases + 1;
    case_name := 'the template of an organisation configured before this is left as it is, and its next raised task still carries the check';
    passed := v_state is null
          and v_tmpl.blocking_check is null
          and v_tmpl.is_waivable
          and v_task.blocking_check = 'erp.assert_grni_reconciles()'
          and v_task.is_waivable
          and v_task.status = 'open';
    detail := coalesce(v_state, format('template %s; raised %s (waivable %s, %s)',
      coalesce(v_tmpl.blocking_check, 'no check'), v_task.blocking_check, v_task.is_waivable, v_task.status),
      'no answer');
    return next;

    -- ── 8. Clean books complete it ─────────────────────────────────────────
    v_step := 'the GRNI task completed on clean books';
    perform erp.complete_close_task(v_t2_sub);
    v_ok := erp.complete_close_task(v_t2_grni);
    select t.status, t.waiver_reason, t.check_output into v_task
      from erp.close_task t where t.id = v_t2_grni;

    v_cases := v_cases + 1;
    case_name := 'on clean books the check runs and the task completes, with what the check said recorded';
    passed := v_state is null
          and v_task.status = 'complete'
          and v_task.waiver_reason is null
          and v_task.check_output like 'grni: ' || v_grni || ' reconciles%'
          and v_ok = v_task.check_output;
    detail := coalesce(v_state, format('%s: %s', v_task.status, v_task.check_output), 'no answer');
    return next;

    -- ── 9. A check of the organisation's own is kept ───────────────────────
    v_step := 'a template naming a check of its own';
    update erp.close_task_template set blocking_check = 'erp.assert_stock_reconciles()', updated_at = now()
     where tenant_id = v_tenant and code = 'grni_reviewed';
    perform erp.open_period_close(v_p3);
    select t.blocking_check, t.is_waivable into v_task
      from erp.close_task t where t.fiscal_period_id = v_p3 and t.code = 'grni_reviewed';

    v_cases := v_cases + 1;
    case_name := 'an organisation that gave the task a check of its own keeps it, and it stays waivable';
    passed := v_state is null
          and v_task.blocking_check = 'erp.assert_stock_reconciles()'
          and v_task.is_waivable;
    detail := coalesce(v_state, format('raised with %s (waivable %s)', v_task.blocking_check, v_task.is_waivable),
      'no answer');
    return next;

    -- ── 10. The balance sheet is a figure of its own ───────────────────────
    --
    -- Money taken off the account today and put back tomorrow nets to nothing
    -- on the ledger, so the reconciliation reads zero; the balance sheet as at
    -- today does not, and the check says so.
    v_step := 'a posting today undone by one dated tomorrow';
    v_on := current_date;
    v_later := current_date + 1;
    if not exists (select 1 from erp.fiscal_period fp
                    where fp.tenant_id = v_tenant and fp.ledger_id = v_ledger
                      and v_later between fp.starts_on and fp.ends_on) then
      insert into erp.fiscal_period (tenant_id, ledger_id, code, fiscal_year, period_number,
                                     starts_on, ends_on, status)
      values (v_tenant, v_ledger, 'ZZ-' || to_char(v_later, 'YYYY-MM'),
              extract(year from v_later)::integer, 1::smallint,
              date_trunc('month', v_later)::date,
              (date_trunc('month', v_later) + interval '1 month - 1 day')::date, 'open');
    end if;
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', v_on, 'ZZPCS-TODAY', 'draft', 'suite: off today')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_grni_id, 500, 0, v_ccy, 500, 0, 1),
           (v_tenant, v_j, 2, v_cos, 0, 500, v_ccy, 0, 500, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', v_later, 'ZZPCS-TOMORROW', 'draft', 'suite: back tomorrow')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_cos, 500, 0, v_ccy, 500, 0, 1),
           (v_tenant, v_j, 2, v_grni_id, 0, 500, v_ccy, 0, 500, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    begin
      v_bad := 'passed: ' || erp.assert_grni_reconciles();
    exception when others then
      v_bad := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'a posting the ledger nets away by a later date still fails, because the balance sheet as at today is out';
    passed := v_state is null
          and (select r.difference_minor from erp.grni_reconciliation() r) = 0
          and v_bad like 'CLOVEERP_GRNI_DOES_NOT_RECONCILE: %ledger 100000 (out by 0), balance sheet at % 99500 (out by -500)%';
    detail := coalesce(v_state, left(v_bad, 400), 'no answer');
    return next;

    -- ── 11. §8.1's chart: GRNI is 3200 ─────────────────────────────────────
    v_step := 'the account renumbered as §8.1 numbers it';
    -- Both undone: put back today, taken off again tomorrow.
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', v_on, 'ZZPCS-BACK', 'draft', 'suite: back today')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_cos, 500, 0, v_ccy, 500, 0, 1),
           (v_tenant, v_j, 2, v_grni_id, 0, 500, v_ccy, 0, 500, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', v_later, 'ZZPCS-OFF', 'draft', 'suite: off tomorrow')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (v_tenant, v_j, 1, v_grni_id, 500, 0, v_ccy, 500, 0, 1),
           (v_tenant, v_j, 2, v_cos, 0, 500, v_ccy, 0, 500, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;
    update erp.account a set code = '3200', updated_at = now()
     where a.tenant_id = v_tenant and a.id = v_grni_id;
    begin
      v_ok := erp.assert_grni_reconciles();
    exception when others then
      v_ok := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'on §8.1''s chart the check finds GRNI at 3200 by its purpose and reconciles it there';
    passed := v_state is null
          and erp.tenant_account_code('goods_received_not_invoiced') = '3200'
          and v_ok like 'grni: 3200 reconciles — open receipts 100000, ledger 100000, balance sheet at % 100000';
    detail := coalesce(v_state, left(v_ok, 300), 'no answer');
    return next;

    -- ── 12. Registered for reading, not for the deploy ─────────────────────
    v_step := 'the registers';
    v_diag := erp.run_diagnostic('grni_reconciles');

    v_cases := v_cases + 1;
    case_name := 'the check is a report the diagnostics screen runs in an organisation, outside the whole-database gate and the structural phase';
    passed := v_state is null
          and exists (select 1 from erp_meta.diagnostic_check d
                       where d.code = 'grni_reconciles' and d.kind = 'report' and d.scope = 'tenant'
                         and d.schema_name = 'erp' and d.function_name = 'assert_grni_reconciles'
                         and d.detail_function = 'grni_reconciliation'
                         and not d.runs_in_ci and d.book_tie_name is null)
          and not exists (select 1 from erp_meta.diagnostic_check d
                           where d.function_name = 'assert_grni_reconciles' and d.kind = 'assertion')
          and not exists (select 1 from erp.ci_check_catalogue() c
                           where c.qualified_name = 'erp.assert_grni_reconciles')
          and (v_diag ->> 'ok')::boolean
          and v_diag ->> 'summary' like 'grni: 3200 reconciles%'
          and not exists (select 1 from erp_ref.refusal f where f.code = 'CLOVEERP_GRNI_DOES_NOT_RECONCILE')
          and position('supabase/ops/20260929_grni_residue.sql' in
                       pg_get_functiondef('erp.assert_grni_reconciles()'::regprocedure)) > 0;
    detail := coalesce(v_state, format('diagnostic: %s', left(v_diag::text, 300)), 'no answer');
    return next;

    -- ── 13. Nobody's books ─────────────────────────────────────────────────
    v_step := 'the check with no organisation';
    v_job := current_setting('erp.job_tenant_id', true);
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    begin
      v_nobody := 'passed: ' || erp.assert_grni_reconciles();
    exception when others then
      v_nobody := sqlerrm;
    end;
    perform set_config('erp.job_tenant_id', coalesce(v_job, ''), true);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_cases := v_cases + 1;
    case_name := 'with no organisation the check refuses rather than reconciling nothing';
    passed := v_state is null and v_nobody like 'CLOVEERP_NO_TENANT_CONTEXT:%';
    detail := coalesce(v_state, left(v_nobody, 200), 'no answer');
    return next;

    -- ── 14. The tile's words ───────────────────────────────────────────────
    v_step := 'the tile''s words';
    v_cases := v_cases + 1;
    case_name := 'the purchasing tile says it counts open receipts at order price today, and the words can be renamed';
    passed := v_state is null
          and exists (select 1 from erp_ref.resource r
                       where r.key = erp_ref.ui_key('open receipts at order price, today')
                         and r.locale = 'en' and r.value = 'open receipts at order price, today');
    detail := coalesce(v_state, 'erp_ref.resource holds the tile''s hint', 'no answer');
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzpcs-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1)
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzpcs rolled back with its receipt, journals, periods and close');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PERIOD_CLOSE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.period_close_suite() from public, anon;

comment on function erp_test.period_close_suite() is
  'The period close (20260929000000, PR12 M1): grni_reviewed is raised with erp.assert_grni_reconciles() '
  'and stays waivable; clean books complete it; a journal no receipt explains fails it naming the three '
  'figures, and the close will not tick past it; a waiver records the difference; a template from '
  'before is left alone and its next close still carries the check; an organisation''s own check is '
  'kept; the balance sheet as at today is a figure of its own; §8.1''s 3200; a report, not a gate.';

create or replace function erp_test.assert_period_close_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.period_close_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PERIOD_CLOSE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A close task was raised, checked, ticked or waived other than the checklist says. Read the case that failed.';
  end if;
  if v_total <> 15 then
    raise exception 'CLOVEERP_PERIOD_CLOSE_SUITE_SHRANK: % case(s), expected 15', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('period close: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_period_close_suite() from public, anon;

comment on function erp_test.assert_period_close_suite() is
  'The close''s GRNI task is checked, stays waivable, and is stamped on every organisation''s next close '
  'without a configuration write (20260929000000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Re-pinned on purpose: every task on the close now has a check
-- ═════════════════════════════════════════════════════════════════════════════

-- erp_test.finance_depth_suite() counted five tasks whose check the close
-- screen can show before it is needed. Goods received not invoiced is the
-- sixth, so it counts six.
do $depth$
declare
  v_sig constant text := 'erp_test.finance_depth_suite()';
  v_def text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$      where cs.check_passes is not null) = 5,
    'every task shows whether its check would pass right now, the trial balance among them since 20260918400000 and the ageing since 20260918500000';$o$;
  v_new constant text := $n$      where cs.check_passes is not null) = 6,
    'every task shows whether its check would pass right now, the trial balance among them since 20260918400000, the ageing since 20260918500000 and goods received not invoiced since 20260929000000';$n$;
  v_hits integer;
begin
  if position('goods received not invoiced since 20260929000000' in v_def) > 0 then
    raise notice '% already counts six; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % close-status count found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$depth$;

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
