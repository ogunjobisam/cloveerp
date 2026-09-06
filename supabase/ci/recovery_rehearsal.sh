#!/usr/bin/env bash
#
# Recovery is rehearsed.
#
# drain_rehearsal.sh proves a command and an email leave the building when
# everything works. This proves what happens when it does not, three ways,
# against the database the build has just proven:
#
#   (i)   a worker is killed before its request leaves — the command goes back
#         to the queue with a backoff, is claimed once more, and the counterpart
#         receives exactly one request under one key;
#   (ii)  the counterpart stops answering mid-command — the worker's timeout
#         fires after the request has left, the command becomes `ambiguous`,
#         its ordering key stays blocked, a person reconciles it through the
#         door with evidence from the counterpart, and the successor on the key
#         is then delivered;
#   (iii) the counterpart answers 503 once — the command fails with a backoff
#         and is delivered on the next pass; two requests, one key.
#
# D19 in three sentences the log can check. Same environment contract as
# drain_rehearsal.sh: PSQL, the PG* variables (or CLOVEERP_DATABASE_URL), bun,
# curl, jq. The stub listens on STUB_PORT (default 8789, beside the drain's).
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
STUB_PORT="${STUB_PORT:-8789}"
STUB="http://localhost:${STUB_PORT}"
DATABASE_URL="${CLOVEERP_DATABASE_URL:-postgres://${PGUSER:-postgres}:${PGPASSWORD:-postgres}@${PGHOST:-localhost}:${PGPORT:-5432}/${PGDATABASE:-clove_erp}}"
STAMP="$(date +%s)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG="${RUNNER_TEMP:-/tmp}/clove-recovery-stub.log"

fail=0
check() {
  local what="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  ok   %-64s %s\n' "$what" "$got"
  else
    printf '  FAIL %-64s got %s, wanted %s\n' "$what" "$got" "$want"
    fail=1
  fi
}
q() { $PSQL_CMD -q -tAc "$1"; }

# ---------------------------------------------------------------------------
# 1. A counterpart that misbehaves on demand
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
# 2. Three systems, four commands
# ---------------------------------------------------------------------------
setup=$($PSQL_CMD -tA <<SQL
begin;
select t.id as tenant_id from erp.tenant t where t.code = 'ci-demo' \gset
select u.id as admin_id, u.auth_user_id as admin_auth
  from erp.app_user u where u.tenant_id = :'tenant_id' and u.email = 'admin@ci-demo.test' \gset
select set_config('request.jwt.claims', json_build_object('sub', :'admin_auth')::text, true) as ctx \gset

select erp.create_service_principal('CI recovery worker') as principal_id \gset
insert into erp.user_role (tenant_id, app_user_id, role_id)
select :'tenant_id', :'principal_id', r.id from erp.role r
 where r.tenant_id = :'tenant_id' and r.code = 'administrator';

insert into erp.external_system (tenant_id, code, name, adapter_code, adapter_version, connection, status, max_attempts, retry_backoff_seconds)
values (:'tenant_id', 'ci_plain', 'CI plain', 'example_http', 1, jsonb_build_object('base_url', '${STUB}/orders'), 'active', 3, 1),
       (:'tenant_id', 'ci_hang',  'CI hang',  'example_http', 1, jsonb_build_object('base_url', '${STUB}/orders/hang'), 'active', 3, 1),
       (:'tenant_id', 'ci_flaky', 'CI flaky', 'example_http', 1, jsonb_build_object('base_url', '${STUB}/orders/flaky'), 'active', 3, 1);
insert into erp.external_system_operation (tenant_id, external_system_id, operation_code, is_enabled)
select :'tenant_id', s.id, 'order.create', true from erp.external_system s
 where s.tenant_id = :'tenant_id' and s.code in ('ci_plain', 'ci_hang', 'ci_flaky');

select erp.submit_command('ci_plain', 'order.create',
         jsonb_build_object('order_ref', 'PLAIN-1', 'lines', jsonb_build_array(jsonb_build_object('item', 'CI', 'quantity', 1))),
         false, 'ci-rec-plain-${STAMP}') as plain_id \gset
select erp.submit_command('ci_hang', 'order.create',
         jsonb_build_object('order_ref', 'HANG-1', 'lines', jsonb_build_array(jsonb_build_object('item', 'CI', 'quantity', 1))),
         false, 'ci-rec-hang-a-${STAMP}') as hang_id \gset
select erp.submit_command('ci_hang', 'order.create',
         jsonb_build_object('order_ref', 'HANG-1', 'lines', jsonb_build_array(jsonb_build_object('item', 'CI', 'quantity', 2))),
         false, 'ci-rec-hang-b-${STAMP}') as hang2_id \gset
select erp.submit_command('ci_flaky', 'order.create',
         jsonb_build_object('order_ref', 'FLAKY-1', 'lines', jsonb_build_array(jsonb_build_object('item', 'CI', 'quantity', 1))),
         false, 'ci-rec-flaky-${STAMP}') as flaky_id \gset
commit;
\echo :tenant_id|:principal_id|:plain_id|:hang_id|:hang2_id|:flaky_id
SQL
)
line=$(printf '%s\n' "$setup" | tail -n 1)
IFS='|' read -r TENANT PRINCIPAL PLAIN HANG HANG2 FLAKY <<<"$line"
echo "tenant $TENANT, principal $PRINCIPAL"

