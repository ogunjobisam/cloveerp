#!/usr/bin/env bash
#
# supabase/ci/fleet_backup.sh, rehearsed with no database, no bucket and no
# key.
#
# The weekly copy of every database is the one copy Supabase does not hold.
# One that skips a database quietly, copies the wrong one under another's
# name, deletes a copy it should keep or anything that is not its own, stops
# the rest of the fleet for one database, or prints a connection string or an
# access key, is learned on the day the copy is needed. So every build runs
# it here first, against a psql that answers from files, a pg_dump, an age
# and an aws that keep what they are given, a project's Storage API and a
# GitHub, all writing what they were asked in one log, in order: a notice and
# a green run before the bucket exists; the control plane, the demonstration
# and every client whose database is up, one at a time with a pause, each
# from its own connection, each client with its stored documents; before
# each, GitHub asked whether a release is replaying into it, and one that is
# waited out or the database left for next time; before each client, whether
# its database password is being changed, waited out the same way, and the
# register read again, a client retired since the run began left alone and
# not counted as missed; the newest eight copies kept and nothing else
# touched; one database's failure said and the rest copied; and nothing
# secret printed. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet_backup.sh"
# shellcheck source=supabase/ci/fleet_rehearsal_fakes.sh
. "$HERE/fleet_rehearsal_fakes.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
fleet_fakes "$work/bin"

PROD=cpcpcpcpcpcpcpcpcpcp
DEMO=dddddddddddddddddddd
ACME=aaaaaaaaaaaaaaaaaaaa
BETA=bbbbbbbbbbbbbbbbbbbb
GAMMA=gggggggggggggggggggg
CP="postgresql://postgres.${PROD}:control-plane-password@pooler.example:5432/postgres"
DEMO_URL="postgresql://postgres.${DEMO}:demonstration-password@pooler.example:5432/postgres"
ACME_URL="postgresql://postgres.${ACME}:acme-database-password@pooler.example:5432/postgres"
BETA_URL="postgresql://postgres.${BETA}:beta-database-password@pooler.example:5432/postgres"
GAMMA_URL="postgresql://postgres.${GAMMA}:gamma-database-password@pooler.example:5432/postgres"
RECIPIENT=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
ENDPOINT=https://rehearsalaccount0123.r2.cloudflarestorage.com
BUCKET=cloveerp-offsite-rehearsal
KEY_ID=rehearsal-access-key-id-4711
SECRET=rehearsal-secret-access-key-0815
DAY=2026-10-11
export FAKE_DIR="$work/fake"

BASE_ENV=(FAKE_CP_URL="$CP" FAKE_DEMO_URL="$DEMO_URL" CLOVEERP_LIVE_DATABASE_URL="$CP" CLOVEERP_DEMO_DATABASE_URL="$DEMO_URL"
          PSQL="$work/bin/psql" PG_DUMP="$work/bin/pg_dump" AGE="$work/bin/age" AWS="$work/bin/aws"
          CURL="$work/bin/curl" MAPI_SLEEP="$work/bin/sleep" GH="$work/bin/gh" GH_REPO=cloveerp/rehearsal
          FLEET_SLEEP="$work/bin/sleep" PRODUCTION_REF="$PROD" DEMO_REF="$DEMO"
          CLOVEERP_BACKUP_AGE_RECIPIENT="$RECIPIENT" CLOVEERP_BACKUP_S3_ENDPOINT="$ENDPOINT"
          CLOVEERP_BACKUP_S3_BUCKET="$BUCKET" CLOVEERP_BACKUP_S3_KEY_ID="$KEY_ID" CLOVEERP_BACKUP_S3_SECRET="$SECRET"
          FAKE_EXPECT_KEY_ID="$KEY_ID" FAKE_EXPECT_SECRET="$SECRET" OFFSITE_NOW="${DAY}T04:00:31Z"
          TMPDIR="$work/tmp")

