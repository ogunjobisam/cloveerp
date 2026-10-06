#!/usr/bin/env bash
#
# supabase/ci/build_from_empty.sh, rehearsed with no database.
#
# The build it does runs once, for an hour, against the demonstration project
# (.github/workflows/demo_from_empty.yml), and a mistake in it is learned
# there or not at all — the lesson of the demonstration step's reporting,
# which broke three times in one day because only production ever ran it
# (supabase/ci/demonstration_report.sh). So every build runs it here first,
# against a psql that answers from a script and writes down what it was asked:
# what it refuses, the order it applies in, that each migration is one
# transaction with the timeout off, the owner and the record inside it, that
# a deadlock goes again and anything else stops it, and that it will not call
# a build finished while the console is claimable.
#
# What this does not prove is that the migrations apply to a real Supabase
# project; the nightly stack replay and the build itself do that. It proves
# the script around them. A few seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/build_from_empty.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── A psql that answers from the environment ─────────────────────────────────
cat > "$work/psql" <<'FAKE'
#!/usr/bin/env bash
# Every call is written down; -f files are copied so the rehearsal can read
# what each transaction would have run.
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/calls"
printf '%s\n' "$*" >> "$FAKE_DIR/log"
cmd=""; file=""; vars=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) cmd+="$2"$'\n'; shift 2 ;;
    -f) file="$2"; shift 2 ;;
    -v) vars+="$2"$'\n'; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "$file" ]]; then
  version=$(sed -n 's/^version=//p' <<< "$vars")
  cp "$file" "$FAKE_DIR/apply.$version.sql"
  printf '%s\n' "$vars" > "$FAKE_DIR/vars.$version"
  echo "$version" >> "$FAKE_DIR/applied"
  if [[ "$version" == "${FAKE_DEADLOCK_ONCE:-}" && ! -e "$FAKE_DIR/deadlocked" ]]; then
    touch "$FAKE_DIR/deadlocked"
    echo "ERROR:  deadlock detected (SQLSTATE 40P01)" >&2
    exit 3
  fi
  if [[ "$version" == "${FAKE_FAIL:-}" ]]; then
    echo "NOTICE:  something first" >&2
    echo "ERROR:  CLOVEERP_REHEARSAL: this migration refuses" >&2
    exit 3
  fi
  exit 0
fi
case "$cmd" in
  *"to_regnamespace('erp')"*) echo "${FAKE_ERP:-f}" ;;
  *"to_regclass('supabase_migrations.schema_migrations')"*) echo "${FAKE_HISTORY:-f}" ;;
  *"count(*) from supabase_migrations"*) echo "${FAKE_RECORDED:-0}" ;;
  *"from erp.tenant"*) echo "${FAKE_TENANTS:-0}" ;;
  *"select version from"*) printf '%s' "${FAKE_APPLIED:-}" ;;
  *"erp_meta.platform_staff where lower"*) echo "${FAKE_OWNER_ROWS:-1}" ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$work/psql"

# Three migrations, named the way the repository names them.
mig="$work/migrations"
mkdir -p "$mig"
echo "select 1;" > "$mig/0001_first.sql"
echo "select 2;" > "$mig/20260830091046_ad905a9f-fe00-4810-961e-441bae0f46a0.sql"
echo "select 3;" > "$mig/20261010062000_a_new_deployment_has_its_owner_before_anyone_signs_in.sql"

CASES=0
FAILED=0
run() {
  # run <name> [VAR=value ...]: a fresh fake, the script, its exit and output.
  local name="$1"; shift
  rm -rf "$work/fake"; mkdir -p "$work/fake"
  out=$(env FAKE_DIR="$work/fake" PSQL="$work/psql" REPLAY_DIR="$mig" VACUUM_EVERY=2 "$@" \
          bash "$SCRIPT" "postgresql://postgres.demoref@pooler.example:5432/postgres" "${OWNER:-owner@example.com}" 2>&1)
  status=$?
  CURRENT="$name"
}
check() {
  CASES=$((CASES + 1))
  if eval "$1"; then
    echo "  ok   $CURRENT: $2"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL $CURRENT: $2"
    echo "$out" | sed 's/^/       | /' | head -n 20
  fi
}

# 1. Not an address
OWNER="not-an-address" run "an owner that is not an email address"
check '[[ $status -eq 2 && "$out" == *"is not an email address"* && ! -s "$work/fake/log" ]]' \
      "refused before anything connects"

