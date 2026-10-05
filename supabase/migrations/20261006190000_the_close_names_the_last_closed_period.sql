set lock_timeout = '30s';

-- =============================================================================
-- 20261006190000  The close names the last closed period
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-98). September had
-- been closed, and Closing the month said nothing about it: no "last closed"
-- line, no who or when. public.erp_close_checklist answers for one period only
-- (the one being closed, else the one we are in) and carries nothing about the
-- month closed before it, so the screen had nothing to draw.
--
-- The same finding read "Close 68" on the Financials step: the Close step
-- counted every closed, reopenable period of every ledger as work waiting. That
-- half is a screen change (src/lib/plain-words.ts orderPeriods): closed
-- periods move behind the "Show future and finished periods" toggle, where
-- Reopen still reaches them.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_close_checklist answers last_closed: the period closed most
--      recently in the organisation (by its end date, the primary ledger
--      first), its ledger, when it was closed and the name of who closed it.
--      Null while nothing has been closed. Nothing else it answers changes.
--   B. The words "Last closed" for the screen.
--   C. erp_test.close_names_last_closed_suite.
--
-- On production: one door is patched. No table is altered and no row is
-- changed; a period closed before this reads with who closed it, because
-- erp.close_period has always kept closed_at and closed_by.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The checklist names the month closed last
-- ─────────────────────────────────────────────────────────────────────────────

do $checklist$
declare
  v_sig  constant text := 'public.erp_close_checklist(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    'failing_since_completed', v_stale,
$o$;
  v_new  constant text := $n$    'failing_since_completed', v_stale,
    -- The month closed most recently, whichever month this is: its period,
    -- when and by whom, the primary ledger first (20261006190000, J-98).
    'last_closed', (select jsonb_build_object(
                 'fiscal_period_id', fp.id, 'code', fp.code, 'ledger', lg.code,
                 'starts_on', fp.starts_on, 'ends_on', fp.ends_on,
                 'closed_at', fp.closed_at, 'closed_by', u.display_name)
                 from erp.fiscal_period fp
                 join erp.ledger lg on lg.tenant_id = fp.tenant_id and lg.id = fp.ledger_id
                 left join erp.app_user u on u.tenant_id = fp.tenant_id and u.id = fp.closed_by
                where fp.tenant_id = v_tenant
                  and fp.status in ('closed', 'permanently_closed')
                order by fp.ends_on desc, lg.is_primary desc, fp.closed_at desc nulls last, fp.id
                limit 1),
$n$;
begin
  if strpos(v_src, '20261006190000') > 0 then
    raise notice '% already names the last closed period; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '0057c55ef759cb7dd2f3ce2f4897c3ee' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006190000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$checklist$;

