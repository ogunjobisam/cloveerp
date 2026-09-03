-- ─────────────────────────────────────────────────────────────────────────────
-- The suite that pinned the old sentence.
--
-- 20260904720000 widened erp.assert_authorising_doors_are_volatile() from one
-- writer to two, and widened its summary with it: "reach erp.authorise() within
-- one call" became "reach a writer within one call", because naming one writer
-- while enforcing two is a check that reports something narrower than it does.
--
-- erp_test.authorising_doors_suite(), written in 20260904680000, pins that
-- summary by regex. So the assertion passed, the migration passed, the
-- from-empty build passed, and CI failed on the suite:
--
--   ERPWARE_AUTHORISING_DOORS_SUITE_FAILED: 6/7
--     the assertion counts the doors rather than asserting silence
--
-- The case is right to exist. Its point is that the assertion returns a census
-- rather than an empty string — an assertion whose success is silence tells you
-- nothing about whether it looked at anything. What it should not do is pin the
-- exact sentence, because then widening the rule and describing the widening
-- are the same edit and the second one breaks a test that has no opinion about
-- either. The case now checks the shape it actually cares about: two numbers
-- and the claim that every door found is volatile.
--
-- The process fault behind it is mine and is worth naming. I verified the
-- migration and a build from empty, and neither runs the suites. CI runs
-- thirty-one of them after the assertions, so "the build is green" was never
-- the same claim as "the checks pass". supabase/ci/run_checks.sh, added in this
-- commit, runs every zero-argument assertion and every suite in the database
-- against a local build — which is a wider net than the workflow's own list,
-- and would have caught this before it was pushed.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.authorising_doors_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
as $$
declare v_msg text;
begin
  return query select 'no public door that reaches a writer is stable or immutable',
    (select count(*) from erp.authorising_door_report()) = 0,
    format('%s finding(s)', (select count(*) from erp.authorising_door_report()));

  v_msg := erp.assert_authorising_doors_are_volatile();
  return query select 'the assertion counts the doors rather than asserting silence',
    -- The shape, not the sentence. An assertion whose success is silence never
    -- tells you whether it looked at anything, which is what this case is for;
    -- pinning the wording only made widening the rule and describing the
    -- widening into one edit that breaks a test with no opinion on either.
    v_msg ~ '^doors: \d+ public entry points, \d+ reach .+ and every one of those is volatile',
    v_msg;

  return query select 'the doors that reach erp.authorise directly are volatile',
    not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.provolatile <> 'v'
         -- prosrc_code, not prosrc. Writing this case against the raw body
         -- failed it on erp_document_approval_chain, whose comment says it does
         -- not authorise. That is the third time the same trap has been walked
         -- into on this branch, which is the argument for the helper existing.
         and erp.prosrc_code(p.prosrc) ~ 'erp\.authorise\s*\('),
    'a direct caller declared stable would fail for every caller through PostgREST';

  return query select 'the doors that reach a writer through one function are volatile',
    not exists (
      select 1 from pg_proc d join pg_namespace dn on dn.oid = d.pronamespace
       where dn.nspname = 'public' and d.provolatile <> 'v'
         and exists (
           select 1 from pg_proc c join pg_namespace cn on cn.oid = c.pronamespace
            where cn.nspname = 'erp'
              and c.prosrc ~ 'erp\.authorise\s*\('
              and erp.prosrc_code(d.prosrc) ~ ('erp\.' || c.proname || '\s*\('))),
    'one level deeper is the level 20260904680000 was written to reach';

  return query select 'erp.authorise really does write, which is why any of this matters',
    (select p.prosrc like '%log_access_decision%' or p.prosrc like '%access_log%'
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp' and p.proname = 'authorise'),
    'the access-log row is the write PostgREST refuses in a read-only transaction';

  return query select 'the rule now names both writers, not just the first one found',
    (select p.prosrc like '%require_platform%'
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp' and p.proname = 'authorising_door_report'),
    'erp_meta.require_platform writes when it binds a staff identity for the first time';

  return query select 'and it reads code rather than comments',
    (select p.prosrc like '%prosrc_code%'
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp' and p.proname = 'authorising_door_report'),
    'a function named in a comment is not a function called';
end;
$$;

select erp.assert_authorising_doors_are_volatile();
select erp_test.assert_authorising_doors_suite();
