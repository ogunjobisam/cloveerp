-- =============================================================================
-- Addendum B, Part 2 — C1, the coverage assertion §8 names and nobody built
--
-- §8 calls for "the C1 coverage assertion that no posting can fail to
-- determine". §5 says what it must prove — "for every combination of posting
-- class, transaction type and entity that can occur, a rule must exist" — and
-- is emphatic that there is no default-to-suspense, so an uncovered
-- combination is a refusal at posting time rather than a suspense entry
-- somebody reconciles at month end.
--
-- Building it turned up something the plan for it did not know, and it changes
-- what the assertion has to cover.
--
-- THERE ARE TWO ACCOUNT-SELECTION MECHANISMS, AND POSTINGS USE THE OTHER ONE.
--
--   erp.post_document_finance() — the only thing that raises a journal — reads
--   erp.document_type.posting_rule_code, finds the erp.posting_rule version in
--   force on the document's posting date, and resolves each of that rule's
--   lines to an erp.account by code AND ENTITY. It never consults
--   erp.account_determination.
--
--   erp.account_determination — Addendum B.3, the surface the previous
--   migration made promotable — is reachable from exactly one caller,
--   public.erp_determine_account(), which the /finance/account-determination
--   screen uses to explain and preview. Nothing posts through it.
--
-- So an assertion built only over erp.determination_coverage() would be a
-- green tick over a mechanism no posting uses. This one covers both, and says
-- which is which. The posting-path findings each correspond to an exception
-- erp.post_document_finance() actually raises:
--
--   1 → ERPWARE_NO_POSTING_RULE
--   2 → ERPWARE_NO_POSTING_RULE_IN_FORCE
--   3 → ERPWARE_UNKNOWN_ACCOUNT      (the entity dimension §5 names)
--   4 → ERPWARE_POSTING_RULE_HAS_NO_LEDGER
--
-- Finding 3 is the one worth the whole exercise. Accounts are resolved per
-- entity, so a chart of accounts complete on one company and short of one
-- account on another posts fine all year and refuses the first time a document
-- is raised on the second company.
--
-- Whether the two mechanisms should be one is a design question, not a defect
-- this migration may decide. It is recorded here rather than resolved.
-- =============================================================================

