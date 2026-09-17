set lock_timeout = '30s';

-- =============================================================================
-- 20260919010000  A limit nobody was sold
-- -----------------------------------------------------------------------------
-- 20260904190000 gave every plan seven numbers. Five of them are on the price
-- list at src/routes/product.tsx: full users, light users, companies, sites,
-- and — in words rather than a figure — sandbox environments. Two are not:
--
--     documents_per_month     2,000 Starter / 50,000 Standard / unlimited
--     movements_per_month    10,000 Starter / 500,000 Standard / unlimited
--
-- A Starter organisation posting its two thousand and first document this month
-- would have been told off for crossing a line it was never shown. The price
-- list does not mention a document allowance, a movement allowance, or a
-- transaction band of any kind; it says the opposite, in the sentence under the
-- plan cards: "No per-transaction fees".
--
-- The owner's decision is to remove them. What follows is what remove had to
-- mean, and why the smaller reading was not available.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Why deleting the plan rows on their own is not an option
--
-- erp.entitlement_enforcement_report() finding 2 crosses every plan with every
-- registered kind and reports "a plan states no limit for an entitlement",
-- because an absent row is indistinguishable from a limit somebody forgot.
-- Deleting the six erp_meta.plan_entitlement rows therefore fails
-- erp.assert_entitlements_enforceable() on the next build. The only way to keep
-- the kind and lose the figure is to write null in all six — and null in that
-- table does not mean "no such limit", it means "unlimited, stated on purpose".
-- That is a statement about a limit, not the absence of one.
--
-- And it would leave the machinery standing. erp_meta.entitlement_kind is the
-- register of "each limit a plan can express, bound to the routine that refuses
-- when it is exceeded". While a row is in it:
--
--   * the contract amendment form (src/components/platform/amendment-form.tsx)
--     offers "Documents posted" in its entitlement dropdown, so an operator can
--     sell a document cap that no price list carries;
--   * the price-book screen offers it as a band an item can be priced against;
--   * erp.report_entitlement_breaches() sweeps it for every organisation and
--     raises commercial.entitlement_exceeded against anyone over it;
--   * erp.invoice_overage_lines() reconciles it on every invoice and prices the
--     excess per unit.
--
-- The kind IS the claim that the limit exists. So the kind goes.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What is NOT removed, and where the measurement went
--
-- The meters stay, untouched: erp_meta.meter_kind keeps documents_posted and
-- movements_recorded, erp_meta.usage_meter keeps every reading, erp.record_meter()
-- and the two metering paths in 20260904510000 are not altered, and §18.2 is
-- honoured exactly as before — because erp.my_agreement() already returns those
-- readings under 'meters', read straight from erp_meta.usage_meter and joined to
-- erp_meta.meter_kind for the title and unit, and /administration/commercial
-- already renders them in their own panel. Measuring what an organisation does
-- is capacity work and billing evidence. Refusing it, reporting it as a breach
-- and charging for it were the parts nobody was sold, and only those go.
--
-- Also untouched, deliberately:
--
--   retention_months  — not a cap that refuses anything. It is the promise about
--                       how long history is kept, read by retention to decide
--                       how far back to hold. Removing it would commit the
--                       company to keeping everything for ever.
--   environments      — the pricing page sells Enterprise partly on "more
--                       sandbox environments", so it is disclosed, in words.
--   users, light_users, companies, sites — on the price list, and the Definition
--                       of Done requires them enforced.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- The overage engine stops having anything to reconcile
--
-- erp.invoice_overage_lines() is the only routine that named the two codes
-- outright. With the register rows gone its loop is over nothing, so it returns
-- no lines and every invoice is the subscription alone: the behaviour is right
-- the moment the rows go, without the routine being touched.
--
-- The first version of this migration re-emitted it anyway, on the grounds that
-- a body naming two codes the register no longer holds reads as a volume band
-- the product sells. The build refused that, and section 4 carries the reason
-- at length: the band arithmetic inside it is the only thing in the schema that
-- consults erp.price_item.band_from, and deleting it turned the price-book
-- screen's "Band from" field into a control that changes nothing. Removing an
-- undisclosed cap is not a licence to leave a new hole behind. The routine
-- keeps its body and gets a new comment.
--
-- What is NOT touched either: src/lib/pdf/commercial-document.ts and
-- src/lib/email/commercial-email.ts still render an overage line, and their
-- tests still fixture one. erp_meta.contract_invoice.lines is stored jsonb; an
-- invoice issued before today keeps whatever it was issued with, and it must
-- still print. A renderer that could not draw a historical invoice would be a
-- second defect, not a tidy-up.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Three suites read these kinds, and each is turned round rather than deleted
--
--   erp_test.metering_suite()  used erp.entitlement_usage('documents_per_month')
--     as a way of READING the meter. The meter is what it is about, so it reads
--     erp_meta.usage_meter directly and proves exactly what it proved before.
--
--   erp_test.commercial_suite()  read the same figure back through
--     erp.entitlement_report() to show §18.2's "the number on an invoice is one
--     the customer has already seen". It now reads the meter and its unit, and
--     gains three cases: a Starter organisation is taken far past both old
--     thresholds and proved to be reported against neither and refused nothing,
--     including when erp.require_entitlement() is called directly, which is
--     §18.1's own threat model. Twenty-one cases become twenty-four and the
--     wrapper's pin moves with them.
--
--   erp_test.commercial_renewal_suite()  sold a DOCS-100K band on a contract and
--     asserted an invoice carrying £1,000 of overage. It now posts the same
--     60,000 documents and asserts the invoice carries the quarter's
--     subscription and nothing else. The case count does not move; the
--     assertion turns round, which is the point.
--
-- Everything is anchored on the live body read through pg_get_functiondef(),
-- not on the file: 20260914095000 patched erp.entitlement_usage(),
-- 20260912240000 patched erp_test.commercial_suite() and its pin, 20260916130000
-- patched erp_test.commercial_renewal_suite(), and 20260904980000 rewrote every
-- refusal prefix in every body. Each needle is required to occur exactly once
-- and each result is read back.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Nothing may be left pointing at the two kinds
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_meta.contract_entitlement references erp_meta.entitlement_kind without a
-- cascade, so a band sold on a contract would block the delete. erp.price_item
-- has no foreign key at all — a band naming a kind that no longer exists would
-- pass every constraint and show up only as a finding in
-- erp.assert_commercial_sound(), which is worse.
--
-- Both are expected to be empty. The platform's own book (erp.set_up_selling,
-- 20260914077000) carries plans, users, companies, sites, onboarding, the pilot
-- and support — no volume band of any kind — and the only DOCS-100K item the
-- repository has ever created lives inside erp_test.commercial_renewal_suite(),
-- whose organisation is purged at the end of it.
--
-- Expected empty is not the same as proven empty, and both tables carry FORCE
-- ROW LEVEL SECURITY, under which a refused DELETE reports nought rows rather
-- than failing. So each statement counts first, deletes, and refuses to
-- continue if it moved fewer rows than it found. A silent no-op here would
-- leave the delete in section 2 to fail on a foreign key with nothing to say.

