set lock_timeout = '30s';

-- =============================================================================
-- 20261010180000  A demonstration keeps its books tidy
-- -----------------------------------------------------------------------------
-- Found walking the demonstration live on 7 October, after its year of
-- history finished building. The Definition of Done asks for "a seeded demo
-- tenant with a month of believable transactions", and these were not:
--
--   all twelve customers in dunning, £259,264 more than sixty days overdue
--   out of £506,597 owed, the longest 213 days; and 58 receipts never billed,
--   the oldest 401 days, £202,479 of goods received not invoiced.
--
-- Reproduced on a copy of the build's seeded organisation extended by three
-- months: 55 receipt lines unbilled, the oldest 369 days, and all twelve
-- customers more than sixty days overdue.
--
-- Why. The builder pays about four invoices in five and never the fifth, so
-- every customer's unpaid fifth piles up for a year. It bills one receipt a
-- week, on Thursdays, while replenishment brings several. The catch-up bills
-- the rest, but only a receipt whose order lines have nothing billed at all,
-- so the second receipt of an order received in two parts, the first part
-- billed, is never billed. Real trading settles nearly everything: a few
-- customers pay late, and a supplier's bill follows its goods.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.tidy_demonstration_books(day), in a demonstration that is not
--      live, through the product's own doors and dated that day:
--        every posted receipt a week old or more that no bill names, and
--        whose order lines are not already billed in full, is billed as the
--        catch-up bills one: dated a week after the goods arrived, or the day
--        where the books no longer take that date, the supplier's VAT stated
--        first, then registered;
--        every customer pays what fell due more than thirty days ago, except
--        about one in four, the slow payers, who pay what fell due more than
--        ninety. So the dunning screens still have customers on them, and
--        none is two hundred days behind.
--      Nothing here draws on random(), so a day the builder builds is what
--      it was.
--   B. erp.seed_demo_history() has its customers pay on each month's pay
--      day, before the month's supplier payments, so a demonstration built
--      from now on stays believable. Its receipts are left to the catch-up,
--      which bills what the builder leaves (erp_test.
--      demonstration_catch_up_bills_suite proves how it dates them).
--   C. erp.demonstration_catch_up() tidies on the last day it trades, before
--      what the month ends left owing is paid, so the demonstration that
--      exists is put right by its next catch-up, which every release runs.
--      Its own pass bills only a receipt whose order lines have nothing
--      billed at all; the tidy bills the rest, the later receipts of orders
--      received in parts, dated by the same rule, and they are counted as the
--      catch-up's bills.
--   D. erp_test.tidy_demonstration_books_suite proves it.
--
-- Production: production makes no demonstrations (20261010061000). On the
-- demonstration project, the next catch-up dates the tidy on its last trading
-- day, in the month still open.
--
-- Proof: erp_test.tidy_demonstration_books_suite.
-- =============================================================================

create or replace function erp.tidy_demonstration_books(p_day date, p_bill boolean default true)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_ccy       char(3);
  g           record;
  c           record;
  v_bill      uuid;
  v_billed    integer := 0;
  v_refused   integer := 0;
  v_paid      integer := 0;
  v_paid_minor bigint := 0;
  v_note      text;
  v_bill_on   date;
