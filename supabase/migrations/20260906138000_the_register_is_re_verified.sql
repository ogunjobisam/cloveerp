-- =============================================================================
-- 20260906138000  The register is re-verified
-- -----------------------------------------------------------------------------
-- Specification v1.6 Part 5. erp_ref.part5_capability is the product's own
-- account of what it has built, and this phase read every row that was not
-- "built" against the tree. Six were closed by the files before this one
-- (supplier catalogues, order types, statistical forecasting, MRP, supply and
-- demand, dimensions, intercompany, accounts receivable). Four remained, and
-- two of their gap texts were stale:
--
--   * 5.9.carrier_integration said labelling "needs a document rendering
--     surface this product does not have". Part 15 built it: erp.render_label,
--     erp.compose_zpl, erp.route_print and the printer register. Flipped, with
--     the artefacts named.
--   * 5.10.scheduled_distribution said assembling several reports into one
--     pack "needs a document composition surface this product does not have".
--     Part 19 built the pack (erp.report_pack, erp.assemble_report_pack) and
--     the scheduled distribution of subscriptions. What was missing was the
--     schedule for a pack: a job handler, reporting.assemble_pack, that
--     assembles a named pack as the job's service principal. Added; flipped.
--   * 5.10.natural_language is an application concern by the accepted policy
--     decision nl_querying_reads_the_contract, which says so in as many
--     words. The register can now say a capability is closed by a decision:
--     part5_capability.closed_by_decision names it, and the coverage report
--     refuses a decision that is not accepted.
--   * 5.9.customs stays absent, and absent now needs a reason on the record:
--     the new decision customs_documentation_not_built says why a customs
--     declaration that is nearly right is worse than none.
--
-- Proof: erp_test.part5_register_suite() (7 cases, wrapper pinned): the
-- totals read 96 built, 0 partial, 1 absent; every closing decision is
-- accepted and every absent row has one; every artefact resolves; no policy
-- decision is open; the two decisions say what they close; the pack handler
-- has a SQL body and names in both languages; an absent row without a
-- decision is reported and rolled back.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A capability can be closed by a decision
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_ref.part5_capability
  add column if not exists closed_by_decision text references erp_meta.policy_decision (code);

comment on column erp_ref.part5_capability.closed_by_decision is
  'The accepted policy decision that closes this row: for an absent capability, '
  'why it is not built; for a built one whose surface is outside the database, '
  'the decision that says where it lives. erp.part5_coverage_report() refuses '
  'a closing decision that is not accepted, and an absent row without one.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The customs decision
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.policy_decision (code, title, spec_reference, decision, rationale, status, evidence, decided_at)
values (
  'customs_documentation_not_built',
  'Customs documentation is not built, and the register says so',
  'v1.6 §5.9',
  'The product records a customs reference on a shipment and nothing more. It does not '
  'produce a customs declaration, an origin statement or a commodity-coded invoice, and '
  'it will not until commodity codes are master data on the item, an origin rule exists per '
  'jurisdiction, and a document template per jurisdiction has been reviewed by someone who '
  'files them.',
  'A customs declaration that is nearly right is worse than none: it is filed, relied on, and '
  'wrong in a way the consignee discovers at the border. The three things it needs are each '
  'a jurisdiction''s content, not the product''s, and the legislation packs (v1.6 §5.7, D21) '
  'are the shape they would take. Until a pack carries them the honest state is absent, '
  'recorded, and visible on the register rather than partially built and quietly relied on.',
  'accepted',
  'erp.shipment.customs_reference is the whole surface; erp_ref.part5_capability 5.9.customs '
  'reads absent and names this decision; erp.part5_coverage_report() refuses an absent row '
  'without an accepted decision.',
  now())
on conflict (code) do update
  set title = excluded.title, decision = excluded.decision, rationale = excluded.rationale,
      status = excluded.status, evidence = excluded.evidence, spec_reference = excluded.spec_reference;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A pack on a schedule
-- ═════════════════════════════════════════════════════════════════════════════

-- The job's service principal assembles the pack; every report in it is run
-- and authorised as that principal, as erp.assemble_report_pack() does for a
-- person. A pack whose reports the principal may not read is refused there.
create or replace function erp.assemble_report_pack_job(p_parameters jsonb default '{}'::jsonb)
returns table(pack_code text, pack_run_id uuid, items integer)
language plpgsql
set search_path = ''
as $$
declare
  v_code text := p_parameters ->> 'pack_code';
  v_res  jsonb;
begin
  if coalesce(v_code, '') = '' then
    raise exception 'CLOVEERP_JOB_NEEDS_A_PACK: the job''s parameters name no pack_code'
      using errcode = '22023',
            hint = 'Give the job {"pack_code": "<code>"}; erp_report_packs() lists the packs.';
  end if;
  v_res := erp.assemble_report_pack(v_code);
  pack_code := v_code;
  pack_run_id := (v_res ->> 'pack_run_id')::uuid;
  items := jsonb_array_length(coalesce(v_res -> 'items', '[]'::jsonb));
  return next;