# The register: a live client, a suspended one and a retiring one; each
# connection and service key in the vault, and each with a stored document
# (beta's bucket empty).
seed() {
  local r
  printf '%s' "$ACME_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
  printf '%s' "$BETA_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${BETA}_db_url"
  printf '%s' "$GAMMA_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${GAMMA}_db_url"
  for r in "$ACME" "$BETA" "$GAMMA"; do
    printf 'sb_secret_%s_service' "$r" > "$FAKE_DIR/vault/cloveerp_deployment_${r}_service_key"
    mkdir -p "$FAKE_DIR/storage/${r}/document-output"
  done
  mkdir -p "$FAKE_DIR/storage/${ACME}/document-output/invoices" "$FAKE_DIR/storage/${GAMMA}/document-output"
  printf '%%PDF acme invoice' > "$FAKE_DIR/storage/${ACME}/document-output/invoices/INV-1.pdf"
  printf '%%PDF gamma statement' > "$FAKE_DIR/storage/${GAMMA}/document-output/statement.pdf"
  answer cp cp-ready true
  answer cp cp-clients "acme|${ACME}|live|https://${ACME}.supabase.co" "beta|${BETA}|suspended|" "gamma|${GAMMA}|retiring|https://${GAMMA}.supabase.co/"
  answer cp cp-refs "${ACME},${BETA},${GAMMA},eeeeeeeeeeeeeeeeeeee"
}
# replaying <run id> <client code>: a release train with a release to that
# client past its wait for copies and in its replay.
replaying() {
  gh_run deploy.yml "$1"
  gh_job "$1" "release to $2 / release to the $2" in_progress "No copy of this database is being made=completed" \
         "Apply pending migrations by replay=in_progress"
}
# rotating <run id> <status of its step> [status of its wait]: a change of
# database passwords (fleet_secrets.yml, titled so), its rotation step at
# that status, its own wait before it at the other (default completed).
ROTATION_STEP="Change the database passwords, one client at a time"
SECRETS_WAIT="No rename, and for a password no export or backup, is under way"
rotating() {
  gh_run fleet_secrets.yml "$1" in_progress workflow_dispatch "fleet secrets: rotate_db_password for all"
  gh_job "$1" "rotate_db_password for all" in_progress "${SECRETS_WAIT}=${3:-completed}" \
         "${ROTATION_STEP}=$2" "Change them, one client at a time=queued"
}
# put <key> [content]: an object already in the bucket.
put() {
  mkdir -p "$(dirname "$FAKE_DIR/s3/${BUCKET}/$1")"
  printf '%s' "${2:-an older copy}" > "$FAKE_DIR/s3/${BUCKET}/$1"
}

CASES=0
FAILED=0
# run <name> [@db:tag=answer | -vault=<ref> | %<ref>=<url> | +<key> | ^<code> (a release to it replaying)
#            | ~<run id>=<step status>[/<its wait's status>] (a change of database passwords)
#            | -key=<ref> | -bucket=<ref>
#            | VAR=value ...] -- <arguments>
run() {
  CURRENT="$1"; shift
  local vars=() a db rest
  rm -rf "$FAKE_DIR" "$work/tmp"; mkdir -p "$FAKE_DIR/vault" "$work/tmp"
  seed
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in
      @*) a="${1#@}"; db="${a%%:*}"; rest="${a#*:}"; answer "$db" "${rest%%=*}" "${rest#*=}" ;;
      -vault=*) rm -f "$FAKE_DIR/vault/cloveerp_deployment_${1#-vault=}_db_url" ;;
      %*) a="${1#%}"; printf '%s' "${a#*=}" > "$FAKE_DIR/vault/cloveerp_deployment_${a%%=*}_db_url" ;;
      +*) put "${1#+}" ;;
      ^*) replaying 900 "${1#^}" ;;
      ~*) a="${1#\~}"; rest="${a#*=}"
          if [[ "$rest" == */* ]]; then rotating "${a%%=*}" "${rest%%/*}" "${rest#*/}"; else rotating "${a%%=*}" "$rest"; fi ;;
      -key=*) rm -f "$FAKE_DIR/vault/cloveerp_deployment_${1#-key=}_service_key" ;;
      -bucket=*) rm -rf "$FAKE_DIR/storage/${1#-bucket=}" ;;
      *) vars+=("$1") ;;
    esac
    shift
  done
  shift || true
  # The register read again just before each client says what it said when
  # the run began, unless the case says otherwise (@cp:cp-client@<code>=...).
  local c r st ap
  while IFS='|' read -r c r st ap; do
    [[ -n "$c" && "$c" != ERROR:* && ! -f "$FAKE_DIR/answers/cp/cp-client@$c" ]] || continue
    answer cp "cp-client@$c" "${st}|true|${r}|${ap}"
  done < "$FAKE_DIR/answers/cp/cp-clients"
  : > "$work/summary"
  out=$(env -u GITHUB_ACTIONS GITHUB_STEP_SUMMARY="$work/summary" GITHUB_RUN_ID=4242 \
          "${BASE_ENV[@]}" ${vars[@]+"${vars[@]}"} bash "$SCRIPT" "$@" 2>&1)
  status=$?
}
check() {
  CASES=$((CASES + 1))
  if eval "$1"; then
    echo "  ok   $CURRENT: $2"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL $CURRENT: $2"
    printf '%s\n' "$out" | sed 's/^/       | /' | head -n 20
    sed 's/^/       > /' "$FAKE_DIR/order.log" 2> /dev/null | head -n 40
  fi
}
order() { tr '\n' ';' 2> /dev/null < "$FAKE_DIR/order.log"; }
events() { cat "$FAKE_DIR/events" 2> /dev/null; }
stored() { find "$FAKE_DIR/s3" -type f 2> /dev/null | sed "s|^$FAKE_DIR/s3/${BUCKET}/||" | LC_ALL=C sort | tr '\n' ' '; }
untouched() { [[ ! -s "$FAKE_DIR/order.log" ]]; }
nothing_left() { [[ -z "$(ls -A "$work/tmp" 2> /dev/null)" ]]; }
dumps() { grep '^pg_dump' "$FAKE_DIR/order.log" 2> /dev/null | tr '\n' ';'; }
# tvar <tag> <name> [nth]: what the nth (default last) statement of that tag was given.
tvar() {
  local n
  if [[ -n "${3:-}" ]]; then
    n=$(awk -v t="$1" -v k="$3" '$3 == t { c++; if (c == k) n = $1 } END { print n }' "$FAKE_DIR/psql.log" 2> /dev/null)
  else
    n=$(awk -v t="$1" '$3 == t { n = $1 } END { print n }' "$FAKE_DIR/psql.log" 2> /dev/null)
  fi
  if [[ -n "$n" ]]; then sed -n "s/^$2=//p" "$FAKE_DIR/vars.$n" | head -n 1; fi
}