do $pointers$
declare
  v_found integer;
  v_moved integer;
begin
  select count(*) into v_found from erp_meta.contract_entitlement ce
   where ce.entitlement_code in ('documents_per_month', 'movements_per_month');
  delete from erp_meta.contract_entitlement ce
   where ce.entitlement_code in ('documents_per_month', 'movements_per_month');
  get diagnostics v_moved = row_count;
  if v_moved <> v_found then
    raise exception 'CLOVEERP_REMOVAL_SHORT: cleared % of % contract band(s)', v_moved, v_found
      using hint = 'Row security refused the delete, or something wrote between the count and the write.';
  end if;
  if v_found > 0 then
    raise notice '% contract band(s) on a document or movement volume cleared', v_found;
  end if;

  select count(*) into v_found from erp.price_item pi
   where pi.entitlement_code in ('documents_per_month', 'movements_per_month');
  delete from erp.price_item pi
   where pi.entitlement_code in ('documents_per_month', 'movements_per_month');
  get diagnostics v_moved = row_count;
  if v_moved <> v_found then
    raise exception 'CLOVEERP_REMOVAL_SHORT: cleared % of % priced volume band(s)', v_moved, v_found
      using hint = 'Row security refused the delete, or something wrote between the count and the write.';
  end if;
  if v_found > 0 then
    raise notice '% priced volume band(s) removed from the book', v_found;
  end if;
