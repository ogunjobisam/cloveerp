set lock_timeout = '30s';

-- =============================================================================
-- 20261006191000  Only a group parent is offered
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-94). The consolidated
-- trial balance, asked for the demonstration's only company, refused with
-- "ACME has no group ledger" and nothing to do next. The refusal is right; the
-- question should not have been offered:
--
--   (a) The Parent company pickers on Financials (Consolidated trial balance,
--       Eliminations, Eliminate intercompany balances) list every active
--       company from public.erp_entities, which does not say whether a
--       company heads a group, so the screen cannot offer only those that do.
--   (b) CLOVEERP_NO_GROUP_LEDGER carried the hint
--       "erp_configure_consolidation(parent, members) installs it.", which is
--       a routine's name and not a next action; the screen drops such a hint,
--       and the token was never registered, so the person read nothing about
--       what to do.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_entities answers is_group_parent for each company: whether it
--      has an active group ledger, which is what every consolidation read and
--      the elimination ask for (erp.group_ledger). The screen keeps only those
--      in the three Parent company pickers; "Add a company to a group" still
--      offers every company, because that is how a company becomes a parent.
--   B. The three raises of CLOVEERP_NO_GROUP_LEDGER (erp.consolidated_trial_
--      balance, erp.intercompany_pairs, erp.post_intercompany_elimination) say
--      in plain words to use "Add a company to a group", and the token is
--      registered with what was refused, why and the next action.
--   C. The words a Parent company picker says when no company heads a group.
--   D. erp_test.group_parent_offered_suite.
--
-- On production: one door and three routines are patched. No table is altered
-- and no row is changed. The demonstration has no group, so its pickers say
-- that no company heads a group yet.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A company says whether it heads a group
-- ─────────────────────────────────────────────────────────────────────────────

do $entities$
declare
  v_sig  constant text := 'public.erp_entities()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$'base_currency', e.base_currency, 'country_code', e.country_code) as x$o$;
  v_new  constant text := $n$'base_currency', e.base_currency, 'country_code', e.country_code,
      -- Whether it heads a group: it has the group ledger every consolidation
      -- read and the elimination ask for (20261006191000, J-94).
      'is_group_parent', exists (
        select 1 from erp.ledger l
         where l.tenant_id = e.tenant_id and l.entity_id = e.id
           and l.ledger_kind = 'group' and l.status = 'active')) as x$n$;
begin
  if strpos(v_src, '20261006191000') > 0 then
    raise notice '% already says which company heads a group; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '86b55f6190340ee9110ff0d131e51527' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006191000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$entities$;

comment on function public.erp_entities() is
  'The organisation''s active legal entities, under finance.read or the permission of the form picking one: '
  'finance.configure, finance.post or administration.configure. Each says whether it heads a group '
  '(is_group_parent: it has an active group ledger), so a picker for a group''s parent offers only those '
  '(20261006191000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The refusal names the next action
-- ─────────────────────────────────────────────────────────────────────────────

do $hints$
declare
  v_old  constant text := $o$hint = 'erp_configure_consolidation(parent, members) installs it.'$o$;
  v_new  constant text := $n$hint = 'Use "Add a company to a group" in Financials to put a subsidiary under this company. That sets up its group ledger.' /* 20261006191000, J-94 */$n$;
  r      record;
  v_src  text;
  v_def  text;
begin
  for r in
    select * from (values
      ('erp.consolidated_trial_balance(uuid,date)', 'fe6d81663e106a3c96154780d44218a5'),
      ('erp.intercompany_pairs(uuid,date)', '4c7665ada08647e7c4c88517ccb18d0c'),
      ('erp.post_intercompany_elimination(uuid,date,text)', 'e88fe655dbff187f94caa0bfc16d1ef1')
    ) as v(sig, digest)
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    if strpos(v_src, '20261006191000') > 0 then
      raise notice '% already names the next action; left as it is', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.digest then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006191000 expects (md5 %)', r.sig, md5(v_src);
    end if;
    if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', r.sig;
    end if;
    execute replace(v_def, v_old, v_new);
  end loop;
end
$hints$;

comment on function erp.intercompany_pairs(uuid, date) is
  'What the companies of a group owe each other at a date, pair by pair, each side and whether they agree. '
  'Refused for a company that heads no group, naming "Add a company to a group" (20261006191000).';

comment on function erp.post_intercompany_elimination(uuid, date, text) is
  'Posts what the companies of a group owe each other into the parent''s group ledger at a date, once every '
  'pair agrees and not twice for the same date. Refused for a company that heads no group, naming "Add a '
  'company to a group" (20261006191000).';

