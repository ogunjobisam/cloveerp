#!/usr/bin/env bash
#
# An incident is communicated.
#
# Specification v1.6 §16.5 says communication is on a timer, scoped, identical
# on every channel, and that the status page is maintained by the platform.
# The migration proves each rule in a suite; this proves the whole path once,
# through the same processes live uses, against the database the build has
# just proven:
#
#   1. an operator declares an incident with components and names the
#      organisation it reached, and posts the five-field update;
#   2. the platform sweep (erp.run_due_jobs_all_tenants) delivers both to the
#      organisation's administrator — one in-app row and one queued email each,
#      with the body as posted — and, because the organisation is the platform's
#      own, publishes both as status.publish commands to the status page;
#   3. one pass of the worker delivers the commands to the stub's status page
#      and the email to the stub's Resend, and the stub has both bodies;
#   4. an update falls due; the sweep records the prompt and tells the named
#      person in the platform organisation;
#   5. a provider's feed reports a major outage; the job-driven handler declares
#      the incident below the platform, the sweep tells everyone and publishes
#      it; the feed recovers and the next poll resolves it;
#   6. the review is assembled, the incident resolved, and the organisation's
#      history still shows it with the review.
#
# Same environment contract as drain_rehearsal.sh: PSQL, the PG* variables (or
# CLOVEERP_DATABASE_URL), bun, curl, jq. The stub listens on STUB_PORT
# (default 8790, beside the other two).
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
STUB_PORT="${STUB_PORT:-8790}"
STUB="http://localhost:${STUB_PORT}"
DATABASE_URL="${CLOVEERP_DATABASE_URL:-postgres://${PGUSER:-postgres}:${PGPASSWORD:-postgres}@${PGHOST:-localhost}:${PGPORT:-5432}/${PGDATABASE:-clove_erp}}"
STAMP="$(date +%s)"
INC="ci-inc-$STAMP"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG="${RUNNER_TEMP:-/tmp}/clove-incident-stub.log"

fail=0
check() {
  local what="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  ok   %-70s %s\n' "$what" "$got"
  else
    printf '  FAIL %-70s got %s, wanted %s\n' "$what" "$got" "$want"
    fail=1
  fi
}
q() { $PSQL_CMD -q -tAc "$1"; }

# ---------------------------------------------------------------------------
# 1. A status page and five provider feeds, on demand
# ---------------------------------------------------------------------------
bun run "$here/supabase/ci/stub_endpoint.ts" "$STUB_PORT" >"$LOG" 2>&1 &
STUB_PID=$!
trap 'kill "$STUB_PID" 2>/dev/null || true' EXIT
for i in $(seq 1 40); do
  if curl -fsS "$STUB/health" >/dev/null 2>&1; then break; fi
  sleep 0.25
done
curl -fsS "$STUB/health" >/dev/null || { echo "the stub endpoint did not come up" >&2; cat "$LOG" >&2; exit 1; }
echo "stub listening on $STUB"