end
$pointers$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The register
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_meta.plan_entitlement cascades from the kind, so the six plan rows would
-- go on their own. They are deleted first and counted anyway, because six is
-- the number this migration is about and a cascade that silently moved four
-- would mean the seed is not what this header says it is.

do $register$
declare
  v_plans integer;
  v_kinds integer;
  v_left  integer;
begin
  delete from erp_meta.plan_entitlement pe
   where pe.entitlement_code in ('documents_per_month', 'movements_per_month');
  get diagnostics v_plans = row_count;

  delete from erp_meta.entitlement_kind k
   where k.code in ('documents_per_month', 'movements_per_month');
  get diagnostics v_kinds = row_count;

  if v_plans <> 6 or v_kinds <> 2 then
    raise exception 'CLOVEERP_REGISTER_UNRECOGNISED: removed % plan figure(s) and % kind(s), expected 6 and 2',
      v_plans, v_kinds
      using hint = '20260904190000 seeded three plans against two volume kinds. Read '
                   'erp_meta.plan_entitlement before writing this migration again.';
  end if;

  select count(*) into v_left from erp_meta.entitlement_kind;
  raise notice 'a document and a movement volume are no longer limits; % kind(s) remain', v_left;
end
$register$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The counter stops counting them
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.entitlement_usage() branches on a CASE rather than query text held in the
-- register, so removing a kind from the register does not remove it from the
-- function. Its else branch raises CLOVEERP_UNKNOWN_ENTITLEMENT, which is the
-- right answer for a code the product no longer has. v_from and v_to went with
-- the two branches: they were the month window those two reads used, and
-- nothing else in the body refers to them.

do $usage$
declare
  v_sig    constant text := 'erp.entitlement_usage(text,uuid)';
  v_def    text := pg_get_functiondef('erp.entitlement_usage(text,uuid)'::regprocedure);
  v_needles constant text[] := array[
$n$    when 'documents_per_month' then
      select coalesce(sum(m.quantity), 0) into v_used from erp_meta.usage_meter m
       where m.tenant_id = v_tenant and m.meter_code = 'documents_posted'
         and m.period_start >= v_from and m.period_end <= v_to;
    when 'movements_per_month' then
      select coalesce(sum(m.quantity), 0) into v_used from erp_meta.usage_meter m
       where m.tenant_id = v_tenant and m.meter_code = 'movements_recorded'
         and m.period_start >= v_from and m.period_end <= v_to;
$n$,
$n$  v_from   date := date_trunc('month', current_date)::date;
  v_to     date := (date_trunc('month', current_date) + interval '1 month - 1 day')::date;
$n$];
  i integer;
