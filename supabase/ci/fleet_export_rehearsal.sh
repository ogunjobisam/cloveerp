#!/usr/bin/env bash
#
# supabase/ci/fleet_export.sh, rehearsed with no database, no bucket and no
# key.
#
# An export is what a client leaving takes with it, and it runs for real only
# against a paying client's database: one that dumps the wrong database, puts
# a readable copy in a bucket, prints a connection string or an access key,
# or says it was made when it was not, is learned then. So every build runs
# it here first, against a psql that answers from files, a pg_dump, an age
# and an aws that keep what they are given, all writing what they were asked
# in one log, in order: what it refuses before reading anything (the bucket
# and the key not made yet above all), that it dumps the client's own
# database and its sign-ins and nothing else, that only the sealed copy
# leaves, that the store is asked for it again before the register is told,
# that each failure says what was and was not done, and that nothing secret
# is printed. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet_export.sh"
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
CP="postgresql://postgres.${PROD}:control-plane-password@pooler.example:5432/postgres"
ACME_URL="postgresql://postgres.${ACME}:acme-database-password@pooler.example:5432/postgres"
RECIPIENT=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
ENDPOINT=https://rehearsalaccount0123.r2.cloudflarestorage.com
BUCKET=cloveerp-offsite-rehearsal
KEY_ID=rehearsal-access-key-id-4711
SECRET=rehearsal-secret-access-key-0815
OBJECT=exports/acme/20261012T040506Z.dump.age
export FAKE_DIR="$work/fake"

BASE_ENV=(FAKE_CP_URL="$CP" CLOVEERP_LIVE_DATABASE_URL="$CP" PSQL="$work/bin/psql" PG_DUMP="$work/bin/pg_dump"
          AGE="$work/bin/age" AWS="$work/bin/aws" PRODUCTION_REF="$PROD" DEMO_REF="$DEMO"
          CLOVEERP_BACKUP_AGE_RECIPIENT="$RECIPIENT" CLOVEERP_BACKUP_S3_ENDPOINT="$ENDPOINT"
          CLOVEERP_BACKUP_S3_BUCKET="$BUCKET" CLOVEERP_BACKUP_S3_KEY_ID="$KEY_ID" CLOVEERP_BACKUP_S3_SECRET="$SECRET"
          FAKE_EXPECT_KEY_ID="$KEY_ID" FAKE_EXPECT_SECRET="$SECRET" OFFSITE_NOW=2026-10-12T04:05:06Z
          TMPDIR="$work/tmp")

# The register and the client as they are on a good day.
seed() {
  printf '%s' "$ACME_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
  answer cp cp-ready true
  answer cp cp-row "live|${ACME}"
  answer cp cp-refs "${BETA}"
  answer cp cp-record "recorded"
  answer "$ACME" client-kind client
}

CASES=0
FAILED=0
# run <name> [@db:tag=answer | -vault | %vault=<url> | VAR=value ...] -- <arguments>
run() {
  CURRENT="$1"; shift
  local vars=() a db rest
  rm -rf "$FAKE_DIR" "$work/tmp"; mkdir -p "$FAKE_DIR/vault" "$work/tmp"
  seed
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in
      @*) a="${1#@}"; db="${a%%:*}"; rest="${a#*:}"; answer "$db" "${rest%%=*}" "${rest#*=}" ;;
      -vault) rm -f "$FAKE_DIR/vault/"* ;;
      %vault=*) printf '%s' "${1#%vault=}" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url" ;;
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
    sed 's/^/       > /' "$FAKE_DIR/order.log" 2> /dev/null | head -n 30
  fi
}
order() { tr '\n' ';' 2> /dev/null < "$FAKE_DIR/order.log"; }
events() { cat "$FAKE_DIR/events" 2> /dev/null; }
stored() { find "$FAKE_DIR/s3" -type f 2> /dev/null | sed "s|^$FAKE_DIR/s3/||" | LC_ALL=C sort | tr '\n' ' '; }
untouched() { [[ ! -s "$FAKE_DIR/order.log" ]]; }
nothing_left() { [[ -z "$(ls -A "$work/tmp" 2> /dev/null)" ]]; }
# tvar <tag> <name>: what the last statement of that tag was given.
tvar() {
  local n
  n=$(awk -v t="$1" '$3 == t { n = $1 } END { print n }' "$FAKE_DIR/psql.log" 2> /dev/null)
  if [[ -n "$n" ]]; then sed -n "s/^$2=//p" "$FAKE_DIR/vars.$n" | head -n 1; fi
}
sha_of() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d " " -f 1; else shasum -a 256 "$1" | cut -d " " -f 1; fi
}

