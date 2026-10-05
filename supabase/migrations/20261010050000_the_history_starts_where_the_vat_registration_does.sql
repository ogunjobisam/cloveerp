set lock_timeout = '30s';

-- =============================================================================
-- 20261010050000  The history starts where the VAT registration does
-- -----------------------------------------------------------------------------
-- Found rehearsing the rebuild of the live demonstration, 5 October. A fresh
-- demonstration is registered for VAT from current_date - 400 by
-- erp.ensure_demo_configuration(): seeded today, from 31 August 2025, so its
-- first VAT period runs 31 August to 30 September 2025. The "Build a year of
-- trading history" panel on Administration → Tenant makes its first call with
-- no start, and erp.seed_demo_history() then started on the first of the
-- month twelve months ago: 1 October 2025. The September period had no
-- trading, and erp.finalise_demonstration_vat_returns() stops a company at
-- the earliest period with none, because a period never traded is not
-- returned empty and nothing after it may be returned before it. So no
-- return was ever finalised: the rehearsal's panel run left September 2025
-- and the four quarters after it overdue with no return, where a run started
-- on 1 September finalised VAT-000001 to VAT-000004 and left Q3 2026 due.
--
-- ── WHICH OF THE TWO MOVES ──────────────────────────────────────────────────
--
-- The history moves to the registration, and the registration stays.
--
--   * The registration is set once, when the organisation is configured; the
--     panel's default is read on the day somebody presses it, and slides a
--     month every month. Registering from "the history's start" could only
--     mean the start on the seeding day, and a demonstration seeded on the
--     30th and built on the 2nd has the same empty month again.
--   * The history's default reads the registration that is there, whatever
--     made it: the seeding, or somebody who changed it on the tax
--     registration screen before building.
--   * Nothing already configured has to change: no registration, terms or
--     period of any organisation is touched.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.seed_demo_history(): with no start given, and nothing built yet, a
--      call starts on the earlier of the first of the month twelve months ago
--      and the first day of the companies' first VAT period, which is the
--      start of the VAT registration in force for each British-registered
--      company (as erp.vat_obligations() reads it), and never before the first
--      of January two years ago, where the demonstration's books begin. The
--      default can therefore not refuse. A start that is given is used as it
--      is, as before.
--
--      Once anything is built, the default is the first of the month twelve
--      months ago, as before. A demonstration built from that day under the
--      old default has had its early months closed by the deploy's catch-up;
--      reaching back into them would refuse the panel's first call every time
--      it was pressed. Its history is what it is; this is for one built from
--      nothing.
--   B. erp_test.demo_history_start_suite, six cases, and its assertion.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No door, permission, refusal or screen string. The builder's days, its
-- pacing and its VAT finaliser are as they were. The panel needs no change:
-- its first call already sends no start.
--
-- On production: one function is replaced and a suite added. No table is
-- altered and no row of any organisation is touched. The next demonstration
-- built from nothing through the panel starts with its VAT registration.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The first call starts where the first VAT period does
-- ─────────────────────────────────────────────────────────────────────────────

do $start$
declare
  v_sig  constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  v_from := coalesce(p_from, (date_trunc('month', current_date) - interval '12 months')::date);
