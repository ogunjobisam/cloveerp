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
# and an aws that keep what they are given, all writing what they were asked
# in one log, in order: a notice and a green run before the bucket exists;
# the control plane, the demonstration and every client whose database is up,
# one at a time with a pause, each from its own connection; the newest eight
# copies kept and nothing else touched; one database's failure said and the
# rest copied; and nothing secret printed. Seconds.
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
          FLEET_SLEEP="$work/bin/sleep" PRODUCTION_REF="$PROD" DEMO_REF="$DEMO"
          CLOVEERP_BACKUP_AGE_RECIPIENT="$RECIPIENT" CLOVEERP_BACKUP_S3_ENDPOINT="$ENDPOINT"
          CLOVEERP_BACKUP_S3_BUCKET="$BUCKET" CLOVEERP_BACKUP_S3_KEY_ID="$KEY_ID" CLOVEERP_BACKUP_S3_SECRET="$SECRET"
          FAKE_EXPECT_KEY_ID="$KEY_ID" FAKE_EXPECT_SECRET="$SECRET" OFFSITE_NOW="${DAY}T04:00:31Z"
          TMPDIR="$work/tmp")

# The register: a live client, a suspended one and a retiring one; each
# connection in the vault.
seed() {
  printf '%s' "$ACME_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
  printf '%s' "$BETA_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${BETA}_db_url"
  printf '%s' "$GAMMA_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${GAMMA}_db_url"
  answer cp cp-ready true
  answer cp cp-clients "acme|${ACME}|live" "beta|${BETA}|suspended" "gamma|${GAMMA}|retiring"
  answer cp cp-refs "${ACME},${BETA},${GAMMA},eeeeeeeeeeeeeeeeeeee"
}
# put <key> [content]: an object already in the bucket.
put() {
  mkdir -p "$(dirname "$FAKE_DIR/s3/${BUCKET}/$1")"
  printf '%s' "${2:-an older copy}" > "$FAKE_DIR/s3/${BUCKET}/$1"
}

CASES=0
FAILED=0
# run <name> [@db:tag=answer | -vault=<ref> | %<ref>=<url> | +<key> | VAR=value ...] -- <arguments>
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
      *) vars+=("$1") ;;
    esac
    shift
  done
  shift || true
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
check '[[ "$(grep -c "^sleep 10$" "$FAKE_DIR/order.log")" == 4 && "$(order)" == "psql cp cp-ready;psql cp cp-clients;psql cp cp-refs;pg_dump cp schemas;"* ]]' "a pause between databases, none before the first"
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

# 5. One database asked for
run "the demonstration alone" -- demonstration
check '[[ $status -eq 0 && "$(dumps)" == "pg_dump demo schemas;pg_dump demo auth.users data-only;" && "$(stored)" == "backups/demonstration/${DAY}.dump.age " ]]' "only it"
run "a client the register does not hold" -- zeta
check '[[ $status -eq 1 && "$out" == *"zeta"*"Nothing was copied."* && "$(dumps)" == "" ]]' "refused, nothing copied"

# 6. Nothing secret printed
run "on a runner" GITHUB_ACTIONS=true --
check '[[ $status -eq 0 ]]' "copied"
for secret in "$CP" "$DEMO_URL" "$ACME_URL" "$BETA_URL" "$GAMMA_URL" "$KEY_ID" "$SECRET" "$ENDPOINT" "$BUCKET"; do
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
