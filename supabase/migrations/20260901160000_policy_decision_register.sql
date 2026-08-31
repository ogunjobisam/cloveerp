-- =============================================================================
-- Addendum B, Part 3 — a register for decisions, and the §2.1 one in it
--
-- This codebase already keeps four registers of deliberate deviation:
-- erp_meta.audit_exemption, attribution_exemption, public_write_allowance and
-- security_definer_allowance. Each is read by an assertion, so a deviation that
-- is not written down fails the build. They work because the thing being
-- recorded is structural — a trigger, a grant, a gate — and a catalogue query
-- can tell whether the record and the deployment agree.
--
-- Judgement is different, and has had nowhere to live. The decision to keep the
-- tenant switcher in the face of spec §2.1 exists today as a paragraph in
-- .lovable/plan/erpware-advice-on-the-remaining-gaps-2026-08-30.md — a planning
-- document, not part of the product, not visible to anybody operating it, and
-- not something a future reader of user-menu.tsx:77 would ever find. The code
-- says what happens; nothing says it was chosen.
--
-- So: a fifth register, deliberately of a different kind. There is no assertion
-- over it and there should not be, because nothing about a judgement is
-- falsifiable by a catalogue query. What it does have is a status that
-- distinguishes a decision taken from a question still open, which is the
-- distinction a document full of prose loses first.
-- =============================================================================

create table if not exists erp_meta.policy_decision (
  code           text primary key,
  title          text not null,
  spec_reference text,
  decision       text not null,
  rationale      text not null,
  status         text not null default 'accepted'
                   check (status in ('accepted', 'open', 'superseded')),
  -- Where in the product this decision is visible. A decision nobody can point
  -- at in running code is an opinion.
  evidence       text,
  decided_by     text,
  decided_at     timestamptz not null default now()
);

comment on table erp_meta.policy_decision is
  'Decisions taken about the product that the code alone does not explain: '
  'deliberate deviations from the specification, and questions deliberately '
  'left open. Unlike the four allowance registers this one is not read by an '
  'assertion — nothing about a judgement can be falsified by a catalogue query '
  '— so its value is that the decision is in the product rather than in a '
  'planning document nobody reads twice.';

