-- A figure says which money it is.
--
-- Four places where a number on a screen was not the number it claimed to be.
-- Three of them are in the database and are fixed here; the fourth is in the
-- screens alone. Each is the same mistake in a different disguise — a figure
-- that does not say, or does not know, which currency it is in, or which
-- charges it added up.
--
-- 1. AN INVOICE TOTAL INCLUDED A CHARGE THAT APPEARED IN NO COLUMN.
--
--    20260914079000 gave erp_meta.contract_invoice a one_off_minor column and
--    taught erp.issue_contract_invoice to set
--
--        total_minor = subscription_minor + overage_minor + one_off_minor
--
--    but neither door that returns an invoice to a screen was widened to
--    return it. The console showed Subscription, Overage and Total, and an
--    invoice carrying £2,500 of onboarding read as a Total £2,500 larger than
--    its own columns, with nothing on the screen to say where the difference
--    came from. The customer's own view of its agreement had the same hole.
--    Both doors now return one_off_minor.
--
--    The same two doors were inconsistent about a *scheduled* invoice. They
--    return the overage it would carry today — priced live from the meters, so
--    that nothing on the issued invoice is a surprise — while total_minor was
--    the stored column, which at scheduling time is the subscription and
--    nothing else. A row could read Subscription 1,095 / Overage 250 /
--    Total 1,095: a total that totals nothing on its own row.
--
--    Of the two ways out — teach the screen to add up, or make the door hand
--    back a figure that is already right — this takes the second. A total is
--    arithmetic over money, and the reason the screens got it wrong twice is
--    that the arithmetic was theirs to get wrong. So erp.contract_invoice_as_shown()
--    decides, once, what an invoice shows: its lines, its overage and its
--    total, with a scheduled invoice's overage and total taken from the live
--    lines and an issued one's from the columns that were reconciled when it
--    was issued. Both doors read it, so the customer and the vendor cannot see
--    different totals for the same invoice, and neither screen adds anything
--    up.
--
--    The stored column is untouched: this changes what is shown, not what is
--    owed. A scheduled invoice's total is what it would come to if it were
--    issued now, which is the only total a scheduled invoice can honestly
--    have.
--
-- 2. REVENUE AGGREGATES ADDED MINOR UNITS ACROSS CURRENCIES.
--
--    erp.revenue_report() summed annual_value_minor over every contract in
--    force with no group by currency and no conversion, and the console then
--    labelled the result with whatever currency the first gross-margin row
--    happened to carry. A hundred thousand yen and a thousand pounds came back
--    as 10,100,000 "pounds". Every money figure in the report was built that
--    way: ARR, MRR, the average contract value, the value by plan, the ARR
--    lost to churn, the revenue at risk and the invoice position.
--
--    It has never been wrong in production, because every contract so far is
--    in GBP. It would have been wrong on the day the second currency was sold,
--    and it would have been wrong quietly.
--
--    The app already holds the principle and the primitive — src/lib/money.ts:
--    "Summing a pound and a dollar gives a number that is neither", and
--    formatMinorTotals(), which totals per currency and prints them side by
--    side. So the report now groups by currency and returns one row per
--    currency for each money figure, and the console renders them through that
--    same primitive. The keys carry _by_currency in their names, because a key
--    called arr_minor holding a list of currencies would be the next version of
--    this bug.
--
-- 3. THE NEW-DOCUMENT FORM CONVERTED TYPED PRICES WITH GBP'S EXPONENT.
--
--    src/components/erp/documents.tsx hardcoded "GBP" into minorUnitsOf(), so
--    a price typed against a zero-decimal currency — JPY, KRW, where
--    erp_ref.currency.minor_units is 0 — was multiplied by a hundred on its
--    way into the ledger. It sent no p_currency either, so the database
--    resolved the real currency itself from the company's base currency and
--    the two never had to agree.
--
--    The screen could not have known better: public.erp_document_types() did
--    not say what currency a document of that type would be opened in. It does
--    now — the base currency of the company the type belongs to, which is
--    exactly what erp.create_document() falls back to when no currency is
--    given. Null only when the type names no company, and a type like that
--    cannot open a document at all (erp.open_document raises ERPWARE_NO_ENTITY).
--
-- The fourth defect — the console's quote builder pricing in GBP whatever the
-- quote's currency — is in src/lib/quote-builder.ts alone. erp.add_quote_line
-- has always priced from the quote's own currency, so the screen was
-- disagreeing with what would actually be charged; the fix is to make the
-- builder's currency argument compulsory, and there is nothing for a migration
-- to do about it.
--
-- Nothing here is needle-patched from an original file without first reading
-- what came after it. erp.my_agreement() has been patched three times since
-- 20260904620000 (tax statement, payment details, commercial documents), so it
-- is patched again rather than re-emitted. public.erp_platform_invoices() was
-- altered to VOLATILE by 20260904720000, which is why it is patched from
-- pg_get_functiondef() — which carries the volatility — rather than re-emitted
-- from a file that says STABLE.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What an invoice shows
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.contract_invoice_as_shown(p_invoice_id uuid)
returns table (lines jsonb, overage_minor bigint, total_minor bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare i erp_meta.contract_invoice; v_lines jsonb; v_over bigint;
begin
  select * into i from erp_meta.contract_invoice where id = p_invoice_id;
  if not found then
    return;
  end if;

  -- A scheduled invoice has no lines of its own yet: what it would carry is
  -- priced live from the meters, the same figures the customer's usage view
  -- shows. An issued one carries the lines it was reconciled against.
  v_lines := case when i.status = 'scheduled'
                  then erp.invoice_overage_lines(p_invoice_id)
                  else coalesce(i.lines, '[]'::jsonb) end;

  select coalesce(sum((x ->> 'net_minor')::bigint) filter (where x ->> 'kind' = 'overage'), 0)
    into v_over
    from jsonb_array_elements(v_lines) x;

  return query select
    v_lines,
    case when i.status = 'scheduled' then v_over else i.overage_minor end,
    -- The total of the parts beside it. For a scheduled invoice the stored
    -- column is the subscription alone, which is not the total of anything the
    -- screen shows; for an issued one the column was written by
    -- erp.issue_contract_invoice() as exactly this sum and is used as it
    -- stands.
    case when i.status = 'scheduled'
         then i.subscription_minor + v_over + i.one_off_minor
         else i.total_minor end;
end;
$$;

comment on function erp.contract_invoice_as_shown(uuid) is
  'What one contract invoice shows: its lines, its overage and its total. One '
  'place, so the vendor console and the customer''s own view of its agreement '
  'cannot disagree, and neither screen has to add money up itself. A scheduled '
  'invoice''s overage and total are priced live from the meters; an issued '
  'one''s are the columns reconciled when it was issued. Reads no more than the '
  'invoice it is given, and is reached only from doors that have already '
  'decided who may see it.';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'contract_invoice_as_shown',
   'Reads one row of erp_meta.contract_invoice, which is platform_internal, and calls erp.invoice_overage_lines() which is a definer for the same reason. It authorises nothing and is reached only from erp.my_agreement() — scoped to the caller''s own organisation — and public.erp_platform_invoices(), gated by erp_meta.require_platform(''support''). Not in the invoker reach, so no caller holds execute on it.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ── The vendor's view of a contract's invoices ───────────────────────────────

do $vendor$
declare
  v_sig   constant text := 'public.erp_platform_invoices(uuid)';
  v_def   text := pg_get_functiondef('public.erp_platform_invoices(uuid)'::regprocedure);
  v_pairs text[][] := array[
    array[$n$'overage_minor', i.overage_minor, 'total_minor', i.total_minor, 'status', i.status,$n$,
          $n$'overage_minor', s.overage_minor, 'one_off_minor', i.one_off_minor, 'total_minor', s.total_minor, 'status', i.status,$n$],
    array[$n$'lines', case when i.status = 'scheduled' then erp.invoice_overage_lines(i.id) else i.lines end)$n$,
          $n$'lines', s.lines)$n$],
    array[$n$from erp_meta.contract_invoice i where i.contract_id = p_contract_id$n$,
          $n$from erp_meta.contract_invoice i
                          cross join lateral erp.contract_invoice_as_shown(i.id) s
                    where i.contract_id = p_contract_id$n$]];
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    if (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]) <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry "%" exactly once', v_sig, left(v_pairs[i][1], 80)
        using hint = 'A later migration changed what the console reads of a contract''s invoices. Read pg_get_functiondef() of it and patch that body.';
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  execute v_def;
  if position('erp.contract_invoice_as_shown(i.id)' in pg_get_functiondef(v_sig::regprocedure)) = 0
     or position($n$'one_off_minor', i.one_off_minor$n$ in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needles with pg_get_functiondef() of the function.';
  end if;
end
$vendor$;

-- ── The customer's own view of the same invoices ─────────────────────────────

do $agreement$
declare
  v_sig   constant text := 'erp.my_agreement()';
  v_def   text := pg_get_functiondef('erp.my_agreement()'::regprocedure);
  v_pairs text[][] := array[
    array[$n$'overage_minor', i.overage_minor, 'total_minor', i.total_minor, 'status', i.status,$n$,
          $n$'overage_minor', s.overage_minor, 'one_off_minor', i.one_off_minor, 'total_minor', s.total_minor, 'status', i.status,$n$],
    array[$n$'lines', case when i.status = 'scheduled' then erp.invoice_overage_lines(i.id) else i.lines end)$n$,
          $n$'lines', s.lines)$n$],
    array[$n$from erp_meta.contract_invoice i where i.tenant_id = v_tenant$n$,
          $n$from erp_meta.contract_invoice i
                                 cross join lateral erp.contract_invoice_as_shown(i.id) s
                           where i.tenant_id = v_tenant$n$]];
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    if (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]) <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry "%" exactly once', v_sig, left(v_pairs[i][1], 80)
        using hint = 'A later migration changed what the customer reads of its own invoices. Read pg_get_functiondef() of it and patch that body.';
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  execute v_def;
  if position('erp.contract_invoice_as_shown(i.id)' in pg_get_functiondef(v_sig::regprocedure)) = 0
     or position($n$'one_off_minor', i.one_off_minor$n$ in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needles with pg_get_functiondef() of the function.';
  end if;
  -- The three patches this body has already taken are still on it.
  if position($n$'tax_statement', i.tax_statement$n$ in pg_get_functiondef(v_sig::regprocedure)) = 0
     or position('erp.platform_payment_details()' in pg_get_functiondef(v_sig::regprocedure)) = 0
     or position('erp.organisation_commercial_documents(v_tenant)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PATCH_LOST: % no longer carries what 20260914093000, 20260914097300 and 20260915020000 put on it', v_sig
      using hint = 'The body was re-emitted from an older file somewhere. Patch pg_get_functiondef() instead.';
  end if;
end
$agreement$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Revenue, one figure per currency
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Re-emitted rather than patched, because grouping by currency changes the
-- shape of nearly every figure in it. The one change made to this body since
-- 20260904620000 — 20260914079000 replacing set_config('erp.job_tenant_id', …)
-- with erp_meta.act_in_tenant() — is carried forward deliberately, and asserted
-- below so that carrying it forward is not something anybody has to take on
-- trust.

create or replace function erp.revenue_report()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_platform uuid; v_margin jsonb := '[]'::jsonb; c record; m jsonb;
begin
  select po.tenant_id into v_platform from erp_meta.platform_organisation po;
  -- Gross margin per organisation, from the cost model behind the quote each
  -- contract was made from. Read in the platform organisation's context.
  if v_platform is not null then
    perform erp_meta.act_in_tenant(v_platform);
    for c in select x.id, x.tenant_code, x.quote_document_id, x.annual_value_minor, x.currency from erp_meta.contract x where x.status in ('active', 'terminating') loop
      m := erp.quote_margin(c.quote_document_id);
      v_margin := v_margin || jsonb_build_array(jsonb_build_object(
        'tenant_code', c.tenant_code, 'annual_value_minor', c.annual_value_minor, 'currency', c.currency,
        'cost_minor', m -> 'totals' -> 'cost_minor', 'margin_minor', m -> 'totals' -> 'margin_minor',
        'margin_pct', m -> 'totals' -> 'margin_pct'));
    end loop;
    perform erp_meta.stop_acting_in_tenant();
  end if;
  return jsonb_build_object(
    -- Every money figure is a list of one amount per currency. A single figure
    -- would have to be in some currency, and adding minor units across
    -- currencies gives a number that is in none of them.
    'arr_by_currency', coalesce((select jsonb_agg(jsonb_build_object('currency', a.currency, 'minor', a.v) order by a.v desc)
                                   from (select currency, sum(annual_value_minor)::bigint v from erp_meta.contract
                                          where status in ('active', 'terminating') group by currency) a), '[]'::jsonb),
    'mrr_by_currency', coalesce((select jsonb_agg(jsonb_build_object('currency', a.currency, 'minor', a.v) order by a.v desc)
                                   from (select currency, round(sum(annual_value_minor) / 12.0)::bigint v from erp_meta.contract
                                          where status in ('active', 'terminating') group by currency) a), '[]'::jsonb),
    'contracts_in_force', (select count(*) from erp_meta.contract where status in ('active', 'terminating')),
    'average_contract_value_by_currency', coalesce((select jsonb_agg(jsonb_build_object('currency', a.currency, 'minor', a.v) order by a.v desc)
                                   from (select currency, round(avg(annual_value_minor))::bigint v from erp_meta.contract
                                          where status in ('active', 'terminating') group by currency) a), '[]'::jsonb),
    -- A plan sold in two currencies is two rows, not one row of nonsense.
    'by_plan', coalesce((select jsonb_agg(jsonb_build_object('plan_code', x.plan_code, 'currency', x.currency, 'contracts', x.n, 'arr_minor', x.v) order by x.v desc)
                           from (select plan_code, currency, count(*) n, sum(annual_value_minor)::bigint v from erp_meta.contract
                                  where status in ('active', 'terminating') group by plan_code, currency) x), '[]'::jsonb),
    'by_capability', coalesce((select jsonb_agg(jsonb_build_object('capability_code', x.capability_code, 'contracts', x.n) order by x.n desc)
                                 from (select cc.capability_code, count(distinct cc.contract_id) n
                                         from erp_meta.contract_capability cc join erp_meta.contract ct on ct.id = cc.contract_id
                                        where ct.status in ('active', 'terminating') and cc.effective_from <= current_date and (cc.effective_to is null or cc.effective_to > current_date)
                                        group by cc.capability_code) x), '[]'::jsonb),
    'gross_margin', v_margin,
    'renewals_last_12_months', jsonb_build_object(
      'accepted', (select count(*) from erp_meta.renewal where status = 'accepted' and decided_at >= now() - interval '12 months'),
      'declined', (select count(*) from erp_meta.renewal where status = 'declined' and decided_at >= now() - interval '12 months'),
      'lapsed', (select count(*) from erp_meta.renewal where status = 'lapsed' and decided_at >= now() - interval '12 months'),
      'renewal_rate_pct', (select case when count(*) = 0 then null else round(100.0 * count(*) filter (where status = 'accepted') / count(*), 1) end
                             from erp_meta.renewal where status in ('accepted', 'declined', 'lapsed') and decided_at >= now() - interval '12 months')),
    'churn', jsonb_build_object(
      'contracts_ended_last_12_months', (select count(*) from erp_meta.contract where status in ('expired', 'terminated') and updated_at >= now() - interval '12 months'),
      'arr_lost_by_currency', coalesce((select jsonb_agg(jsonb_build_object('currency', a.currency, 'minor', a.v) order by a.v desc)
                                          from (select currency, sum(annual_value_minor)::bigint v from erp_meta.contract
                                                 where status in ('expired', 'terminated') and updated_at >= now() - interval '12 months'
                                                 group by currency) a), '[]'::jsonb)),
    'revenue_at_risk', coalesce((
      -- Within the next two notice windows, with no renewal accepted.
      select jsonb_agg(jsonb_build_object('tenant_code', x.tenant_code, 'annual_value_minor', x.annual_value_minor, 'currency', x.currency,
                                          'notice_deadline', (x.current_term_end - x.notice_days)::date, 'renewal_status',
                                          (select r.status from erp_meta.renewal r where r.contract_id = x.id and r.term_start = x.current_term_end))
                       order by x.current_term_end)
        from erp_meta.contract x
       where x.status in ('active', 'terminating')
         and (x.current_term_end - x.notice_days)::date <= current_date + 2 * x.notice_days
         and not exists (select 1 from erp_meta.renewal r where r.contract_id = x.id and r.term_start = x.current_term_end and r.status = 'accepted')), '[]'::jsonb),
    'revenue_at_risk_by_currency', coalesce((select jsonb_agg(jsonb_build_object('currency', a.currency, 'minor', a.v) order by a.v desc)
                                               from (select x.currency, sum(x.annual_value_minor)::bigint v from erp_meta.contract x
                                                      where x.status in ('active', 'terminating')
                                                        and (x.current_term_end - x.notice_days)::date <= current_date + 2 * x.notice_days
                                                        and not exists (select 1 from erp_meta.renewal r where r.contract_id = x.id and r.term_start = x.current_term_end and r.status = 'accepted')
                                                      group by x.currency) a), '[]'::jsonb),
    'invoices', jsonb_build_object(
      'scheduled_by_currency', coalesce((select jsonb_agg(jsonb_build_object('currency', a.currency, 'minor', a.v) order by a.v desc)
                                           from (select currency, sum(total_minor)::bigint v from erp_meta.contract_invoice
                                                  where status = 'scheduled' group by currency) a), '[]'::jsonb),
      'issued_by_currency', coalesce((select jsonb_agg(jsonb_build_object('currency', a.currency, 'minor', a.v) order by a.v desc)
                                        from (select currency, sum(total_minor)::bigint v from erp_meta.contract_invoice
                                               where status = 'issued' group by currency) a), '[]'::jsonb),
      'paid_by_currency', coalesce((select jsonb_agg(jsonb_build_object('currency', a.currency, 'minor', a.v) order by a.v desc)
                                      from (select currency, sum(total_minor)::bigint v from erp_meta.contract_invoice
                                             where status = 'paid' group by currency) a), '[]'::jsonb),
      'overage_issued_by_currency', coalesce((select jsonb_agg(jsonb_build_object('currency', a.currency, 'minor', a.v) order by a.v desc)
                                                from (select currency, sum(overage_minor)::bigint v from erp_meta.contract_invoice
                                                       where status in ('issued', 'paid') group by currency) a), '[]'::jsonb)),
    'renewals', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'tenant_code', ct.tenant_code, 'term_start', r.term_start, 'term_end', r.term_end,
                                                              'uplift_pct', r.uplift_pct, 'previous_annual_value_minor', r.previous_annual_value_minor,
                                                              'proposed_annual_value_minor', r.proposed_annual_value_minor, 'currency', r.currency,
                                                              'notice_deadline', r.notice_deadline, 'status', r.status, 'quote_document_id', r.quote_document_id)
                                         order by r.term_start)
                            from erp_meta.renewal r join erp_meta.contract ct on ct.id = r.contract_id), '[]'::jsonb));