# 2. Somebody's database
run "a database with an erp schema" FAKE_ERP=t
check '[[ $status -eq 2 && "$out" == *"already has an erp schema"* && ! -e "$work/fake/applied" ]]' \
      "refused, and nothing applied"

# 3. Something pushed to it
run "a database with migrations recorded" FAKE_HISTORY=t FAKE_RECORDED=4
check '[[ $status -eq 2 && "$out" == *"already records 4 migration"* && ! -e "$work/fake/applied" ]]' \
      "refused, and nothing applied"

# 4. Carrying on over a database somebody uses
run "carrying on over organisations" RESUME=yes FAKE_ERP=t FAKE_HISTORY=t FAKE_RECORDED=2 FAKE_TENANTS=3
check '[[ $status -eq 2 && "$out" == *"holds 3 organisation"* && ! -e "$work/fake/applied" ]]' \
      "refused, and nothing applied"

# 5. Carrying on with nothing to carry on
run "carrying on from nothing" RESUME=yes
check '[[ $status -eq 2 && "$out" == *"nothing to carry on"* ]]' "refused"

# 6. An empty database, built
run "an empty database"
check '[[ $status -eq 0 && "$(tr "\n" " " < "$work/fake/applied")" == "0001 20260830091046 20261010062000 " ]]' \
      "every migration applied once, in order"
check 'grep -q -- "--single-transaction" "$work/fake/log" && [[ $(grep -c -- "--single-transaction" "$work/fake/log") -eq 3 ]]' \
      "each migration is its own transaction"
check '[[ "$(head -n 1 "$work/fake/apply.0001.sql")" == "set statement_timeout = 0;" && "$(sed -n 2p "$work/fake/apply.0001.sql")" == "\\i '"'"'$mig/0001_first.sql'"'"'" ]]' \
      "the timeout is off before the migration, in the same transaction"
check 'grep -q "insert into erp_meta.platform_staff" "$work/fake/apply.20260830091046.sql" && grep -q "if to_regclass('"'"'erp_meta.platform_staff'"'"') is null then" "$work/fake/apply.20260830091046.sql"' \
      "the owner is written inside the migration's transaction, once the staff list exists"
check 'grep -q "insert into supabase_migrations.schema_migrations (version, name, statements)" "$work/fake/apply.0001.sql" && grep -qx "name=ad905a9f-fe00-4810-961e-441bae0f46a0" "$work/fake/vars.20260830091046" && grep -qx "owner=owner@example.com" "$work/fake/vars.0001"' \
      "each migration is recorded the way the CLI records it, under its version and name"
check '[[ "$out" == *"built: 3 migration(s) applied"* && "$out" == *"owner@example.com is the platform'"'"'s owner"* ]]' \
      "it says what it built, and who owns it"

# 7. Carrying on
run "carrying on a build that stopped" RESUME=yes FAKE_ERP=t FAKE_HISTORY=t FAKE_RECORDED=1 FAKE_TENANTS=0 FAKE_APPLIED=$'0001\n'
check '[[ $status -eq 0 && "$(tr "\n" " " < "$work/fake/applied")" == "20260830091046 20261010062000 " ]]' \
      "what is recorded is not applied again"

# 8. A deadlock
run "a deadlock" FAKE_DEADLOCK_ONCE=20260830091046 DEADLOCK_WAIT=0
check '[[ $status -eq 0 && $(grep -c 20260830091046 "$work/fake/applied") -eq 2 && "$out" == *"deadlocked on attempt 1"* ]]' \
      "the migration that lost goes again, and the build finishes"

# 9. Any other error
run "a migration that refuses" FAKE_FAIL=20260830091046
check '[[ $status -eq 1 && "$out" == *"20260830091046_ad905a9f-fe00-4810-961e-441bae0f46a0.sql failed"* && "$out" == *"CLOVEERP_REHEARSAL"* && "$(tr "\n" " " < "$work/fake/applied")" == "0001 20260830091046 " ]]' \
      "the build stops there, names it and its ERROR, and applies nothing after it"

# 10. A claimable console
run "no owner at the end" FAKE_OWNER_ROWS=0
check '[[ $status -eq 1 && "$out" == *"the console is claimable"* ]]' \
      "a build that leaves the console claimable is not finished"

echo "$CASES checks over the build from empty, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