select erp_meta.register_table(
  'erp_meta', 'policy_decision', 'platform_internal',
  'Platform register of decisions. Not tenant data, and readable by platform '
  'staff rather than by a tenant''s administrators.');

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence, decided_by) values

  ('tenant_switching',
   'One identity belongs to one organisation, except for platform staff',
   'Spec §2.1',
   'Keep the switcher. An ordinary account belongs to exactly one organisation, '
   'as §2.1 requires. Platform staff are the single exception, and every entry '
   'into a customer organisation is recorded with a reason.',
   'Strict §2.1 would make the platform console unable to do the job it exists '
   'for, and would make demonstrating or supporting more than one organisation '
   'from one account impossible. The isolation boundary is row-level security, '
   'which is unaffected either way — the switcher changes which organisation a '
   'session is in, not what it may see once there. An organisation that needs '
   'strict §2.1 should get it from a per-organisation policy flag rather than '
   'from removing the switcher for everybody.',
   'accepted',
   'src/components/erp/user-menu.tsx renders the picker only when '
   'erp_platform_me() reports staff; public.erp_platform_enter_tenant() writes '
   'erp_meta.platform_audit, and the entry is visible on Platform → Activity.',
   'ogunjobisam@gmail.com'),

  ('promotion_authorises_once',
   'Promotion is authorised at the change set, not at each item',
   'Spec §3.11, Addendum B cross-cutting',
   'The permission gate stays in the public erp_upsert_* door and is '
   'deliberately absent from the erp.* mechanism the promoter calls. A '
   'principal holding administration.promote and nothing else can promote a '
   'change set carrying an account_determination item.',
   'This is the separation of duties B6 exists for: the person who authors a '
   'change and the person who releases it are different people, and the '
   'releaser is not required to hold every permission the change touches. All '
   'thirty-one branches of erp.apply_change_set_item() follow it. The cost is '
   'that the gate lives in one place and the logic in another, which looks '
   'like duplication until you try to promote somebody else''s work.',
   'accepted',
   'erp_test.addendum_b_promotion_suite() promotes all nine surfaces as a '
   'principal holding only administration.promote; putting the gate back into '
   'erp.upsert_account_determination() fails that case with '
   'ERPWARE_PERMISSION_DENIED.',
   'ogunjobisam@gmail.com'),

  ('two_account_selection_mechanisms',
   'Account determination and posting rules both choose accounts, and only one posts',
   'Addendum B §5 and §8, Part 5 §5.7',
   'Left as it stands for now, and recorded rather than resolved. '
   'erp.post_document_finance() chooses accounts through erp.posting_rule. '
   'erp.account_determination — Addendum B.3 — is reached only by '
   'public.erp_determine_account(), which explains and previews. C1 asserts '
   'over both so neither is unwatched.',
   'Merging them is a real change to how every journal is raised and is not '
   'something to do as a side effect of building an assertion. Until it is '
   'decided, the risk is that configuring determination rules feels like '
   'configuring how postings behave when it is not — which is exactly the kind '
   'of thing that should be written down rather than discovered at a close.',
   'open',
   'erp.determination_coverage_report() labels every finding with the '
   'mechanism it belongs to; public.erp_determination_coverage_report() shows '
   'both on Finance → Account determination.',
   null),

  ('promotable_surface_completeness',
   'The configuration register cannot prove its own completeness',
   'Addendum B cross-cutting',
   'erp_meta.promotable_surface is the single statement of which tables hold '
   'configuration. erp.assert_configuration_promotable() proves every '
   'registered surface is promotable, capturable and guarded, and that nothing '
   'carries the guard without being registered. It cannot prove that a tenth '
   'surface does not exist unregistered.',
   'That gap is why nine Addendum B surfaces went unguarded for as long as they '
   'existed: apply_live_config_guards() held a hardcoded array and nothing '
   'compared it to anything. Making the register generate the guard closes the '
   'drift in both directions, which is as far as a structural check reaches — '
   'the remaining step is a person deciding a new table is configuration, and '
   'no query can make that decision for them.',
   'accepted',
   'erp.assert_configuration_promotable() runs in CI over '
   'erp_meta.promotable_surface, and fails on a surface registered but not '
   'wired, or wired but not registered.',
   'ogunjobisam@gmail.com')

on conflict (code) do update set
  title = excluded.title, spec_reference = excluded.spec_reference,
  decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

-- -----------------------------------------------------------------------------
-- The door
--
-- Platform staff rather than a tenant's administrators: these are decisions
-- about the product, not about any one organisation's configuration.
-- -----------------------------------------------------------------------------

create or replace function public.erp_platform_policy_decisions()
returns jsonb
language plpgsql
-- Not STABLE: erp_meta.require_platform() binds the identity the first time it
-- is seen, which is a write. erp_platform_audit() is volatile for the same
-- reason.
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'code', d.code, 'title', d.title,
             'spec_reference', d.spec_reference,
             'decision', d.decision, 'rationale', d.rationale,
             'status', d.status, 'evidence', d.evidence,
             'decided_by', d.decided_by, 'decided_at', d.decided_at)
           -- Open questions first: a register read top to bottom should start
           -- with what has not been settled.
           order by case d.status when 'open' then 0 when 'accepted' then 1
                                  else 2 end, d.code)
      from erp_meta.policy_decision d), '[]'::jsonb);
end;
$$;

comment on function public.erp_platform_policy_decisions is
  'Read-only view of erp_meta.policy_decision for platform staff. There is no '
  'write door: a decision is taken in a migration, with the reasoning beside '
  'it in the diff, not typed into a form.';