# ---------------------------------------------------------------------------
# 3. (i) A worker killed before its request left
# ---------------------------------------------------------------------------
# Claimed by a worker that then dies: a one-second lease nobody renews.
q "begin; select erp.set_job_tenant('$TENANT'); select erp.set_job_principal('$PRINCIPAL');
   select count(*) from erp.claim_command_batch('ci_plain', 1, 'worker-gone', interval '1 second'); commit;" >/dev/null
sleep 1.5
gone=$(q "begin; select erp.set_job_tenant('$TENANT');
          select (erp.reclaim_stranded_work() ->> 'commands');
          select status || '|' || attempts || '|' || (next_attempt_at > now()) || '|' || left(coalesce(last_error, ''), 13)
            from erp.command where id = '$PLAIN';
          update erp.command set next_attempt_at = now() where id = '$PLAIN';
          commit;" | sed -n 3p)
check "(i) a dead worker's command is reclaimed to the queue with a backoff" "$gone" "queued|1|true|lease expired"

# ---------------------------------------------------------------------------
# 4. Pass one: plain delivers, hang times out, flaky is refused once
# ---------------------------------------------------------------------------
run_worker() {
  (
    cd "$here/worker"
    CLOVEERP_DATABASE_URL="$DATABASE_URL" \
    CLOVEERP_TENANTS="$TENANT" \
    CLOVEERP_PRINCIPALS="$PRINCIPAL" \
    CLOVEERP_SYSTEMS="ci_plain,ci_hang,ci_flaky" \
    CLOVEERP_WORKER_NAME="ci-recovery" \
    CLOVEERP_LEASE_SECONDS=5 \
    CLOVEERP_HTTP_TIMEOUT_MS=1000 \
    CLOVEERP_ONCE=1 \
    bun run src/main.ts
  )
}
run_worker

st() { q "select status || '|' || attempts || '|' || (sent_at is not null) || '|' || coalesce(claimed_by, '-') from erp.command where id = '$1'"; }
check "(i) the reclaimed command was delivered on the next pass"      "$(st "$PLAIN")" "succeeded|2|true|-"
check "(ii) a request that got no answer leaves the command ambiguous" "$(st "$HANG")"  "ambiguous|1|true|ci-recovery"
check "(ii) its successor on the ordering key waits"                   "$(st "$HANG2")" "queued|0|false|-"
check "(iii) a 503 fails the command with a backoff"                   "$(q "select status || '|' || attempts || '|' || (next_attempt_at > now()) || '|' || left(coalesce(last_error, ''), 22) from erp.command where id = '$FLAKY'")" "queued|1|true|ci_flaky responded 503"

received=$(curl -fsS "$STUB/received")
check "the plain counterpart received one request"   "$(jq -r '.routes["/orders"].requests // 0' <<<"$received")" "1"
check "under the reclaimed command's own key"         "$(jq -r '.routes["/orders"].keys[0] // "none"' <<<"$received")" "ci-rec-plain-$STAMP"
check "the hanging counterpart received one request"  "$(jq -r '.routes["/orders/hang"].requests // 0' <<<"$received")" "1"
check "the flaky counterpart received one request"    "$(jq -r '.routes["/orders/flaky"].requests // 0' <<<"$received")" "1"

check "(ii) the transition log names the worker that lost the answer" \
  "$(q "select count(*) from erp.command_event e where e.command_id = '$HANG' and e.to_status = 'ambiguous' and e.actor_label = 'ci-recovery'")" "1"
check "(ii) the backlog tells an operator what to do" \
  "$(q "begin; select erp.set_job_tenant('$TENANT');
        select count(*) from erp.integration_backlog(50) b where b.reference = '$HANG' and b.suggested_action like 'erp.reconcile_ambiguous_command()%'; rollback;" | sed -n 2p)" "1"

# ---------------------------------------------------------------------------
# 5. A person reconciles the ambiguous command, with evidence
# ---------------------------------------------------------------------------
reconciled=$(q "begin; select set_config('request.jwt.claims', json_build_object('sub', u.auth_user_id)::text, true) from erp.app_user u where u.tenant_id = '$TENANT' and u.email = 'admin@ci-demo.test';
                select public.erp_reconcile_ambiguous_command('$HANG', 'succeeded', 'the stub logged the request under key ci-rec-hang-a-$STAMP') ->> 'status'; commit;" | sed -n 2p)
check "(ii) reconciled as succeeded through the door" "$reconciled" "succeeded"
check "(ii) the successor is still queued until a pass runs" "$(st "$HANG2")" "queued|0|false|-"
q "update erp.command set next_attempt_at = now() where id = '$FLAKY'" >/dev/null

# ---------------------------------------------------------------------------
# 6. Pass two: the successor and the flaky command are delivered
# ---------------------------------------------------------------------------
run_worker

check "(ii) the successor was delivered once the key was free" "$(st "$HANG2")" "succeeded|1|true|-"
check "(ii) the reconciled command keeps its note" \
  "$(q "select (reconciled_at is not null) || '|' || left(reconciliation_note, 12) from erp.command where id = '$HANG'")" "true|the stub log"
check "(iii) the flaky command was delivered on the next pass" "$(st "$FLAKY")" "succeeded|2|true|-"

received=$(curl -fsS "$STUB/received")
check "the hanging counterpart received two requests, in order, under two keys" \
  "$(jq -r '.routes["/orders/hang"] | "\(.requests)|\(.keys | join(","))|\(.duplicateKeys)"' <<<"$received")" \
  "2|ci-rec-hang-a-$STAMP,ci-rec-hang-b-$STAMP|0"
check "the flaky counterpart received two requests under one key" \
  "$(jq -r '.routes["/orders/flaky"] | "\(.requests)|\(.keys | length)|\(.duplicateKeys)"' <<<"$received")" "2|1|1"
check "the plain counterpart still has one" "$(jq -r '.routes["/orders"].requests' <<<"$received")" "1"

check "two passes recorded, the first with one ambiguous command" \
  "$(q "select count(*) || '|' || coalesce(max((report ->> 'commandsAmbiguous')::int), 0) from erp_meta.drain_pass where worker = 'ci-recovery'")" "2|1"
check "the stranded-work report is empty afterwards" \
  "$(q "begin; select erp.set_job_tenant('$TENANT'); select count(*) from erp.stranded_work_report(); rollback;" | sed -n 2p)" "0"
if q "begin; select erp.set_job_tenant('$TENANT'); select erp.assert_gateway_integrity(); rollback;" >/dev/null 2>&1; then
  check "the gateway is whole after three failures" "yes" "yes"
else
  check "the gateway is whole after three failures" "refused" "yes"
fi

[[ $fail -eq 0 ]] || { echo; echo "stub log follows"; cat "$LOG"; exit 1; }
echo "a dead worker, a silent counterpart and a flaky one: every command settled, nothing sent twice"