# 1. Nowhere to put them yet: a notice, and green
run "no bucket yet" CLOVEERP_BACKUP_S3_ENDPOINT= CLOVEERP_BACKUP_S3_BUCKET= CLOVEERP_BACKUP_S3_KEY_ID= CLOVEERP_BACKUP_S3_SECRET= --
check '[[ $status -eq 0 && "$out" == *"no database is copied off the platform until the owner has made somewhere to put the copies: a bucket"*"CLOVEERP_BACKUP_S3_KEY_ID"*"Nothing was dumped, uploaded or recorded."* ]] && untouched' \
      "green, naming the bucket and the access key; nothing read or dumped"
run "no key yet, on a runner" GITHUB_ACTIONS=true CLOVEERP_BACKUP_AGE_RECIPIENT= --
check '[[ $status -eq 0 && "$(printf "%s\n" "$out" | grep -c "^::notice::no database is copied")" == 1 && "$out" == *"CLOVEERP_BACKUP_AGE_RECIPIENT"* && "$out" != *"::error::"* ]] && untouched' \
      "a notice, not an error"
run "only asked, and it is not" CHECK_ONLY=yes CLOVEERP_BACKUP_S3_SECRET= --
check '[[ $status -eq 3 && "$out" == *"CLOVEERP_BACKUP_S3_SECRET"* ]] && untouched' "3, so the workflow skips the rest"
run "only asked, and it is" CHECK_ONLY=yes --
check '[[ $status -eq 0 && "$out" == *"the bucket and the key are set"* ]] && untouched' "0, and nothing done"
run "a target that is not one" -- "Acme!"
check '[[ $status -eq 2 && "$out" == *"neither control-plane, demonstration nor a client"* ]] && untouched' "refused"
run "no control plane" CLOVEERP_LIVE_DATABASE_URL= --
check '[[ $status -eq 2 && "$out" == *"CLOVEERP_LIVE_DATABASE_URL is not set"* ]] && untouched' "refused"

# 2. Every database, one at a time
run "the whole fleet" --
check '[[ $status -eq 0 && "$out" == *"5 database(s) copied off the platform, 0 not"* ]]' "five copied"
check '[[ "$(dumps)" == "pg_dump cp schemas;pg_dump cp auth.users data-only;pg_dump demo schemas;pg_dump demo auth.users data-only;pg_dump ${ACME} schemas;pg_dump ${ACME} auth.users data-only;pg_dump ${BETA} schemas;pg_dump ${BETA} auth.users data-only;pg_dump ${GAMMA} schemas;pg_dump ${GAMMA} auth.users data-only;" ]]' \
      "the control plane, the demonstration, then the live, the suspended and the retiring client, each from its own connection"
check '[[ "$(stored)" == "backups/acme/${DAY}.dump.age backups/beta/${DAY}.dump.age backups/control-plane/${DAY}.dump.age backups/demonstration/${DAY}.dump.age backups/gamma/${DAY}.dump.age " ]]' \
      "one copy each, under backups/<database>/<date>.dump.age"
check '[[ "$(grep -c "^sleep 10$" "$FAKE_DIR/order.log")" == 4 && "$(order)" == "psql cp cp-ready;psql cp cp-clients;psql cp cp-refs;gh workflows/deploy.yml/runs;pg_dump cp schemas;"* ]]' "a pause between databases, none before the first"
check '[[ "$(grep -c "^gh workflows/deploy.yml/runs$" "$FAKE_DIR/order.log")" == 5 && "$(order)" == *"sleep 10;gh workflows/fleet_secrets.yml/runs;gh workflows/deploy.yml/runs;psql cp cp-client;psql cp vault-get cloveerp:deployment:${ACME}:db_url;"* ]]' \
      "GitHub asked before each database, not once: whether a release is replaying into it; and before a client, first whether its password is being changed, then the register again"