revoke all on function public.erp_platform_policy_decisions() from public, anon;
grant execute on function public.erp_platform_policy_decisions() to authenticated;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('public', 'erp_platform_policy_decisions',
        'Platform-level read. erp_meta is platform_internal — RLS enabled with '
        'no policy and a blanket revoke — so no tenant session can reach it '
        'without a definer; gated on erp_meta.require_platform(''support'').')
on conflict do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values ('erp_platform_policy_decisions', 'erp_meta.require_platform',
        'Platform staff read, gated on the platform staff list rather than on '
        'erp.authorise(), because it is performed above every tenant.')
on conflict do nothing;

-- ── The suite ────────────────────────────────────────────────────────────────
--
-- There is no assertion over this register and there should not be: nothing
-- about a judgement is falsifiable by a catalogue query. What can be proved is
-- that the door is gated, that the register is not empty, and that a decision
-- still open is not quietly presented as one that has been taken.

create or replace function erp_test.policy_register_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  st uuid := gen_random_uuid();   -- platform support
  nb uuid := gen_random_uuid();   -- nobody
  res jsonb; v_ok boolean; v_msg text;
begin
  insert into auth.users (id, email) values
    (st, 'support@zzpolicy.test'), (nb, 'nobody@zzpolicy.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('support@zzpolicy.test', st, 'Policy Support', 'support');

  perform set_config('request.jwt.claims', json_build_object('sub', nb)::text, true);
  begin
    perform public.erp_platform_policy_decisions();
    v_ok := false; v_msg := 'an account off the staff list read the register';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_PLATFORM_STAFF%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'an account that is not platform staff cannot read it',
    v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', st)::text, true);
  res := public.erp_platform_policy_decisions();

  return query select 'platform support can',
    jsonb_array_length(res) > 0,
    'a register nobody can read is a planning document with extra steps';

  return query select 'the §2.1 switcher decision is there, and accepted',
    exists (select 1 from jsonb_array_elements(res) d
             where d.value ->> 'code' = 'tenant_switching'
               and d.value ->> 'status' = 'accepted'),
    'today it exists only as a paragraph in a planning file';

  return query select 'and it names where the decision is visible in the product',
    (select length(d.value ->> 'evidence') > 0 from jsonb_array_elements(res) d
      where d.value ->> 'code' = 'tenant_switching'),
    'a decision nobody can point at in running code is an opinion';

  return query select 'a question still open is not recorded as settled',
    (select d.value ->> 'status' from jsonb_array_elements(res) d
      where d.value ->> 'code' = 'two_account_selection_mechanisms') = 'open',
    'the distinction between decided and undecided is the first thing a '
    'document full of prose loses';

  return query select 'and open questions are listed first',
    (res -> 0 ->> 'status') = 'open',
    'a register read top to bottom should start with what is unsettled';

  return query select 'every decision carries a rationale, not just a verdict',
    not exists (select 1 from jsonb_array_elements(res) d
                 where coalesce(length(d.value ->> 'rationale'), 0) < 40),
    'the reason is the part that is worth anything a year later';

  return query select 'the status column refuses a word nobody defined',
    (select not exists (
       select 1 from jsonb_array_elements(res) d
        where d.value ->> 'status' not in ('accepted', 'open', 'superseded'))),
    'a free-text status drifts into a dozen synonyms for "probably fine"';

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.platform_staff where email = 'support@zzpolicy.test';
  delete from auth.users where id in (st, nb);

  return query select 'and the suite removes the staff row it added',
    not exists (select 1 from erp_meta.platform_staff
                 where email = 'support@zzpolicy.test'),
    'left behind it would change what erp_platform_claim_ownership() does next';
end $$;

create or replace function erp_test.assert_policy_register_suite()
returns text
language plpgsql
set search_path to ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Two on the gate, four on what the register holds, two on its shape, and
  -- the cleanup.
  c_expected constant integer := 9;
begin
  create temporary table if not exists zz_policy_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_policy_result;
  insert into zz_policy_result select * from erp_test.policy_register_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_policy_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_POLICY_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_POLICY_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('policy register: %s/%s', v_pass, v_total);
end $$;

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();

select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_configuration_promotable();