create or replace function erp.determination_coverage_report(p_tenant_id uuid default null)
returns table(tenant_code text, mechanism text, finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- ── The posting path: what actually raises journals ──────────────────────

  -- 1. affects_finance and no rule named at all.
  select t.code, 'posting path',
         'a document type reaches the ledger but names no posting rule',
         dt.code,
         'erp_ref.document_type.affects_finance is true for base type '
           || dt.base_type_code
           || ', so posting this document raises ERPWARE_NO_POSTING_RULE'
    from erp.document_type dt
    join erp.tenant t on t.id = dt.tenant_id
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'
     and bt.affects_finance
     and dt.posting_rule_code is null
     and (p_tenant_id is null or dt.tenant_id = p_tenant_id)

  union all

  -- 2. A rule named, and no version of it in force today.
  select t.code, 'posting path',
         'a document type names a posting rule with no version in force',
         dt.code || ' → ' || dt.posting_rule_code,
         'a rule is promoted with an effective date; a document outside every '
         'version''s range raises ERPWARE_NO_POSTING_RULE_IN_FORCE and must '
         'not be guessed at'
    from erp.document_type dt
    join erp.tenant t on t.id = dt.tenant_id
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'
     and bt.affects_finance
     and dt.posting_rule_code is not null
     and (p_tenant_id is null or dt.tenant_id = p_tenant_id)
     and not exists (
       select 1 from erp.posting_rule r
        where r.tenant_id = dt.tenant_id
          and r.code = dt.posting_rule_code
          and r.status = 'active'
          and r.effective_from <= current_date
          and (r.effective_to is null or r.effective_to > current_date))

  union all

  -- 3. §5's own sentence, on the mechanism that posts: a combination of
  --    transaction type (the document type) and entity for which the rule
  --    names an account that company does not have.
  select t.code, 'posting path',
         'a posting rule names an account a company does not have',
         format('%s on %s wants account %s', pr.code, e.code, l.value ->> 'account'),
         'erp.post_document_finance() resolves each line to an account by code '
         'AND entity, so this document type refuses on this company with '
         'ERPWARE_UNKNOWN_ACCOUNT while working everywhere else'
    from erp.document_type dt
    join erp.tenant t on t.id = dt.tenant_id
    join erp_ref.document_type bt on bt.code = dt.base_type_code
    join lateral (
      select r.* from erp.posting_rule r
       where r.tenant_id = dt.tenant_id
         and r.code = dt.posting_rule_code
         and r.status = 'active'
         and r.effective_from <= current_date
         and (r.effective_to is null or r.effective_to > current_date)
       order by r.version desc limit 1) pr on true
    -- A document type scoped to one company is only ever raised on that one.
    join erp.entity e
      on e.tenant_id = dt.tenant_id and e.status = 'active'
     and (dt.entity_id is null or dt.entity_id = e.id)
    cross join lateral jsonb_array_elements(coalesce(pr.posting_lines, '[]'::jsonb)) l
   where dt.status = 'active'
     and bt.affects_finance
     and (p_tenant_id is null or dt.tenant_id = p_tenant_id)
     and (l.value ->> 'account') is not null
     and not exists (
       select 1 from erp.account a
        where a.tenant_id = dt.tenant_id
          and a.entity_id = e.id
          and a.code = (l.value ->> 'account')
          and a.status = 'active')

  union all

  -- 4. A rule in force that names no ledger to post into.
  select t.code, 'posting path',
         'a posting rule in force names no ledger',
         pr.code,
         'erp.post_document_finance() raises ERPWARE_POSTING_RULE_HAS_NO_LEDGER '
         'before it writes anything'
    from erp.posting_rule pr
    join erp.tenant t on t.id = pr.tenant_id
   where pr.status = 'active'
     and pr.effective_from <= current_date
     and (pr.effective_to is null or pr.effective_to > current_date)
     and (p_tenant_id is null or pr.tenant_id = p_tenant_id)
     and (pr.ledger_id is null
          or not exists (select 1 from erp.ledger l
                          where l.tenant_id = pr.tenant_id and l.id = pr.ledger_id
                            and l.status = 'active'))

  -- ── Addendum B.3: the determination surface ──────────────────────────────

  union all

  -- 5. A determination rule pointing at an account that is not active. The
  --    rule resolves, and then the account it resolves to cannot be posted to.
  select t.code, 'determination',
         'a determination rule points at an account that is not active',
         ad.transaction_type || ' → ' || coalesce(a.code, '(missing)'),
         'erp.determine_account() returns this rule and the account behind it '
         'cannot receive a posting'
    from erp.account_determination ad
    join erp.tenant t on t.id = ad.tenant_id
    left join erp.account a on a.id = ad.account_id
   where ad.status = 'active'
     and daterange(ad.valid_from, ad.valid_to, '[)') @> current_date
     and (p_tenant_id is null or ad.tenant_id = p_tenant_id)
     and (a.id is null or a.status <> 'active')

  union all

  -- 6. §5's sentence on the determination surface itself: every combination of
  --    posting class, transaction type and entity that can occur.
  --
  --    The honest limit, stated rather than papered over: the set of
  --    transaction types is derived from the rules that exist, because nothing
  --    in the schema declares which transaction types can occur. A transaction
  --    type with no rule at all is therefore invisible here — and, on this
  --    mechanism, unreachable too, since erp.determine_account() is only ever
  --    called with a type somebody has asked about.
  select t.code, 'determination',
         'a posting class and company combination has no determination rule',
         format('%s × %s × %s', c.transaction_type, c.item_class_code, c.entity_code),
         '§5 refuses a default-to-suspense, so this combination is a refusal '
         'at posting time rather than a suspense entry'
    from (
      select ad.tenant_id, tt.transaction_type,
             ic.id as item_class_id, ic.code as item_class_code,
             en.id as entity_id, en.code as entity_code
        from (select distinct a2.tenant_id, a2.transaction_type
                from erp.account_determination a2
               where a2.status = 'active') tt
        join erp.account_determination ad on ad.tenant_id = tt.tenant_id
        join erp.posting_class ic
          on ic.tenant_id = tt.tenant_id and ic.kind = 'item' and ic.status = 'active'
        join erp.entity en
          on en.tenant_id = tt.tenant_id and en.status = 'active'
       group by ad.tenant_id, tt.transaction_type, ic.id, ic.code, en.id, en.code
    ) c
    join erp.tenant t on t.id = c.tenant_id
   where (p_tenant_id is null or c.tenant_id = p_tenant_id)
     and not exists (
       select 1 from erp.account_determination ad
        where ad.tenant_id = c.tenant_id
          and ad.status = 'active'
          and ad.transaction_type = c.transaction_type
          and daterange(ad.valid_from, ad.valid_to, '[)') @> current_date
          and (ad.item_class_id is null or ad.item_class_id = c.item_class_id)
          and (ad.entity_id is null or ad.entity_id = c.entity_id))
$$;

comment on function erp.determination_coverage_report is
  'C1 (Addendum B §8): every way a posting can fail to determine an account, '
  'across both mechanisms — erp.posting_rule, which raises journals, and '
  'erp.account_determination, which does not. Pass a tenant id to scope it to '
  'one organisation; null reports on all of them.';

create or replace function erp.assert_determination_coverage(p_tenant_id uuid default null)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text; v_posting integer;
begin
  select count(*),
         count(*) filter (where mechanism = 'posting path'),
         string_agg(format('  [%s] %s — %s: %s',
                           tenant_code, finding, reference, detail), E'\n')
    into v_count, v_posting, v_detail
    from erp.determination_coverage_report(p_tenant_id);

  if v_count > 0 then
    raise exception
      'ERPWARE_DETERMINATION_NOT_COVERED: % finding(s), % of them on the '
      'path that actually posts', v_count, v_posting
      using errcode = 'P0001', detail = v_detail,
            hint = '§5 refuses a default-to-suspense: each of these is a '
                   'refusal at posting time, not a suspense entry.';
  end if;

  return 'determination: no posting can fail to determine';
end;
$$;

comment on function erp.assert_determination_coverage is
  'The C1 coverage assertion of Addendum B §8. Run before promotion, not after '
  'month-end: an uncovered combination refuses the posting rather than landing '
  'it in suspense.';


-- -----------------------------------------------------------------------------
-- §5: "run before promotion, not after month-end"
-- -----------------------------------------------------------------------------

create or replace function erp.promote_change_set(
  p_change_set_id uuid, p_scope_kinds text[] default null,
  p_ignore_schedule boolean default false)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  cs         erp.change_set%rowtype;
  v_promo    uuid;
  v_snapshot uuid;
  v_applied  integer := 0;
  v_env      uuid;
  r          record;
  v_entity   record;
  v_before   text[];
  v_new      text;
begin
  perform erp.authorise('administration.promote', null, null, null,
                        'change_set', p_change_set_id);

  -- Before the snapshot, so a tenant with no environment fails without having
  -- written anything.
  v_env := erp.self_environment_id(v_tenant);

  select * into cs from erp.change_set
   where tenant_id = v_tenant and id = p_change_set_id for update;

  if cs.status <> 'approved' then
    raise exception 'ERPWARE_CHANGE_SET_NOT_APPROVED: % is %', cs.code, cs.status
      using errcode = '42501';
  end if;

  if cs.scheduled_for is not null and not p_ignore_schedule and now() < cs.scheduled_for then
    raise exception 'ERPWARE_CHANGE_SET_NOT_DUE: % is scheduled for %', cs.code, cs.scheduled_for
      using errcode = '23514';
  end if;

  -- Snapshot first. Rollback is only "one action" if the previous state was
  -- captured before anything moved.
  v_snapshot := erp.take_config_snapshot(
    format('before promotion of %s', cs.code),
    format('pre-%s-%s', cs.code, to_char(clock_timestamp(), 'YYYYMMDDHH24MISS')));

  insert into erp.promotion (
    tenant_id, change_set_id, environment_id, snapshot_id, scope_kinds, actor_id)
  values (
    v_tenant, p_change_set_id, v_env,
    v_snapshot, p_scope_kinds, erp.current_principal_id())
  returning id into v_promo;

  update erp.change_set
     set status = 'promoting', rollback_snapshot_id = v_snapshot, updated_at = now()
   where id = p_change_set_id;

  -- Opens the window in which configuration may be written in a live
  -- environment. Transaction-scoped, so it closes whatever happens next.
  perform set_config('erp.promotion_id', v_promo::text, true);

  -- C1, Addendum B §5: "run before promotion, not after month-end".
  --
  -- Stated as a delta rather than as an absolute, and the difference matters.
  -- An absolute check fires on states that are merely intermediate: an
  -- organisation part-way through installing its modules has document types
  -- naming posting rules a later change set will supply, and failing that
  -- promotion would turn the installation order into a hidden precondition.
  -- What a promotion must never do is make determination WORSE — introduce a
  -- way for a posting to fail that did not exist a moment ago. The whole
  -- promotion rolls back with it.
  select coalesce(array_agg(c.finding || ' | ' || c.reference), '{}')
    into v_before
    from erp.determination_coverage_report(v_tenant) c;

  for r in
    select i.id from erp.change_set_item i
     where i.tenant_id = v_tenant
       and i.change_set_id = p_change_set_id
       and (p_scope_kinds is null or i.object_kind = any (p_scope_kinds))
     order by
       -- Roles and terminology before the things that reference them.
       case i.object_kind
         when 'role' then 1 when 'terminology' then 2 when 'config' then 3
         when 'legislation_binding' then 4 when 'event_subscription' then 5
         when 'rule_set' then 6 when 'state_machine' then 7
         when 'approval_chain' then 8 else 9 end,
       i.seq
  loop
    perform erp.apply_change_set_item(r.id);
    v_applied := v_applied + 1;
  end loop;

  -- Spec 3.11: "validated by tests". The pack conformance suite is the test
  -- that matters most here, because a promotion that quietly changes a tax
  -- answer is the expensive kind.
  for v_entity in
    select distinct b.entity_id from erp.entity_legislation_binding b
     where b.tenant_id = v_tenant and b.status = 'active'
  loop
    perform erp.assert_legislation_conformance(v_entity.entity_id);
  end loop;

  select string_agg(format('  %s — %s: %s', c.finding, c.reference, c.detail), E'\n')
    into v_new
    from erp.determination_coverage_report(v_tenant) c
   where (c.finding || ' | ' || c.reference) <> all (v_before);

  if v_new is not null then
    raise exception
      'ERPWARE_PROMOTION_BREAKS_DETERMINATION: % introduces a way for a posting to fail',
      cs.code
      using errcode = 'P0001', detail = v_new,
            hint = '§5 refuses a default-to-suspense, so each of these is a '
                   'refusal at posting time rather than a suspense entry. '
                   'erp.determination_coverage_report() lists what was already '
                   'outstanding before this promotion.';
  end if;

  update erp.promotion
     set status = 'succeeded', finished_at = now(), applied_count = v_applied
   where id = v_promo;

  update erp.change_set
     set status = 'promoted', promoted_at = now(), updated_at = now()
   where id = p_change_set_id;

  perform set_config('erp.promotion_id', '', true);

  return v_promo;
end;
$$;


-- ── The suite, and why the assertion needs one ───────────────────────────────
--
-- Every suite in this repository purges the organisation it built, so by the
-- time CI reaches its closing assertions the database is empty: no tenants, no
-- document types, no posting rules, no accounts. A coverage assertion run
-- there passes because there is nothing to judge — which is precisely the
-- failure mode this codebase already documents in
-- erp.assert_scheduler_integrity(), and precisely the reason to write down
-- what a green tick from it is worth.
--
-- So the assertion is proved here, on a fixture: a fully configured
-- organisation reports nothing, and then each of the six findings is planted
-- in turn and each one is caught. The plant for finding 3 is worth naming: the
-- first attempt added a second company with an empty chart of accounts and
-- reported nothing — correctly, because every document type on that
-- organisation is scoped to one company, so no document can be raised on the
-- second at all. The scenario that does bite is an account retired out from
-- under a posting rule that names it.

create or replace function erp_test.determination_coverage_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  a1 uuid := gen_random_uuid();
  b1 uuid := gen_random_uuid();
  v jsonb; v_t uuid; v_e uuid; v_tb uuid;
  v_dt uuid; v_rule text; v_pr uuid; v_acc uuid; v_want text;
  n integer; v_ok boolean; v_msg text; v_cs uuid;
begin
  insert into auth.users (id, email) values
    (a1, 'c1@zzc1.test'), (b1, 'c1b@zzc1.test');

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  v := erp.onboard_tenant('C1 coverage', 'zzc1');
  v_t := (v ->> 'tenant_id')::uuid;
  v_e := (v ->> 'entity_id')::uuid;
  perform erp.configure_finance();
  perform erp.configure_procurement();
  perform erp.configure_sales(20);

  -- ── The baseline ────────────────────────────────────────────────────────

  return query select
    'a fully configured organisation has nothing to report',
    (select count(*) from erp.determination_coverage_report(v_t)) = 0,
    'if this is not zero every case below is measuring the wrong thing';

  return query select 'and it has finance-bearing document types to judge',
    (select count(*) from erp.document_type dt
       join erp_ref.document_type bt on bt.code = dt.base_type_code
      where dt.tenant_id = v_t and dt.status = 'active' and bt.affects_finance) > 0,
    'a report over an organisation with no postable documents is green for '
    'the same reason an empty database is';

  -- ── The posting path ────────────────────────────────────────────────────

  select dt.id, dt.posting_rule_code into v_dt, v_rule
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = v_t and dt.status = 'active' and bt.affects_finance
     and dt.posting_rule_code is not null
   limit 1;

  update erp.document_type set posting_rule_code = null where id = v_dt;
  select count(*) into n from erp.determination_coverage_report(v_t)
   where finding like '%names no posting rule';
  return query select 'a document type that reaches the ledger and names no rule',
    n = 1, format('%s finding(s) — posting it raises ERPWARE_NO_POSTING_RULE', n);

  update erp.document_type set posting_rule_code = 'NO-SUCH-RULE' where id = v_dt;
  select count(*) into n from erp.determination_coverage_report(v_t)
   where finding like '%no version in force';
  return query select 'a document type naming a rule with no version in force',
    n = 1,
    format('%s finding(s) — a document outside every version''s range must not '
           'be guessed at', n);
  update erp.document_type set posting_rule_code = v_rule where id = v_dt;

  -- §5's own sentence, on the mechanism that posts. Accounts resolve by code
  -- AND company, so retiring one breaks every rule that names it, on the
  -- companies that no longer have it, and nowhere else.
  select l.value ->> 'account' into v_want
    from erp.posting_rule pr,
         lateral jsonb_array_elements(pr.posting_lines) l
   where pr.tenant_id = v_t and pr.status = 'active'
     and (l.value ->> 'account') is not null
   limit 1;
  update erp.account set status = 'inactive'
   where tenant_id = v_t and code = v_want;
  select count(*) into n from erp.determination_coverage_report(v_t)
   where finding like '%account a company does not have';
  return query select
    'an account retired out from under a rule that names it',
    n > 0,
    format('%s document type(s) would refuse on this company with '
           'ERPWARE_UNKNOWN_ACCOUNT and work everywhere else', n);
  update erp.account set status = 'active'
   where tenant_id = v_t and code = v_want;

  select id into v_pr from erp.posting_rule
   where tenant_id = v_t and status = 'active' limit 1;
  update erp.posting_rule set ledger_id = null where id = v_pr;
  select count(*) into n from erp.determination_coverage_report(v_t)
   where finding like '%names no ledger';
  return query select 'a rule in force with no ledger to post into',
    n = 1, format('%s finding(s)', n);
  update erp.posting_rule
     set ledger_id = (select l.id from erp.ledger l
                       where l.tenant_id = v_t and l.code = 'GL')
   where id = v_pr;

  return query select 'and with all four put back, the posting path is clear',
    (select count(*) from erp.determination_coverage_report(v_t)
      where mechanism = 'posting path') = 0,
    'a report that cannot go back to green is a report nobody will act on';

  -- ── The determination surface ───────────────────────────────────────────

  insert into erp.account (tenant_id, entity_id, code, name, account_type, status)
  values (v_t, v_e, '9999', 'Retired account', 'expense', 'inactive')
  returning id into v_acc;
  insert into erp.account_determination (
    tenant_id, transaction_type, account_id, valid_from, status)
  values (v_t, 'zz_probe', v_acc, current_date, 'active');

  select count(*) into n from erp.determination_coverage_report(v_t)
   where finding like '%account that is not active';
  return query select 'a determination rule pointing at a retired account',
    n = 1,
    format('%s finding(s) — the rule resolves and the account behind it cannot '
           'receive a posting', n);

  insert into erp.posting_class (tenant_id, kind, code, name, valid_from, status)
  values (v_t, 'item', 'FG', 'Finished goods', current_date, 'active'),
         (v_t, 'item', 'RM', 'Raw materials',  current_date, 'active');
  update erp.account_determination
     set item_class_id = (select pc.id from erp.posting_class pc
                           where pc.tenant_id = v_t and pc.kind = 'item'
                             and pc.code = 'FG')
   where tenant_id = v_t and transaction_type = 'zz_probe';

  select count(*) into n from erp.determination_coverage_report(v_t)
   where finding like '%no determination rule';
  return query select
    'a posting class and company combination with no rule to cover it',
    n = 1,
    format('%s finding(s) — §5 refuses a default-to-suspense, so this is a '
           'refusal at posting time', n);

  return query select 'the report names which mechanism each finding is on',
    (select count(distinct mechanism) from erp.determination_coverage_report(v_t)) = 1
      and (select distinct mechanism from erp.determination_coverage_report(v_t))
          = 'determination',
    'erp.account_determination is not on the path that raises journals, and a '
    'report that blurred the two would overstate what it proves';

  -- ── The assertion over the report ───────────────────────────────────────

  begin
    perform erp.assert_determination_coverage(v_t);
    v_ok := false; v_msg := 'the assertion returned with two findings outstanding';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DETERMINATION_NOT_COVERED%';
    v_msg := left(sqlerrm, 80);
  end;
  return query select 'the assertion raises rather than returning a count',
    v_ok, v_msg;

  -- ── The gate on the promotion path ──────────────────────────────────────
  --
  -- Two gaps are outstanding at this point, deliberately. That is what makes
  -- these two cases worth anything: the first proves the gate does not punish
  -- a promotion for a gap it did not cause, and the second proves it stops one
  -- that does.

  v_cs := erp.create_change_set('zzc1-t', 'Terminology', 'Touches nothing financial.');
  perform erp.add_change_set_item(v_cs, 'terminology', 'nav.sales|en',
    jsonb_build_object('key', 'nav.sales', 'locale', 'en', 'value', 'Selling'));
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  begin
    perform erp.promote_change_set(v_cs);
    v_ok := true; v_msg := 'promoted, with two gaps outstanding and untouched';
  exception when others then
    v_ok := false; v_msg := 'REFUSED: ' || left(sqlerrm, 70);
  end;
  return query select
    'a promotion that changes nothing financial is not held up by an old gap',
    v_ok, v_msg;

  -- A posting class with no determination rule to cover it is a real way to
  -- break determination by promotion, and an easy one to do by accident.
  v_cs := erp.create_change_set('zzc1-p', 'A class nothing covers',
    'One posting class, no rule for it.');
  perform erp.add_change_set_item(v_cs, 'posting_class', 'item|ZZNEW',
    jsonb_build_object('kind', 'item', 'code', 'ZZNEW', 'name', 'Uncovered class'));
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  begin
    perform erp.promote_change_set(v_cs);
    v_ok := false; v_msg := 'promoted a change set that broke determination';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PROMOTION_BREAKS_DETERMINATION%';
    v_msg := left(sqlerrm, 80);
  end;
  return query select
    'and one that introduces a new way for a posting to fail is refused',
    v_ok, v_msg;

  return query select 'the refused promotion rolled back whole',
    not exists (select 1 from erp.posting_class pc
                 where pc.tenant_id = v_t and pc.code = 'ZZNEW'),
    'a promotion that fails half-applied is worse than one that never ran';

  -- ── Scope ───────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', b1)::text, true);
  v := erp.onboard_tenant('C1 neighbour', 'zzc1b');
  v_tb := (v ->> 'tenant_id')::uuid;
  perform erp.configure_finance();

  return query select 'one organisation''s gaps are not reported against another',
    (select count(*) from erp.determination_coverage_report(v_tb)) = 0,
    'the whole point of a per-organisation scope is that a promotion here is '
    'not held up by a gap over there';

  return query select 'and the unscoped report sees both',
    (select count(*) from erp.determination_coverage_report()) >=
    (select count(*) from erp.determination_coverage_report(v_t)),
    'CI runs it unscoped, over whatever is in the database at the time';

  -- ── Clean up ────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_t);
  delete from erp.tenant where id = v_t;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(v_tb);
  delete from erp.tenant where id = v_tb;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, b1);

  return query select 'and the suite removes both organisations it built',
    (select count(*) from erp.determination_coverage_report()) = 0,
    'which is also why this assertion is vacuous in CI without this suite';