end;
$$;
revoke all on function erp.assemble_report_pack_job(jsonb) from public, anon, authenticated;

insert into erp_ref.job_handler (code, name_key, description, module_code, parameter_schema,
                                 default_timeout_seconds, forbids_overlap, is_current, sql_function,
                                 default_max_silence_seconds)
values ('reporting.assemble_pack', 'job_handler.assemble_pack.name',
        'Assembles the named report pack as the job''s service principal: every report in it is run, extracted and listed in the pack run''s manifest. §19.4 on a schedule.',
        'reporting',
        '{"type": "object", "required": ["pack_code"], "properties": {"pack_code": {"type": "string", "minLength": 1}}, "additionalProperties": false}'::jsonb,
        900, true, true, 'assemble_report_pack_job', 8 * 86400)
on conflict (code) do update
  set name_key = excluded.name_key, description = excluded.description, module_code = excluded.module_code,
      parameter_schema = excluded.parameter_schema, default_timeout_seconds = excluded.default_timeout_seconds,
      forbids_overlap = excluded.forbids_overlap, is_current = excluded.is_current,
      sql_function = excluded.sql_function, default_max_silence_seconds = excluded.default_max_silence_seconds;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('job_handler.assemble_pack.name', 'en', 'Assemble a report pack', 'reporting'),
  ('job_handler.assemble_pack.name', 'de', 'Berichtspaket zusammenstellen', 'reporting')
on conflict (key, locale) do update set value = excluded.value, module_code = excluded.module_code;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The four rows
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.part5_capability
   set status = 'built',
       gap = null,
       artefacts = array['erp.record_proof_of_delivery(uuid,timestamptz,text,text)',
                         'erp.external_system',
                         'erp.render_label(text,text,uuid,text)',
                         'erp.compose_zpl(jsonb,integer,text)',
                         'erp.route_print(uuid,uuid,text)',
                         'erp.printer']
 where code = '5.9.carrier_integration';

update erp_ref.part5_capability
   set status = 'built',
       gap = null,
       artefacts = array['erp.job',
                         'erp.job_run',
                         'erp.notification_template',
                         'erp.report_subscription',
                         'erp.distribute_report_subscriptions()',
                         'erp.report_pack',
                         'erp.report_pack_item',
                         'erp.report_pack_run',
                         'erp.assemble_report_pack(text)',
                         'erp.assemble_report_pack_job(jsonb)']
 where code = '5.10.scheduled_distribution';

update erp_ref.part5_capability
   set status = 'built',
       gap = null,
       closed_by_decision = 'nl_querying_reads_the_contract',
       artefacts = array['erp.governed_view',
                         'erp_ai.proposal',
                         'erp.analytics_read(text,text,timestamp with time zone,integer)']
 where code = '5.10.natural_language';