begin
  for i in 1 .. array_length(v_needles, 1) loop
    if (length(v_def) - length(replace(v_def, v_needles[i], ''))) / length(v_needles[i]) <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not count volumes the way 20260904190000 wrote it', v_sig
        using hint = 'Read the live body with pg_get_functiondef() and write the needle against it.';
    end if;
    v_def := replace(v_def, v_needles[i], '');
  end loop;
  execute v_def;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('documents_per_month' in v_def) > 0
     or position('movements_per_month' in v_def) > 0
     or position($n$when 'light_users' then$n$ in v_def) = 0
     or position($n$when 'retention_months' then$n$ in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement, or lost a branch it should have kept', v_sig;
  end if;
end
$usage$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. An invoice charges the subscription and nothing per transaction
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.invoice_overage_lines() walks each month of an invoice period against the
-- two entitlement kinds it names and prices whatever the organisation used
-- beyond its band. With both rows out of the register that loop has nothing to
-- iterate: it returns no lines, erp.issue_contract_invoice() records an overage
-- of nought, and every invoice is its subscription and whatever was charged
-- once. Section 2 is what makes that true; this section changes no behaviour.
--
-- The routine is deliberately NOT re-emitted, and the reason is worth writing
-- down because the first version of this migration got it wrong. That version
-- replaced the body with one that returned no lines, arguing that a body naming
-- two codes the register no longer holds reads as a volume band the product
-- sells. The build refused it:
--
--   CLOVEERP_WRITE_ONLY_COLUMN: erp.price_item.band_from —
--   erp_set_up_selling writes it and nothing decides on it
--
-- The per-unit division in this routine — amount_minor / greatest(band_to −
-- coalesce(band_from, 1) + 1, 1) — is the only arithmetic anywhere in the
-- schema that consults band_from. Delete it and the price-book screen's "Band
-- from" field becomes a control that saves, says it saved and changes nothing,
-- which is the same class of defect as a limit nobody was sold. Removing an
-- undisclosed cap is not a licence to leave a new hole behind.
--
-- So the reconciliation stays exactly as 20260904620000 wrote it, over an empty
-- register, and only its comment changes. The guard below reads the live body
-- and refuses if it is not that one — a later rewrite would take the band
-- arithmetic with it and would have to answer the same question.
--
-- One thing this leaves standing, reported rather than fixed: the band columns
-- and every band kind the price-book screen offers exist for bands the
-- published price list does not sell. That is a question about what the product
-- charges for, not about an undisclosed limit, and it belongs to whoever
-- answers the first.

do $overage$
declare
  v_def constant text := pg_get_functiondef('erp.invoice_overage_lines(uuid)'::regprocedure);
begin
  if position('documents_per_month' in v_def) = 0
     or position('movements_per_month' in v_def) = 0
     or position('volume_band' in v_def) = 0
     or position('coalesce(pi.band_from, 1)' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.invoice_overage_lines(uuid) is not the body 20260904620000 left'
      using hint = 'Something replaced it after 20260904620000. Read the live body: this migration relies on '
                   'its loop having nothing to iterate, and on its band arithmetic being the reader of '
                   'erp.price_item.band_from that erp.assert_write_only_columns() counts.';
  end if;
  if exists (select 1 from erp_meta.entitlement_kind k
              where k.code in ('documents_per_month', 'movements_per_month')) then
    raise exception 'CLOVEERP_REGISTER_UNRECOGNISED: a volume kind is still registered, so this loop still has something to reconcile';
  end if;
end
$overage$;

comment on function erp.invoice_overage_lines is
  'Specification v1.5 §17.10 reconciles an invoice period against the metering '
  'for every entitlement measured by volume. Since 20260919010000 there is no '
  'such entitlement — the two there were appeared on no price list, and the '
  'price list promises no per-transaction fees — so this iterates nothing and '
  'an invoice carries its subscription and whatever was charged once. The '
  'reconciliation is kept whole rather than deleted: it is where a volume band '
  'belongs if one is ever registered, priced on the book AND published '
  'together, and its band arithmetic is what reads erp.price_item.band_from.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The metering suite reads the meter
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Four reads, two distinct expressions. The suite is about whether a posting
-- path and a stock writer record a meter at all, and it was asking the
-- entitlement layer for the answer; it asks erp_meta.usage_meter instead, over
-- the same month window erp.entitlement_usage() used. Not one case moves.

do $metering$
declare
  v_sig    constant text := 'erp_test.metering_suite()';
  v_def    text := pg_get_functiondef('erp_test.metering_suite()'::regprocedure);
  v_pairs  text[][] := array[
    array[$n$erp.entitlement_usage('documents_per_month', r.tenant_id)$n$,
          $n$(select sum(m2.quantity) from erp_meta.usage_meter m2
           where m2.tenant_id = r.tenant_id and m2.meter_code = 'documents_posted'
             and m2.period_start >= date_trunc('month', current_date)::date)$n$],
    array[$n$erp.entitlement_usage('movements_per_month', r.tenant_id)$n$,
          $n$(select sum(m2.quantity) from erp_meta.usage_meter m2
           where m2.tenant_id = r.tenant_id and m2.meter_code = 'movements_recorded'
             and m2.period_start >= date_trunc('month', current_date)::date)$n$]];
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    if (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]) <> 2 then
      raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % does not read the meter twice per kind the way 20260904510000 wrote it', v_sig
        using hint = 'Read the live body with pg_get_functiondef() and write the needle against it.';
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  execute v_def;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('documents_per_month' in v_def) > 0 or position('movements_per_month' in v_def) > 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % did not take the replacement', v_sig;
  end if;
end
$metering$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The commercial suite proves the removal
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The existing case read 8 documents back through erp.entitlement_report(),
-- which lists the registered kinds; it reads the meter and the unit the meter
-- names, which is what §18.2 actually promises — "in the same units the plan is
-- expressed in, so the number on an invoice is one the customer has already
-- seen" — and is where erp.my_agreement() takes it from.
--
-- Then three new cases, in the order somebody would doubt them:
--
--   1. the register no longer holds either kind, and neither has a limit;
--   2. a Starter organisation is driven far past both old thresholds — 5,008
--      documents against the old 2,000, and 200,000 movements against the old
--      10,000 — the sweep is run, and no commercial.entitlement_exceeded event
--      names either. The sweep DOES still raise one for companies, because this
--      organisation is genuinely over a limit that is on the price list, so the
--      case filters on the payload rather than on the event type: a case that
--      passed only because the sweep found nothing at all would prove nothing.
--   3. erp.require_entitlement() is called directly with a million documents.
--      §18.1's whole premise is that an organisation cannot exceed its plan by
--      calling a function directly; the test of a limit that is gone is that
--      the same direct call refuses nothing.

do $commercial$
declare
  v_sig    constant text := 'erp_test.commercial_suite()';
  v_def    text := pg_get_functiondef('erp_test.commercial_suite()'::regprocedure);
  v_needle constant text :=
$n$  return query select 'and the organisation can read its own meters',
    exists (select 1 from erp.entitlement_report(v_tenant) er
             where er.entitlement_code = 'documents_per_month' and er.used = 8),
    '§18.2: the number on an invoice is one the customer has already seen';
$n$;
  v_new    constant text :=
$n$  return query select 'and the organisation can read its own meters',
    exists (select 1 from erp_meta.usage_meter m
             join erp_meta.meter_kind k on k.code = m.meter_code
            where m.tenant_id = v_tenant and m.meter_code = 'documents_posted'
              and m.quantity = 8 and k.unit = 'documents'),
    '§18.2: the number on an invoice is one the customer has already seen, in the unit the meter names';

  -- ── 20260919010000 a volume is measured, never limited ────────────────────

  perform erp.record_meter('documents_posted', 5000, v_tenant);
  perform erp.record_meter('movements_recorded', 200000, v_tenant);

  return query select 'a document or a movement volume is not a limit the product can express',
    not exists (select 1 from erp_meta.entitlement_kind k
                 where k.code in ('documents_per_month', 'movements_per_month'))
    and erp.entitlement_limit('documents_per_month', v_tenant) is null
    and erp.entitlement_limit('movements_per_month', v_tenant) is null,
    'the Starter figures of 2,000 documents and 10,000 movements were on no price list';

  perform erp.report_entitlement_breaches();
  perform set_config('erp.job_tenant_id', v_tenant::text, true);

  return query select 'and an organisation far past the old figures is reported against neither',
    not exists (select 1 from erp.event e
                 where e.tenant_id = v_tenant
                   and e.event_type = 'commercial.entitlement_exceeded'
                   and e.payload ->> 'entitlement' in ('documents_per_month', 'movements_per_month')),
    '5,008 documents and 200,000 movements this month, and the sweep still names the company it is genuinely over';

  begin
    perform erp.require_entitlement('documents_per_month', 1000000);
    v_ok := true; v_msg := 'permitted';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 80);
  end;
  return query select 'nor refused, even by calling the gate directly with a million documents',
    v_ok,
    v_msg || ' — §18.1''s own threat model, and there is no limit left to exceed';