$o$;
  v_new  constant text := $n$  -- With no start given (the panel's first call), a demonstration built from
  -- nothing starts on the first day of its companies' first VAT period where
  -- that is earlier than the first of the month twelve months ago
  -- (20261010050000). The finaliser stops a company at its earliest period
  -- with no trading, so a history that began after the registration did left
  -- every return unmade. Never before the books begin, so the default cannot
  -- refuse. Once anything is built the default is as it was: the early months
  -- of a history built from the old default are closed by now.
  v_from := p_from;
  if v_from is null then
    v_from := (date_trunc('month', current_date) - interval '12 months')::date;
    if not exists (select 1 from erp.document d
                    where d.tenant_id = v_tenant
                      and d.their_reference ~ '^DEMO-[0-9]{8}-') then
      select greatest(least(v_from, min(reg.valid_from)),
                      make_date(extract(year from current_date)::integer - 2, 1, 1))
        into v_from
        from erp.entity e
        cross join lateral (
          -- The registration erp.vat_obligations() reads: the British VAT
          -- registration in force, the latest to have started.
          select g.valid_from
            from erp.entity_tax_registration g
           where g.tenant_id = e.tenant_id and g.entity_id = e.id
             and upper(g.registration_type) like 'VAT%'
             and upper(g.jurisdiction) = 'GB'
             and g.valid_from <= current_date
           order by g.valid_from desc, g.created_at desc
           limit 1) reg
       where e.tenant_id = v_tenant and e.status = 'active';
    end if;
  end if;
$n$;
begin
  if strpos(v_src, '20261010050000') > 0 then
    raise notice '% already starts where the VAT registration does; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '12c05883d4b1adfd7b10f3e0f3df448e' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010050000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$start$;

revoke all on function erp.seed_demo_history(date, date, numeric) from public, anon;

comment on function erp.seed_demo_history(date, date, numeric) is
  'Builds demonstration trading one day at a time through the spine — purchase orders and receipts, sales orders, '
  'despatches, invoices and cash, quotations, requisitions, every Monday a delivery that arrives short, every Tuesday '
  'a return to a supplier, every Wednesday a transfer from the main warehouse to the company''s other site, every '
  'Thursday a supplier''s bill above the order and a customer''s order delivered in part, every Friday a credit note '
  'to a customer and every Saturday a weekend count that writes one unit off — at most five days per call, starting '
  'no new day once a quarter of the caller''s statement timeout has gone, and says where the next call should start. '
  'With no start given, a demonstration with nothing built starts on the first day of its first VAT period where that '
  'is earlier than the first of the month twelve months ago, so every quarter it trades through can be returned '
  '(20261010050000). A day already built, or inside a five-day slice built before, is skipped; refused in a live '
  'environment; every journal and movement is raised by the same bridges and doors a person''s document goes through.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demo_history_start_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_ent    uuid;
  v_reg    uuid;
  v_regd   date;
  v_year   constant date := (date_trunc('month', current_date) - interval '12 months')::date;
  v_floor  constant date := make_date(extract(year from current_date)::integer - 2, 1, 1);
  v_first  date;
  v_end    date;
  v_res    jsonb;
  v_vat    jsonb;
  v_ret    record;
  v_built  integer;

  -- Where a call with no start would begin, asked without building anything:
  -- a range that ends before it starts answers with its start and stops.
  function_probe constant text := 'select erp.seed_demo_history(null, date ''2000-01-02'', 1) ->> ''from''';
begin
  begin
    -- ── The fixture: a demonstration configured and never built ─────────────
    v_step := 'a demonstration configured to trade, with nothing built';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzhst-' || v_tag, 'History Start Suite', 'admin@zzhst-' || v_tag || '.test', 'History Start Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzhst-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;

    select g.id, g.entity_id, g.valid_from into v_reg, v_ent, v_regd
      from erp.entity_tax_registration g
     where g.tenant_id = v_tenant and upper(g.registration_type) like 'VAT%'
       and upper(g.jurisdiction) = 'GB'
     order by g.valid_from limit 1;

    -- ── 1. The default reaches back to the registration ─────────────────────
    v_step := 'the start of a call with none given, as configured';
    execute function_probe into v_first;
    v_cases := v_cases + 1;
    case_name := 'a demonstration built from nothing, registered for VAT before the first of the month twelve months ago, starts on the day its registration does';
    passed := v_state is null and v_reg is not null
          and v_regd < v_year
          and v_first = v_regd;
    detail := coalesce(v_state, format('registered from %s; a call with no start begins %s; twelve months ago is %s',
                                       v_regd, v_first, v_year));
    return next;

    -- ── 2. A later registration leaves the year as it was ───────────────────
    v_step := 'a registration that starts within the last twelve months';
    update erp.entity_tax_registration set valid_from = current_date - 30 where id = v_reg;
    execute function_probe into v_first;
    v_cases := v_cases + 1;
    case_name := 'a company registered within the last twelve months still has a year of history from the first of the month twelve months ago';
    passed := v_state is null and v_first = v_year;
    detail := coalesce(v_state, format('registered from %s; begins %s', current_date - 30, v_first));
    return next;

    -- ── 3. Never before the books begin ─────────────────────────────────────
    v_step := 'a registration older than the books';
    update erp.entity_tax_registration set valid_from = v_floor - 100 where id = v_reg;
    execute function_probe into v_first;
    v_cases := v_cases + 1;
    case_name := 'a registration older than the books starts the history where the books begin, and the default does not refuse';
    passed := v_state is null and v_first = v_floor;
    detail := coalesce(v_state, format('registered from %s; begins %s; the books begin %s',
                                       v_floor - 100, v_first, v_floor));
    return next;

    -- ── 4. Without a registration in force, the year ────────────────────────
    v_step := 'a registration not yet in force';
    update erp.entity_tax_registration set valid_from = current_date + 30 where id = v_reg;
    execute function_probe into v_first;
    v_cases := v_cases + 1;
    case_name := 'a company with no VAT registration in force has a year of history, as before';
    passed := v_state is null and v_first = v_year;
    detail := coalesce(v_state, format('registered from %s; begins %s', current_date + 30, v_first));
    return next;

    update erp.entity_tax_registration set valid_from = v_regd where id = v_reg;

    -- ── 5. Built from the default, the first period is returned ─────────────
    -- The panel's first call, made as far as the old default, and then the
    -- finaliser through the end of the company's first VAT period. Built from
    -- the old default, that period had no trading and stopped every return.
    v_step := 'the panel''s first call, and the finaliser through the first period';
    v_res := erp.seed_demo_history(null, v_year, 1);
    select min(o.period_end) into v_end from erp.vat_obligations(v_ent) o;
    v_vat := erp.finalise_demonstration_vat_returns(v_end);
    select d.document_number,
           (d.attributes #>> '{vat_return,period_start}')::date as period_start,
           (d.attributes #>> '{vat_return,period_end}')::date as period_end
      into v_ret
      from erp.document d
      join erp.document_type dt
        on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id and dt.base_type_code = 'vat_return'
     where d.tenant_id = v_tenant and d.entity_id = v_ent
       and erp.object_current_state('document', d.id) = 'finalised'
     order by d.document_number
     limit 1;
    v_cases := v_cases + 1;
    case_name := 'the panel''s first call starts in the first VAT period, so that period is returned and does not stand in front of every quarter after it';
    passed := v_state is null
          and (v_res ->> 'from')::date = v_regd
          and (v_res ->> 'built')::integer > 0
          and jsonb_array_length(v_vat) = 1
          and v_ret.period_start = v_regd
          and v_ret.period_end = v_end
          and v_ret.document_number = v_vat ->> 0;
    detail := coalesce(v_state, format('first call %s; first period ends %s; finalised %s (%s to %s)',
                                       left((v_res - 'notes')::text, 160), v_end, v_vat,
                                       v_ret.period_start, v_ret.period_end));
    return next;

    -- ── 6. Once built, the default is the year again ────────────────────────
    v_step := 'the start of a call with none given, once something is built';
    execute function_probe into v_first;
    select count(*) into v_built from erp.document d
     where d.tenant_id = v_tenant and d.their_reference ~ '^DEMO-[0-9]{8}-';
    v_cases := v_cases + 1;
    case_name := 'once anything is built, a call with no start begins on the first of the month twelve months ago, as before, and never reaches back into months that may be closed';
    passed := v_state is null and v_built > 0 and v_first = v_year;
    detail := coalesce(v_state, format('%s document(s) built; begins %s', v_built, v_first));
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
    raise exception 'CLOVEERP_DEMO_HISTORY_START_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demo_history_start_suite() from public, anon;

comment on function erp_test.demo_history_start_suite() is
  'Where a demonstration''s history starts when no start is given (20261010050000): at its VAT registration where that '
  'is earlier than a year ago, never before the books begin, a year where the registration is later or not in force, '
  'the first VAT period then returned rather than left empty, and a year again once anything is built.';

create or replace function erp_test.assert_demo_history_start_suite()
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
    from erp_test.demo_history_start_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMO_HISTORY_START_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A demonstration built from nothing does not start where its first VAT period does, so its returns cannot be made. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_DEMO_HISTORY_START_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demonstration history start: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demo_history_start_suite() from public, anon;

comment on function erp_test.assert_demo_history_start_suite() is
  'A demonstration built from nothing starts its history on its VAT registration, so its first period is returned '
  '(20261010050000).';

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