# 1. Nowhere to put it yet: said, and nothing done
run "no key yet" CLOVEERP_BACKUP_AGE_RECIPIENT= -- acme
check '[[ $status -eq 1 && "$out" == *"acme cannot be exported until the owner has made somewhere to put it: an age key pair"*"CLOVEERP_BACKUP_AGE_RECIPIENT"*"Nothing was dumped, uploaded or recorded."* ]] && untouched' \
      "refused, naming the key the owner must make; nothing read, dumped, uploaded or recorded"
run "no bucket yet" CLOVEERP_BACKUP_S3_ENDPOINT= CLOVEERP_BACKUP_S3_BUCKET= -- acme
check '[[ $status -eq 1 && "$out" == *"a bucket in an S3-compatible store (Cloudflare R2 works)"*"CLOVEERP_BACKUP_S3_ENDPOINT"*"CLOVEERP_BACKUP_S3_BUCKET"* && "$out" != *"age key pair"* ]] && untouched' \
      "refused, naming the bucket and nothing that is there"
run "nothing made yet, on a runner" GITHUB_ACTIONS=true CLOVEERP_BACKUP_AGE_RECIPIENT= CLOVEERP_BACKUP_S3_ENDPOINT= CLOVEERP_BACKUP_S3_BUCKET= CLOVEERP_BACKUP_S3_KEY_ID= CLOVEERP_BACKUP_S3_SECRET= -- acme
check '[[ $status -eq 1 && "$(printf "%s\n" "$out" | grep -c "^::error::acme cannot be exported")" == 1 && "$out" == *"; and a bucket"*"; and an access key"* ]] && untouched' \
      "one plain error naming the key, the bucket and the access key"
run "a key that is not one" CLOVEERP_BACKUP_AGE_RECIPIENT=ssh-rsa-AAAA -- acme
check '[[ $status -eq 1 && "$out" == *"which is not an age public key"* ]] && untouched' "refused"
run "an endpoint that is not one" CLOVEERP_BACKUP_S3_ENDPOINT=r2.example/bucket -- acme
check '[[ $status -eq 1 && "$out" == *"not an https address of a host alone"* ]] && untouched' "refused"
run "only asked whether it is set" CHECK_ONLY=yes -- acme
check '[[ $status -eq 0 && "$out" == *"the bucket and the key are set"* ]] && untouched' "says so, and does nothing"
run "only asked, and it is not" CHECK_ONLY=yes CLOVEERP_BACKUP_S3_SECRET= -- acme
check '[[ $status -eq 1 && "$out" == *"CLOVEERP_BACKUP_S3_SECRET"* ]] && untouched' "the same error"