$n$;
  v_check text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_COMMERCIAL_SUITE_UNRECOGNISED: % does not read the meter through the entitlement report as 20260904190000 left it', v_sig
      using hint = 'Read the live body with pg_get_functiondef() and write the needle against it.';
  end if;
  execute replace(v_def, v_needle, v_new);

  v_check := pg_get_functiondef(v_sig::regprocedure);
  -- The 20260912240000 repair has to have survived: it is the reason §18.3 is
  -- asked of the organisation's own administrator rather than of platform staff.
  if position('but the platform owner is not locked out of it' in v_check) = 0
     or position($n$delete from auth.users where id in (ow, ad);$n$ in v_check) = 0 then
    raise exception 'CLOVEERP_COMMERCIAL_SUITE_UNRECOGNISED: % lost the 20260912240000 repair', v_sig;
  end if;
  if position('erp.entitlement_report(v_tenant)' in v_check) > 0
     or position('a million documents' in v_check) = 0 then
    raise exception 'CLOVEERP_COMMERCIAL_SUITE_UNRECOGNISED: % did not take the replacement', v_sig;
  end if;
end
$commercial$;

-- Twenty-one cases become twenty-four, deliberately. The guard also prints what
-- failed: a suite that stops short because its fixture threw reports a count
-- nobody can read without the error beside it.
do $pin$
declare
  v_sig    constant text := 'erp_test.assert_commercial_suite()';
  v_def    text := pg_get_functiondef('erp_test.assert_commercial_suite()'::regprocedure);
  v_needle constant text :=
