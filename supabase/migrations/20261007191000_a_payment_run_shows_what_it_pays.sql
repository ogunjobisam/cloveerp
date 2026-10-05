set lock_timeout = '30s';

-- =============================================================================
-- 20261007191000  A payment run shows what it pays
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-28). A tester proposed
-- a payment run and was shown a total, £9,067.20, and nothing else: not which
-- bills, not which suppliers, not which bill was held and why. The run's lines
-- were always readable, through public.erp_payment_proposal_lines, but no
-- screen read them. And Propose a payment run said nothing of what it gathers,
-- so a run that also took the bills falling due in the week after the payment
-- date read as more than was due.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The words Propose a payment run now says: what it gathers, to when, and
--      what it holds. And the lines read leaves erp_meta.api_only_door, where
--      it was registered as waiting for a screen ("the panel that opens one
--      proposal and shows its lines is not built yet"): it has one now.
--   B. erp_test.payment_run_lines_suite, which reads a run's lines as the
--      Payment run step does: each line names its supplier, its bill, its
--      amount and when it falls due, the lines to pay first and a held one
--      with its reason, and the lines to pay add up to the run's total.
--
-- The screen's half is in src/lib/modules.tsx and
-- src/components/erp/process-flow.tsx: the Payment run step draws the chosen
-- run's lines beneath it, under Lines, with Due and Held, words that are
-- already screen strings.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No door changes. The lines read is a plain read of the organisation's own
-- rows, as the run's list beside it is.
--
-- On production: one screen string is added and one row of
-- erp_meta.api_only_door is deleted. No table is altered and no row of any
-- organisation is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). What proposing a payment run gathers (20261007191000).'
  from (values
    ('Gathers what suppliers are owed by the payment date, or up to a week after it, and any prepayment an order asks for. A bill in dispute is listed but held, and one already on another run is left to it. Somebody else approves the run.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- The door has a home: the Payment run step reads it.
delete from erp_meta.api_only_door
 where function_name = 'erp_payment_proposal_lines';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.payment_run_lines_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  c_words    constant text :=
    'Gathers what suppliers are owed by the payment date, or up to a week after it, and any prepayment an order '
    'asks for. A bill in dispute is listed but held, and one already on another run is left to it. Somebody else '
    'approves the run.';
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid;
  v_sa uuid; v_sb uuid; v_ba uuid; v_bb uuid; v_run uuid;
  v_lines jsonb; v_runs jsonb; v_total bigint;
begin
  -- ── 1. The words ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'Propose a payment run says what it gathers and to when, in words a screen can show, and the run''s lines read is no longer registered as waiting for a screen';
  passed := exists (select 1 from erp_ref.resource r
                     where r.key = erp_ref.ui_key(c_words) and r.locale = 'en' and r.value = c_words)
        and not exists (select 1 from erp_meta.api_only_door d
                         where d.function_name = 'erp_payment_proposal_lines');
  detail := 'the description is a screen string; the lines read has a home';
  return next;

  begin
    -- ── The fixture: an organisation that pays its suppliers ─────────────────
    v_step := 'an organisation configured as the demonstration is';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzprl-' || v_tag, 'Payment Run Lines Suite',
      'admin@zzprl-' || v_tag || '.test', 'Run Lines Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzprl-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'its company, site, unit and product';
    select e.id into v_entity
      from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (rb.tenant_id, v_entity, 'ZRMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZREA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZRWID', 'Run Lines Widget', v_uom, 'active') returning id into v_item;

    v_step := 'two suppliers'' bills, the second disputed';
    v_sa := erp_test.cash_payment_supplier('ZRA');
    v_sb := erp_test.cash_payment_supplier('ZRB');
    v_ba := erp_test.cash_payment_bill(v_entity, v_site, v_item, v_sa, 20000, 'ZRA-INV-1');
    v_bb := erp_test.cash_payment_bill(v_entity, v_site, v_item, v_sb, 30000, 'ZRB-INV-1');
    perform erp.transition_document(v_bb, 'dispute', 'the price is not what was agreed');

    v_step := 'a run proposed over both, and its lines read as the Payment run step reads them';
    v_run := erp.propose_payment_run(current_date, null, interval '60 days');
    v_lines := public.erp_payment_proposal_lines(v_run);
    v_runs := public.erp_payment_proposals(200);
    select pp.total_minor into v_total from erp.payment_proposal pp
     where pp.tenant_id = rb.tenant_id and pp.id = v_run;

    -- ── 2. Each line says what it pays ───────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the chosen run''s lines name each line''s supplier, bill, amount and due date, the line to pay first and the disputed one held with its reason';
    passed := v_state is null
          and jsonb_array_length(v_lines) = 2
          and v_lines -> 0 ->> 'supplier' = 'Cash Payment ZRA'
          and v_lines -> 0 ->> 'document_number' = (select d.document_number from erp.document d where d.id = v_ba)
          and (v_lines -> 0 ->> 'amount_minor')::bigint = 20000
          and (v_lines -> 0 ->> 'due_date')::date = current_date + 30
          and (v_lines -> 0 ->> 'held')::boolean = false
          and v_lines -> 0 ->> 'hold_reason' is null
          and v_lines -> 1 ->> 'supplier' = 'Cash Payment ZRB'
          and v_lines -> 1 ->> 'document_number' = (select d.document_number from erp.document d where d.id = v_bb)
          and (v_lines -> 1 ->> 'amount_minor')::bigint = 30000
          and (v_lines -> 1 ->> 'held')::boolean = true
          and v_lines -> 1 ->> 'hold_reason' = 'disputed';
    detail := coalesce(v_state, left(v_lines::text, 400));
    return next;

    -- ── 3. The lines to pay are the run's total ──────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the lines to pay add up to the total the run''s list shows, and the held line is not in it';
    passed := v_state is null
          and v_total = 20000
          and (select sum((l ->> 'amount_minor')::bigint) from jsonb_array_elements(v_lines) l
                where not (l ->> 'held')::boolean) = v_total
          and exists (select 1 from jsonb_array_elements(v_runs) r
                       where r ->> 'proposal_id' = v_run::text
                         and (r ->> 'total_minor')::bigint = v_total);
    detail := coalesce(v_state, format('total %s; runs %s', v_total, left(v_runs::text, 300)));
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzprl-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1)
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzprl rolled back with its bills and its run');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PAYMENT_RUN_LINES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
end;
$$;

revoke all on function erp_test.payment_run_lines_suite() from public, anon;

comment on function erp_test.payment_run_lines_suite() is
  'A payment run shows what it pays (20261007191000): the Payment run step''s lines read names each line''s '
  'supplier, bill, amount and due date, the lines to pay first and a disputed one held with its reason; the lines to '
  'pay add up to the total the run''s list shows; Propose a payment run''s words are a screen string; and the lines '
  'read is no longer registered as having no screen.';

create or replace function erp_test.assert_payment_run_lines_suite()
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
    from erp_test.payment_run_lines_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PAYMENT_RUN_LINES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The Payment run step would show a run''s lines other than as they are paid. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_PAYMENT_RUN_LINES_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('payment run lines: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_payment_run_lines_suite() from public, anon;

comment on function erp_test.assert_payment_run_lines_suite() is
  'A payment run''s lines, as the Payment run step draws them, say what the run pays and what it holds '
  '(20261007191000).';

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
