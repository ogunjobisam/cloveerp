set lock_timeout = '30s';

-- =============================================================================
-- 20261010012000  A payment settles the bills it paid
-- -----------------------------------------------------------------------------
-- Found in the live re-test of 5 October (B2). The run PAY-20261005142957795
-- paid PINV-000116 on a supplier payment, PMT-000001. The payment's page had
-- no related documents at all, though its one line read "PINV-000116, your
-- ref RT2-INV-149"; the bill's page listed its receipt and its order and not
-- the payment that paid it; and neither said which run it was. Since
-- 20260930200000 erp.pay_payment_run opens one payment per supplier and
-- writes each bill it pays as a line, and it wrote no relation: lineage, which
-- is what Related documents reads, walks erp.document_relation and nothing
-- else.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.pay_payment_run relates each payment to each bill it pays, as
--      `settles` (declared by 20261010011000), from the payment's line that
--      names the bill. The bill's page lists the payment; the payment's lists
--      the bill, and through it the receipt and the order.
--   B. erp.relate_payments_to_bills(): in the organisation it runs in, every
--      supplier payment a run made before this is related to the bills its
--      journals paid, from the line that names each where there is one. Asked
--      again it adds nothing.
--   C. public.erp_document answers payment_run, the reference of the run a
--      supplier payment was made by; the page says it.
--   D. Every organisation's existing payments are related here: the defect is
--      in every organisation that has paid a run since 30 September, not only
--      the demonstrations.
--   E. erp_test.payment_settles_suite, four cases.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- What a run pays, posts or settles is unchanged; a relation is a record of
-- what was paid, and posts nothing. A prepayment paid ahead of the goods
-- (erp.pay_prepayment_line) pays an order, not a bill, and is not related
-- here. A customer's cash receipt is not touched.
--
-- On production: two routines are edited and one is added. No table is
-- altered. In each organisation that has paid a run, one erp.document_relation
-- row is added for each bill each of its supplier payments paid; no other row
-- is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A run's payment settles the bills it pays
-- ─────────────────────────────────────────────────────────────────────────────

do $pay$
declare
  v_sig  constant text := 'erp.pay_payment_run(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  v_pre          jsonb;
begin
$o$;
  v_new1 constant text := $n$  v_pre          jsonb;
  -- The payment's line for the bill it pays (20261010012000).
  v_pline        uuid;
begin
$n$;
  v_old2 constant text := $o$                   where b.tenant_id = v_tenant and b.id = si.document_id), 'an open item'),
        1, v_amount, v_amount, si.currency);
    end if;
$o$;
  v_new2 constant text := $n$                   where b.tenant_id = v_tenant and b.id = si.document_id), 'an open item'),
        1, v_amount, v_amount, si.currency)
      returning id into v_pline;

      -- And the payment settles the bill (20261010012000, B2), from the line
      -- that names it: Related documents reads the relation, on both pages.
      if si.document_id is not null
         and not exists (select 1 from erp.document_relation rel
                          where rel.tenant_id = v_tenant and rel.from_document_id = v_payment
                            and rel.to_document_id = si.document_id and rel.relation_kind = 'settles') then
        insert into erp.document_relation (
          tenant_id, from_document_id, to_document_id, relation_kind, from_line_id)
        values (v_tenant, v_payment, si.document_id, 'settles', v_pline);
      end if;
    end if;