$n$  if v_total <> 21 then
    raise exception
      'CLOVEERP_COMMERCIAL_SUITE_SHRANK: % case(s), expected 21', v_total
      using errcode = 'P0001',
            hint = 'A suite that reports n/n without saying what n should be '
                   'cannot notice a test that stopped running.';
  end if;$n$;
  v_new    constant text :=
$n$  if v_total <> 24 then
    raise exception
      'CLOVEERP_COMMERCIAL_SUITE_SHRANK: % case(s), expected 24', v_total
      using errcode = 'P0001',
            detail = coalesce(v_detail, 'every case that ran passed; the suite stopped short'),
            hint = 'A suite that reports n/n without saying what n should be '
                   'cannot notice a test that stopped running. 20260919010000 '
                   'added three cases for the volume limits it removed.';
  end if;$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_COMMERCIAL_PIN_UNRECOGNISED: % does not pin 21 cases', v_sig
      using hint = 'Read the live body with pg_get_functiondef() and write the needle against it.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('expected 24' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_COMMERCIAL_PIN_UNRECOGNISED: % did not take the replacement', v_sig;
  end if;
end
$pin$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The renewal suite asserts the opposite of what it asserted
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Four replacements: the fixture that put a DOCS-100K band on the book and
-- priced it, the case that read £1,000 of overage off the issued invoice, the
-- customer-view case that read the same figure back out of erp.my_agreement(),
-- and that case's own detail line, which named the overage. The customer still
-- posts 60,000 documents in the month — that is the whole point of the case —
-- and still sees the reading, now under 'meters' where erp.my_agreement() has
-- always carried it; what has gone is the charge.