# ---------------------------------------------------------------------------
# 2. The platform's own organisation, a status page, an operator, an incident
# ---------------------------------------------------------------------------
setup=$($PSQL_CMD -tA <<SQL
begin;
select t.id as tenant_id from erp.tenant t where t.code = 'ci-demo' \gset
select u.id as admin_id, u.auth_user_id as admin_auth
  from erp.app_user u where u.tenant_id = :'tenant_id' and u.email = 'admin@ci-demo.test' \gset

-- The organisation's administrator is also the platform's owner here: one
-- person, two hats, which is how a small platform team actually looks.
delete from erp_meta.platform_staff where lower(email) = 'admin@ci-demo.test';
insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
values ('admin@ci-demo.test', :'admin_auth', 'CI Owner', 'owner');

select set_config('request.jwt.claims', json_build_object('sub', :'admin_auth')::text, true) as ctx \gset
select erp.designate_platform_organisation('ci-demo', 'the build''s platform organisation') as platform_org \gset

select erp.create_service_principal('CI incident worker') as principal_id \gset
insert into erp.user_role (tenant_id, app_user_id, role_id)
select :'tenant_id', :'principal_id', r.id from erp.role r
 where r.tenant_id = :'tenant_id' and r.code = 'administrator';

insert into erp.external_system (tenant_id, code, name, adapter_code, adapter_version, connection, status, max_attempts, retry_backoff_seconds)
values (:'tenant_id', 'ci_status', 'CI status page', 'status_page', 1, jsonb_build_object('base_url', '${STUB}/status/publish'), 'active', 3, 1)
returning id as system_id \gset
insert into erp.external_system_operation (tenant_id, external_system_id, operation_code, is_enabled)
values (:'tenant_id', :'system_id', 'status.publish', true);

-- The poll job, pointed at the stub's feeds. Disabled until the rehearsal
-- arms it, so a tick is claimed by the worker pass that follows and not by
-- the sweep before it.
select erp.upsert_job('poll_dependency_status', 'Poll provider status feeds', 'platform.poll_dependency_status',
                      'interval', 60, null, null, null, 'UTC',
                      jsonb_build_object('feed_base_url', '${STUB}/status/feed'), 60, null, false) as job \gset

select erp.declare_incident('${INC}', 'sev2', 'Allocation failing for one organisation',
                            'CI Commander', 'admin@ci-demo.test', 'CI Scribe', false,
                            'One organisation''s allocation', false,
                            array['allocation', 'order_intake'], array['ci-demo'], 30) as incident_id \gset
select erp.post_incident_update('${INC}', null, false,
                                'Allocation for ci-demo', 'Every other organisation',
                                'The allocation policy resolver is being rolled back',
                                'Allocate by hand from the order screen', 20) as update_id \gset
select u.body as update_body from erp_meta.incident_update u where u.id = :'update_id' \gset
commit;
\echo :tenant_id|:principal_id|:system_id|:incident_id|:update_id
SQL
)
line=$(printf '%s\n' "$setup" | tail -n 1)
IFS='|' read -r TENANT PRINCIPAL SYSTEM INCIDENT UPDATE <<<"$line"
echo "tenant $TENANT, principal $PRINCIPAL, incident $INC"

# ---------------------------------------------------------------------------
# 3. The sweep delivers and publishes
# ---------------------------------------------------------------------------
sweep() { q "select erp.run_due_jobs_all_tenants()" >/dev/null; }
sweep
check "the declaration and the update were delivered to the organisation" \
  "$(q "select count(*) from erp_meta.incident_delivery d where d.incident_id = '$INCIDENT' and d.tenant_id = '$TENANT'")" "2"
check "its administrator has both in-app, delivered" \
  "$(q "select count(*) from erp.notification n where n.tenant_id = '$TENANT' and n.channel_kind = 'in_app' and n.status = 'delivered' and n.subject like '[SEV2] Allocation failing%'")" "2"
check "and both queued as email" \
  "$(q "select count(*) from erp.notification n where n.tenant_id = '$TENANT' and n.channel_kind = 'email' and n.status = 'queued' and n.subject like '[SEV2] Allocation failing%'")" "2"
check "the email body is the update as posted" \
  "$(q "select count(*) from erp.notification n join erp_meta.incident_update u on u.body = n.body where u.id = '$UPDATE' and n.tenant_id = '$TENANT' and n.channel_kind = 'email'")" "1"
check "both were published as queued commands to the status page" \
  "$(q "select count(*) || '|' || string_agg(c.status::text, ',') from erp.command c where c.external_system_id = '$SYSTEM' and c.operation_code = 'status.publish'")" "2|queued,queued"
sweep
check "a second sweep delivers and publishes nothing twice" \
  "$(q "select (select count(*) from erp_meta.incident_delivery where incident_id = '$INCIDENT') || '|' || (select count(*) from erp.command where external_system_id = '$SYSTEM')")" "2|2"

