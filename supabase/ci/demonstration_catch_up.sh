#!/usr/bin/env bash
#
# The demonstration is brought up to date over a connection that arrives with
# nothing set, because that is what the deploy is.
#
# On 18 September the deploy's step "Bring the demonstration up to today" failed
# and the deploy went green anyway, because the step is deliberately non-fatal.
# The demonstration did not move. What it said:
#
#   CONTEXT:  PL/pgSQL function erp.require_tenant_id() line 7 at RAISE
#     PL/pgSQL function erp.journal_number_for(uuid,date) line 11
#     PL/pgSQL function erp.number_journal_on_commit() line 11
#
# erp.journal's number and both of its balance checks are constraint triggers
# that are INITIALLY DEFERRED: they fire at commit, not when the row is written.
# erp.catch_up_demonstrations() put the session's organisation context back one
# statement before it returned, so by the time the commit asked thousands of
# journals which organisation they belonged to, nothing could answer.
#
# Three checks in this repository already covered the routine and none of them
# could see this:
#
#   * erp_test.demonstration_catch_up_suite() proves what the routine DOES, and
#     it establishes its own session and keeps it for the whole fixture. The
#     routine had never been asked to work on a connection that arrived with
#     nothing set.
#   * The catalogue runs that suite on every build, in a psql session that has
#     already set a context for something else.
#   * The migration that defines the routine runs in the one connection it has,
#     so it cannot open a second one to ask the question.
#
# So this is a build step and not an assertion, and the only thing that makes it
# a real test is the blank line in the middle: THE ROUTINE IS CALLED FROM ITS
# OWN psql INVOCATION, with nothing set on it, exactly as .github/workflows/
# deploy.yml calls it. Run it in one connection with a context already in place
# and it passes whether or not the defect is there.
#
# It is small on purpose. The question is about the session, not about volume:
# one journal reaching commit without an organisation fails the same way a
# hundred thousand do. Five days of trading, then whatever days separate them
# from today.
#
# Reads PSQL from the environment like run_checks.sh and close_month.sh.
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"

# The organisation's name has to begin 'demo-' or the routine refuses it, which
# is the guard working and not something to route around.
ORG='demo-cibare'

started=$(date +%s%N)

# ── 1. A demonstration, built the way the product builds one ─────────────────
#
# One connection, its own context, exactly as supabase/ci/seed_demo.sql does it.
# Nothing here is the test; this is the fixture.
$PSQL_CMD <<SQL
\set ON_ERROR_STOP on
begin;

select * from erp.provision_tenant(
  '${ORG}', 'Bare-connection demonstration',
  'admin@${ORG}.test', 'Bare Admin') \gset

select set_config('request.jwt.claims',
                  json_build_object('sub', '00000000-0000-4000-8000-0000000cba1e')::text, true);
select erp.claim_invitation(:'admin_token');

-- provision_tenant leaves the organisation live; the demo builder refuses a
-- live environment, as it should.
update erp.environment set is_live = false
 where tenant_id = :'tenant_id' and is_self;

select left(erp.ensure_demo_configuration(:'tenant_id', :'admin_user_id')::text, 120) as configured;

-- Five days, three weeks back, so there is a gap for the routine to close and
-- an invoice or two still owing when it starts.
select erp.seed_demo_history((current_date - 20)::date, null, 1) ->> 'built' as fixture_built;

commit;
SQL

# ── 2. THE TEST ──────────────────────────────────────────────────────────────
#
# A new connection. No claims, no job tenant, no transaction already open — the
# shape deploy.yml has and the shape nothing else in this build produces. If the
# routine gives its context back before the deferred queue has drained, this
# statement's COMMIT raises CLOVEERP_NO_TENANT_CONTEXT from inside
# erp.number_journal_on_commit() and psql exits non-zero, which fails the build.
echo "── calling erp.catch_up_demonstrations('${ORG}') from a connection with nothing set"
$PSQL_CMD -c "select jsonb_pretty(erp.catch_up_demonstrations('${ORG}'));"