check '[[ "$(grep -c "^gh workflows/fleet_secrets.yml/runs$" "$FAKE_DIR/order.log")" == 3 && "$(grep -c "^psql cp cp-client$" "$FAKE_DIR/order.log")" == 3 && "$(order)" == "psql cp cp-ready;psql cp cp-clients;psql cp cp-refs;gh workflows/deploy.yml/runs;pg_dump cp schemas;"*"sleep 10;gh workflows/deploy.yml/runs;pg_dump demo schemas;"* ]]' \
      "the clients alone: no rotation changes the control plane's or the demonstration's password, and neither is in the register"
check '[[ "$(tvar cp-client code 1)" == acme && "$(tvar cp-client code 3)" == gamma && "$(sed -n "/-- fleet: cp-client/,\$p" "$FAKE_DIR/sql.$(awk "\$3 == \"cp-client\" { print \$1; exit }" "$FAKE_DIR/psql.log")")" == *"built_at is not null"*"project_ref"*"api_url"* ]]' \
      "each client's own row, its status, whether it was built, its project and its API address"
check '[[ "$(order)" == *"pg_dump ${ACME} auth.users data-only;POST /storage/v1/object/list/document-output;POST /storage/v1/object/list/document-output;GET /storage/v1/object/document-output/invoices/INV-1.pdf;age ${RECIPIENT};"* ]]' \
      "a client's stored documents fetched after its dumps, before it is sealed"
check '[[ "$(cut -d"|" -f1-2 "$FAKE_DIR/storage.lists" | sort -u | tr "\n" " ")" == "${ACME}|document-output ${BETA}|document-output ${GAMMA}|document-output " ]]' \
      "each client's from its own project; the control plane's and the demonstration's not asked for"
check '[[ "$(cat "$FAKE_DIR/age.members.3")" == *"storage/document-output/invoices/INV-1.pdf "* && "$(cat "$FAKE_DIR/age.members.4")" == *"storage/document-output/ "* && "$(cat "$FAKE_DIR/age.members.1")" != *"storage"* ]]' \
      "in each client's copy, an empty bucket an empty folder; none in the control plane's"
check '[[ "$(jq -r .storage.objects "$FAKE_DIR/age.manifest.5")" == 1 && "$(jq -r ".storage // \"none\"" "$FAKE_DIR/age.manifest.2")" == none ]]' "and the manifests say so"
check '[[ "$(events)" == *"acme|note|done|copied off the platform as backups/acme/${DAY}.dump.age ("*"with 1 stored document(s)"* ]]' "the client's row says its documents came too"
check '[[ "$(order)" == *"aws cp backups/control-plane/${DAY}.dump.age;aws head backups/control-plane/${DAY}.dump.age;aws list backups/control-plane/;sleep 10;"* ]]' \
      "each uploaded, asked for again, and its copies listed before the next"
check '[[ "$(cut -d"|" -f1-3 <<< "$(events)" | tr "\n" " ")" == "acme|note|done beta|note|done gamma|note|done " && "$(events)" == *"copied off the platform as backups/acme/${DAY}.dump.age"* ]]' \
      "each client's row says it was copied, and where"
check '[[ "$(cat "$FAKE_DIR/age.members.1")" == "auth_users.dump manifest.json product.dump " && "$(jq -r .database "$FAKE_DIR/age.manifest.2")" == demonstration ]]' "each copy the two dumps and the manifest, named for its database"
check '[[ "$(grep -c "^age ${RECIPIENT}$" "$FAKE_DIR/order.log")" == 5 ]] && nothing_left' "every one sealed to the owner's key, and no dump left on the runner"
check '[[ "$(cat "$work/summary")" == *"| backups/gamma/${DAY}.dump.age |"* ]]' "the summary lists them"
check '[[ "$(sed -n "/-- fleet: cp-clients/,\$p" "$FAKE_DIR/sql.2")" == *"'"'"'built'"'"', '"'"'live'"'"', '"'"'suspended'"'"', '"'"'retiring'"'"'"* ]]' \
      "the register is asked for every client whose database is up"

# 3. The newest eight are kept, and nothing else is touched
run "two months of Sundays" +backups/acme/2026-08-09.dump.age +backups/acme/2026-08-16.dump.age +backups/acme/2026-08-23.dump.age \
    +backups/acme/2026-08-30.dump.age +backups/acme/2026-09-06.dump.age +backups/acme/2026-09-13.dump.age +backups/acme/2026-09-20.dump.age \
    +backups/acme/2026-09-27.dump.age +backups/acme/2026-10-04.dump.age +backups/acme/notes.txt +backups/acme-old/2026-01-04.dump.age \
    +exports/acme/20260101T000000Z.dump.age -- acme