do $renewal$
declare
  v_sig   constant text := 'erp_test.commercial_renewal_suite()';
  v_def   text := pg_get_functiondef('erp_test.commercial_renewal_suite()'::regprocedure);
  v_pairs text[][] := array[
    array[$n$  perform erp.upsert_price_item('DOCS-100K', 'Up to 100,000 documents a month', 'volume_band', null, null, 'documents_per_month', 50001, 100000);
  perform erp.set_rate('PB-2026', 'PLAN-STD', 'GBP', 1200000);
  perform erp.set_rate('PB-2026', 'DOCS-100K', 'GBP', 500000);
  perform erp.set_cost_model('PLAN-STD', 'GBP', 300000, 100000, 50000);
  perform erp.set_cost_model('DOCS-100K', 'GBP', 100000, 0, 0);$n$,
          $n$  perform erp.set_rate('PB-2026', 'PLAN-STD', 'GBP', 1200000);
  perform erp.set_cost_model('PLAN-STD', 'GBP', 300000, 100000, 50000);$n$],
    array[$n$  -- The customer posts beyond its band this month; the meter the platform
  -- already keeps says so.
  perform erp.record_meter('documents_posted', 60000, v_customer);
  select i.id into v_inv from erp_meta.contract_invoice i where i.contract_id = v_contract and i.period_start <= current_date and i.period_end > current_date;
  res := erp.issue_contract_invoice(v_inv);
  return query select 'issuing an invoice reconciles the period against the metering and prices the overage from the book',
    (res ->> 'overage_minor')::bigint = 100000
    and (res ->> 'total_minor')::bigint = 300000 + 100000
    and exists (select 1 from jsonb_array_elements(res -> 'lines') x where x ->> 'kind' = 'overage' and (x ->> 'over')::numeric = 10000 and (x ->> 'unit_minor')::numeric = 10),
    '10,000 documents over 50,000 at 10p each from the DOCS-100K band';$n$,
          $n$  -- The customer posts a great many documents this month; the meter the
  -- platform already keeps says so, and since 20260919010000 that is all it
  -- does. There is no volume band to exceed and none on the price list.
  perform erp.record_meter('documents_posted', 60000, v_customer);
  select i.id into v_inv from erp_meta.contract_invoice i where i.contract_id = v_contract and i.period_start <= current_date and i.period_end > current_date;
  res := erp.issue_contract_invoice(v_inv);
  return query select 'issuing an invoice charges the subscription and nothing per transaction',
    (res ->> 'overage_minor')::bigint = 0
    and (res ->> 'total_minor')::bigint = 300000
    and not exists (select 1 from jsonb_array_elements(res -> 'lines') x where x ->> 'kind' = 'overage'),
    '60,000 documents in the month and the invoice is the quarter''s subscription of 3,000';$n$],
    array[$n$    and exists (select 1 from jsonb_array_elements(res -> 'entitlements') e where e ->> 'entitlement_code' = 'documents_per_month' and (e ->> 'used')::numeric = 60000)
    and exists (select 1 from jsonb_array_elements(res -> 'invoices') i where i ->> 'status' = 'issued' and (i ->> 'overage_minor')::bigint = 100000)$n$,
          $n$    and exists (select 1 from jsonb_array_elements(res -> 'meters') m where m ->> 'meter_code' = 'documents_posted' and (m ->> 'quantity')::numeric = 60000)
    and exists (select 1 from jsonb_array_elements(res -> 'invoices') i where i ->> 'status' = 'issued' and (i ->> 'overage_minor')::bigint = 0)$n$],
    array[$n$    'the same overage the invoice carries, the notice deadline, the uplift rule';$n$,
          $n$    'the reading the invoice was reconciled against, the notice deadline, the uplift rule';$n$]];
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    if (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]) <> 1 then
      raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % does not sell and bill a document band the way 20260904620000 left it', v_sig
        using hint = 'Read the live body with pg_get_functiondef() and write the needle against it.';
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  execute v_def;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('DOCS-100K' in v_def) > 0
     or position('documents_per_month' in v_def) > 0
     or position('nothing per transaction' in v_def) = 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % did not take the replacement', v_sig;
  end if;
  -- The 20260916130000 repair has to have survived: it is the reason the
  -- revenue case says which currency its figure is in.
  if position('arr_by_currency' in v_def) = 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % lost the 20260916130000 repair', v_sig;
  end if;
