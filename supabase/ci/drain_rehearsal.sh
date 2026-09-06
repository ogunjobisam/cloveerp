#!/usr/bin/env bash
#
# A queue drains in anger.
#
# Every suite proved that a command could be claimed and settled and that an
# email could be queued; none proved that anything received either. The worker
# had never been run against a built database in any build, and it showed: it
# refused to start against an organisation whose jobs have SQL handlers, read a
# connection key the adapter schema forbids, and the email queue could not be
# queued at all because a stale constraint refused the status. Three defects,
# each invisible to a suite that reads source and rows, each visible the first
# time a request is made.
#
# So this makes the requests. Against the database the build has just proven:
#
#   1. start supabase/ci/stub_endpoint.ts — an external system and a Resend
#      that record what arrives and answer the way the real ones do;
#   2. as the demonstration organisation's administrator, create a service
#      principal for the worker, register the stub as an external system with
#      one enabled operation, submit a command carrying an idempotency key, and
#      raise an email notification that dispatch leaves at `queued`;
#   3. run the worker for exactly one pass (CLOVEERP_ONCE=1) with the stub as
#      its Resend and a throwaway key;
#   4. read back: the command `succeeded`, the stub received one POST carrying
#      the key, the email is `sent` with the provider id the stub returned, and
#      the pass is recorded in erp_meta.drain_pass, which is what
#      erp.dispatch_evidence() shows an operator.
#
# Reads PSQL from the environment like run_checks.sh, and the PG* variables for
# the worker's connection string unless CLOVEERP_DATABASE_URL is set. Needs bun
# (the worker's runtime), curl and jq.
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
STUB_PORT="${STUB_PORT:-8788}"
STUB="http://localhost:${STUB_PORT}"
DATABASE_URL="${CLOVEERP_DATABASE_URL:-postgres://${PGUSER:-postgres}:${PGPASSWORD:-postgres}@${PGHOST:-localhost}:${PGPORT:-5432}/${PGDATABASE:-clove_erp}}"
KEY="ci-drain-$(date +%s)"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---------------------------------------------------------------------------
# 1. The other end of the wire
# ---------------------------------------------------------------------------
bun run "$here/supabase/ci/stub_endpoint.ts" "$STUB_PORT" >"${RUNNER_TEMP:-/tmp}/clove-stub.log" 2>&1 &
STUB_PID=$!
trap 'kill "$STUB_PID" 2>/dev/null || true' EXIT

for i in $(seq 1 40); do
  if curl -fsS "$STUB/health" >/dev/null 2>&1; then break; fi
  sleep 0.25
done
curl -fsS "$STUB/health" >/dev/null || { echo "the stub endpoint did not come up" >&2; cat "${RUNNER_TEMP:-/tmp}/clove-stub.log" >&2; exit 1; }
echo "stub listening on $STUB"