check '[[ $status -eq 0 && "$(grep "^aws rm" "$FAKE_DIR/order.log" | tr "\n" ";")" == "aws rm backups/acme/2026-08-09.dump.age;aws rm backups/acme/2026-08-16.dump.age;" ]]' \
      "the two oldest deleted, after this week's copy was made and found"
check '[[ "$(stored)" == "backups/acme-old/2026-01-04.dump.age backups/acme/2026-08-23.dump.age backups/acme/2026-08-30.dump.age backups/acme/2026-09-06.dump.age backups/acme/2026-09-13.dump.age backups/acme/2026-09-20.dump.age backups/acme/2026-09-27.dump.age backups/acme/2026-10-04.dump.age backups/acme/${DAY}.dump.age backups/acme/notes.txt exports/acme/20260101T000000Z.dump.age " ]]' \
      "eight copies kept; another database's, an export and a file that is not a copy left alone"
check '[[ "$(dumps)" == "pg_dump ${ACME} schemas;pg_dump ${ACME} auth.users data-only;" && "$out" == *"copies kept: 8"* ]]' "one database asked for, one copied"
run "kept fewer" KEEP=2 +backups/beta/2026-09-27.dump.age +backups/beta/2026-10-04.dump.age -- beta
check '[[ $status -eq 0 && "$(stored)" == "backups/beta/2026-10-04.dump.age backups/beta/${DAY}.dump.age " ]]' "KEEP says how many"
run "a store that cannot list" FAKE_AWS_LIST_FAIL=yes +backups/acme/2026-01-04.dump.age -- acme
check '[[ $status -eq 0 && "$out" == *"none deleted, because the store could not list backups/acme/"* && "$(order)" != *"aws rm"* ]]' "copied, and nothing deleted on a doubt"
run "a store that will not delete" FAKE_AWS_RM_FAIL=yes KEEP=1 +backups/acme/2026-10-04.dump.age -- acme
check '[[ $status -eq 0 && "$out" == *"could not be deleted"* && "$(stored)" == "backups/acme/2026-10-04.dump.age backups/acme/${DAY}.dump.age " ]]' "copied, and said"

# 4. One database never stops the others
run "a client with no connection" -vault="$BETA" --
check '[[ $status -eq 1 && "$out" == *"beta was not copied: the control plane'"'"'s vault has no cloveerp:deployment:${BETA}:db_url"* && "$out" == *"4 database(s) copied off the platform, 1 not"* ]]' \
      "red, said, and the four others copied"
check '[[ "$(stored)" != *"backups/beta/"* && "$(stored)" == *"backups/gamma/${DAY}"* && "$(events)" == *"beta|note|failed|not copied off the platform this week"* ]]' "beta's row says so; gamma, after it, was copied"
run "no demonstration connection" CLOVEERP_DEMO_DATABASE_URL= --
check '[[ $status -eq 1 && "$out" == *"demonstration was not copied: CLOVEERP_DEMO_DATABASE_URL is not set"* && "$(stored)" == *"backups/acme/${DAY}"* ]]' "red, and the clients copied"
run "a control plane connection that is not production's" PRODUCTION_REF=pppppppppppppppppppp --
check '[[ $status -eq 1 && "$out" == *"control-plane was not copied: CLOVEERP_LIVE_DATABASE_URL does not name the control plane"* && "$(dumps)" != *"pg_dump cp"* ]]' "not dumped"
run "a client's connection that names another" "%${ACME}=postgresql://postgres.${ACME}:pw@pooler.example:5432/postgres?also=${BETA}" -- acme
check '[[ $status -eq 1 && "$out" == *"names another deployment'"'"'s project (${BETA})"* && "$(dumps)" == "" ]]' "not dumped"
run "a client given production's project" "@cp:cp-clients=acme|${PROD}|live" --
check '[[ $status -eq 1 && "$out" == *"acme was not copied: the register gives it the control plane"* && "$(grep -c "^pg_dump cp schemas" "$FAKE_DIR/order.log")" == 1 ]]' \
      "refused, and the control plane copied once, as itself"
run "a client named for the control plane's copies" "@cp:cp-clients=control-plane|${ACME}|live" --
check '[[ $status -eq 1 && "$out" == *"control-plane was not copied: its code is the name the control-plane'"'"'s copies are kept under"* ]]' "refused, and the others kept apart"
run "a dump that fails" "FAKE_PG_DUMP_FAIL=${GAMMA} auth.users" --
check '[[ $status -eq 1 && "$out" == *"gamma was not copied: the sign-ins (auth.users) could not be dumped"* && "$out" != *"gamma-database-password"* && "$(stored)" != *"gamma"* ]] && nothing_left' \
      "red, the connection taken out of the error, nothing of it uploaded or left"