# ── 3. And it did the work, rather than merely not refusing ──────────────────
#
# A statement that commits is not the same claim as a statement that did
# something. Another connection, and this one only reads.
$PSQL_CMD <<SQL
\set ON_ERROR_STOP on
do \$proved\$
declare
  v_tenant   uuid;
  v_last     date;
  v_open     integer;
  v_closed   integer;
  v_waived   integer;
  v_numbered integer;
begin
  select t.id into v_tenant from erp.tenant t where t.code = '${ORG}';
  if v_tenant is null then
    raise exception 'CLOVEERP_CI_NO_DEMONSTRATION: ${ORG} was not built, so nothing was tested';
  end if;

  -- Said outright, so that erp.local_today() below answers in the
  -- organisation's own month rather than the server's. This connection is
  -- trusted (the build role bypasses row security), which is the only place
  -- erp.job_tenant_id is read, and it is the same second answer the routine
  -- itself now sets.
  perform set_config('erp.job_tenant_id', v_tenant::text, true);

  -- It traded up to today. The builder makes no document on a day it has
  -- nothing to make one for, so yesterday is allowed and the day before is not.
  select max(to_date(substring(d.their_reference from 6 for 8), 'YYYYMMDD'))
    into v_last
    from erp.document d
   where d.tenant_id = v_tenant and d.their_reference ~ '^DEMO-[0-9]{8}-';

  if v_last is null or v_last < current_date - 1 then
    raise exception
      'CLOVEERP_CI_NOT_CAUGHT_UP: ${ORG} last traded on %, and today is %',
      coalesce(v_last::text, 'no day at all'), current_date
      using hint = 'The routine returned without refusing and without trading. Read what it answered above.';
  end if;

  -- Every journal it wrote was numbered. This is the thing that failed on the
  -- deploy, and an unnumbered journal is what a drained queue would have left.
  select count(*) into v_numbered
    from erp.journal j
   where j.tenant_id = v_tenant and j.journal_number is null;

  if v_numbered > 0 then
    raise exception
      'CLOVEERP_CI_JOURNALS_UNNUMBERED: % journal(s) of ${ORG} carry no number', v_numbered
      using hint = 'The deferred queue was drained somewhere that could not name the organisation.';
  end if;

  -- And the months before this one are closed, with nothing waived.
  select count(*) filter (where fp.status = 'open'::erp.period_status
                            and fp.ends_on < date_trunc('month', erp.local_today())::date),
         count(*) filter (where fp.status = 'closed'::erp.period_status)
    into v_open, v_closed
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant;

  select count(*) into v_waived
    from erp.close_task ct
   where ct.tenant_id = v_tenant and ct.status <> 'complete';

  if v_open > 0 or v_closed = 0 or v_waived > 0 then
    raise exception
      'CLOVEERP_CI_NOT_CLOSED: ${ORG} has % historic month(s) still open, % closed, % task(s) not complete',
      v_open, v_closed, v_waived
      using hint = 'The close is part of what the deploy step does, so it is part of what this proves.';
  end if;

  raise warning
    '${ORG} traded to % over a bare connection: % month(s) closed, none waived, every journal numbered',
    v_last, v_closed;
end
\$proved\$;

-- And the books, over every organisation this build now holds.
select erp.assert_whole_database_reconciles();
SQL

wall_ms=$(( ($(date +%s%N) - started) / 1000000 ))
echo "the demonstration caught up over a bare connection in ${wall_ms} ms"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## The demonstration catches up over a bare connection"
    echo "erp.catch_up_demonstrations() was called from its own psql invocation," \
         "with no organisation context set on it — the shape deploy.yml has —" \
         "and ${ORG} traded to today, closed its months and numbered every" \
         "journal, in ${wall_ms} ms."
  } >> "$GITHUB_STEP_SUMMARY"
fi
