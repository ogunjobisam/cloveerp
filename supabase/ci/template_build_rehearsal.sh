#!/usr/bin/env bash
#
# supabase/ci/template_build.sh, rehearsed with no database, no register and
# no template.
#
# It decides, for deployment_from_empty.yml with method template, whether a
# client is restored from a template or carries on from_empty in the same
# run. Wrong one way, a template that failed leaves a client unbuilt for a
# reason a replay would have got past (the owner's decision of 9 October: the
# first client built so is the template's live proof); wrong the other, a
# replay runs over a database something was committed to. So, against
# stand-ins for template_register.sh, template_restore.sh and psql: every
# failure before the restore commits (none registered, the register not
# answering, an answer not in its form, a fetch that fails, a refusal before
# anything is sent, a transaction rolled back) carries on from_empty and says
# why on one line; the restore is given the registered dump's sha256 and the
# registered fingerprint; whether anything was committed is the database's
# answer, never an exit code's; and anything committed, or a database that
# cannot be asked, stops the run. No password printed, and never the owner's
# whole address. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/template_build.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

URL="postgresql://postgres.abcdefghijklmnopqrst:s3cret-pass@pooler.example.invalid:5432/postgres"
OWNER="Owner@Example.com"
DUMP_SHA=$(printf '%064d' 1)
GIT_SHA="0123456789abcdef0123456789abcdef01234567"
FP='{"columns":"aa","functions":"bb","version":1}'

# ── A template_register.sh that answers from the environment ─────────────────
cat > "$work/register" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/register.log"
case "$1" in
  match)
    case "${FAKE_MATCH:-found}" in
      none) echo "no template is registered for these migrations (805, the newest 20261012070000)" >&2; exit 3 ;;
      broken) echo "x the register could not be asked for a template (password authentication failed)" >&2; exit 2 ;;
      partial) echo "git_sha=${FAKE_GIT_SHA}"; echo "dump_sha256=${FAKE_DUMP}"; echo "storage_key=artifact:77:t" ;;
      found)
        echo "git_sha=${FAKE_GIT_SHA}"; echo "dump_sha256=${FAKE_DUMP}"; echo "storage_key=artifact:77:cloveerp-template"
        echo "proving_run_id=77"; echo "fingerprint=${FAKE_FP}" ;;
    esac ;;
  fetch)
    if [[ -n "${FAKE_FETCH_FAIL:-}" ]]; then
      echo "x the template could not be fetched from run 77's artifact cloveerp-template; an artifact is kept ninety days (no valid artifacts found)" >&2
      exit 2
    fi
    mkdir -p "$3" && : > "$3/manifest.json"
    echo "fetched: template.dump 12 bytes, 805 migrations" ;;
esac
FAKE
chmod +x "$work/register"

# ── A template_restore.sh that exits as asked, and keeps what it was given ───
cat > "$work/restore" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/restore.args"
printf 'sha=%s\nfingerprint=%s\n' "${TEMPLATE_SHA256:-}" "${TEMPLATE_FINGERPRINT:-}" > "$FAKE_DIR/restore.env"
echo "- restoring 805 migrations' schema (the newest 20261012070000) in one transaction"
case "${FAKE_RESTORE:-0}" in
  0) echo "restored: 805 migration(s) recorded; o…@example.com is the platform's owner"; exit 0 ;;
  1) echo "x the template is restored, and then this failed: analyze" >&2; exit 1 ;;
  2) echo "x template.dump's sha256 is 0000000000000000…, not the 1111111111111111… registered for it." >&2; exit 2 ;;
  3)
    echo "x the template did not restore, and nothing of it was kept: it was one transaction." >&2
    echo "psql:/tmp/restore.sql:40: ERROR:  CLOVEERP_TEMPLATE_FINGERPRINT: the restored schema is not the one the template was made from (these parts differ: grants)" >&2
    echo "x 5 object(s) in the parts that differ (grants) are not as the template made them:" >&2
    echo "  grants  function public.erp_tenant_by_address(p_address text)  (not as the template made it)" >&2
    exit 3 ;;
  9) echo "x pg_restore was killed on $1 restoring for $3" >&2; exit 9 ;;
esac
FAKE
chmod +x "$work/restore"