run "a store that refuses everything" FAKE_AWS_CP_FAIL=yes --
check '[[ $status -eq 1 && "$out" == *"0 database(s) copied off the platform, 5 not"* && "$out" != *"$KEY_ID"* && "$out" != *"$ENDPOINT"* ]]' "every one said, the key and endpoint taken out"
run "a register that cannot be read" "@cp:cp-clients=ERROR:  canceling statement due to statement timeout" --
check '[[ $status -eq 1 && "$out" == *"the control plane'"'"'s register could not be read"* && "$(dumps)" == "" ]]' "red, nothing copied"
run "a client with no service key" -key="$GAMMA" --
check '[[ $status -eq 1 && "$out" == *"gamma was not copied: the control plane'"'"'s vault has no cloveerp:deployment:${GAMMA}:service_key, so its stored documents (document-output) cannot be fetched"* && "$out" == *"4 database(s) copied off the platform, 1 not"* && "$(dumps)" != *"${GAMMA}"* ]]' \
      "not copied, never dumped: a copy without its documents is not the business's copy"
run "a client whose bucket is gone" -bucket="$BETA" --
check '[[ $status -eq 1 && "$out" == *"beta was not copied: its stored documents (document-output) could not be listed (Storage answered 400"* && "$(stored)" != *"backups/beta/"* && "$(stored)" == *"backups/gamma/${DAY}"* ]] && nothing_left' \
      "not copied, nothing of it left, and the next client copied"
run "a client whose document will not come" FAKE_STORAGE_FETCH_STATUSES=403 -- acme
check '[[ $status -eq 1 && "$out" == *"the stored document invoices/INV-1.pdf could not be fetched"* && "$out" != *"sb_secret_"* && -z "$(stored)" ]] && nothing_left' \
      "not copied, the key in no error"
run "a client's API address that is not its project's" "@cp:cp-clients=acme|${ACME}|live|https://evil.example/${ACME}" -- acme
check '[[ $status -eq 1 && "$out" == *"is not its project'"'"'s, so its service key would not be sent there"* && "$(order)" != *"service_key"* && "$(order)" != *"storage"* ]]' \
      "not copied, the key never read"

# 4b. A release replaying into a database is waited out before it, not once
run "a release replaying into acme" ^acme RELEASE_WAIT_MINUTES=2 --
check '[[ $status -eq 1 && "$out" == *"acme was not copied: a release to it was still replaying after 2 minute(s) (deploy.yml run 900: release to acme / release to the acme"* && "$out" == *"4 database(s) copied off the platform, 1 not"* ]]' \
      "waited out up to the limit, then not copied this time; the rest copied"
check '[[ "$(order)" == *"aws list backups/demonstration/;sleep 10;gh workflows/fleet_secrets.yml/runs;gh workflows/deploy.yml/runs;gh runs/900/jobs;sleep 60;gh workflows/deploy.yml/runs;gh runs/900/jobs;sleep 60;gh workflows/deploy.yml/runs;gh runs/900/jobs;event acme note failed;sleep 10;"* && "$(dumps)" != *"${ACME}"* ]]' \
      "asked again each minute before acme, acme never dumped, and beta after it"
check '[[ "$(events)" == *"acme|note|failed|not copied off the platform this week: a release to it was still replaying"* ]]' "acme's row says why"
run "a release to acme still waiting for copies" --
gh_run deploy.yml 901
gh_job 901 "release to acme / release to the acme" in_progress "No copy of this database is being made=in_progress" "Apply pending migrations by replay=queued"
out=$(env -u GITHUB_ACTIONS GITHUB_STEP_SUMMARY="$work/summary" GITHUB_RUN_ID=4242 "${BASE_ENV[@]}" bash "$SCRIPT" acme 2>&1); status=$?
check '[[ $status -eq 0 && "$(grep -c "^sleep 60" "$FAKE_DIR/order.log")" == 0 && "$(stored)" == *"backups/acme/${DAY}"* ]]' "not waited for: that release waits for this copy"
run "a release replaying into another client" ^beta RELEASE_WAIT_MINUTES=1 -- acme
check '[[ $status -eq 0 && "$(grep -c "^sleep 60" "$FAKE_DIR/order.log")" == 0 && "$(stored)" == "backups/acme/${DAY}.dump.age " ]]' "acme copied without a wait"
run "GitHub that cannot be asked" FAKE_GH_FAIL=yes RELEASE_WAIT_MINUTES=1 -- demonstration
check '[[ $status -eq 1 && "$out" == *"demonstration was not copied: a release to it was still replaying after 1 minute(s) (GitHub could not be asked"* && "$(dumps)" == "" ]]' \
      "counted as busy, as every wait here: not copied, and said"