end;
$$;

comment on function erp.revenue_report() is
  'Specification v1.5 §17.10, per currency. Every money figure is a list of '
  'one amount per currency, because summing minor units across currencies '
  'gives a number in none of them. Read in the platform organisation''s '
  'context for the gross margin behind each contract''s quote.';

-- The borrowed-organisation change 20260914079000 made to this body is still
-- on it, and the way it was written before is not.
do $acting$
declare v_def constant text := pg_get_functiondef('erp.revenue_report()'::regprocedure);
begin
  if position('erp_meta.act_in_tenant(v_platform)' in v_def) = 0
     or position('erp_meta.stop_acting_in_tenant()' in v_def) = 0
     or position('erp.job_tenant_id' in v_def) > 0 then
    raise exception 'CLOVEERP_PATCH_LOST: erp.revenue_report() does not borrow the platform organisation the way 20260914079000 left it'
      using hint = 'Re-emit it calling erp_meta.act_in_tenant() and erp_meta.stop_acting_in_tenant(), never set_config(''erp.job_tenant_id'', …).';
  end if;
end
$acting$;

-- The suite that reads the report reads it the new way, and says the currency
-- out loud. It asserted an ARR of 1,260,000 with nothing to say what 1,260,000
-- was — which is the defect, written down as a passing test.