end
$renewal$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. What the screens say about it
-- ═════════════════════════════════════════════════════════════════════════════
--
-- /administration/commercial told the organisation that a scheduled invoice
-- "shows the overage it would carry today". It would now always show none,
-- which is a sentence about a thing that cannot happen. The wording is keyed by
-- its own source text, so changing the sentence changes the key: the row is
-- moved rather than one inserted and another left behind, because a glossary
-- entry for words no screen says is a rename nobody can ever see take effect.
-- erp_ref.resource carries FORCE ROW LEVEL SECURITY, under which a refused
-- update reports nought rows rather than failing, so the move is counted.

do $wording$
declare
  v_old constant text := 'Each invoice in the schedule, and the metering behind any overage. A scheduled invoice shows the overage it would carry today, from the same meters you see above.';
  v_new constant text := 'Each invoice in the schedule and what it is made of. The subscription is the whole of it: there are no per-transaction fees, so nothing you do in a month changes what you pay for it.';
  v_moved integer;
begin
  update erp_ref.resource
     set key = erp_ref.ui_key(v_new), value = v_new
   where key = erp_ref.ui_key(v_old) and locale = 'en';
  get diagnostics v_moved = row_count;
  if v_moved <> 1 then
    raise exception 'CLOVEERP_WORDING_UNRECOGNISED: moved % row(s) for the invoice panel, expected 1', v_moved
      using hint = '20260904620000 seeded this sentence. Row security may have refused the update.';
  end if;
end
$wording$;

update erp_ref.help_topic set
  steps = '["Read the contract and download its documents; each carries the checksum of what was signed.","Compare each entitlement against what is used; a contract band overrides the plan''s figure.","Read what you will pay next: the schedule, and the subscription that is the whole of each invoice.","Read the meters: they are what the platform measured, and nothing on them is charged or capped.","Note the notice deadline and the uplift rule; a renewal is proposed at the lead time and shown here."]'
where screen_path = '/administration/commercial';

-- The Part 5 coverage register states §17.10 as "reconciled against metering
-- with overage priced from the book". Every artefact it names still exists, so
-- erp.assert_part5_coverage() would have passed on a requirement the product no
-- longer meets — which is the quietest way for a register to stop describing
-- anything.

do $part5$
declare v_moved integer;
begin
  update erp_ref.part5_capability
     set requirement = 'Renewals proposed at the lead time with the uplift rule applied and quoted through the same builder; invoice schedules from the term, each invoice carrying the subscription for its period and no per-transaction charge; revenue, margin, renewal rate, churn and revenue at risk from the contract register'
   where code = '17.10.renewal_and_revenue';
  get diagnostics v_moved = row_count;
  if v_moved <> 1 then
    raise exception 'CLOVEERP_COVERAGE_UNRECOGNISED: moved % row(s) for 17.10, expected 1', v_moved
      using hint = '20260904640000 registered it. Row security may have refused the update.';
  end if;
end
$part5$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_dead_configuration();
select erp.assert_resource_coverage('en');
-- The register this migration emptied two rows out of, and the two reports that
-- read it: a plan silent about a kind, and a priced band naming one.
select erp.assert_entitlements_enforceable();
select erp.assert_part5_coverage();
select erp.assert_commercial_sound();
select erp.assert_contract_provisions_entitlement();
select erp.assert_customer_view_sound();
-- The three suites this disturbs, proved here rather than left to the
-- catalogue: a restated figure that is wrong costs a whole build to find.
select erp_test.assert_metering_suite();
select erp_test.assert_commercial_suite();
-- erp_test.assert_commercial_renewal_suite() is deliberately NOT run here, and
-- removing this call is the edit that 20260919020000 repairs. The suite's
-- fixture designates its own throwaway tenant as the platform's organisation:
-- an empty build has none, so it passes; a live database has clove-erp, so it
-- refuses the second. The deploy of this migration died on that statement with
-- CLOVEERP_PLATFORM_ORGANISATION_ALREADY_DESIGNATED and rolled back whole, so
-- no database has ever carried this version. The suite is in
-- erp.ci_check_catalogue() and runs on every build, which is where a fixture
-- that must be the only platform organisation belongs. A migration runs only
-- what a live database can answer.