update erp_ref.part5_capability
   set closed_by_decision = 'customs_documentation_not_built'
 where code = '5.9.customs';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The coverage report reads the decisions
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.part5_coverage_report()'::regprocedure);
begin
  if position('a module has no registered capabilities' in v_src) = 0
     or position('closed_by_decision' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.part5_coverage_report is not the deployed body';
  end if;
end $$;

create or replace function erp.part5_coverage_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- A named function that does not exist.
  select 'a capability claims a function that does not exist',
         c.code, a.artefact
    from erp_ref.part5_capability c
    cross join lateral unnest(c.artefacts) a(artefact)
   where a.artefact like '%(%'
     and to_regprocedure(a.artefact) is null
  union all
  -- A named table or view that does not exist. Anything without brackets is
  -- read as a relation.
  select 'a capability claims a table that does not exist',
         c.code, a.artefact
    from erp_ref.part5_capability c
    cross join lateral unnest(c.artefacts) a(artefact)
   where a.artefact not like '%(%'
     and to_regclass(a.artefact) is null
  union all
  -- A capability that claims nothing is a row in a register and not a
  -- capability.
  select 'a capability names no artefact at all',
         c.code, c.requirement
    from erp_ref.part5_capability c
   where coalesce(array_length(c.artefacts, 1), 0) = 0
  union all
  -- Every module the product declares should appear. A section of Part 5 with
  -- no capabilities registered is one somebody forgot to write down, which is
  -- exactly the failure this register exists to prevent.
  select 'a module has no registered capabilities',
         m.code, 'Part 5 names this module and nothing claims to deliver any of it'
    from erp_ref.module m
   where not exists (select 1 from erp_ref.part5_capability c
                      where c.module_code = m.code)
  union all
  -- Absent is a decision, not a shrug.
  select 'an absent capability has no decision closing it',
         c.code, c.requirement
    from erp_ref.part5_capability c
   where c.status = 'absent' and c.closed_by_decision is null
  union all
  -- A closing decision that is not accepted closes nothing.
  select 'a capability is closed by a decision that is not accepted',
         c.code, format('%s is %s', c.closed_by_decision, coalesce(d.status, 'missing'))
    from erp_ref.part5_capability c
    left join erp_meta.policy_decision d on d.code = c.closed_by_decision
   where c.closed_by_decision is not null
     and coalesce(d.status, '') <> 'accepted'
  union all
  -- A partial row still needs to say what is missing.
  select 'a partial capability does not say what is missing',
         c.code, c.requirement
    from erp_ref.part5_capability c
   where c.status = 'partial' and length(coalesce(c.gap, '')) < 20
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.part5_register_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_built integer; v_partial integer; v_absent integer; v_n integer; v_ok boolean; v_msg text;
begin
  select count(*) filter (where status = 'built'), count(*) filter (where status = 'partial'),
         count(*) filter (where status = 'absent')
    into v_built, v_partial, v_absent
    from erp_ref.part5_capability;

  return query select 'the register reads 96 built, 0 partial, 1 absent, and the summary agrees',
    v_built = 96 and v_partial = 0 and v_absent = 1
    and (select sum(s.built) from erp.part5_summary() s) = 96
    and (select sum(s.total) from erp.part5_summary() s) = 97,
    format('%s built, %s partial, %s absent', v_built, v_partial, v_absent);

  return query select 'every closing decision is accepted, and every absent row has one',
    not exists (select 1 from erp_ref.part5_capability c where c.status = 'absent' and c.closed_by_decision is null)
    and not exists (select 1 from erp_ref.part5_capability c
                     join erp_meta.policy_decision d on d.code = c.closed_by_decision
                    where d.status <> 'accepted')
    and (select count(*) from erp_ref.part5_capability c where c.closed_by_decision is not null) = 2,
    '5.9.customs by customs_documentation_not_built; 5.10.natural_language by nl_querying_reads_the_contract';

  select count(*) into v_n from erp.part5_coverage_report();
  return query select 'every artefact the register names resolves, and the coverage report is empty',
    v_n = 0, format('%s finding(s)', v_n);

  select count(*) into v_n from erp_meta.policy_decision d where d.status = 'open';
  return query select 'no policy decision is open',
    v_n = 0, format('%s open', v_n);

  return query select 'the two decisions say what they close, in the register''s own words',
    exists (select 1 from erp_meta.policy_decision d where d.code = 'customs_documentation_not_built'
             and d.status = 'accepted' and d.rationale like '%nearly right is worse than none%'
             and d.evidence like '%5.9.customs%')
    and exists (select 1 from erp_meta.policy_decision d where d.code = 'nl_querying_reads_the_contract'
             and d.status = 'accepted' and d.decision like '%model outside the database%')
    and (select c.gap is null from erp_ref.part5_capability c where c.code = '5.10.natural_language'),
    'customs: absent for a reason; natural language: a client of the analytics contract';

  return query select 'a report pack can be assembled on a schedule: the handler has a SQL body and names in both languages',
    exists (select 1 from erp_ref.job_handler h where h.code = 'reporting.assemble_pack' and h.is_current
             and h.sql_function = 'assemble_report_pack_job'
             and to_regprocedure('erp.' || h.sql_function || '(jsonb)') is not null)
    and (select count(*) from erp_ref.resource r where r.key = 'job_handler.assemble_pack.name' and r.locale in ('en', 'de')) = 2,
    'reporting.assemble_pack → erp.assemble_report_pack_job(jsonb)';

  -- The negative: an absent row without a decision is reported.
  begin
    update erp_ref.part5_capability set closed_by_decision = null where code = '5.9.customs';
    select count(*) into v_n from erp.part5_coverage_report() f
     where f.finding = 'an absent capability has no decision closing it' and f.reference = '5.9.customs';
    v_ok := v_n = 1; v_msg := format('%s finding(s) for 5.9.customs without its decision', v_n);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_ok := false; v_msg := left(sqlerrm, 200);
    end if;
  end;
  return query select 'an absent row without a decision is reported, and the register is put back',
    v_ok and (select c.closed_by_decision from erp_ref.part5_capability c where c.code = '5.9.customs') = 'customs_documentation_not_built',
    v_msg;
end;
$$;

create or replace function erp_test.assert_part5_register_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _part5_register on commit drop as
    select * from erp_test.part5_register_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _part5_register;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_PART5_REGISTER_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_PART5_REGISTER_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('part 5 register: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_part5_register_suite() from public, anon, authenticated;
revoke all on function erp_test.part5_register_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_part5_register_suite();
select erp_test.assert_policy_register_suite();
select erp_test.assert_reporting_services_suite();
select erp.assert_part5_coverage();
select erp.assert_vocabulary_aligned();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