do $suite$
declare
  v_sig   constant text := 'erp_test.commercial_renewal_suite()';
  v_def   text := pg_get_functiondef('erp_test.commercial_renewal_suite()'::regprocedure);
  v_pairs text[][] := array[
    array[$n$    (res ->> 'arr_minor')::bigint = 1260000 and (res ->> 'mrr_minor')::bigint = 105000
    and (res -> 'by_plan' -> 0 ->> 'plan_code') = 'standard'$n$,
          $n$    (res -> 'arr_by_currency' -> 0 ->> 'minor')::bigint = 1260000
    and (res -> 'arr_by_currency' -> 0 ->> 'currency') = 'GBP'
    and jsonb_array_length(res -> 'arr_by_currency') = 1
    and (res -> 'mrr_by_currency' -> 0 ->> 'minor')::bigint = 105000
    and (res -> 'by_plan' -> 0 ->> 'plan_code') = 'standard'
    and (res -> 'by_plan' -> 0 ->> 'currency') = 'GBP'$n$],
    array[$n$    format('ARR %s, MRR %s, renewal rate %s%%', res ->> 'arr_minor', res ->> 'mrr_minor', res -> 'renewals_last_12_months' ->> 'renewal_rate_pct');$n$,
          $n$    format('ARR %s %s, MRR %s, renewal rate %s%%', res -> 'arr_by_currency' -> 0 ->> 'currency', res -> 'arr_by_currency' -> 0 ->> 'minor', res -> 'mrr_by_currency' -> 0 ->> 'minor', res -> 'renewals_last_12_months' ->> 'renewal_rate_pct');$n$]];
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    if (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]) <> 1 then
      raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % does not read the revenue report the way 20260904620000 left it', v_sig
        using hint = 'Read pg_get_functiondef() of the suite and turn round the case that reads arr_minor.';
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  execute v_def;
  if position('arr_by_currency' in pg_get_functiondef(v_sig::regprocedure)) = 0
     or position($n$res ->> 'arr_minor'$n$ in pg_get_functiondef(v_sig::regprocedure)) > 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % did not take the replacement', v_sig;
  end if;