# ── And a psql that says what the database holds afterwards ─────────────────
cat > "$work/psql" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/psql.log"
if [[ -n "${FAKE_ASK_FAIL:-}" ]]; then
  echo "psql: error: connection to server failed: timeout expired" >&2
  exit 2
fi
cmd=""
while [[ $# -gt 0 ]]; do case "$1" in -c) cmd="$2"; shift 2 ;; *) shift ;; esac; done
case "$cmd" in
  *"from pg_catalog.pg_namespace where nspname = any"*) echo "${FAKE_SCHEMAS:-0}" ;;
  *"to_regclass('supabase_migrations.schema_migrations') is not null"*) echo "${FAKE_HISTORY:-f}" ;;
  *"count(*) from supabase_migrations.schema_migrations"*) echo "${FAKE_RECORDED:-0}" ;;
  *) echo "unexpected: $cmd" >> "$FAKE_DIR/unexpected" ;;
esac
FAKE
chmod +x "$work/psql"

CASES=0
FAILED=0
run() {
  # run <name> [VAR=value ...]: a fresh fake, the script, its exit and output.
  local name="$1"; shift
  rm -rf "$work/fake" "$work/into"; mkdir -p "$work/fake"
  out=$(env FAKE_DIR="$work/fake" PSQL="$work/psql" TEMPLATE_REGISTER="$work/register" TEMPLATE_RESTORE="$work/restore" \
          FAKE_GIT_SHA="$GIT_SHA" FAKE_DUMP="$DUMP_SHA" FAKE_FP="$FP" "$@" \
          bash "$SCRIPT" "$URL" "$OWNER" "$work/into" 2>&1)
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
said() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | tail -n 1; }
fell_back='[[ $status -eq 0 && "$(said method)" == from_empty && "$(said committed)" == no && -n "$(said fell_back)" && $(printf "%s\n" "$out" | grep -c "^fell_back=") -eq 1 && ${#out} -gt 0 ]]'
not_restored='[[ ! -e "$work/fake/restore.args" ]]'
not_asked='[[ ! -e "$work/fake/psql.log" ]]'
no_secret='[[ "$out" != *"s3cret-pass"* && "$out" != *"owner@example.com"* && "$out" != *"Owner@Example.com"* ]]'

# 1. Before anything is sent: carried on from_empty, and why
run "no template registered for these migrations" FAKE_MATCH=none
check "$fell_back"' && [[ "$(said fell_back)" == "no template is registered for these migrations (805, the newest 20261012070000)" ]] && '"$not_restored"' && '"$not_asked" \
      "from_empty, saying why on one line; nothing restored, the database not asked"
check '[[ "$(said template_sha256)" == "" && "$(said template_git_sha)" == "" ]]' "and no template named"
run "a register that cannot be asked" FAKE_MATCH=broken
check "$fell_back"' && [[ "$(said fell_back)" == "the register could not be asked for a template (the register could not be asked for a template (password authentication failed))" ]] && '"$not_restored" \
      "from_empty, saying so"
run "an answer not in its form" FAKE_MATCH=partial
check "$fell_back"' && [[ "$(said fell_back)" == *"did not name a dump, a commit, where it is kept and its fingerprint"* && "$(said template_sha256)" == "" ]] && '"$not_restored" \
      "from_empty, and nothing of the half-answer kept"
run "a template that cannot be fetched" FAKE_FETCH_FAIL=1
check "$fell_back"' && [[ "$(said fell_back)" == "the template made at 0123456789ab could not be fetched (the template could not be fetched from run 77'"'"'s artifact cloveerp-template; an artifact is kept ninety days (no valid artifacts found))" ]] && '"$not_restored"' && '"$not_asked" \
      "from_empty, saying why; nothing restored"
check '[[ "$(said template_sha256)" == "$DUMP_SHA" && "$(said template_git_sha)" == "$GIT_SHA" ]]' "the template that was chosen still named"

# 2. Restored
run "a template restored"
check '[[ $status -eq 0 && "$(said method)" == template && "$(said committed)" == yes && "$(said fell_back)" == "" && "$(said template_sha256)" == "$DUMP_SHA" && "$(said template_git_sha)" == "$GIT_SHA" && "$(said template_run)" == 77 ]]' \
      "template, committed, the template named"