# 4c. A change of database passwords is waited out before each client: a new
# password breaks the connection the dumps are made with
run "a change of passwords under way" "~300=in_progress" ROTATION_WAIT_MINUTES=2 --
check '[[ $status -eq 1 && "$out" == *"acme was not copied: a change of database passwords (fleet_secrets.yml) was still under way after 2 minute(s) (fleet_secrets.yml run 300: in \"${ROTATION_STEP}\")"* && "$out" == *"2 database(s) copied off the platform, 3 not"* ]]' \
      "each client waited for up to the limit, then not copied this time"
check '[[ "$(dumps)" == "pg_dump cp schemas;pg_dump cp auth.users data-only;pg_dump demo schemas;pg_dump demo auth.users data-only;" && "$(grep -c "^sleep 60$" "$FAKE_DIR/order.log")" == 6 && "$(order)" != *"vault-get"* ]]' \
      "the control plane and the demonstration copied without a wait; no client's connection even read"
check '[[ "$(events)" == *"beta|note|failed|not copied off the platform this week: a change of database passwords"* ]]' "each client's row says why"
run "a change of passwords through its own wait, about to begin its step" "~300=queued" ROTATION_WAIT_MINUTES=1 -- acme
check '[[ $status -eq 1 && "$out" == *"acme was not copied: a change of database passwords (fleet_secrets.yml) was still under way after 1 minute(s) (fleet_secrets.yml run 300: in \"${ROTATION_STEP}\")"* && "$(dumps)" == "" ]]' \
      "waited for as one in its step: nothing is left for it to wait for"
# A rotation still at its own wait, begun before this backup (a smaller run
# id), with the backup in "Copy every database": the backup asks from inside
# that step, so it counts only a rotation in its own, and goes; the rotation's
# wait asks about the backup's step, and waits for it. Never both.
run "a change of passwords begun before this run, still at its own wait" "~300=queued/in_progress" --
check '[[ $status -eq 0 && "$(grep -c "^sleep 60$" "$FAKE_DIR/order.log")" == 0 && "$out" == *"5 database(s) copied off the platform, 0 not"* && "$(dumps)" == *"${ACME}"*"${BETA}"*"${GAMMA}"* ]]' \
      "not waited for, though it began first: every client copied"
gh_run fleet_backup.yml 4242
gh_job 4242 "every database, copied off the platform" in_progress "Somewhere to put them=completed" "Copy every database=in_progress"
wait_step=$(workflow_step "$HERE/../../.github/workflows/fleet_secrets.yml" "$SECRETS_WAIT")
out=$(cd "$HERE/../.." && env -u GITHUB_ACTIONS PATH="$work/bin:$PATH" GH_REPO=cloveerp/rehearsal GITHUB_RUN_ID=300 FLEET_SLEEP="$work/bin/sleep" \
        POLL_SECONDS=1800 ACTION=rotate_db_password bash -c "$wait_step" 2>&1); status=$?
check '[[ -n "$wait_step" && $status -eq 1 && "$out" == *"fleet_backup.yml run 4242: in \"Copy every database\""* && "$out" == *"::error::still under way after an hour"* ]]' \
      "and the rotation's own wait (fleet_secrets.yml's step, as the runner runs it) waits for this backup"
run "a change of passwords begun after this run" "~5000=queued/in_progress" --
check '[[ $status -eq 0 && "$(grep -c "^sleep 60$" "$FAKE_DIR/order.log")" == 0 && "$out" == *"5 database(s) copied off the platform, 0 not"* ]]' \
      "not waited for: it waits for this run instead, so the two never both wait"
run "a change of something else" --
gh_run fleet_secrets.yml 300
gh_job 300 "patch_auth for all" in_progress "${ROTATION_STEP}=completed" "Change them, one client at a time=in_progress"
rm -rf "$FAKE_DIR/order.log" "$FAKE_DIR/s3"
out=$(env -u GITHUB_ACTIONS GITHUB_STEP_SUMMARY="$work/summary" GITHUB_RUN_ID=4242 "${BASE_ENV[@]}" bash "$SCRIPT" acme 2>&1); status=$?
check '[[ $status -eq 0 && "$(grep -c "^sleep 60" "$FAKE_DIR/order.log")" == 0 && "$(order)" == "psql cp cp-ready;psql cp cp-clients;psql cp cp-refs;gh workflows/fleet_secrets.yml/runs;gh runs/300/jobs;gh workflows/deploy.yml/runs;psql cp cp-client;"* && "$(stored)" == "backups/acme/${DAY}.dump.age " ]]' \
      "not waited for: only a new password breaks a connection"