end
$suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A document type says which money it opens documents in
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Re-emitted from the 20260831130000 body, which is the latest definition of
-- this door; nothing has patched it since. One column added: the base currency
-- of the company the type belongs to, which is the currency
-- erp.create_document() gives a document when the caller names none. Null only
-- when the type names no company, and such a type cannot open a document at
-- all — erp.open_document() raises ERPWARE_NO_ENTITY first.

create or replace function public.erp_document_types(p_base_type_code text default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'document_type_id', dt.id,
           'code', dt.code,
           'name', dt.name,
           'base_type_code', dt.base_type_code,
           'requires_party', bt.requires_party,
           'requires_site', bt.requires_site,
           'currency', e.base_currency,
           'create_permission',
             coalesce(dt.create_permission, bt.create_permission))
           order by dt.code), '[]'::jsonb)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
    left join erp.entity e on e.tenant_id = dt.tenant_id and e.id = dt.entity_id
   where dt.tenant_id = erp.current_tenant_id()
     and dt.status = 'active'::erp.record_status
     and (p_base_type_code is null or dt.base_type_code = p_base_type_code)
$fn$;

comment on function public.erp_document_types(text) is
  'The organisation''s configured document types: the tenant''s own code and '
  'name, the base type behind it, whether it needs a party or a site, the '
  'currency a document of this type is opened in — the company''s base '
  'currency — and the permission erp.open_document() will authorise.';

revoke all on function public.erp_document_types(text) from public, anon;
grant execute on function public.erp_document_types(text) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The word for the new column
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The organisation's own view of its invoices gains a One-off column beside
-- Subscription and Overage, so it needs a row it can be renamed by — the
-- console's own column needs none, because the console says its words as
-- caption props rather than through ui().

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('One-off', 'The column on an invoice for what is charged once rather than every period: onboarding, implementation, a pilot. Beside Subscription and Overage.')
) as v(text, why)
on conflict (key, locale) do nothing;

do $words$
declare v_missing text;
begin
  select string_agg(quote_literal(t.text), ', ' order by t.text) into v_missing
    from (values ('One-off')) as t(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(t.text) and r.locale = 'en');
  if v_missing is not null then
    raise exception 'CLOVEERP_SCREEN_WORDS_MISSING: % have no en row', v_missing;
  end if;
end
$words$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_vocabulary_aligned();
select erp.assert_resource_coverage('en');
