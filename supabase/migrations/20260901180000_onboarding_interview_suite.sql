-- =============================================================================
-- Addendum B, Part 4 — the suite
--
-- The thing worth proving is not that the interview asks questions. It is that
-- what comes out the far end is a diff the existing machinery promotes, and
-- that nothing about it is a second, weaker way to change configuration.
--
-- So the suite runs one interview end to end — answers, proposals, evidence,
-- promotion — and then reads the nine surfaces back. It also proves the two
-- ways an interview can produce nothing, because an empty proposal that looks
-- like a full one is the failure mode a feature like this has.
-- =============================================================================

create or replace function erp_test.onboarding_interview_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  a1 uuid := gen_random_uuid();
  v jsonb; v_t uuid; v_e uuid; v_s uuid; v_s2 uuid; res jsonb;
  v_ok boolean; v_msg text; r record; n integer;
begin
  insert into auth.users (id, email) values (a1, 'interview@zzint.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  v := erp.onboard_tenant('Interview', 'zzint');
  v_t := (v ->> 'tenant_id')::uuid;
  v_e := (v ->> 'entity_id')::uuid;
  perform erp.configure_finance();

  -- ── The bank ────────────────────────────────────────────────────────────

  return query select 'the question bank is data, and covers all six sections',
    (select count(distinct q.section) from erp_ref.interview_question q) = 6,
    'six question lists in TypeScript would have made the interview the one '
    'part of this product whose behaviour is not configured';

  -- The tie back to Part 1. A question that maps to a kind the promoter does
  -- not handle would ask something the product cannot act on.
  return query select 'every question maps to a kind the promoter can promote',
    not exists (
      select 1 from erp_ref.interview_question q
       where q.maps_to is not null
         and position('when ''' || q.maps_to || '''' in (
               select p.prosrc from pg_catalog.pg_proc p
                 join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'erp'
                  and p.proname = 'apply_change_set_item')) = 0),
    'until 20260901130000 not one of them did, which is why this could not '
    'have been built before it';

  -- ── Asking ──────────────────────────────────────────────────────────────

  v_s := (public.erp_start_interview('suite') ->> 'session_id')::uuid;

  select count(*) into n from erp.interview_questions(v_s) q where q.applies;
  return query select 'a gated question is not asked before its gate is answered',
    n < (select count(*) from erp_ref.interview_question),
    format('%s of %s questions apply at the start', n,
           (select count(*) from erp_ref.interview_question));

  perform public.erp_answer_interview(v_s, 'approval.needed', 'true'::jsonb);
  return query select 'and is asked once the gate says yes',
    (select count(*) from erp.interview_questions(v_s) q where q.applies) > n,
    'an interview that asks about thresholds when nothing needs approval is '
    'an interview nobody finishes';

  begin
    perform public.erp_answer_interview(v_s, 'dept.list', '"Operations"'::jsonb);
    v_ok := false; v_msg := 'a list question accepted a bare string';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ANSWER_SHAPE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'an answer of the wrong shape is refused', v_ok, v_msg;

  begin
    perform public.erp_answer_interview(v_s, 'approval.currency', '"XXX"'::jsonb);
    v_ok := false; v_msg := 'a choice question accepted a value not offered';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ANSWER_NOT_A_CHOICE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and a choice outside the offered set is refused',
    v_ok, v_msg;

  -- ── The two ways to produce nothing ─────────────────────────────────────

  v_s2 := (public.erp_start_interview('suite-empty') ->> 'session_id')::uuid;
  begin
    perform public.erp_propose_from_interview(v_s2);
    v_ok := false; v_msg := 'an interview with no answers produced a proposal';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_INTERVIEW_EMPTY%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'an interview with no answers proposes nothing',
    v_ok, v_msg;

  perform public.erp_answer_interview(v_s2, 'approval.needed', 'false'::jsonb);
  begin
    perform public.erp_propose_from_interview(v_s2);
    v_ok := false; v_msg := 'an all-declined interview produced a proposal';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_INTERVIEW_PROPOSES_NOTHING%';
    v_msg := left(sqlerrm, 60);
  end;
  return query select
    'and one that declines everything proposes nothing rather than an empty diff',
    v_ok, v_msg;

  -- Release areas need somewhere to be, and saying so here beats a promotion
  -- that fails for a reason nobody can act on.
  perform public.erp_answer_interview(v_s, 'release.areas', '["Picking"]'::jsonb);
  begin
    perform public.erp_propose_from_interview(v_s);
    v_ok := false; v_msg := 'release areas were proposed with no site to put them on';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_INTERVIEW_NEEDS_SITE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a release area with nowhere to go is refused, with a reason',
    v_ok, v_msg;

  insert into erp.site (tenant_id, entity_id, code, name, site_type)
  values (v_t, v_e, 'MAIN', 'Main', 'warehouse');

  -- ── The whole thread ────────────────────────────────────────────────────

  perform public.erp_answer_interview(v_s, 'dept.list',
    '["Operations","Finance"]'::jsonb);
  perform public.erp_answer_interview(v_s, 'approval.object_type',
    '"purchase_order"'::jsonb);
  perform public.erp_answer_interview(v_s, 'approval.currency', '"GBP"'::jsonb);
  perform public.erp_answer_interview(v_s, 'approval.threshold', '5000'::jsonb);
  perform public.erp_answer_interview(v_s, 'approval.role', '"administrator"'::jsonb);
  perform public.erp_answer_interview(v_s, 'posting.item_classes',
    '["Finished goods","Raw materials"]'::jsonb);
  perform public.erp_answer_interview(v_s, 'posting.receipt_account', '"1200"'::jsonb);
  perform public.erp_answer_interview(v_s, 'classification.axes', '["Colour"]'::jsonb);
  perform public.erp_answer_interview(v_s, 'classification.mandatory', 'false'::jsonb);
  perform public.erp_answer_interview(v_s, 'classification.values',
    '[{"left":"Colour","right":"Red"},{"left":"Colour","right":"Blue"}]'::jsonb);
  perform public.erp_answer_interview(v_s, 'code.wanted', 'true'::jsonb);
  perform public.erp_answer_interview(v_s, 'code.prefix', '"IT"'::jsonb);
  perform public.erp_answer_interview(v_s, 'code.digits', '6'::jsonb);
  -- Re-answered, not added: answers upsert, so changing your mind before
  -- proposing is a second answer rather than a second interview.
  perform public.erp_answer_interview(v_s, 'release.areas',
    '["Picking","Despatch"]'::jsonb);
  perform public.erp_answer_interview(v_s, 'release.mode', '"pull"'::jsonb);
  perform public.erp_answer_interview(v_s, 'release.ageing_hours', '48'::jsonb);

  res := public.erp_propose_from_interview(v_s);

  return query select 'a full interview proposes across all six sections',
    jsonb_array_length(res -> 'proposals') = 6,
    format('%s section(s), %s item(s)', jsonb_array_length(res -> 'proposals'),
           res ->> 'items');

  return query select 'every proposal it made is a diff, as §3.12 requires',
    not exists (select 1 from erp_ai.proposal p
                 where p.tenant_id = v_t and p.change_set_id is null),
    'onboarding_interview is exempt from the change-set constraint, so a '
    'prose-only version would have passed the schema';

  return query select 'and each change set it points at has items in it',
    not exists (
      select 1 from erp_ai.proposal p
       where p.tenant_id = v_t
         and not exists (select 1 from erp.change_set_item i
                          where i.tenant_id = v_t
                            and i.change_set_id = p.change_set_id)),
    'a change set with no items is a diff in name only';

  return query select 'every proposal says what was looked at, not only what it concluded',
    not exists (
      select 1 from erp_ai.proposal p
       where p.tenant_id = v_t
         and not exists (select 1 from erp_ai.proposal_evidence ev
                          where ev.tenant_id = v_t and ev.proposal_id = p.id)),
    '§3.12 asks for explainability, and a rationale without evidence is a '
    'sentence';

  return query select 'no proposal names the person who answered as its producer',
    not exists (select 1 from erp_ai.proposal p
                 where p.tenant_id = v_t and p.produced_by is not null),
    'recording them would block them from reviewing a mapping they did not '
    'make; the label says where it came from instead';

  return query select 'the interview cannot be proposed from twice',
    (select s.status from erp.interview_session s where s.id = v_s) = 'proposed',
    'a second run would raise a second set of change sets for the same answers';

  -- ── Promotion, through the machinery that already existed ───────────────

  for r in select (x.value ->> 'change_set_id')::uuid as cs
             from jsonb_array_elements(res -> 'proposals')
                    with ordinality x(value, ord)
            order by x.ord
  loop
    perform erp.submit_change_set(r.cs);
    perform erp.approve_change_set(r.cs);
    perform erp.promote_change_set(r.cs);
  end loop;

  return query select 'and the promoted answers are really in the eight surfaces',
    (select count(*) from erp.department where tenant_id = v_t) = 2
      and (select count(*) from erp.approval_band where tenant_id = v_t) = 2
      and (select count(*) from erp.posting_class where tenant_id = v_t) = 2
      and (select count(*) from erp.account_determination where tenant_id = v_t) = 1
      and (select count(*) from erp.classification_axis where tenant_id = v_t) = 1
      and (select count(*) from erp.classification_value where tenant_id = v_t) = 2
      and (select count(*) from erp.code_template where tenant_id = v_t) = 1
      and (select count(*) from erp.release_area where tenant_id = v_t) = 2,
    format('%s departments, %s bands, %s classes, %s determinations, %s axes, '
           '%s values, %s templates, %s areas',
           (select count(*) from erp.department where tenant_id = v_t),
           (select count(*) from erp.approval_band where tenant_id = v_t),
           (select count(*) from erp.posting_class where tenant_id = v_t),
           (select count(*) from erp.account_determination where tenant_id = v_t),
           (select count(*) from erp.classification_axis where tenant_id = v_t),
           (select count(*) from erp.classification_value where tenant_id = v_t),
           (select count(*) from erp.code_template where tenant_id = v_t),
           (select count(*) from erp.release_area where tenant_id = v_t));

  return query select 'the band it raised carries the threshold that was given',
    exists (select 1 from erp.approval_band ab
              join erp.department d on d.id = ab.department_id
             where ab.tenant_id = v_t and d.code = 'OPERATIONS'
               and ab.lower_bound_minor = 500000),
    'five thousand pounds, in minor units, on the department the answer named';

  return query select 'and the proposals are readable on the public API',
    (select jsonb_array_length(public.erp_proposals())) = 6,
    'B10 had no public surface at all before this, so the intelligence layer '
    'was unreachable end to end rather than merely unused';

  -- ── Clean up ────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_t);
  delete from erp.tenant where id = v_t;
  perform erp.end_tenant_purge();
  delete from auth.users where id = a1;

  return query select 'and the suite removes the organisation it built',
    not exists (select 1 from erp_ai.proposal p where p.tenant_id = v_t),
    'proposals cascade with the tenant, as every tenant-scoped table does';
end $$;

create or replace function erp_test.assert_onboarding_interview_suite()
returns text
language plpgsql
set search_path to ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Two on the bank, four on asking, three on producing nothing, six on the
  -- proposals, three on promotion, and the cleanup.
  c_expected constant integer := 19;
begin
  create temporary table if not exists zz_interview_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_interview_result;
  insert into zz_interview_result select * from erp_test.onboarding_interview_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_interview_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_INTERVIEW_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_INTERVIEW_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('onboarding interview: %s/%s', v_pass, v_total);
end $$;

-- ── The decision this part could not take on its own ─────────────────────────

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence, decided_by)
values
  ('proposal_apply_path_unreachable',
   'erp_ai.apply_proposal() cannot complete for any organisation this product creates',
   'Spec §3.12',
   'Left as it stands, and recorded. The interview produces a change set and '
   'the proposal that explains it; the change set is approved and promoted '
   'through B6 exactly as a human-authored one is, and the proposal stays at '
   '"proposed" as the record of where the change came from.',
   'erp_ai.apply_proposal() requires a proposal validated in an environment '
   'that is neither production nor the one being promoted into — §3.12''s '
   '"test environment first", enforced by a trigger. erp.onboard_tenant() '
   'creates exactly one environment, production and is_self, so no '
   'organisation the product can create today has anywhere to validate. '
   'Giving organisations a second environment is a real piece of B6 work with '
   'its own decisions about what a test environment contains, and doing it as '
   'a side effect of building an interview would settle those by accident. '
   'The alternative — relaxing the rule so a proposal can be applied where it '
   'was written — would make "we tested it in production" the supported route, '
   'which is the thing the rule exists to refuse.',
   'open',
   'erp_ai.check_proposal_reviewer() refuses a production validation '
   'environment; erp.onboard_tenant() inserts one environment, kind '
   'production, is_self true.',
   null)
on conflict (code) do update set
  title = excluded.title, decision = excluded.decision,
  rationale = excluded.rationale, status = excluded.status,
  evidence = excluded.evidence;

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.assert_public_api_safe();
select erp.assert_intelligence_boundary();
select erp.assert_isolation();
