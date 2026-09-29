set lock_timeout = '30s';

-- ═════════════════════════════════════════════════════════════════════════════
-- Accepting an interview fits its request
-- ═════════════════════════════════════════════════════════════════════════════
--
-- On 29 September at 15:07 UTC an administrator pressed "Put these changes in
-- force" on a proposed onboarding interview and got "That took too long". The
-- call ran 8.3 s, which is the authenticated role's statement_timeout, and was
-- cancelled here:
--
--   erp.support_window_closed ← erp.principal_context ← erp.current_tenant_id
--   ← erp.determination_coverage_report
--   ← erp.promote_change_set line 104 ← erp_ai.accept_interview line 289
--
-- A cancelled statement takes its transaction with it, so nothing was put in
-- force and the interview is still proposed. Accepting again will do the whole
-- thing again.
--
-- Two causes, and both are fixed here.
--
-- ── ONE REQUEST DOES A WHOLE ONBOARDING ─────────────────────────────────────
--
-- Before go-live, erp_ai.accept_interview() submits, approves and promotes up
-- to seven sections and sets finance up, all in one call. Every promotion runs
-- erp.determination_coverage_report() twice, before and after, so that a
-- promotion cannot make determination worse. That is at least fourteen full
-- reports inside one request, and the request had the eight seconds a single
-- screen read is given.
--
-- The door gets the fifty-five seconds erp_platform_assurance (20260902121206)
-- and both purge doors (20260914085500) have. PostgREST applies a function's
-- own statement_timeout to the call, and sixty seconds is the most a request
-- through the API is given.
--
-- ── THE REPORT MULTIPLIED ITS OWN ROWS ──────────────────────────────────────
--
-- Clause 6 builds every combination of transaction type, item posting class
-- and company, then asks whether a rule covers it. It built that set by
-- joining erp.account_determination to itself on tenant alone:
--
--   distinct transaction types × EVERY determination row × classes × companies
--
-- and then threw the multiplication away with a GROUP BY. Each of those rows
-- also passed row security, and row security calls erp.current_tenant_id(),
-- which is never inlined, so erp.principal_context() ran once for every row.
-- That is why the cancellation landed inside principal_context(). The join
-- contributed nothing: the transaction types are read from that same table,
-- so any tenant that has one already has a row to join to. The clause now
-- takes the distinct types and crosses them with classes and companies
-- directly. It returns the same set, and the tenant filter moves inside, so
-- a report for one organisation no longer reads every organisation's rules
-- first.
--
-- The other five clauses are unchanged.
-- ═════════════════════════════════════════════════════════════════════════════

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
  --
  --    The distinct types are crossed with classes and companies directly.
  --    Each combination is one row already (a type once per tenant, a class
  --    and a company by id), so nothing needs grouping away.
  select t.code, 'determination',
         'a posting class and company combination has no determination rule',
         format('%s × %s × %s', tt.transaction_type, ic.code, en.code),
         '§5 refuses a default-to-suspense, so this combination is a refusal '
         'at posting time rather than a suspense entry'
    from (select distinct a2.tenant_id, a2.transaction_type
            from erp.account_determination a2
           where a2.status = 'active'
             and (p_tenant_id is null or a2.tenant_id = p_tenant_id)) tt
    join erp.posting_class ic
      on ic.tenant_id = tt.tenant_id and ic.kind = 'item' and ic.status = 'active'
    join erp.entity en
      on en.tenant_id = tt.tenant_id and en.status = 'active'
    join erp.tenant t on t.id = tt.tenant_id
   where not exists (
       select 1 from erp.account_determination ad
        where ad.tenant_id = tt.tenant_id
          and ad.status = 'active'
          and ad.transaction_type = tt.transaction_type
          and daterange(ad.valid_from, ad.valid_to, '[)') @> current_date
          and (ad.item_class_id is null or ad.item_class_id = ic.id)
          and (ad.entity_id is null or ad.entity_id = en.id))
$$;

alter function public.erp_accept_interview(uuid) set statement_timeout = '55s';

-- Proved here rather than trusted: the door carries the setting, and the
-- clause no longer joins the determination table to itself.
do $$
begin
  if not (select 'statement_timeout=55s' = any (coalesce(p.proconfig, '{}'))
            from pg_catalog.pg_proc p
           where p.oid = 'public.erp_accept_interview(uuid)'::regprocedure) then
    raise exception 'CLOVEERP_ACCEPT_INTERVIEW_TIMEOUT_MISSING: public.erp_accept_interview has no statement_timeout of 55s';
  end if;

  if (select p.prosrc ~ 'join\s+erp\.account_determination\s+ad\s+on\s+ad\.tenant_id\s*=\s*tt\.tenant_id'
        from pg_catalog.pg_proc p
       where p.oid = 'erp.determination_coverage_report(uuid)'::regprocedure) then
    raise exception 'CLOVEERP_DETERMINATION_REPORT_SELF_JOIN: clause 6 still joins erp.account_determination to itself on tenant alone';
  end if;
end
$$;

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