end $$;

create or replace function erp_test.assert_determination_coverage_suite()
returns text
language plpgsql
set search_path to ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Two on the baseline, five on the posting path, three on the determination
  -- surface, one on the assertion itself, three on the promotion gate, two on
  -- scope, and the cleanup.
  c_expected constant integer := 17;
begin
  create temporary table if not exists zz_c1_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_c1_result;
  insert into zz_c1_result select * from erp_test.determination_coverage_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_c1_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_C1_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_C1_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('determination coverage: %s/%s', v_pass, v_total);
end $$;

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.assert_determination_coverage();
select erp.assert_public_api_safe();
select erp.assert_isolation();

-- -----------------------------------------------------------------------------
-- A door, so the finding reaches a person
--
-- An assertion that only fails a build tells the person who broke it. This one
-- also has to tell the person who has to fix it, which is why the report is on
-- the public API beside erp_determination_coverage(). The difference between
-- the two is the whole point of this migration: the older one reports on
-- erp.account_determination, and this one also reports on erp.posting_rule,
-- which is what actually raises journals.
-- -----------------------------------------------------------------------------

create or replace function public.erp_determination_coverage_report()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform erp.authorise('finance.read');

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'mechanism', c.mechanism,
             'finding',   c.finding,
             'reference', c.reference,
             'detail',    c.detail)
           order by c.mechanism, c.finding, c.reference)
      from erp.determination_coverage_report(erp.require_tenant_id()) c),
    '[]'::jsonb);
end;
$$;

revoke all on function public.erp_determination_coverage_report() from public, anon;
grant execute on function public.erp_determination_coverage_report() to authenticated;

comment on function public.erp_determination_coverage_report is
  'C1 for this organisation: every way a posting can fail to determine an '
  'account, on both mechanisms, named so somebody can fix it.';

select erp.assert_public_api_safe();
select erp.assert_governed_views_are_safe();