begin
  if not erp.tenant_is_demonstration(v_tenant)
     or exists (select 1 from erp.environment e
                 where e.tenant_id = v_tenant and e.is_self and e.is_live) then
    return jsonb_build_object('tidied', false);
  end if;

  -- ── The bills that follow their goods ─────────────────────────────────────
  for g in
    select d.id, d.document_number, d.document_date, d.entity_id
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = v_tenant
       and dt.code = 'goods_receipt'
       and not d.is_cancelled
       and d.stock_owner_party_id is null
       and d.document_date <= p_day - 7
       and erp.object_current_state('document', d.id) = 'posted'
       and exists (select 1 from erp.document_relation fr
                    where fr.tenant_id = d.tenant_id and fr.from_document_id = d.id
                      and fr.relation_kind = 'fulfils' and fr.to_line_id is not null)
       -- No bill names it yet.
       and not exists (select 1 from erp.document_relation r
                         join erp.document b on b.tenant_id = r.tenant_id and b.id = r.from_document_id
                         join erp.document_type bt on bt.tenant_id = b.tenant_id and bt.id = b.document_type_id
                        where r.tenant_id = d.tenant_id and r.to_document_id = d.id
                          and r.relation_kind = 'invoices' and bt.code = 'purchase_invoice'
                          and not b.is_cancelled)
       -- None of the order lines it arrived against is billed in full
       -- already, so billing it cannot bill more than arrived.
       and not exists (select 1 from erp.document_relation fr
                         join erp.document_line ol on ol.tenant_id = fr.tenant_id and ol.id = fr.to_line_id
                        where fr.tenant_id = d.tenant_id and fr.from_document_id = d.id
                          and fr.relation_kind = 'fulfils'
                          and coalesce(ol.quantity_invoiced, 0) >= coalesce(ol.quantity_fulfilled, 0))
       -- Nothing on its way back to the supplier.
       and not exists (select 1 from erp.document_line gl
                         join erp.document_relation rr
                           on rr.tenant_id = gl.tenant_id and rr.to_line_id = gl.id and rr.relation_kind = 'returns'
                        where gl.tenant_id = d.tenant_id and gl.document_id = d.id)
     order by d.document_date, d.document_number
  loop
    exit when not p_bill;
    begin
      -- Dated as the catch-up dates a bill (20261010052000): a week after the
      -- goods arrived, never after the day; the day itself where the books
      -- no longer take that date, a month of the company's ledgers closed or
      -- a VAT return it finalised covering it.
      v_bill_on := least(g.document_date + 7, p_day);
      if v_bill_on < p_day and (
           exists (select 1 from erp.ledger l
                    where l.tenant_id = v_tenant and l.entity_id = g.entity_id and l.status = 'active'
                      and not exists (select 1 from erp.fiscal_period fp
                                       where fp.tenant_id = l.tenant_id and fp.ledger_id = l.id
                                         and v_bill_on between fp.starts_on and fp.ends_on
                                         and erp.period_accepts_postings(fp.id)))
        or exists (select 1 from erp.document vr
                     join erp.document_type vt on vt.tenant_id = vr.tenant_id and vt.id = vr.document_type_id
                      and vt.base_type_code = 'vat_return'
                    where vr.tenant_id = v_tenant and vr.entity_id = g.entity_id and not vr.is_cancelled
                      and (vr.attributes #>> '{vat_return,period_end}')::date >= v_bill_on
                      and erp.object_current_state('document', vr.id) = 'finalised')) then
        v_bill_on := p_day;
      end if;
      v_bill := erp.bill_from_receipt(g.id, 'INV/' || g.document_number, v_bill_on, v_bill_on + 30, false);
      perform erp.state_demonstration_input_tax(v_bill);
      perform erp.transition_document(v_bill, 'register', 'billed from ' || g.document_number);
      v_billed := v_billed + 1;
    exception when others then
      v_refused := v_refused + 1;
      v_note := coalesce(v_note, format('%s was not billed: %s', g.document_number, left(sqlerrm, 160)));
    end;
  end loop;

  -- ── The customers who pay ─────────────────────────────────────────────────
  select e.base_currency into v_ccy
    from erp.entity e where e.tenant_id = v_tenant and e.status = 'active'
   order by e.code limit 1;

  for c in
    select o.party_id, sum(o.owing_minor)::bigint as owing
      from erp.open_receivables(v_ccy) o
      join erp.party p on p.tenant_id = v_tenant and p.id = o.party_id
     where o.owing_minor > 0
       and o.due_date < p_day - case when abs(hashtext(p.code)) % 4 = 0 then 90 else 30 end
     group by o.party_id
     order by o.party_id
  loop
    begin
      perform erp.apply_cash(c.party_id, c.owing, v_ccy, 'Remittance ' || to_char(p_day, 'DDMMYY'), p_day);
      v_paid := v_paid + 1;
      v_paid_minor := v_paid_minor + c.owing;
    exception when others then
      v_note := coalesce(v_note, format('a customer''s remittance was not applied: %s', left(sqlerrm, 160)));
    end;
  end loop;

  return jsonb_build_object(
    'tidied', true, 'day', p_day,
    'bills', v_billed, 'bills_refused', v_refused,
    'customers_paid', v_paid, 'paid_minor', v_paid_minor,
    'note', v_note);
end;
$$;

revoke all on function erp.tidy_demonstration_books(date, boolean) from public, anon, authenticated;

comment on function erp.tidy_demonstration_books(date, boolean) is
  'In a demonstration that is not live, on the day given (20261010180000): bills every posted receipt a week old '
  'that no bill names, dated as the catch-up dates a bill (unless p_bill is false), and collects what each customer owes that fell due more than thirty days ago, or ninety for '
  'the one in four who pay late. Through the product''s doors; draws on no random().';

-- ── B. The builder tidies on each month's pay day ────────────────────────────

do $seed_demo_history$
declare
  v_sig  constant text := 'erp.seed_demo_history(date, date, numeric)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_day = erp.demonstration_pay_day(v_day) then
    declare
      v_payrun jsonb;
    begin
      v_payrun := erp.pay_demonstration_suppliers(v_day, v_day + 7);$o$;
  v_new  constant text := $n$  if v_day = erp.demonstration_pay_day(v_day) then
    declare
      v_payrun jsonb;
      v_tidy   jsonb;
    begin
      -- The month's customers paying first (20261010180000): what is a month
      -- overdue, or three for the slow payers. Its receipts are left to the
      -- catch-up, which bills what the builder leaves. Nothing there draws
      -- on random().
      v_tidy := erp.tidy_demonstration_books(v_day, false);
      v_built := v_built + coalesce((v_tidy ->> 'bills')::integer, 0)
                         + coalesce((v_tidy ->> 'customers_paid')::integer, 0);
      if v_tidy ->> 'note' is not null then
        v_notes := v_notes || to_jsonb(v_tidy ->> 'note');
      end if;
      v_payrun := erp.pay_demonstration_suppliers(v_day, v_day + 7);$n$;
  n integer;
begin
  if position('erp.tidy_demonstration_books(' in v_def) > 0 then
    raise notice '% already tidies on pay day; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % pay day block found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$seed_demo_history$;

-- ── C. The catch-up tidies on the last day it trades ─────────────────────────

do $demonstration_catch_up$
declare
  v_sig  constant text := 'erp.demonstration_catch_up()';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- ── What the month ends left owing (20261006160000, J-142) ────────────────
$o$;
  v_new  constant text := $n$  -- ── The books tidied on the last day traded (20261010180000) ────────────────
  --
  -- The receipts a week old billed and the customers paying what is a month
  -- overdue, or three for the slow payers, dated the last day traded, in the
  -- month still open. Before what the month ends left owing is paid, so the
  -- bills it raises are there to be paid when they fall due.
  begin
    if v_frontier is not null
       and (v_finish_by is null or clock_timestamp() < v_finish_by) then
      declare
        v_tidy jsonb := erp.tidy_demonstration_books(v_frontier, true);
      begin
        -- Its bills are the catch-up's: the receipts its own pass left
        -- because an earlier receipt of the same order was billed.
        v_billed := v_billed + coalesce((v_tidy ->> 'bills')::integer, 0);
        if v_tidy ->> 'note' is not null then
          v_notes := v_notes || to_jsonb(v_tidy ->> 'note');
        end if;
      end;
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(format(
      'Its books were left as they were, because tidying refused. %s', sqlerrm));
  end;

  -- ── What the month ends left owing (20261006160000, J-142) ────────────────
$n$;
  n integer;
begin
  if position('erp.tidy_demonstration_books(' in v_def) > 0 then
    raise notice '% already tidies; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % month-end block found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$demonstration_catch_up$;

-- ── D. The proof ─────────────────────────────────────────────────────────────

create or replace function erp_test.tidy_demonstration_books_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_fast uuid; v_slowc uuid; v_inv_fast uuid; v_inv_slow uuid; v_site uuid; v_item uuid;
  v_owing_fast bigint; v_owing_slow bigint;
  v_from   date := (date_trunc('month', current_date) - interval '4 months')::date;
  v_day    date;
  v_res    jsonb; v_again jsonb;
  v_ccy    char(3);
  v_unbilled_old bigint; v_late_customers bigint; v_slow bigint; v_customers bigint;
  v_worst integer;
begin
  begin
    v_step := 'a demonstration with three months of the builder''s trading, as it trades without tidying';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zztdy' || v_tag, 'Tidy Books Suite',
      'admin@demo-zztdy' || v_tag || '.test', 'Presenter');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zztdy' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.base_currency into v_ccy from erp.entity e where e.id = rb.entity_id;
    v_day := v_from;
    while v_day < v_from + 90 loop
      perform erp.seed_demo_history(v_day, null, 1);
      v_day := v_day + 5;
    end loop;

    -- Cash goes to a customer's oldest invoice first, so three months of the
    -- builder's trading leaves nobody far behind; a year does. So an invoice
    -- sixty days past due is raised for a customer who pays on time and for
    -- one who pays late.
    v_step := 'an invoice sixty days past due for a prompt payer and for a slow one';
    v_day := v_from + 89;
    select p.id into v_fast from erp.party p
      join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id and pr.role_kind = 'customer'
     where p.tenant_id = rb.tenant_id and abs(hashtext(p.code)) % 4 <> 0 order by p.code limit 1;
    select p.id into v_slowc from erp.party p
      join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id and pr.role_kind = 'customer'
     where p.tenant_id = rb.tenant_id and abs(hashtext(p.code)) % 4 = 0 order by p.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = rb.tenant_id and s.entity_id = rb.entity_id order by s.code limit 1;
    select i.id into v_item from erp.item i where i.tenant_id = rb.tenant_id and i.item_class = 'finished_good' order by i.code limit 1;
    v_inv_fast := erp.create_document('sales_invoice', rb.entity_id, v_site, v_fast, v_day - 90, v_ccy, 'ZZTDY-FAST', '{}'::jsonb);
    perform erp.add_document_line(v_inv_fast, v_item, 1, 10000, 'a late invoice');
    update erp.document set due_date = v_day - 60 where id = v_inv_fast;
    perform erp.transition_document(v_inv_fast, 'issue', 'tidy books suite');
    if v_slowc is not null then
      v_inv_slow := erp.create_document('sales_invoice', rb.entity_id, v_site, v_slowc, v_day - 90, v_ccy, 'ZZTDY-SLOW', '{}'::jsonb);
      perform erp.add_document_line(v_inv_slow, v_item, 1, 10000, 'a late invoice');
      update erp.document set due_date = v_day - 60 where id = v_inv_slow;
      perform erp.transition_document(v_inv_slow, 'issue', 'tidy books suite');
    end if;

    -- ── 1–7. What a day's tidy does ─────────────────────────────────────────
    v_step := 'the books tidied on the last day built';
    v_res := erp.tidy_demonstration_books(v_day);

    select coalesce(sum(o.owing_minor), 0) into v_owing_fast
      from erp.open_receivables(v_ccy) o where o.document_id = v_inv_fast;
    select coalesce(sum(o.owing_minor), 0) into v_owing_slow
      from erp.open_receivables(v_ccy) o where o.document_id = v_inv_slow;

    v_cases := v_cases + 1;
    case_name := 'a customer who pays on time settles an invoice sixty days past due';
    passed := v_state is null and v_owing_fast = 0;
    detail := format('%s still owed on it', v_owing_fast);
    return next;

    v_cases := v_cases + 1;
    case_name := 'a slow payer is left owing at sixty days, so the dunning screens have somebody on them';
    passed := v_state is null and v_slowc is not null and v_owing_slow > 0;
    detail := format('%s still owed on it', v_owing_slow);
    return next;

    select count(*) into v_unbilled_old
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.code = 'goods_receipt' and not d.is_cancelled
       and d.stock_owner_party_id is null and d.document_date <= v_day - 7
       and erp.object_current_state('document', d.id) = 'posted'
       and exists (select 1 from erp.document_relation fr
                    where fr.tenant_id = d.tenant_id and fr.from_document_id = d.id
                      and fr.relation_kind = 'fulfils' and fr.to_line_id is not null)
       and not exists (select 1 from erp.document_relation r
                         join erp.document b on b.tenant_id = r.tenant_id and b.id = r.from_document_id
                         join erp.document_type bt on bt.tenant_id = b.tenant_id and bt.id = b.document_type_id
                        where r.tenant_id = d.tenant_id and r.to_document_id = d.id
                          and r.relation_kind = 'invoices' and bt.code = 'purchase_invoice' and not b.is_cancelled)
       and not exists (select 1 from erp.document_relation fr
                         join erp.document_line ol on ol.tenant_id = fr.tenant_id and ol.id = fr.to_line_id
                        where fr.tenant_id = d.tenant_id and fr.from_document_id = d.id and fr.relation_kind = 'fulfils'
                          and coalesce(ol.quantity_invoiced, 0) >= coalesce(ol.quantity_fulfilled, 0))
       and not exists (select 1 from erp.document_line gl
                         join erp.document_relation rr on rr.tenant_id = gl.tenant_id and rr.to_line_id = gl.id
                          and rr.relation_kind = 'returns'
                        where gl.tenant_id = d.tenant_id and gl.document_id = d.id);

    v_cases := v_cases + 1;
    case_name := 'every receipt a week old that no bill names is billed, and none refused';
    passed := v_state is null and (v_res ->> 'tidied')::boolean
          and v_unbilled_old = 0 and (v_res ->> 'bills_refused')::integer = 0;
    detail := format('%s billed, %s refused, %s left unbilled; %s',
                     v_res ->> 'bills', v_res ->> 'bills_refused', v_unbilled_old, coalesce(v_res ->> 'note', 'no note'));
    return next;

    select count(distinct o.party_id),
           count(distinct o.party_id) filter (where abs(hashtext(p.code)) % 4 = 0)
      into v_late_customers, v_slow
      from erp.open_receivables(v_ccy) o
      join erp.party p on p.id = o.party_id
     where o.owing_minor > 0
       and o.due_date < v_day - case when abs(hashtext(p.code)) % 4 = 0 then 90 else 30 end;
    select count(*) into v_customers
      from erp.party p join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     where p.tenant_id = rb.tenant_id and pr.role_kind = 'customer';

    v_cases := v_cases + 1;
    case_name := 'no customer is left owing past what they are allowed: a month, or three for a slow payer';
    passed := v_state is null and v_late_customers = 0;
    detail := format('%s customer(s) paid %s; %s still past their allowance',
                     v_res ->> 'customers_paid', v_res ->> 'paid_minor', v_late_customers);
    return next;

    select max(v_day - o.due_date) into v_worst
      from erp.open_receivables(v_ccy) o where o.owing_minor > 0;

    v_cases := v_cases + 1;
    case_name := 'and nobody is more than ninety days past due';
    passed := v_state is null and coalesce(v_worst, 0) <= 90;
    detail := format('the longest overdue is %s day(s)', coalesce(v_worst, 0));
    return next;

    v_cases := v_cases + 1;
    case_name := 'the books still tie: trial balance, debtors and creditors against their ledgers';
    begin
      perform erp.assert_trial_balance_balances();
      perform erp.assert_subledger_reconciles();
      perform erp.assert_ageing_equals_control();
      passed := v_state is null;
      detail := 'the three ties hold';
    exception when others then
      passed := false; detail := left(sqlerrm, 200);
    end;
    return next;

    v_again := erp.tidy_demonstration_books(v_day);

    v_cases := v_cases + 1;
    case_name := 'tidying the same day again does nothing';
    passed := v_state is null and (v_again ->> 'bills')::integer = 0 and (v_again ->> 'customers_paid')::integer = 0;
    detail := v_again::text;
    return next;

    -- ── 6. Outside a demonstration it does nothing ──────────────────────────
    v_step := 'the demonstration made live';
    update erp.environment set is_live = true where tenant_id = rb.tenant_id and is_self;
    v_again := erp.tidy_demonstration_books(v_day + 1);
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;

    v_cases := v_cases + 1;
    case_name := 'a demonstration that is live is never tidied';
    passed := v_state is null and not (v_again ->> 'tidied')::boolean;
    detail := v_again::text;
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
        and not exists (select 1 from erp.tenant t where t.code = 'demo-zztdy' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'the demonstration rolled back with its trading and its tidy');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_TIDY_BOOKS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_tidy_demonstration_books_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _tidy_books on commit drop as
    select * from erp_test.tidy_demonstration_books_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _tidy_books;
  drop table _tidy_books;
  if v_fail > 0 then
    raise exception E'CLOVEERP_TIDY_BOOKS_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_TIDY_BOOKS_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a demonstration keeps its books tidy: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.tidy_demonstration_books_suite() from public, anon;
revoke all on function erp_test.assert_tidy_demonstration_books_suite() from public, anon;

comment on function erp_test.tidy_demonstration_books_suite() is
  'A demonstration keeps its books tidy (20261010180000): over three months of the builder''s trading, a tidy bills '
  'every week-old receipt no bill names, leaves no customer past their allowance or ninety days overdue, keeps the '
  'ties, does nothing twice, and never touches a live organisation.';

comment on function erp_test.assert_tidy_demonstration_books_suite() is
  'erp_test.tidy_demonstration_books_suite(), nine cases.';

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