# 2. Refused before anything is dumped
run "a code that is not one" -- "Acme!"
check '[[ $status -eq 2 && "$out" == *"is not a client"* ]] && untouched' "refused"
run "a control plane without the routine" @cp:cp-ready=false -- acme
check '[[ $status -eq 1 && "$out" == *"cannot record an export yet (20261012020000"* && "$(order)" == "psql cp cp-ready;" ]]' "refused before reading the client"
run "a client the register does not have" @cp:cp-row= -- zeta
check '[[ $status -eq 1 && "$out" == *"zeta is not in the control plane"* && "$(order)" != *"pg_dump"* ]]' "refused"
run "a client still being built" "@cp:cp-row=building|${ACME}" -- acme
check '[[ $status -eq 1 && "$out" == *"acme is building: only a client whose database is up"* && "$(order)" != *"vault-get"* ]]' "refused before its connection is read"
run "a retired client" "@cp:cp-row=retired|${ACME}" -- acme
check '[[ $status -eq 1 && "$out" == *"acme is retired"* && "$(order)" != *"pg_dump"* ]]' "refused"
run "no connection in the vault" -vault -- acme
check '[[ $status -eq 1 && "$out" == *"has no cloveerp:deployment:${ACME}:db_url"* && "$(order)" != *"pg_dump"* ]]' "refused, nothing dumped"
check '[[ "$(events)" == "acme|export|failed|export not made: the control plane"*"(fleet_export.yml)" ]]' "and the client's row says so"
run "a connection that names another project" "%vault=postgresql://postgres.${ACME}:pw@pooler.example:5432/postgres?also=${BETA}" -- acme
check '[[ $status -eq 1 && "$out" == *"names another deployment'"'"'s project (${BETA})"* && "$(order)" != *"pg_dump"* ]]' "refused, nothing dumped"
run "a database that is not a client's" "@${ACME}:client-kind=demonstration" -- acme
check '[[ $status -eq 1 && "$out" == *"says it is the demonstration deployment"* && "$(order)" != *"pg_dump"* ]]' "refused, nothing dumped"

# 3. Exported
run "a live client exported" -- acme
check '[[ $status -eq 0 && "$out" == *"acme: exported as ${OBJECT}"* ]]' "says so"
check '[[ "$(order)" == "psql cp cp-ready;psql cp cp-row;psql cp cp-refs;psql cp vault-get cloveerp:deployment:${ACME}:db_url;psql ${ACME} client-kind;pg_dump ${ACME} schemas;pg_dump ${ACME} auth.users data-only;age ${RECIPIENT};aws cp ${OBJECT};aws head ${OBJECT};psql cp cp-record;" ]]' \
      "the register, the client's own connection, its schemas and its sign-ins, sealed, uploaded, asked for again, then recorded"
check '[[ "$(stored)" == "${BUCKET}/${OBJECT} " ]]' "one object, under exports/<code>/<UTC time>.dump.age, in the bucket named"
check '[[ "$(sed -n 1p "$FAKE_DIR/s3/${BUCKET}/${OBJECT}")" == "age-encryption.org/v1" && "$(sed -n 2p "$FAKE_DIR/s3/${BUCKET}/${OBJECT}")" == "-> X25519 ${RECIPIENT}" ]]' "sealed to the owner's key"
check '[[ "$(cat "$FAKE_DIR/age.members.1")" == "auth_users.dump manifest.json product.dump " ]]' "holding the two dumps and the manifest"
check '[[ "$(cut -d"|" -f1-4 "$FAKE_DIR/pg_dump.log" | tr "\n" ";")" == "${ACME}|schemas|erp erp_ref erp_meta erp_ai erp_test erp_ingress public supabase_migrations|no;${ACME}|auth.users||yes;" ]]' \
      "the schemas restore_drill.yml dumps, and auth.users as data alone"
check '[[ "$(jq -r "[.database, .project_ref, (.files | keys | join(\",\")), .files[\"auth_users.dump\"].data_only] | join(\" \")" "$FAKE_DIR/age.manifest.1")" == "acme ${ACME} auth_users.dump,product.dump true" ]]' \
      "the manifest says what, from where"
check '[[ "$(tvar cp-record code)" == acme && "$(tvar cp-record object)" == "$OBJECT" && "$(tvar cp-record bytes)" == "$(wc -c < "$FAKE_DIR/s3/${BUCKET}/${OBJECT}" | tr -d " ")" ]]' \
      "the register is told the object and its size"
check '[[ "$(tvar cp-record sha)" == "$(sha_of "$FAKE_DIR/s3/${BUCKET}/${OBJECT}")" ]]' "and the sha256 of what is in the bucket"
check '[[ "$(sort -u "$FAKE_DIR/aws.env")" == "${ENDPOINT}|auto|when_required" ]]' "the endpoint given, region auto, checksums only where asked for"
check '[[ "$(cat "$work/summary")" == *"## acme exported"*"age -d -i"* ]] && nothing_left' "the summary says how to read it, and no dump is left on the runner"
run "a suspended client exported" "@cp:cp-row=suspended|${ACME}" -- acme
check '[[ $status -eq 0 && "$(stored)" == "${BUCKET}/${OBJECT} " ]]' "exported"
run "a retiring client exported" "@cp:cp-row=retiring|${ACME}" -- acme
check '[[ $status -eq 0 && "$(stored)" == "${BUCKET}/${OBJECT} " ]]' "exported"