check '[[ "$(sed -n 1p "$work/fake/restore.args")" == "$URL" && "$(sed -n 2p "$work/fake/restore.args")" == "$work/into" && "$(sed -n 3p "$work/fake/restore.args")" == "$OWNER" ]] && grep -qx "sha=$DUMP_SHA" "$work/fake/restore.env" && grep -qx "fingerprint=$FP" "$work/fake/restore.env"' \
      "the restore given the database, the template fetched, the owner, and the dump's sha256 and fingerprint the register holds"
check 'grep -q "^match" "$work/fake/register.log" && grep -qx "fetch artifact:77:cloveerp-template $work/into" "$work/fake/register.log" && '"$not_asked" \
      "matched, fetched where the register keeps it, and no question of the database needed"
check "$no_secret" "no password printed, and never the owner's whole address"

# 3. A restore that did not finish: the database says whether anything was committed
run "a dump refused before anything was sent, the database empty" FAKE_RESTORE=2
check "$fell_back"' && [[ "$(said fell_back)" == "the template made at 0123456789ab was refused before anything was sent: template.dump'"'"'s sha256 is 0000000000000000…, not the 1111111111111111… registered for it" ]]' \
      "from_empty, saying why"
check 'grep -q "from pg_catalog.pg_namespace where nspname = any (string_to_array('"'"'erp erp_ref erp_meta erp_ai erp_test erp_ingress'"'"', '"'"' '"'"'))" "$work/fake/psql.log" && grep -q "to_regclass('"'"'supabase_migrations.schema_migrations'"'"')" "$work/fake/psql.log" && [[ ! -e "$work/fake/unexpected" ]]' \
      "the database asked: any product schema, and the history"
run "a transaction rolled back, the database empty" FAKE_RESTORE=3
check "$fell_back"' && [[ "$(said fell_back)" == "the restore'"'"'s one transaction did not commit: CLOVEERP_TEMPLATE_FINGERPRINT: the restored schema is not the one the template was made from (these parts differ: grants)" ]]' \
      "from_empty, with the refusal that rolled it back"
check '[[ "$out" == *"grants  function public.erp_tenant_by_address(p_address text)  (not as the template made it)"* ]]' \
      "and what the restore said of it left in the log"
run "a transaction rolled back, the history table there and empty" FAKE_RESTORE=3 FAKE_HISTORY=t FAKE_RECORDED=0
check "$fell_back" "from_empty: an empty history is nothing committed"
run "an exit that says committed, a database that says nothing was" FAKE_RESTORE=1
check "$fell_back" "from_empty: the database decides, not the exit code"
run "a restore that stopped some other way, the database empty" FAKE_RESTORE=9
check "$fell_back"' && [[ "$(said fell_back)" == "the restore stopped (it exited 9: pg_restore was killed on [the database] restoring for o…@example.com)" ]]' \
      "from_empty, with the connection and the owner's whole address taken out of why"
check "$no_secret" "no password printed"

# 4. Something committed, or nobody can say: the run stops
run "restored, and then a step after it failed" FAKE_RESTORE=1 FAKE_SCHEMAS=6 FAKE_HISTORY=t FAKE_RECORDED=805
check '[[ $status -eq 1 && "$(said method)" == template && "$(said committed)" == yes && "$(said fell_back)" == "" && "$out" == *"6 product schema(s), 805 migration(s) recorded"* && "$out" == *"this run stops"* ]]' \
      "stops: template, committed, and why"
run "a rolled-back exit, and yet a product schema there" FAKE_RESTORE=3 FAKE_SCHEMAS=1
check '[[ $status -eq 1 && "$(said committed)" == yes && "$out" == *"not as the build found it"* ]]' "stops: no replay over what is there"
run "migrations recorded, no schema" FAKE_RESTORE=3 FAKE_HISTORY=t FAKE_RECORDED=3
check '[[ $status -eq 1 && "$(said committed)" == yes ]]' "stops"
run "a database that cannot be asked" FAKE_RESTORE=3 FAKE_ASK_FAIL=1
check '[[ $status -eq 1 && "$(said committed)" == unknown && "$(said method)" == template && "$out" == *"cannot be asked whether anything of it was committed"* && "$out" == *"timeout expired"* ]]' \
      "stops, saying it cannot tell, rather than replay over what might be there"
check "$no_secret" "no password printed"

echo "$CASES checks over building from a template or carrying on from empty, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
