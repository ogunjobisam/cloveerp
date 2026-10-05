set lock_timeout = '30s';

-- =============================================================================
-- 20261010052000  The catch-up's bills state their VAT, dated near their goods
-- -----------------------------------------------------------------------------
-- Found rehearsing the rebuild of the live demonstration, 5 October. The
-- builder bills one receipt a week, on Thursdays, and states the supplier's
-- VAT on that bill before it registers (erp.state_demonstration_input_tax(),
-- 20261001400000). Every other receipt is billed by the deploy's catch-up,
-- erp.demonstration_catch_up(), through erp.bill_from_receipt(), and that
-- stated nothing and dated every bill today. The first catch-up after a year
-- was built raised 59 bills dated the deploy day, about £446,000 net; the 17
-- from British suppliers carried £98,007 net and no VAT at all. The quarter
-- to date then read box 7 £529,527 against box 4 £7,654: a year's purchases
-- in one fortnight, and four fifths of them with no input tax.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.demonstration_catch_up(), its billing of the receipts nobody
--      billed, and nothing else in it:
--        - each bill is opened unregistered, its VAT is stated by
--          erp.state_demonstration_input_tax() exactly as the builder's
--          Thursday bill states it (20% on a British supplier's
--          standard-rated goods; nothing on a supplier abroad, which is left
--          to the reverse charge), and then it is registered with the same
--          reason erp.bill_from_receipt() gives;
--        - each bill is dated a week after its goods arrived, as a supplier's
--          bill comes in, and never after the site's today. Where the books no
--          longer take that day it is dated today, as before: where a month
--          of any of the company's ledgers holding it is closed (or has no
--          period), or a VAT return the company has finalised covers it. A
--          bill dated into a returned quarter would be carried into the next
--          return as a correction of the one already made, which is not what
--          a late bill is.
--      The bill is still due thirty days after its date.
--   B. erp_test.demonstration_catch_up_bills_suite, five cases, and its
--      assertion.
--
-- What it means for the rebuilt demonstration: its builder finalises each
-- quarter as its trading passes it, so the receipts of the quarters already
-- returned are billed today, with their VAT, and the receipts of the quarter
-- left for somebody to return (Q3 2026) are billed in that quarter, a week
-- after they arrived. That quarter then reads the purchases it made.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No bill already raised is touched: a bill states its VAT once, before it
-- registers. The rest of the catch-up (trading, payments, closes, returns) is
-- as it was. No door, permission, refusal or screen string is added.
--
-- On production: one function is replaced and a suite added. No table is
-- altered and no row of any organisation is touched. The next catch-up bills
-- with VAT, near the goods.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A bill as the builder raises one, dated near its goods
-- ─────────────────────────────────────────────────────────────────────────────

do $bills$
declare
  v_sig  constant text := 'erp.demonstration_catch_up()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$      select d.id, d.document_number, d.document_date, d.site_id
        from erp.document d$o$;
  v_new1 constant text := $n$      select d.id, d.document_number, d.document_date, d.site_id, d.entity_id
        from erp.document d$n$;
  v_old2 constant text := $o$      begin
        -- Dated where the goods arrived rather than where the database is
        -- standing (20260920110000).
        v_today := erp.local_today(g.site_id);
        perform erp.bill_from_receipt(
                  g.id, 'INV/' || g.document_number, v_today, v_today + 30, true);
        v_billed := v_billed + 1;