# ---------------------------------------------------------------------------
# 4. The worker carries them out of the building
# ---------------------------------------------------------------------------
run_worker() {
  (
    cd "$here/worker"
    CLOVEERP_DATABASE_URL="$DATABASE_URL" \
    CLOVEERP_TENANTS="$TENANT" \
    CLOVEERP_PRINCIPALS="$PRINCIPAL" \
    CLOVEERP_SYSTEMS="ci_status" \
    CLOVEERP_WORKER_NAME="ci-incident" \
    RESEND_API_KEY="ci-stub-key" \
    CLOVEERP_RESEND_ENDPOINT="$STUB/emails" \
    CLOVEERP_ONCE=1 \
    bun run src/main.ts
  )
}
# Two commands on one ordering key: the second waits for the first to settle,
# so it takes two passes — one a minute, on a scheduled host.
run_worker
run_worker
published=$(curl -fsS "$STUB/status/published")
check "the status page received the declaration and the update, in order" \
  "$(jq -r '[.[].key] | join(",")' <<<"$published")" "status-$INC-declared,status-$INC-$UPDATE"
check "with the update's components, state and severity" \
  "$(jq -r '.[1].body | (.components | join(",")) + "|" + .state + "|" + .severity' <<<"$published")" "allocation,order_intake|live|sev2"
check "and the body as posted, word for word" \
  "$(jq -r '.[1].body.body' <<<"$published")" "$(q "select u.body from erp_meta.incident_update u where u.id = '$UPDATE'")"
check "both commands succeeded" \
  "$(q "select string_agg(c.status::text, ',' order by c.global_seq) from erp.command c where c.external_system_id = '$SYSTEM'")" "succeeded,succeeded"
check "the two emails were sent through the stub" \
  "$(q "select count(*) from erp.notification n where n.tenant_id = '$TENANT' and n.channel_kind = 'email' and n.status = 'sent' and n.subject like '[SEV2] Allocation failing%'")" "2"
check "the evidence door lists two deliveries and two publications" \
  "$(q "select count(*) filter (where kind = 'delivery') || '|' || count(*) filter (where kind = 'publication') from erp.incident_communication_report('$INC')")" "2|2"

# ---------------------------------------------------------------------------
# 5. An update falls due
# ---------------------------------------------------------------------------
q "update erp_meta.incident set next_update_due_at = now() - interval '1 minute' where code = '$INC'" >/dev/null
sweep
check "the sweep recorded the prompt to the communications owner" \
  "$(q "select count(*) || '|' || max(level) || '|' || max(notified) from erp_meta.incident_prompt p where p.incident_id = '$INCIDENT'")" "1|communications_owner|1"
check "with an audit row" \
  "$(q "select count(*) from erp_meta.platform_audit a where a.action = 'platform.incident_update_due' and a.target = '$INC'")" "1"
check "and told the named person in the platform organisation" \
  "$(q "select count(*) from erp.notification n where n.tenant_id = '$TENANT' and n.channel_kind = 'in_app' and n.subject like '%an update is due'")" "1"
check "the discipline report names the missed promise" \
  "$(q "select count(*) from erp.support_discipline_report() f where f.reference = '$INC' and f.finding = 'a live incident is past the update it promised'")" "1"
check "the console reads it as prompted" \
  "$(q "select r.timer_state from erp.incident_report() r where r.code = '$INC'")" "prompted"

# ---------------------------------------------------------------------------
# 6. A provider goes dark, and comes back
# ---------------------------------------------------------------------------
curl -fsS -X POST "$STUB/status/feed" -H 'content-type: application/json' \
  -d '{"code":"supabase","indicator":"major","description":"Partial outage: database connectivity"}' >/dev/null