run "a change of something else, through its own wait and about to pass the rotation's step" --
gh_run fleet_secrets.yml 300 in_progress workflow_dispatch "fleet secrets: patch_auth for all"
gh_job 300 "patch_auth for all" in_progress "${SECRETS_WAIT}=completed" "${ROTATION_STEP}=queued" "Change them, one client at a time=queued"
rm -rf "$FAKE_DIR/order.log" "$FAKE_DIR/s3"
out=$(env -u GITHUB_ACTIONS GITHUB_STEP_SUMMARY="$work/summary" GITHUB_RUN_ID=4242 "${BASE_ENV[@]}" bash "$SCRIPT" acme 2>&1); status=$?
check '[[ $status -eq 0 && "$(grep -c "^sleep 60" "$FAKE_DIR/order.log")" == 0 && "$(order)" != *"runs/300/jobs"* && "$(stored)" == "backups/acme/${DAY}.dump.age " ]]' \
      "not waited for: its title says it changes no password, though GitHub cannot yet say it skips that step"

# 4d. The register read again just before each client: one retired since
# the run began is left alone, not missed, and its row not written
run "a client retired while the run copied the ones before it" "@cp:cp-client@gamma=retired|true|${GAMMA}|" -vault="$GAMMA" -key="$GAMMA" --
check '[[ $status -eq 0 && "$out" == *"gamma is no longer up (retired) since this run began: left alone, and not copied"* && "$out" == *"4 database(s) copied off the platform, 0 not; 1 left alone, no longer up"* && "$out" != *"error"* ]]' \
      "green: a client retired on its purge date mid-run is not a copy missed"
check '[[ "$(events)" != *"gamma|"* && "$(order)" != *"vault-get cloveerp:deployment:${GAMMA}"* && "$(dumps)" != *"${GAMMA}"* && "$(cat "$work/summary")" == *"| gamma | left alone: no longer up (retired) since the run began |"* ]]' \
      "nothing written on its row, its vault not asked, nothing dumped; the summary says so"
run "a client gone from the register" "@cp:cp-client@beta=" -- beta
check '[[ $status -eq 0 && "$out" == *"beta is no longer up (no longer in the register)"* && -z "$(events)" && "$(dumps)" == "" ]]' "left alone"
run "a retiring client never built" "@cp:cp-client@gamma=retiring|false|${GAMMA}|" -- gamma
check '[[ $status -eq 0 && "$out" == *"gamma is no longer up (retiring, and never built)"* && -z "$(events)" ]]' "left alone"
run "a register that cannot be read again" "@cp:cp-client@acme=ERROR:  canceling statement due to statement timeout" --
check '[[ $status -eq 1 && "$out" == *"acme was not copied: the register could not be read again just before it (canceling statement due to statement timeout)"* && "$out" == *"4 database(s) copied off the platform, 1 not"* ]]' \
      "not copied, said, the rest copied"
run "a client moved to another project since the run began" "@cp:cp-client@acme=live|true|${BETA}|" -- acme
check '[[ $status -eq 0 && "$(dumps)" == "pg_dump ${BETA} schemas;pg_dump ${BETA} auth.users data-only;" && "$(order)" == *"vault-get cloveerp:deployment:${BETA}:db_url"* ]]' \
      "copied from where the register says it is now"

# 5. One database asked for
run "the demonstration alone" -- demonstration
check '[[ $status -eq 0 && "$(dumps)" == "pg_dump demo schemas;pg_dump demo auth.users data-only;" && "$(stored)" == "backups/demonstration/${DAY}.dump.age " ]]' "only it"
run "a client the register does not hold" -- zeta
check '[[ $status -eq 1 && "$out" == *"zeta"*"Nothing was copied."* && "$(dumps)" == "" ]]' "refused, nothing copied"

# 6. Nothing secret printed
run "on a runner" GITHUB_ACTIONS=true --
check '[[ $status -eq 0 ]]' "copied"
for secret in "$CP" "$DEMO_URL" "$ACME_URL" "$BETA_URL" "$GAMMA_URL" "$KEY_ID" "$SECRET" "$ENDPOINT" "$BUCKET" \
              "sb_secret_${ACME}_service" "sb_secret_${BETA}_service" "sb_secret_${GAMMA}_service"; do
  CASES=$((CASES + 1))
  if [[ "$(printf "%s\n" "$out" | grep -F -- "$secret" | grep -vc "^::add-mask::")" == 0 && "$(printf "%s\n" "$out" | grep -cxF -- "::add-mask::$secret")" -ge 1 ]]; then
    echo "  ok   $CURRENT: ${secret:0:24}… masked, and printed nowhere else"
  else
    FAILED=$((FAILED + 1)); echo "  FAIL $CURRENT: ${secret:0:24}… printed unmasked, or never masked"
  fi
done
run "outside a runner" --
check '[[ $status -eq 0 && "$out" != *"::add-mask::"* && "$out" != *"-password@"* && "$out" != *"$SECRET"* ]]' "no mask line, and nothing secret"

echo "$CASES checks over the fleet's off-platform copies, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