$o$;
  v_new2 constant text := $n$      declare
        v_bill_on date;
        v_bill    uuid;
      begin
        -- Dated where the goods arrived rather than where the database is
        -- standing (20260920110000).
        v_today := erp.local_today(g.site_id);
        -- A week after the goods arrived, as a supplier's bill comes in, and
        -- never after today (20261010052000). Today, as before, where the
        -- books no longer take that day: a month of one of the company's
        -- ledgers holding it is closed or missing, or a VAT return the
        -- company finalised covers it, so that a late bill is not carried
        -- into the next return as a correction of one already made.
        v_bill_on := least(g.document_date + 7, v_today);
        if v_bill_on < v_today and (
             exists (select 1 from erp.ledger l
                      where l.tenant_id = v_tenant and l.entity_id = g.entity_id
                        and l.status = 'active'
                        and not exists (select 1 from erp.fiscal_period fp
                                         where fp.tenant_id = l.tenant_id and fp.ledger_id = l.id
                                           and v_bill_on between fp.starts_on and fp.ends_on
                                           and erp.period_accepts_postings(fp.id)))
          or exists (select 1 from erp.document vr
                       join erp.document_type vt
                         on vt.tenant_id = vr.tenant_id and vt.id = vr.document_type_id
                        and vt.base_type_code = 'vat_return'
                      where vr.tenant_id = v_tenant and vr.entity_id = g.entity_id
                        and not vr.is_cancelled
                        and (vr.attributes #>> '{vat_return,period_end}')::date >= v_bill_on
                        and erp.object_current_state('document', vr.id) = 'finalised')) then
          v_bill_on := v_today;
        end if;
        v_bill := erp.bill_from_receipt(
                    g.id, 'INV/' || g.document_number, v_bill_on, v_bill_on + 30, false);
        -- What the supplier charged, stated before the bill registers, as the
        -- builder's Thursday bill states it (20261001400000): the ledger reads
        -- the figure once, as it posts.
        perform erp.state_demonstration_input_tax(v_bill);
        perform erp.transition_document(v_bill, 'register', 'billed from ' || g.document_number);
        v_billed := v_billed + 1;
$n$;
begin
  if strpos(v_src, '20261010052000') > 0 then
    raise notice '% already states the VAT of the bills it raises; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'ca941967fc04971e7ed2139dfda67ed8' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010052000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$bills$;

revoke all on function erp.demonstration_catch_up() from public, anon;

comment on function erp.demonstration_catch_up() is
  'Brings one demonstration organisation up to today: reopens the months a close ran on before its trading ever '
  'reached them, trades forward from the last day its builder built, bills the goods it received and never billed, '
  'and closes the months whose trading is finished — re-running every close check of a month it reopened against the '
  'figures the new trading leaves. Each bill states its VAT as the builder''s Thursday bill does and is dated a week '
  'after its goods, or today where the books or a finalised VAT return no longer take that day (20261010052000). '
  'Closes nothing past the day the builder reached. Stops and commits before the session''s statement_timeout would '
  'cancel it, and says so, because a cancelled statement loses everything it did (20260921130000). Refuses any '
  'organisation that is not a demonstration or whose environment is live, which is what makes the reopening '
  'permissible at all. Safe to run twice.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demonstration_catch_up_bills_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  rb        record;
  v_step    text := 'provisioning';
  v_state   text;
  v_tenant  uuid;
  v_ent     uuid;
  -- Registered from the start of the quarter before last, and traded over its
  -- last ten days and the last fortnight: the builder returns that quarter
  -- once its trading passes the end of it, and leaves the latest quarter to
  -- have ended for somebody. A history's first orders arrive on its third to
  -- sixth days, so a week after them falls on both sides of the quarter end.
  v_qstart  constant date := (date_trunc('quarter', current_date) - interval '6 months')::date;
  v_qend    constant date := (date_trunc('quarter', current_date) - interval '3 months')::date - 1;
  v_old     constant date := (date_trunc('quarter', current_date) - interval '3 months')::date - 11;
  v_recent  constant date := current_date - 12;
  v_returned date;
  v_old_unbilled integer;
  v_new_unbilled integer;
  v_report  jsonb;
  v_n       integer;
  v_taxed   integer;
  v_wrong   text;
  v_today   date;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'a demonstration configured to trade';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzcub-' || v_tag, 'Catch-up Bills Suite', 'admin@zzcub-' || v_tag || '.test', 'Catch-up Bills Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    update erp.tenant set code = 'demo-zzcub-' || v_tag where id = rb.tenant_id;
    insert into auth.users (id, email) values (a1, 'admin@zzcub-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;

    select g.entity_id into v_ent
      from erp.entity_tax_registration g
     where g.tenant_id = v_tenant and upper(g.registration_type) like 'VAT%'
       and upper(g.jurisdiction) = 'GB'
     order by g.valid_from limit 1;
    update erp.entity_tax_registration g set valid_from = v_qstart
     where g.tenant_id = v_tenant and g.entity_id = v_ent
       and upper(g.registration_type) like 'VAT%' and upper(g.jurisdiction) = 'GB';

    v_step := 'the last ten days of the quarter before last, and ten in the last fortnight';
    perform erp.seed_demo_history(v_old, null, 1);
    perform erp.seed_demo_history(v_old + 5, null, 1);
    perform erp.seed_demo_history(v_recent, null, 1);
    perform erp.seed_demo_history(v_recent + 5, null, 1);
    set constraints all immediate;

    select max((d.attributes #>> '{vat_return,period_end}')::date) into v_returned
      from erp.document d
      join erp.document_type dt
        on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id and dt.base_type_code = 'vat_return'
     where d.tenant_id = v_tenant and d.entity_id = v_ent
       and erp.object_current_state('document', d.id) = 'finalised';

    -- The receipts nobody billed and nothing went back from, which are what
    -- the catch-up bills: those whose week ends inside the returned quarter,
    -- and those whose week ends after it.
    select count(*) filter (where g.document_date + 7 <= v_qend),
           count(*) filter (where g.document_date + 7 > v_qend)
      into v_old_unbilled, v_new_unbilled
      from erp.document g
      join erp.document_type gt on gt.tenant_id = g.tenant_id and gt.id = g.document_type_id
     where g.tenant_id = v_tenant and gt.code = 'goods_receipt' and not g.is_cancelled
       and erp.object_current_state('document', g.id) = 'posted'
       and not exists (select 1 from erp.document_relation rel
                        where rel.tenant_id = g.tenant_id and rel.to_document_id = g.id
                          and rel.relation_kind = 'invoices')
       and not exists (select 1 from erp.document_line gl
                         join erp.document_relation rr
                           on rr.tenant_id = gl.tenant_id and rr.to_line_id = gl.id
                          and rr.relation_kind = 'returns'
                        where gl.tenant_id = g.tenant_id and gl.document_id = g.id);

    -- ── 1. The fixture is the shape this suite is about ─────────────────────
    v_cases := v_cases + 1;
    case_name := 'the fixture''s builder returned the quarter before last, and left receipts nobody billed whose week ends inside it and after it';
    passed := v_state is null and v_returned = v_qend
          and v_old_unbilled > 0 and v_new_unbilled > 0;
    detail := coalesce(v_state, format('returned through %s (quarter ends %s); unbilled %s whose week ends in it, %s after',
                                       v_returned, v_qend, v_old_unbilled, v_new_unbilled));
    return next;

    v_step := 'the catch-up';
    v_report := erp.demonstration_catch_up();
    v_today := erp.local_today();

    -- The bills it raised: named for their receipt, and linked to it.
    create temp table _cub_bills on commit drop as
      select b.id, b.document_date, g.document_date as received_on, b.party_id,
             coalesce(erp.document_tax_minor(b.id), 0) as tax_minor,
             (select coalesce(sum(l.net_minor), 0) from erp.document_line l
               where l.tenant_id = b.tenant_id and l.document_id = b.id
                 and not coalesce(l.is_cancelled, false))::bigint as net_minor,
             (p.country_code = 'GB' and e.country_code = 'GB'
              and not exists (select 1 from erp.document_line l2
                                left join erp.item i on i.tenant_id = l2.tenant_id and i.id = l2.item_id
                               where l2.tenant_id = b.tenant_id and l2.document_id = b.id
                                 and not coalesce(l2.is_cancelled, false)
                                 and coalesce(i.tax_class, 'standard') <> 'standard')) as british,
             erp.object_current_state('document', b.id) as state
        from erp.document b
        join erp.document_type bt on bt.tenant_id = b.tenant_id and bt.id = b.document_type_id
        join erp.document_relation rel
          on rel.tenant_id = b.tenant_id and rel.from_document_id = b.id and rel.relation_kind = 'invoices'
        join erp.document g on g.tenant_id = rel.tenant_id and g.id = rel.to_document_id
        join erp.party p on p.tenant_id = b.tenant_id and p.id = b.party_id
        join erp.entity e on e.tenant_id = b.tenant_id and e.id = b.entity_id
       where b.tenant_id = v_tenant and bt.code = 'purchase_invoice'
         and b.their_reference = 'INV/' || g.document_number;

    -- ── 2. It billed them all ───────────────────────────────────────────────
    -- Its own trading up to today may receive more, and it bills those too.
    select count(*) into v_n from _cub_bills;
    v_cases := v_cases + 1;
    -- A bill already due by the last pay day is paid by the run the catch-up
    -- makes after billing (20261006160000).
    case_name := 'the catch-up billed every receipt nobody had billed, and registered each bill';
    passed := v_state is null
          and (v_report ->> 'bills_raised')::integer = v_n
          and v_n >= v_old_unbilled + v_new_unbilled
          and (v_report ->> 'receipts_unbilled')::integer = 0
          and not exists (select 1 from _cub_bills b where b.state not in ('registered', 'part_paid', 'paid'));
    detail := coalesce(v_state, format('%s bill(s) raised, %s found, %s refused; states %s',
                                       v_report ->> 'bills_raised', v_n, v_report ->> 'receipts_unbilled',
                                       (select string_agg(distinct b.state, ', ') from _cub_bills b)));
    return next;

    -- ── 3. Each states its VAT as the builder's does ────────────────────────
    select count(*) filter (where b.british),
           string_agg(format('%s net %s tax %s', b.id, b.net_minor, b.tax_minor), '; ')
             filter (where b.tax_minor <> case when b.british then round(b.net_minor * 0.20)::bigint else 0 end)
      into v_taxed, v_wrong
      from _cub_bills b;
    v_cases := v_cases + 1;
    case_name := 'each bill from a British supplier for standard-rated goods states 20% VAT, as the builder''s Thursday bill does, and a bill from abroad states none';
    passed := v_state is null and v_taxed > 0 and v_wrong is null;
    detail := coalesce(v_state, coalesce('wrong: ' || v_wrong,
                       format('%s British bill(s) at 20%%, %s from abroad with none', v_taxed, v_n - v_taxed)));
    return next;

    -- ── 4. Dated a week after its goods ─────────────────────────────────────
    select string_agg(format('received %s billed %s', b.received_on, b.document_date), '; ')
      into v_wrong
      from _cub_bills b
     where b.received_on + 7 > v_qend
       and b.document_date <> least(b.received_on + 7, v_today);
    v_cases := v_cases + 1;
    case_name := 'a bill whose goods arrived a week or less before the end of the last quarter returned, or later, is dated a week after they arrived, or today if that is sooner';
    passed := v_state is null and v_wrong is null
          and exists (select 1 from _cub_bills b
                       where b.received_on + 7 > v_qend and b.document_date = b.received_on + 7
                         and b.document_date < v_today);
    detail := coalesce(v_state, coalesce('wrong: ' || v_wrong,
                       (select string_agg(format('%s→%s', b.received_on, b.document_date), ', ' order by b.received_on)
                          from _cub_bills b where b.received_on + 7 > v_qend)));
    return next;

    -- ── 5. And not into a quarter already returned ──────────────────────────
    select string_agg(format('received %s billed %s', b.received_on, b.document_date), '; ')
      into v_wrong
      from _cub_bills b
     where b.received_on + 7 <= v_qend
       and b.document_date <> v_today;
    v_cases := v_cases + 1;
    case_name := 'a bill whose week would end inside a quarter already returned is dated today, so the return stands as it was made';
    passed := v_state is null and v_wrong is null
          and exists (select 1 from _cub_bills b where b.received_on + 7 <= v_qend)
          and not exists (select 1 from _cub_bills b where b.document_date <= v_returned);
    detail := coalesce(v_state, coalesce('wrong: ' || v_wrong,
                       (select string_agg(format('%s→%s', b.received_on, b.document_date), ', ' order by b.received_on)
                          from _cub_bills b where b.received_on + 7 <= v_qend)));
    return next;

    drop table _cub_bills;
    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_DEMONSTRATION_CATCH_UP_BILLS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demonstration_catch_up_bills_suite() from public, anon;

comment on function erp_test.demonstration_catch_up_bills_suite() is
  'The bills the demonstration catch-up raises (20261010052000): every receipt nobody billed is billed and registered, '
  'a British supplier''s at 20% VAT as the builder''s Thursday bill and one from abroad with none, dated a week after '
  'the goods or today if sooner, and today where a finalised VAT return covers that week.';

create or replace function erp_test.assert_demonstration_catch_up_bills_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.demonstration_catch_up_bills_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMONSTRATION_CATCH_UP_BILLS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The demonstration catch-up raises a bill without its VAT, or dates it away from its goods or into a quarter already returned. Read the case that failed.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_DEMONSTRATION_CATCH_UP_BILLS_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demonstration catch-up bills: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demonstration_catch_up_bills_suite() from public, anon;

comment on function erp_test.assert_demonstration_catch_up_bills_suite() is
  'The demonstration catch-up''s bills state their VAT and are dated near their goods, never into a returned quarter '
  '(20261010052000).';

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