ADMIN_AUTH=$(q "select u.auth_user_id from erp.app_user u where u.tenant_id = '$TENANT' and u.email = 'admin@ci-demo.test'")
as_admin() { q "begin; select set_config('request.jwt.claims', json_build_object('sub', '$ADMIN_AUTH'::uuid)::text, true); $1; commit;"; }
# Arm the poll job for exactly one tick, run the worker, disarm it. The sweep
# leaves it alone either way (it has no SQL body), but a scheduled job on a
# minute interval would otherwise tick again during a later pass.
poll() {
  # Enabling recomputes the schedule (a tick a minute out); the second update
  # brings that tick to now without touching the schedule.
  q "update erp.job set is_enabled = true where tenant_id = '$TENANT' and code = 'poll_dependency_status';
     update erp.job set next_run_at = now() - interval '1 second' where tenant_id = '$TENANT' and code = 'poll_dependency_status'" >/dev/null
  run_worker
  q "update erp.job set is_enabled = false where tenant_id = '$TENANT' and code = 'poll_dependency_status'" >/dev/null
}
poll
DEP=$(q "select i.code from erp_meta.incident i where i.origin_dependency_code = 'supabase' and i.declared_at > now() - interval '10 minutes' order by i.declared_at desc limit 1")
check "the job-driven handler declared the incident below the platform" \
  "$(q "select i.severity_code || '|' || i.affects_all_tenants || '|' || (select count(*) from erp_meta.incident_component c where c.incident_id = i.id) || '|' || i.declared_by from erp_meta.incident i where i.code = '$DEP'")" "sev3|true|12|dependency feed"
check "five feeds were observed" \
  "$(q "select count(distinct o.dependency_code) from erp_meta.dependency_observation o where o.observed_by = 'worker'")" "5"
sweep
check "declared as reaching everyone, the organisation was told at once" \
  "$(q "select count(*) from erp_meta.incident_delivery d join erp_meta.incident i on i.id = d.incident_id where i.code = '$DEP' and d.tenant_id = '$TENANT'")" "1"
curl -fsS -X POST "$STUB/status/feed" -H 'content-type: application/json' \
  -d '{"code":"supabase","indicator":"none","description":"All Systems Operational"}' >/dev/null
poll
check "recovery on the feed resolved it with a closing update" \
  "$(q "select (i.resolved_at is not null) || '|' || (select count(*) from erp_meta.incident_update u where u.incident_id = i.id and u.body like 'Supabase reports recovery%') from erp_meta.incident i where i.code = '$DEP'")" "true|1"
sweep
run_worker
run_worker
check "and the status page was told the declaration and the recovery" \
  "$(curl -fsS "$STUB/status/published" | jq -r '[.[] | select(.body.incident_code == "'"$DEP"'") | .body.state] | join(",")')" "live,resolved"

# ---------------------------------------------------------------------------
# 7. The review, the resolution, the history
# ---------------------------------------------------------------------------
as_admin "select erp.add_incident_action('$INC', 'Guard the allocation policy resolver', 'CI Developer', current_date + 7);
   select erp.assemble_incident_review('$INC'); select erp.resolve_incident('$INC')" >/dev/null
sweep
check "the closing update reached the organisation" \
  "$(q "select count(*) from erp.notification n where n.tenant_id = '$TENANT' and n.channel_kind = 'in_app' and n.body like 'Resolved: Allocation failing%'")" "1"
history=$(as_admin "select erp.incident_history()" | sed -n 2p)
check "the organisation's history holds both, resolved, with the review shared" \
  "$(jq -r '[.[] | select(.code == "'"$INC"'" or .code == "'"$DEP"'")] | (length | tostring) + "|" + ([.[] | .state] | join(",")) + "|" + ([.[] | (.review != null) | tostring] | join(","))' <<<"$history")" "2|resolved,resolved|false,true"
check "the discipline report is clean" \
  "$(q "select count(*) from erp.support_discipline_report() f where f.reference in ('$INC', '$DEP')")" "0"
if q "begin; select erp.set_job_tenant('$TENANT'); select erp.assert_gateway_integrity(); rollback;" >/dev/null 2>&1; then
  check "the gateway is whole after the passes" "yes" "yes"
else
  check "the gateway is whole after the passes" "no" "yes"
fi

if [[ $fail -ne 0 ]]; then
  echo "incident rehearsal: FAILED" >&2
  echo "--- stub log ---" >&2; cat "$LOG" >&2
  exit 1
fi
echo "an incident declared, updated, prompted, published and resolved: every channel carried the same words"