comment on function public.erp_close_checklist(uuid) is
  'The period close as a person works it: the period being closed, the periods that close with it '
  '(erp.period_siblings), the month''s checklist wherever it was raised, every task with its state, who '
  'completed or waived it and when, the dependency it is waiting on, whether its blocking check would pass '
  'right now and what it says when it does not, and the one sentence saying what is stopping the close. Says '
  'what the doors would take for this reader: can_open, can_close, and each task''s can_complete and '
  'can_waive, by the rules erp.open_period_close, erp.close_period and erp.complete_close_task apply. '
  'Resolves the period when none is named. Invoker throughout, so it answers for the caller''s organisation '
  'only (20260929400000). Names the month closed most recently, when and by whom, as last_closed '
  '(20261006190000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The close names the last closed period (20261006190000).'
  from (values
    ('Last closed')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.close_names_last_closed_suite()
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
  rb2      record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_gl uuid; v_gl_code text;
  v_first  uuid; v_second uuid;
  v_first_code text; v_second_code text;
  v_before jsonb;
  v_one    jsonb;
  v_two    jsonb;
  v_other  jsonb;
begin
  begin
    -- ── The fixture: an organisation configured as the demonstration is ─────
    v_step := 'an organisation configured as the demonstration is';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzlcl-' || v_tag, 'Last Closed Suite',
      'admin@zzlcl-' || v_tag || '.test', 'Last Close Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzlcl-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'two months of its primary ledger that are not this one';
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select l.id, l.code into strict v_gl, v_gl_code from erp.ledger l
     where l.tenant_id = rb.tenant_id and l.entity_id = v_entity and l.is_primary;
    select fp.id, fp.code into strict v_first, v_first_code from erp.fiscal_period fp
     where fp.tenant_id = rb.tenant_id and fp.ledger_id = v_gl
       and not (current_date between fp.starts_on and fp.ends_on)
       and erp.period_accepts_postings(fp.id)
     order by fp.starts_on limit 1;
    select fp.id, fp.code into strict v_second, v_second_code from erp.fiscal_period fp
     where fp.tenant_id = rb.tenant_id and fp.ledger_id = v_gl
       and not (current_date between fp.starts_on and fp.ends_on)
       and erp.period_accepts_postings(fp.id) and fp.id <> v_first
     order by fp.starts_on limit 1;

    -- ── 1. Nothing closed yet ───────────────────────────────────────────────
    v_step := 'the checklist read before any month is closed';
    v_before := public.erp_close_checklist(null);
    v_cases := v_cases + 1;
    case_name := 'before any month is closed the checklist answers last_closed, and it is empty';
    passed := v_state is null
          and v_before ? 'last_closed'
          and jsonb_typeof(v_before -> 'last_closed') = 'null'
          and v_before -> 'period' is not null;
    detail := coalesce(v_state, left(format('last_closed %s, period %s',
      v_before -> 'last_closed', v_before -> 'period' ->> 'code'), 300));
    return next;

    -- ── 2. A month closed ───────────────────────────────────────────────────
    v_step := 'the first month opened and closed';
    perform erp.open_period_close(v_first);
    perform public.erp_close_period(v_first);
    v_one := public.erp_close_checklist(null);
    v_cases := v_cases + 1;
    case_name := 'once a month is closed the checklist of the month being worked names it, its primary ledger, when and who closed it';
    passed := v_state is null
          and v_one -> 'last_closed' ->> 'fiscal_period_id' = v_first::text
          and v_one -> 'last_closed' ->> 'code' = v_first_code
          and v_one -> 'last_closed' ->> 'ledger' = v_gl_code
          and v_one -> 'last_closed' ->> 'closed_by' = 'Last Close Admin'
          and (v_one -> 'last_closed' ->> 'closed_at')::timestamptz is not null
          and v_one -> 'period' ->> 'fiscal_period_id' <> v_first::text;
    detail := coalesce(v_state, left(format('last_closed %s; period %s',
      v_one -> 'last_closed', v_one -> 'period' ->> 'code'), 400));
    return next;

    -- ── 3. A later month closed ─────────────────────────────────────────────
    v_step := 'the second month opened and closed';
    perform erp.open_period_close(v_second);
    perform public.erp_close_period(v_second);
    v_two := public.erp_close_checklist(v_first);
    v_cases := v_cases + 1;
    case_name := 'a later month closed becomes the last closed, whichever period the checklist is asked about';
    passed := v_state is null
          and v_two -> 'last_closed' ->> 'fiscal_period_id' = v_second::text
          and v_two -> 'last_closed' ->> 'code' = v_second_code
          and v_two -> 'period' ->> 'fiscal_period_id' = v_first::text
          and v_two ->> 'state' = 'closed';
    detail := coalesce(v_state, left(format('last_closed %s; period %s (%s)',
      v_two -> 'last_closed' ->> 'code', v_two -> 'period' ->> 'code', v_two ->> 'state'), 300));
    return next;

    -- ── 4. Another organisation ─────────────────────────────────────────────
    v_step := 'a second organisation reads its own close';
    perform set_config('request.jwt.claims', '', true);
    select * into rb2 from erp.provision_tenant(
      'zzlc2-' || v_tag, 'Last Closed Suite Two',
      'admin@zzlc2-' || v_tag || '.test', 'Other Close Admin');
    update erp.environment set is_live = false where tenant_id = rb2.tenant_id and is_self;
    insert into auth.users (id, email) values (a2, 'admin@zzlc2-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rb2.admin_token);
    perform erp.ensure_demo_configuration(rb2.tenant_id, rb2.admin_user_id);
    v_other := public.erp_close_checklist(null);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'another organisation that has closed nothing is not told about the first one''s months';
    passed := v_state is null
          and jsonb_typeof(v_other -> 'last_closed') = 'null'
          and v_other -> 'period' ->> 'fiscal_period_id' not in (v_first::text, v_second::text);
    detail := coalesce(v_state, left(format('last_closed %s', v_other -> 'last_closed'), 300));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_LAST_CLOSED_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.close_names_last_closed_suite() from public, anon;

comment on function erp_test.close_names_last_closed_suite() is
  'The close names the last closed period (20261006190000, J-98): erp_close_checklist answers last_closed, '
  'empty before anything is closed, then the month closed most recently with its primary ledger, when and '
  'who, whichever period is asked about, and never another organisation''s.';

create or replace function erp_test.assert_close_names_last_closed_suite()
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
    from erp_test.close_names_last_closed_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_LAST_CLOSED_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Closing the month no longer says which month was closed last. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_LAST_CLOSED_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('close names the last closed period: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_close_names_last_closed_suite() from public, anon;

comment on function erp_test.assert_close_names_last_closed_suite() is
  'erp_close_checklist names the month closed most recently, when and by whom (20261006190000).';

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