$n$;
begin
  if strpos(v_src, '20261010012000') > 0 then
    raise notice '% already relates its payments; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '5d445e558f1932ec05f1b7b9d60b8bfe' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010012000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$pay$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The payments already made
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.relate_payments_to_bills()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_n      integer;
begin
  -- Every supplier payment a run made, related to each bill its journals paid
  -- (20261010012000, B2): the payable item the run's journal settled names the
  -- bill. From the payment's line that names the bill where there is one.
  -- Only in the organisation the session acts for; asked again, nothing.
  insert into erp.document_relation (
    tenant_id, from_document_id, to_document_id, relation_kind, from_line_id)
  select v_tenant, x.payment_id, x.bill_id, 'settles',
         (select l.id from erp.document_line l
           where l.tenant_id = v_tenant and l.document_id = x.payment_id
             and not coalesce(l.is_cancelled, false)
             and (l.description = x.bill_number or l.description like x.bill_number || ',%')
           order by l.line_no limit 1)
    from (select distinct pay.id as payment_id, b.id as bill_id, b.document_number as bill_number
            from erp.document pay
            join erp.document_type pt
              on pt.tenant_id = pay.tenant_id and pt.id = pay.document_type_id
             and pt.base_type_code = 'cash_payment'
            join erp.journal j
              on j.tenant_id = pay.tenant_id and j.document_id = pay.id
             and j.source_code = 'payment.made'
            join erp.subledger_item si
              on si.tenant_id = j.tenant_id and si.journal_id = j.id
             and si.control_kind = 'payable' and si.document_id is not null
            join erp.document b on b.tenant_id = si.tenant_id and b.id = si.document_id
            join erp.document_type bt
              on bt.tenant_id = b.tenant_id and bt.id = b.document_type_id
             and bt.base_type_code = 'invoice_reference'
           where pay.tenant_id = v_tenant and b.id <> pay.id) x
   where not exists (select 1 from erp.document_relation rel
                      where rel.tenant_id = v_tenant and rel.from_document_id = x.payment_id
                        and rel.to_document_id = x.bill_id and rel.relation_kind = 'settles');
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function erp.relate_payments_to_bills() from public, anon;

comment on function erp.relate_payments_to_bills() is
  'Relates every supplier payment a run made, in the organisation the session acts for, to each bill its journals '
  'paid, as settles (20261010012000). For the payments made before erp.pay_payment_run wrote the relation itself; '
  'asked again it adds nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. A payment's page names its run
-- ─────────────────────────────────────────────────────────────────────────────

do $page$
declare
  v_sig  constant text := 'public.erp_document(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$        'awaiting', erp.document_awaiting(d.id),
$o$;
  v_new  constant text := $n$        'awaiting', erp.document_awaiting(d.id),
        -- The run a supplier payment was made by (20261010012000, B2). A run
        -- is not a document, so lineage cannot name it.
        'payment_run', case when dt.base_type_code = 'cash_payment' then (
                         select pp.reference from erp.payment_proposal pp
                          where pp.tenant_id = d.tenant_id
                            and pp.id::text = d.attributes ->> 'payment_proposal_id') end,
$n$;
begin
  if strpos(v_src, '20261010012000') > 0 then
    raise notice '% already names a payment''s run; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '13d21c64cc1bca1619add80b9dd29601' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010012000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$page$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.payment_settles_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_ent    uuid; v_site uuid; i_fg uuid; p_sup uuid;
  v_po     uuid; v_grn uuid; v_bill uuid; v_pmt uuid; v_run text;
  x        jsonb;
  v_pay    jsonb;
  pp       jsonb;
  pb       jsonb;
  v_n1     integer;
  v_n2     integer;