select erp.register_refusal(
  'CLOVEERP_NO_GROUP_LEDGER',
  'Reading or eliminating group figures for a company that heads no group.',
  'Group figures are kept in a group ledger of the parent company, and this company has none because no company has been put under it yet.',
  'Use "Add a company to a group" in Financials to put a subsidiary under this company, which sets up its group ledger. Then choose it again.');

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Only a group parent is offered (20261006191000).'
  from (values
    ('No company heads a group yet. Use “Add a company to a group” to put a subsidiary under its parent.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.group_parent_offered_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_parent uuid;
  v_member uuid;
  v_before jsonb;
  v_after  jsonb;
  v_err    text;
  v_hint   text;
  v_err2   text;
  v_hint2  text;
begin
  begin
    -- ── The fixture: a company and a second one, not yet a group ────────────
    v_step := 'an organisation configured as the demonstration is, with a second company';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzgrp-' || v_tag, 'Group Parent Suite',
      'admin@zzgrp-' || v_tag || '.test', 'Group Parent Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzgrp-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_parent from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    v_member := erp.create_entity('ZZ-GSUB', 'Zz Group Subsidiary', 'Zz Group Subsidiary Ltd',
                                  'GBP', 'GB', 'en-GB', 'en-GB', 1::smallint);
    perform erp.configure_finance(null, 'GBP', v_member);

    -- ── 1. No group yet ─────────────────────────────────────────────────────
    v_step := 'the companies read before any group';
    v_before := public.erp_entities();
    v_cases := v_cases + 1;
    case_name := 'before a group is set up every company says it heads no group';
    passed := v_state is null
          and jsonb_array_length(v_before) >= 2
          and not exists (select 1 from jsonb_array_elements(v_before) x
                           where not (x ? 'is_group_parent')
                              or jsonb_typeof(x -> 'is_group_parent') <> 'boolean'
                              or (x ->> 'is_group_parent')::boolean);
    detail := coalesce(v_state, left(v_before::text, 400));
    return next;

    -- ── 2. The refusal says what to do ──────────────────────────────────────
    v_step := 'the consolidated trial balance asked of a company that heads no group';
    begin
      perform public.erp_consolidated_trial_balance(v_parent, current_date);
      v_err := 'answered';
    exception when others then
      get stacked diagnostics v_err = message_text, v_hint = pg_exception_hint;
    end;
    begin
      perform erp.post_intercompany_elimination(v_parent, current_date, 'suite: no group');
      v_err2 := 'posted';
    exception when others then
      get stacked diagnostics v_err2 = message_text, v_hint2 = pg_exception_hint;
    end;
    v_cases := v_cases + 1;
    case_name := 'asked of a company that heads no group, the read and the elimination refuse naming "Add a company to a group", and the refusal is registered with its next action';
    passed := v_state is null
          and v_err like 'CLOVEERP_NO_GROUP_LEDGER:%'
          and v_hint like '%"Add a company to a group"%'
          and v_err2 like 'CLOVEERP_NO_GROUP_LEDGER:%'
          and v_hint2 like '%"Add a company to a group"%'
          and not erp_test.sounds_internal(v_hint)
          and exists (select 1 from erp_ref.refusal f
                       where f.code = 'CLOVEERP_NO_GROUP_LEDGER'
                         and f.next_action like '%"Add a company to a group"%')
          -- Every routine that raises it says so, the read of the pairs too.
          and (select count(*) from pg_catalog.pg_proc p
                where p.oid in ('erp.consolidated_trial_balance(uuid,date)'::regprocedure,
                                'erp.intercompany_pairs(uuid,date)'::regprocedure,
                                'erp.post_intercompany_elimination(uuid,date,text)'::regprocedure)
                  and strpos(p.prosrc, '"Add a company to a group"') > 0
                  and strpos(p.prosrc, 'installs it.') = 0) = 3;
    detail := coalesce(v_state, left(format('%s [%s] / %s [%s]', v_err, v_hint, v_err2, v_hint2), 500));
    return next;

    -- ── 3. A group ──────────────────────────────────────────────────────────
    v_step := 'the second company put under the first';
    perform erp.configure_consolidation(v_parent, array[v_member]);
    v_after := public.erp_entities();
    v_cases := v_cases + 1;
    case_name := 'once a subsidiary is put under it, the parent says it heads a group and the subsidiary does not';
    passed := v_state is null
          and (select (x ->> 'is_group_parent')::boolean from jsonb_array_elements(v_after) x
                where x ->> 'entity_id' = v_parent::text)
          and not (select (x ->> 'is_group_parent')::boolean from jsonb_array_elements(v_after) x
                    where x ->> 'entity_id' = v_member::text)
          and (select count(*) from jsonb_array_elements(v_after) x
                where (x ->> 'is_group_parent')::boolean) = 1;
    detail := coalesce(v_state, left(v_after::text, 400));
    return next;

    -- ── 4. And the read answers ─────────────────────────────────────────────
    v_step := 'the consolidated trial balance asked of the parent';
    v_err := null;
    begin
      perform public.erp_consolidated_trial_balance(v_parent, current_date);
    exception when others then
      v_err := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'the company the picker now offers is answered, not refused';
    passed := v_state is null and v_err is null;
    detail := coalesce(v_state, coalesce(left(v_err, 300), 'answered'));
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
    raise exception 'CLOVEERP_GROUP_PARENT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.group_parent_offered_suite() from public, anon;

comment on function erp_test.group_parent_offered_suite() is
  'Only a group parent is offered (20261006191000, J-94): erp_entities says which company heads a group, '
  'before and after a subsidiary is put under it, and a company that heads none is refused with "Add a '
  'company to a group" as the next action.';

create or replace function erp_test.assert_group_parent_offered_suite()
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
    from erp_test.group_parent_offered_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_GROUP_PARENT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A company that heads no group is offered or refused without a next action. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_GROUP_PARENT_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('only a group parent is offered: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_group_parent_offered_suite() from public, anon;

comment on function erp_test.assert_group_parent_offered_suite() is
  'erp_entities says which company heads a group, and CLOVEERP_NO_GROUP_LEDGER names the next action '
  '(20261006191000).';

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