# 4. An export that fails says what was done
run "a database that will not be dumped" "FAKE_PG_DUMP_FAIL=${ACME} schemas" -- acme
check '[[ $status -eq 1 && "$out" == *"the product'"'"'s schemas could not be dumped"* && "$out" != *"acme-database-password"* && -z "$(stored)" ]]' \
      "red, the connection taken out of the error, nothing uploaded"
check '[[ "$(order)" != *"cp-record"* && "$(events)" == "acme|export|failed|export not made: the product"* ]] && nothing_left' "nothing recorded but the failure on its row"
run "sign-ins that will not be dumped" "FAKE_PG_DUMP_FAIL=${ACME} auth.users" -- acme
check '[[ $status -eq 1 && "$out" == *"the sign-ins (auth.users) could not be dumped"* && -z "$(stored)" ]] && nothing_left' "red, nothing uploaded, nothing left"
run "a copy that will not seal" FAKE_AGE_FAIL=yes -- acme
check '[[ $status -eq 1 && "$out" == *"could not be encrypted"* && -z "$(stored)" && "$(order)" != *"aws"* ]] && nothing_left' "nothing unsealed ever reaches the store"
run "a store that refuses it" FAKE_AWS_CP_FAIL=yes -- acme
check '[[ $status -eq 1 && "$out" == *"could not be uploaded as ${OBJECT}"* && "$out" != *"$KEY_ID"* && "$out" != *"$ENDPOINT"* && "$out" != *"$BUCKET"* && "$(order)" != *"cp-record"* ]]' \
      "red, the key, the endpoint and the bucket taken out of the error, not recorded"
run "a store that holds something else" FAKE_HEAD_BYTES=1 -- acme
check '[[ $status -eq 1 && "$out" == *"holds 1 bytes under ${OBJECT}"* && "$(order)" != *"cp-record"* ]]' "red, not recorded"
run "another key" FAKE_EXPECT_KEY_ID=someone-else -- acme
check '[[ $status -eq 1 && "$out" == *"could not be uploaded"* ]]' "the key given is the key used"
run "a register that will not record it" "@cp:cp-record=ERROR:  CLOVEERP_DEPLOYMENT_STATE: no" -- acme
check '[[ $status -eq 1 && "$out" == *"the copy is in the bucket as ${OBJECT}"*"the register refused to record it"* && "$(stored)" == "${BUCKET}/${OBJECT} " ]]' \
      "red, saying the copy is there and where"

# 5. Nothing secret printed
run "on a runner" GITHUB_ACTIONS=true -- acme
check '[[ $status -eq 0 ]]' "exported"
for secret in "$ACME_URL" "$KEY_ID" "$SECRET" "$ENDPOINT" "$BUCKET"; do
  CASES=$((CASES + 1))
  if [[ "$(printf "%s\n" "$out" | grep -F -- "$secret" | grep -vc "^::add-mask::")" == 0 && "$(printf "%s\n" "$out" | grep -cxF -- "::add-mask::$secret")" -ge 1 ]]; then
    echo "  ok   $CURRENT: ${secret:0:12}… masked, and printed nowhere else"
  else
    FAILED=$((FAILED + 1)); echo "  FAIL $CURRENT: ${secret:0:12}… printed unmasked, or never masked"
  fi
done
check '[[ "$(printf "%s\n" "$out" | grep -nF -- "$ACME_URL" | head -n 1 | cut -d: -f1)" -lt "$(printf "%s\n" "$out" | grep -n "^exporting" | cut -d: -f1)" ]]' \
      "the connection is masked before anything else is said about the client"
run "outside a runner" -- acme
check '[[ $status -eq 0 && "$out" != *"::add-mask::"* && "$out" != *"acme-database-password"* && "$out" != *"$SECRET"* ]]' "no mask line, and nothing secret"

echo "$CASES checks over a client's export, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