begin
  begin
    -- ── The fixture: a bill paid by a run ───────────────────────────────────
    v_step := 'an organisation with two administrators and a bill owed';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzpst-' || v_tag, 'Payment Settles Suite', 'admin@zzpst-' || v_tag || '.test', 'Settles Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzpst-' || v_tag || '.test'), (a2, 'second@zzpst-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('second@zzpst-' || v_tag || '.test', 'Second Admin');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_tenant := rb.tenant_id;

    select e.id into v_ent from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select i.id into i_fg from erp.item i where i.tenant_id = v_tenant and i.code = 'FG-1000';
    select pt.id into p_sup from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'S-FAST';

    v_po := erp.open_document('purchase_order', p_sup, v_ent, v_site);
    perform erp.add_document_line(v_po, i_fg, 5, 4000, 'stock');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'fixture');
    perform erp.transition_document(v_po, 'send', null);
    x := erp.create_receipt_from_order(v_po, null, 'post');
    v_grn := (x ->> 'document_id')::uuid;
    v_bill := erp.bill_from_receipt(v_grn, 'PST-BILL-1', current_date, current_date, true);

    v_step := 'the run that pays it';
    v_pay := erp_test.cash_payment_run(array[v_bill], a1, a2);
    v_pmt := (v_pay #>> '{payments,0,document_id}')::uuid;
    v_run := v_pay ->> 'reference';
    pp := public.erp_document(v_pmt);
    pb := public.erp_document(v_bill);

    -- ── 1. The payment lists the bill it paid ───────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a payment a run made lists the bill it paid among its related documents, from the line naming it';
    passed := v_state is null and v_pmt is not null
          and exists (select 1 from jsonb_array_elements(pp -> 'lineage') l
                       where l ->> 'document_id' = v_bill::text and l ->> 'direction' = 'downstream'
                         and l ->> 'relation' = 'settles')
          and exists (select 1 from erp.document_relation rel
                        join erp.document_line pl on pl.tenant_id = rel.tenant_id and pl.id = rel.from_line_id
                       where rel.tenant_id = v_tenant and rel.from_document_id = v_pmt
                         and rel.to_document_id = v_bill and rel.relation_kind = 'settles'
                         and pl.document_id = v_pmt);
    detail := coalesce(v_state, format('payment %s | lineage %s', v_pmt, pp -> 'lineage'));
    return next;

    -- ── 2. The bill lists the payment ───────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the bill lists the payment that paid it';
    passed := v_state is null
          and exists (select 1 from jsonb_array_elements(pb -> 'lineage') l
                       where l ->> 'document_id' = v_pmt::text and l ->> 'direction' = 'upstream'
                         and l ->> 'relation' = 'settles');
    detail := coalesce(v_state, (pb -> 'lineage')::text);
    return next;

    -- ── 3. The payment's page names its run ─────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the payment''s page names the run it was made by, and a bill''s names none';
    passed := v_state is null and v_run is not null
          and pp -> 'document' ->> 'payment_run' = v_run
          and (pb -> 'document' ->> 'payment_run') is null;
    detail := coalesce(v_state, format('run %s, page %s', v_run, pp -> 'document' ->> 'payment_run'));
    return next;

    -- ── 4. A payment made before is related once ────────────────────────────
    v_step := 'a payment made before the relation was written';
    delete from erp.document_relation rel
     where rel.tenant_id = v_tenant and rel.from_document_id = v_pmt and rel.relation_kind = 'settles';
    v_n1 := erp.relate_payments_to_bills();
    v_n2 := erp.relate_payments_to_bills();
    v_cases := v_cases + 1;
    case_name := 'a payment made before is related to the bill it paid, from its line, once however often asked';
    passed := v_state is null and v_n1 = 1 and v_n2 = 0
          and exists (select 1 from erp.document_relation rel
                       where rel.tenant_id = v_tenant and rel.from_document_id = v_pmt
                         and rel.to_document_id = v_bill and rel.relation_kind = 'settles'
                         and rel.from_line_id is not null);
    detail := coalesce(v_state, format('first %s, again %s', v_n1, v_n2));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_PAYMENT_SETTLES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.payment_settles_suite() from public, anon;

comment on function erp_test.payment_settles_suite() is
  'A payment settles the bills it paid (20261010012000): the payment lists the bill and the bill the payment, the '
  'payment names its run, and a payment made before is related once.';

create or replace function erp_test.assert_payment_settles_suite()
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
    from erp_test.payment_settles_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PAYMENT_SETTLES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A supplier payment and the bill it paid do not name each other, or the payment does not name its run. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_PAYMENT_SETTLES_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('payment settles: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_payment_settles_suite() from public, anon;

comment on function erp_test.assert_payment_settles_suite() is
  'A supplier payment is related to the bills it paid, and names its run (20261010012000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Every organisation's payments, and said
-- ─────────────────────────────────────────────────────────────────────────────

do $relate$
declare
  r   record;
  v_n integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null
              and exists (select 1 from erp.document d
                            join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                           where d.tenant_id = tn.id and dt.base_type_code = 'cash_payment')
            order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.relate_payments_to_bills();
    -- The checks the writes left waiting, fired while still in the
    -- organisation they read, so the generators below can alter the tables.
    set constraints all immediate;
    if v_n > 0 then
      raise warning 'payments settle their bills: % relation(s) added in %', v_n, r.code;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$relate$;

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