# ---------------------------------------------------------------------------
# 2. Something to drain
# ---------------------------------------------------------------------------
# One transaction, as the demonstration organisation's administrator (the
# impersonation is transaction-local, like every context). The last line is the
# identifiers the worker and the assertions need.
setup=$($PSQL_CMD -tA <<SQL
begin;
select t.id as tenant_id from erp.tenant t where t.code = 'ci-demo' \gset
select u.id as admin_id, u.auth_user_id as admin_auth
  from erp.app_user u where u.tenant_id = :'tenant_id' and u.email = 'admin@ci-demo.test' \gset
select set_config('request.jwt.claims', json_build_object('sub', :'admin_auth')::text, true) as ctx \gset

-- The worker's own identity: a service principal, asserted by a trusted session,
-- holding the administrator role so it may settle what it claims.
select erp.create_service_principal('CI drain worker') as principal_id \gset
insert into erp.user_role (tenant_id, app_user_id, role_id)
select :'tenant_id', :'principal_id', r.id from erp.role r
 where r.tenant_id = :'tenant_id' and r.code = 'administrator';

-- The stub, as an external system with one enabled operation. base_url is the
-- key the adapter schema names; nothing else is allowed in a connection.
insert into erp.external_system (tenant_id, code, name, adapter_code, adapter_version, connection, status)
values (:'tenant_id', 'ci_counterpart', 'CI counterpart', 'example_http', 1,
        jsonb_build_object('base_url', '${STUB}/orders'), 'active')
returning id as system_id \gset
insert into erp.external_system_operation (tenant_id, external_system_id, operation_code, is_enabled)
values (:'tenant_id', :'system_id', 'order.create', true);

select erp.submit_command('ci_counterpart', 'order.create',
         jsonb_build_object('order_ref', 'CI-1', 'lines', jsonb_build_array(jsonb_build_object('item', 'CI-ITEM', 'quantity', 1))),
         false, '${KEY}') as command_id \gset

-- An email for the administrator. Dispatch leaves it at queued; the worker is
-- what makes it sent.
insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
values (:'tenant_id', 'info', :'admin_id', 'email', 'CI drain rehearsal', 'A queue drained in anger.', 'pending')
returning id as notification_id \gset
select d.sent as dispatched from erp.dispatch_notifications() d \gset
select n.status as queued_status from erp.notification n where n.id = :'notification_id' \gset
commit;
\echo :tenant_id|:principal_id|:command_id|:notification_id|:queued_status
SQL
)
line=$(printf '%s\n' "$setup" | tail -n 1)
IFS='|' read -r TENANT PRINCIPAL COMMAND NOTIFICATION QUEUED <<<"$line"
echo "tenant $TENANT, principal $PRINCIPAL, command $COMMAND, notification $NOTIFICATION ($QUEUED)"
[[ "$QUEUED" == "queued" ]] || { echo "dispatch left the email at '$QUEUED', not queued" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 3. One pass of the worker
# ---------------------------------------------------------------------------
(
  cd "$here/worker"
  CLOVEERP_DATABASE_URL="$DATABASE_URL" \
  CLOVEERP_TENANTS="$TENANT" \
  CLOVEERP_PRINCIPALS="$PRINCIPAL" \
  CLOVEERP_SYSTEMS="ci_counterpart" \
  CLOVEERP_WORKER_NAME="ci-drain" \
  RESEND_API_KEY="ci-stub-key" \
  CLOVEERP_RESEND_ENDPOINT="$STUB/emails" \
  CLOVEERP_ONCE=1 \
  bun run src/main.ts
)

# ---------------------------------------------------------------------------
# 4. What happened
# ---------------------------------------------------------------------------
fail=0
check() {
  local what="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  ok   %-48s %s\n' "$what" "$got"
  else
    printf '  FAIL %-48s got %s, wanted %s\n' "$what" "$got" "$want"
    fail=1
  fi
}

received=$(curl -fsS "$STUB/received")
check "the stub received one order"        "$(jq -r '.orders' <<<"$received")" "1"
check "carrying the command's key"         "$(jq -r '.orderKeys[0] // "none"' <<<"$received")" "$KEY"
check "and one email"                      "$(jq -r '.emails' <<<"$received")" "1"

check "the command succeeded" \
  "$($PSQL_CMD -q -tAc "select status from erp.command where id = '$COMMAND'")" "succeeded"
check "the email is sent with the provider's id" \
  "$($PSQL_CMD -q -tAc "select status || ':' || coalesce(provider_message_id, 'none') from erp.notification where id = '$NOTIFICATION'")" "sent:stub_1"
check "the pass is recorded" \
  "$($PSQL_CMD -q -tAc "select count(*) from erp_meta.drain_pass where worker = 'ci-drain'")" "1"
check "the evidence door shows it to the administrator" \
  "$($PSQL_CMD -q -tAc "begin; select set_config('request.jwt.claims', json_build_object('sub', u.auth_user_id)::text, true) from erp.app_user u where u.tenant_id = '$TENANT' and u.email = 'admin@ci-demo.test'; select (select count(*) from jsonb_array_elements(public.erp_dispatch_evidence()) e where e ->> 'queue' = 'commands' and e ->> 'worker' = 'ci-drain'); rollback;" | sed -n 2p)" "1"
# The gateway assertion returns nothing when it is satisfied and raises when it
# is not, so the check is that the call comes back at all.
if $PSQL_CMD -q -tAc "begin; select erp.set_job_tenant('$TENANT'); select erp.assert_gateway_integrity(); rollback;" >/dev/null 2>&1; then
  check "the gateway is whole after the pass" "yes" "yes"
else
  check "the gateway is whole after the pass" "refused" "yes"
fi

[[ $fail -eq 0 ]] || { echo; echo "worker log follows"; cat "${RUNNER_TEMP:-/tmp}/clove-stub.log"; exit 1; }
echo "a command and an email left the building, once each, and the database knows it"
