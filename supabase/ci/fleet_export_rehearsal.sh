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
# and an aws that keep what they are given, and a project's Storage API, all
# writing what they were asked in one log, in order: what it refuses before
# reading anything (the bucket and the key not made yet above all, said on
# the client's row too), that it dumps the client's own database and its
# sign-ins and fetches every stored document of its own project and nothing
# else, that only the sealed copy leaves, that the store is asked for it
# again before the register is told, that each failure says what was and was
# not done, that the outcome the workflow settles the request with is written
# on every way out, that nothing is written on the row of a client that is
# not up (a failed step there would mark a client being built as failed),
# and that nothing secret is printed. And two of the workflow's own steps,
# run as the runner runs them: the wait for a change of database passwords
# before the export, and the last step, which tells the row only of a client
# that is up. Seconds.
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
SERVICE_KEY=sb_secret_acme_rehearsal_service_key
STORE="https://${ACME}.supabase.co"
# The control plane's clock just before the dump, and a reason for a
# suspension: the owner's words about a client's business, printed nowhere.
TAKEN=2026-10-12T04:05:07.250000Z
REASON='unpaid since August | "final" notice'
export FAKE_DIR="$work/fake"

BASE_ENV=(FAKE_CP_URL="$CP" CLOVEERP_LIVE_DATABASE_URL="$CP" PSQL="$work/bin/psql" PG_DUMP="$work/bin/pg_dump"
          AGE="$work/bin/age" AWS="$work/bin/aws" CURL="$work/bin/curl" MAPI_SLEEP="$work/bin/sleep"
          PRODUCTION_REF="$PROD" DEMO_REF="$DEMO"
          CLOVEERP_BACKUP_AGE_RECIPIENT="$RECIPIENT" CLOVEERP_BACKUP_S3_ENDPOINT="$ENDPOINT"
          CLOVEERP_BACKUP_S3_BUCKET="$BUCKET" CLOVEERP_BACKUP_S3_KEY_ID="$KEY_ID" CLOVEERP_BACKUP_S3_SECRET="$SECRET"
          FAKE_EXPECT_KEY_ID="$KEY_ID" FAKE_EXPECT_SECRET="$SECRET" OFFSITE_NOW=2026-10-12T04:05:06Z
          OUTCOME_FILE="$work/outcome" TMPDIR="$work/tmp")

# The register and the client as they are on a good day: its connection and
# its service key in the vault, and three documents in its bucket.
seed() {
  printf '%s' "$ACME_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
  printf '%s' "$SERVICE_KEY" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_service_key"
  answer cp cp-ready true
  answer cp cp-row "live|true|${ACME}|${STORE}"
  answer cp cp-refs "${BETA}"
  answer cp cp-record "recorded"
  answer cp cp-clock "$TAKEN"
  answer "$ACME" client-kind "client|true"
  answer "$ACME" client-follow '{"changed": true, "status": "suspended", "by_fleet": true}'
  answer "$ACME" client-follow-again '{"changed": false, "status": "suspended", "by_fleet": true}'
  local b="$FAKE_DIR/storage/${ACME}/document-output"
  mkdir -p "$b/invoices" "$b/orders/2026"
  printf '%%PDF-1.7 the readme' > "$b/readme.pdf"
  printf '%%PDF-1.7 invoice INV-0001' > "$b/invoices/INV-0001.pdf"
  printf '%%PDF-1.7 purchase order 7, longer' > "$b/orders/2026/PO 7.pdf"
}

CASES=0
FAILED=0
# run <name> [@db:tag=answer | -vault | %vault=<url> | VAR=value ...] -- <arguments>
run() {
  CURRENT="$1"; shift
  local vars=() a db rest
  rm -rf "$FAKE_DIR" "$work/tmp" "$work/outcome"; mkdir -p "$FAKE_DIR/vault" "$work/tmp"
  seed
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in
      @*) a="${1#@}"; db="${a%%:*}"; rest="${a#*:}"; answer "$db" "${rest%%=*}" "${rest#*=}" ;;
      -vault) rm -f "$FAKE_DIR/vault/"* ;;
      -key) rm -f "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_service_key" ;;
      %key=*) printf '%s' "${1#%key=}" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_service_key" ;;
      -bucket) rm -rf "$FAKE_DIR/storage/${ACME}/document-output" ;;
      -documents) rm -rf "$FAKE_DIR/storage/${ACME}/document-output"; mkdir -p "$FAKE_DIR/storage/${ACME}/document-output" ;;
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
# only_told: whether it is up asked of the register, nothing else read,
# nothing dumped, fetched, uploaded or recorded; the row told.
only_told() { [[ "$(order)" == "psql cp cp-row;event acme export failed;" ]]; }
nothing_left() { [[ -z "$(ls -A "$work/tmp" 2> /dev/null)" ]]; }
outcome() { sed -n 1p "$work/outcome" 2> /dev/null; }
told() { [[ "$(sed -n 2p "$work/outcome" 2> /dev/null)" == told ]]; }
members() { cat "$FAKE_DIR/age.members.1" 2> /dev/null; }
storage_calls() { grep -c 'storage/v1' "$FAKE_DIR/order.log" 2> /dev/null || true; }
# tvar <tag> <name>: what the last statement of that tag was given.
tvar() {
  local n
  n=$(awk -v t="$1" '$3 == t { n = $1 } END { print n }' "$FAKE_DIR/psql.log" 2> /dev/null)
  if [[ -n "$n" ]]; then sed -n "s/^$2=//p" "$FAKE_DIR/vars.$n" | head -n 1; fi
}
sha_of() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d " " -f 1; else shasum -a 256 "$1" | cut -d " " -f 1; fi
}


# 1. Nowhere to put it yet: said, on the row too, and nothing done
run "no key yet" CLOVEERP_BACKUP_AGE_RECIPIENT= -- acme
check '[[ $status -eq 1 && "$out" == *"acme cannot be exported until the owner has made somewhere to put it: an age key pair"*"CLOVEERP_BACKUP_AGE_RECIPIENT"*"Nothing was dumped, uploaded or recorded."* ]] && only_told' \
      "refused, naming the key the owner must make; nothing read, dumped, uploaded or recorded, and the client's row told"
check '[[ "$(events)" == "acme|export|failed|export not made: acme cannot be exported until the owner has made somewhere to put it: an age key pair"*"(fleet_export.yml)" ]]' \
      "the row says what is missing"
check '[[ "$(outcome)" == "failure: acme cannot be exported until the owner has made somewhere to put it"* ]] && told' "the outcome, for the request, and that the row was told"
run "no bucket yet" CLOVEERP_BACKUP_S3_ENDPOINT= CLOVEERP_BACKUP_S3_BUCKET= -- acme
check '[[ $status -eq 1 && "$out" == *"a bucket in an S3-compatible store (Cloudflare R2 works)"*"CLOVEERP_BACKUP_S3_ENDPOINT"*"CLOVEERP_BACKUP_S3_BUCKET"* && "$out" != *"age key pair"* ]] && only_told' \
      "refused, naming the bucket and nothing that is there"
run "nothing made yet, on a runner" GITHUB_ACTIONS=true CLOVEERP_BACKUP_AGE_RECIPIENT= CLOVEERP_BACKUP_S3_ENDPOINT= CLOVEERP_BACKUP_S3_BUCKET= CLOVEERP_BACKUP_S3_KEY_ID= CLOVEERP_BACKUP_S3_SECRET= -- acme
check '[[ $status -eq 1 && "$(printf "%s\n" "$out" | grep -c "^::error::acme cannot be exported")" == 1 && "$out" == *"; and a bucket"*"; and an access key"* ]] && only_told' \
      "one plain error naming the key, the bucket and the access key"
run "a key that is not one" CLOVEERP_BACKUP_AGE_RECIPIENT=ssh-rsa-AAAA -- acme
check '[[ $status -eq 1 && "$out" == *"which is not an age public key"* ]] && only_told' "refused"
run "an endpoint that is not one" CLOVEERP_BACKUP_S3_ENDPOINT=r2.example/bucket -- acme
check '[[ $status -eq 1 && "$out" == *"not an https address of a host alone"* ]] && only_told' "refused"
run "only asked whether it is set" CHECK_ONLY=yes -- acme
check '[[ $status -eq 0 && "$out" == *"the bucket and the key are set"* && "$(outcome)" == "success: the bucket and the key are set" && "$(order)" == "psql cp cp-row;" ]]' \
      "says so, having asked the register only whether it is up, and does nothing"
run "only asked, and it is not" CHECK_ONLY=yes CLOVEERP_BACKUP_S3_SECRET= -- acme
check '[[ $status -eq 1 && "$out" == *"CLOVEERP_BACKUP_S3_SECRET"* && "$(outcome)" == failure:* ]] && only_told && told' \
      "the same error, the row told, and the outcome for the workflow's last step"
run "not set, and no control plane to tell" CLOVEERP_LIVE_DATABASE_URL= CLOVEERP_BACKUP_S3_SECRET= -- acme
check '[[ $status -eq 1 && "$(outcome)" == failure:* ]] && untouched && ! told' "the outcome says the row was not told, so the workflow tells it"

# 2. Refused before anything is dumped
run "a code that is not one" -- "Acme!"
check '[[ $status -eq 2 && "$out" == *"is not a client"* && "$(outcome)" == "failure: '"'"'Acme!'"'"' is not a client'"'"'s code; nothing was exported" ]] && untouched && ! told' "refused, and said for the request"
run "a control plane without the routine" @cp:cp-ready=false -- acme
check '[[ $status -eq 1 && "$out" == *"cannot record an export yet (20261012030000"* && "$(order)" == "psql cp cp-row;psql cp cp-ready;event acme export failed;" ]] && told' \
      "refused before the client's connection is read; the row, of a client that is up, told"
run "a client the register does not have" @cp:cp-row= -- zeta
check '[[ $status -eq 1 && "$out" == *"zeta is not in the control plane"* && "$(order)" == "psql cp cp-row;" && -z "$(events)" ]]' "refused, nothing written"
run "a client still being built" "@cp:cp-row=building|false||" -- acme
check '[[ $status -eq 1 && "$out" == *"acme is building: only a client whose database is up"* && "$(order)" == "psql cp cp-row;" && -z "$(events)" ]] && ! told' \
      "refused before anything is written: a failed step on its row would mark its build failed"
check '[[ "$(outcome)" == "failure: acme is building: only a client whose database is up"* ]]' "the outcome, for the workflow's last step, says so"
run "a client being built, and nowhere to put it yet" CHECK_ONLY=yes CLOVEERP_BACKUP_AGE_RECIPIENT= "@cp:cp-row=building|false||" -- acme
check '[[ $status -eq 1 && "$out" == *"acme is building"* && "$out" != *"cannot be exported until the owner"* && "$(order)" == "psql cp cp-row;" && -z "$(events)" ]] && ! told' \
      "a hand run of the workflow's first step leaves a build alone too"
run "a client asked for, not yet built" "@cp:cp-row=requested|false||" -- acme
check '[[ $status -eq 1 && "$out" == *"acme is requested"* && -z "$(events)" ]]' "refused, nothing written"
run "a retiring client never built" "@cp:cp-row=retiring|false||" -- acme
check '[[ $status -eq 1 && "$out" == *"acme is retiring and was never built, so there is no database to export"* && "$(order)" == "psql cp cp-row;" && -z "$(events)" ]]' \
      "refused, nothing written"
run "a retired client" "@cp:cp-row=retired|true|${ACME}|" -- acme
check '[[ $status -eq 1 && "$out" == *"acme is retired"* && "$(order)" != *"pg_dump"* && -z "$(events)" ]]' "refused, nothing written"
run "a register that cannot be read" "@cp:cp-row=ERROR:  could not connect to server" CLOVEERP_BACKUP_S3_SECRET= -- acme
check '[[ $status -eq 1 && "$out" == *"the register could not be read (could not connect to server)"* && "$out" != *"cannot be exported until the owner"* && -z "$(events)" ]] && ! told' \
      "red, and nothing written where its status is not known"
run "no connection in the vault" -vault -- acme
check '[[ $status -eq 1 && "$out" == *"has no cloveerp:deployment:${ACME}:db_url"* && "$(order)" != *"pg_dump"* ]]' "refused, nothing dumped"
check '[[ "$(events)" == "acme|export|failed|export not made: the control plane"*"(fleet_export.yml)" ]] && told' "and the client's row says so"
run "a connection that names another project" "%vault=postgresql://postgres.${ACME}:pw@pooler.example:5432/postgres?also=${BETA}" -- acme
check '[[ $status -eq 1 && "$out" == *"names another deployment'"'"'s project (${BETA})"* && "$(order)" != *"pg_dump"* ]]' "refused, nothing dumped"
run "a database that is not a client's" "@${ACME}:client-kind=demonstration" -- acme
check '[[ $status -eq 1 && "$out" == *"says it is the demonstration deployment"* && "$(order)" != *"pg_dump"* ]]' "refused, nothing dumped"
run "no service key in the vault" -key -- acme
check '[[ $status -eq 1 && "$out" == *"has no cloveerp:deployment:${ACME}:service_key, so its stored documents (document-output) cannot be fetched"* && "$(order)" != *"pg_dump"* && "$(storage_calls)" == 0 ]]' \
      "refused before anything is dumped: a copy without its documents is not the business's copy"
run "an API address that is not its project's" "@cp:cp-row=live|true|${ACME}|https://${ACME}.supabase.co.example.net" -- acme
check '[[ $status -eq 1 && "$out" == *"is not its project'"'"'s, so its service key would not be sent there"* && "$(order)" != *"vault-get"* && "$(storage_calls)" == 0 ]]' \
      "refused before the key is even read"

# 3. Exported
run "a live client exported" -- acme
check '[[ $status -eq 0 && "$out" == *"acme: exported as ${OBJECT}"*"with 3 stored document(s)"* ]]' "says so"
check '[[ "$(order)" == "psql cp cp-row;psql cp cp-ready;psql cp cp-refs;psql cp vault-get cloveerp:deployment:${ACME}:db_url;psql cp vault-get cloveerp:deployment:${ACME}:service_key;psql ${ACME} client-kind;psql cp cp-clock;pg_dump ${ACME} schemas;pg_dump ${ACME} auth.users data-only;POST /storage/v1/object/list/document-output;GET /storage/v1/object/document-output/readme.pdf;POST /storage/v1/object/list/document-output;GET /storage/v1/object/document-output/invoices/INV-0001.pdf;POST /storage/v1/object/list/document-output;POST /storage/v1/object/list/document-output;GET /storage/v1/object/document-output/orders/2026/PO%207.pdf;age ${RECIPIENT};aws cp ${OBJECT};aws head ${OBJECT};psql cp cp-record;" ]]' \
      "the register, the client's own connection and key, its schemas, its sign-ins and every stored document, folder by folder, sealed, uploaded, asked for again, then recorded"
check '[[ "$(cut -d"|" -f1-3 "$FAKE_DIR/storage.lists" | tr "\n" ";")" == "${ACME}|document-output|;${ACME}|document-output|invoices/;${ACME}|document-output|orders/;${ACME}|document-output|orders/2026/;" ]]' \
      "its own project's bucket, each folder listed"
check '[[ "$(cat "$FAKE_DIR/headers.1")" == *"apikey: ${SERVICE_KEY}"* && "$(cat "$FAKE_DIR/headers.1")" != *"Authorization"* ]]' "a new-format service key as apikey only, never as a bearer"
check '[[ "$(stored)" == "${BUCKET}/${OBJECT} " ]]' "one object, under exports/<code>/<UTC time>.dump.age, in the bucket named"
check '[[ "$(sed -n 1p "$FAKE_DIR/s3/${BUCKET}/${OBJECT}")" == "age-encryption.org/v1" && "$(sed -n 2p "$FAKE_DIR/s3/${BUCKET}/${OBJECT}")" == "-> X25519 ${RECIPIENT}" ]]' "sealed to the owner's key"
check '[[ "$(members)" == "auth_users.dump manifest.json product.dump storage/"* && "$(members)" == *"storage/document-output/readme.pdf "* && "$(members)" == *"storage/document-output/invoices/INV-0001.pdf "* && "$(members)" == *"storage/document-output/orders/2026/PO 7.pdf "* ]]' \
      "holding the two dumps, the manifest and every stored document under its own name"
check '[[ "$(cut -d"|" -f1-4 "$FAKE_DIR/pg_dump.log" | tr "\n" ";")" == "${ACME}|schemas|erp erp_ref erp_meta erp_ai erp_test erp_ingress public supabase_migrations|no;${ACME}|auth.users||yes;" ]]' \
      "the schemas restore_drill.yml dumps, and auth.users as data alone"
check '[[ "$(jq -r "[.database, .project_ref, (.files | keys | join(\",\")), .files[\"auth_users.dump\"].data_only] | join(\" \")" "$FAKE_DIR/age.manifest.1")" == "acme ${ACME} auth_users.dump,product.dump true" ]]' \
      "the manifest says what, from where"
check '[[ "$(jq -r "[.storage.bucket, .storage.objects, .storage.bytes, (.storage.files | map(.name) | join(\",\"))] | join(\" \")" "$FAKE_DIR/age.manifest.1")" == "document-output 3 $(( $(wc -c < "$FAKE_DIR/storage/${ACME}/document-output/readme.pdf") + $(wc -c < "$FAKE_DIR/storage/${ACME}/document-output/invoices/INV-0001.pdf") + $(wc -c < "$FAKE_DIR/storage/${ACME}/document-output/orders/2026/PO 7.pdf") )) readme.pdf,invoices/INV-0001.pdf,orders/2026/PO 7.pdf" ]]' \
      "and how many documents, how many bytes, and each by name"
check '[[ "$(jq -r ".storage.files[1].sha256" "$FAKE_DIR/age.manifest.1")" == "$(sha_of "$FAKE_DIR/storage/${ACME}/document-output/invoices/INV-0001.pdf")" ]]' "with each one's sha256"
check '[[ "$(tvar cp-record code)" == acme && "$(tvar cp-record object)" == "$OBJECT" && "$(tvar cp-record bytes)" == "$(wc -c < "$FAKE_DIR/s3/${BUCKET}/${OBJECT}" | tr -d " ")" ]]' \
      "the register is told the object and its size"
check '[[ "$(tvar cp-record sha)" == "$(sha_of "$FAKE_DIR/s3/${BUCKET}/${OBJECT}")" ]]' "and the sha256 of what is in the bucket"
check '[[ "$(tvar cp-record taken_at)" == "$TAKEN" && "$(tvar cp-record stopped)" == false && "$(order)" != *"client-follow"* ]]' \
      "and when it was taken, by the control plane's clock just before the dump; a client the register does not have suspended is not stopped, and recorded so"
check '[[ "$(sed -n "/-- fleet: cp-record/,\$p" "$FAKE_DIR/sql.$(awk "\$3 == \"cp-record\" { print \$1 }" "$FAKE_DIR/psql.log")")" == *":'"'"'taken_at'"'"'::timestamptz, :'"'"'stopped'"'"'::boolean)"* && "$(sed -n "/-- fleet: cp-clock/,\$p" "$FAKE_DIR/sql.$(awk "\$3 == \"cp-clock\" { print \$1 }" "$FAKE_DIR/psql.log")")" == *"clock_timestamp()"* ]]' \
      "recorded through the routine of six arguments, the moment from the clock, not the transaction"
check '[[ "$(sort -u "$FAKE_DIR/aws.env")" == "${ENDPOINT}|auto|when_required" ]]' "the endpoint given, region auto, checksums only where asked for"
check '[[ "$(cat "$work/summary")" == *"## acme exported"*"3 stored document(s)"*"age -d -i"* ]] && nothing_left' "the summary says how to read it, and no dump or document is left on the runner"
check '[[ "$(outcome)" == "success: acme exported as ${OBJECT} ("*"3 stored document(s)"* ]] && told' "the outcome, for the request; the register's own record is the step on the row"
check '[[ "$(sed -n "/-- fleet: client-kind/,\$p" "$FAKE_DIR/sql.$(awk "\$3 == \"client-kind\" { print \$1 }" "$FAKE_DIR/psql.log")")" == *"set statement_timeout = :'"'"'timeout'"'"';"* && "$(tvar client-kind timeout)" == 30s ]]' \
      "the statement on the client has its limit"
run "a suspended client exported" "@cp:cp-row=suspended|true|${ACME}|${STORE}" -- acme
check '[[ $status -eq 0 && "$(stored)" == "${BUCKET}/${OBJECT} " ]]' "exported"
run "a retiring client exported" "@cp:cp-row=retiring|true|${ACME}|" -- acme
check '[[ $status -eq 0 && "$(stored)" == "${BUCKET}/${OBJECT} " && "$(cut -d"|" -f1 "$FAKE_DIR/storage.lists" | sort -u)" == "$ACME" ]]' "exported; no API address in the register is its project's own"
run "a client with no documents yet" -documents -- acme
check '[[ $status -eq 0 && "$(members)" == "auth_users.dump manifest.json product.dump storage/ storage/document-output/ " && "$(jq -r .storage.objects "$FAKE_DIR/age.manifest.1")" == 0 ]]' \
      "exported, with an empty folder for them"
run "a bucket listed a page at a time" OFFSITE_PAGE_SIZE=2 -- acme
check '[[ $status -eq 0 && "$(cut -d"|" -f3,5 "$FAKE_DIR/storage.lists" | tr "\n" ";")" == "|0;|2;invoices/|0;orders/|0;orders/2026/|0;" && "$(jq -r .storage.objects "$FAKE_DIR/age.manifest.1")" == 3 ]]' \
      "a full page asks for the next, and nothing is missed"
run "a legacy service key" "%key=eyJhbGciOiJIUzI1NiJ9.rehearsal.service-role" -- acme
check '[[ $status -eq 0 && "$(cat "$FAKE_DIR/headers.1")" == *"Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.rehearsal.service-role"* ]]' "a JWT goes as a bearer too"
run "a busy Storage" FAKE_STORAGE_LIST_STATUSES=503,200 -- acme
check '[[ $status -eq 0 && "$(order)" == *"POST /storage/v1/object/list/document-output;sleep 5;POST /storage/v1/object/list/document-output;"* ]]' "asked again after a pause, as mapi asks"
run "a document deleted between the listing and the fetch" FAKE_STORAGE_GONE=invoices/INV-0001.pdf -- acme
check '[[ $status -eq 0 && "$(jq -r "[.storage.objects, (.storage.gone_since_listed | join(\",\"))] | join(\" \")" "$FAKE_DIR/age.manifest.1")" == "2 invoices/INV-0001.pdf" && "$(members)" != *"INV-0001"* ]]' \
      "exported without it, and the manifest names it as gone (the application sweeps expired previews)"
check '[[ "$(outcome)" == *"(1 deleted between listing and fetching, named in the manifest)"* ]]' "and says so"

# 3b. A client the register has suspended: its organisation suspended on its
# own database first, then dumped, and recorded as taken after its service
# stopped; when that cannot be made sure of, copied all the same and recorded
# as taken while it was served, and said. The reason printed nowhere.
REASON_JSON=$(jq -cn --arg r "$REASON" '$r')
SUSPENDED_ROW="@cp:cp-row=suspended|true|${ACME}|${STORE}|${REASON_JSON}"
# not_said: the reason in nothing the run printed, summed up or wrote.
not_said() { [[ "$out $(cat "$work/summary") $(cat "$work/outcome") $(events)" != *"unpaid since August"* ]]; }
run "a suspended client, its organisation suspended first" "$SUSPENDED_ROW" -- acme
check '[[ $status -eq 0 && "$(order)" == *"psql ${ACME} client-kind;psql ${ACME} client-follow;event acme note note;psql cp cp-clock;pg_dump ${ACME} schemas;"* ]]' \
      "its organisation suspended on its own database, then the clock read, then the dump"
check '[[ "$(tvar client-follow reason)" == "$REASON" && "$(sed -n "/-- fleet: client-follow/,\$p" "$FAKE_DIR/sql.$(awk "\$3 == \"client-follow\" { print \$1 }" "$FAKE_DIR/psql.log")")" == *"set statement_timeout"*"erp_meta.follow_deployment_status(true, nullif(:'"'"'reason'"'"', '"'"''"'"'))"* ]]' \
      "through the status sync's own routine, given the register's reason whole, under a limit"
check '[[ "$(tvar cp-record stopped)" == true && "$(tvar cp-record taken_at)" == "$TAKEN" && "$(outcome)" == "success: acme exported as ${OBJECT} ("*"; taken at ${TAKEN}, after its service was stopped" ]]' \
      "recorded as taken after its service was stopped, when its dump began"
check '[[ "$(events)" == "acme|note|note|status: its organisation suspended on its own database, as the register says, before its export (fleet_export.yml)" ]] && not_said' \
      "its row says its organisation was suspended; the reason printed, summed up and written nowhere"
check '[[ "$(order)" == *"pg_dump ${ACME} schemas;"*"psql ${ACME} client-follow-again;"* && "$(order)" != *"client-follow-again;"*"pg_dump"* ]]' \
      "asked once more, after the copy, whether its organisation stayed suspended"
run "a suspended client whose suspension was lifted while it was copied" "$SUSPENDED_ROW" \
    "@${ACME}:client-follow-again={\"changed\": true, \"status\": \"suspended\", \"by_fleet\": true}" -- acme
check '[[ $status -eq 0 && "$(tvar cp-record stopped)" == false && "$(tvar cp-record taken_at)" == "$TAKEN" && "$(stored)" == "${BUCKET}/${OBJECT} " ]] && not_said' \
      "copied all the same, and recorded as taken while it was still served"
check '[[ "$out" == *"acme: its organisation was not still suspended once its data had been copied"*"recorded as taken while it was still served"* && "$(outcome)" == *"so it is not the last copy that retiring it waits for" ]]' \
      "the run and the outcome say why it does not count as the last copy"
run "a suspended client whose suspension cannot be confirmed after the copy" "$SUSPENDED_ROW" GITHUB_ACTIONS=true \
    "@${ACME}:client-follow-again=ERROR:  could not connect: unpaid since August | \"final\" notice" -- acme
check '[[ $status -eq 0 && "$(tvar cp-record stopped)" == false && "$out" == *"::warning::acme: whether its organisation stayed suspended while it was copied could not be confirmed"* ]] && not_said' \
      "not counted as stopped when it cannot be confirmed; the reason printed nowhere"
run "a retiring client whose organisation the status sync suspended already" "@cp:cp-row=retiring|true|${ACME}|${STORE}|${REASON_JSON}" \
    "@${ACME}:client-follow={\"changed\": false, \"status\": \"suspended\", \"by_fleet\": true}" -- acme
check '[[ $status -eq 0 && "$(tvar cp-record stopped)" == true && -z "$(events)" && "$(order)" == *"client-follow;psql cp cp-clock;pg_dump"* ]] && not_said' \
      "recorded as stopped; nothing changed, so nothing written on its row"
run "a suspended client suspended on its own console" "$SUSPENDED_ROW" "@${ACME}:client-follow={\"changed\": false, \"status\": \"suspended\", \"by_fleet\": false}" -- acme
check '[[ $status -eq 0 && "$(tvar cp-record stopped)" == true ]]' "stopped all the same: nobody can change its data"
run "a suspended client with no organisation yet" "$SUSPENDED_ROW" "@${ACME}:client-follow={\"changed\": false, \"status\": null, \"by_fleet\": false}" -- acme
check '[[ $status -eq 0 && "$(tvar cp-record stopped)" == true && "$out" == *"acme has no organisation yet"* ]] && not_said' "nothing can change its data: stopped"
run "a suspended client whose routine fails" "$SUSPENDED_ROW" "@${ACME}:client-follow=ERROR:  CLOVEERP_CLIENT_HOLDS_ONE_ORGANISATION: this deployment holds acme, acme-two" -- acme
check '[[ $status -eq 0 && "$(tvar cp-record stopped)" == false && "$(tvar cp-record taken_at)" == "$TAKEN" && "$(stored)" == "${BUCKET}/${OBJECT} " ]]' \
      "copied all the same, and recorded as taken while it was still served"
check '[[ "$out" == *"acme: its organisation could not be suspended on its own database (CLOVEERP_CLIENT_HOLDS_ONE_ORGANISATION"*"recorded as taken while it was still served"* && "$(outcome)" == *"while it was still served (its organisation could not be suspended on its own database"*"so it is not the last copy that retiring it waits for" ]] && not_said' \
      "the run and the outcome say why it does not count as the last copy"
run "a suspended client whose routine fails, saying the reason" "$SUSPENDED_ROW" GITHUB_ACTIONS=true "@${ACME}:client-follow=ERROR:  no organisation follows: unpaid since August | \"final\" notice" -- acme
check '[[ $status -eq 0 && "$(tvar cp-record stopped)" == false && "$out" == *"::warning::acme: its organisation could not be suspended on its own database (no organisation follows: [hidden])"* ]] && not_said' \
      "the reason taken out of what the database said"
run "a suspended client not yet released the routine" "$SUSPENDED_ROW" "@${ACME}:client-kind=client|false" -- acme
check '[[ $status -eq 0 && "$(order)" != *"client-follow"* && "$(tvar cp-record stopped)" == false && "$out" == *"has not yet been released the routine that suspends its organisation"* ]] && not_said' \
      "not asked of a database that cannot answer; copied, recorded as not stopped, and said"
run "a suspended client whose organisation is in another state" "$SUSPENDED_ROW" "@${ACME}:client-follow={\"changed\": false, \"status\": \"closing\", \"by_fleet\": false}" -- acme
check '[[ $status -eq 0 && "$(tvar cp-record stopped)" == false && "$(outcome)" == *"its organisation is closing on its own database, not suspended"* ]]' "not stopped, and said"
run "a suspended client whose database answers something else" "$SUSPENDED_ROW" "@${ACME}:client-follow=done" -- acme
check '[[ $status -eq 0 && "$(tvar cp-record stopped)" == false ]]' "not taken as stopped"
run "a clock that cannot be read" "@cp:cp-clock=ERROR:  canceling statement due to statement timeout" -- acme
check '[[ $status -eq 1 && "$out" == *"the control plane'"'"'s clock could not be read (canceling statement due to statement timeout)"* && "$(order)" != *"pg_dump"* && -z "$(stored)" ]] && told' \
      "red before anything is dumped, and the row told"
run "a clock that answers something else" "@cp:cp-clock=soon" -- acme
check '[[ $status -eq 1 && "$out" == *"answered '"'"'soon'"'"', which is not a time"* && "$(order)" != *"pg_dump"* ]]' "red before anything is dumped"

# 4. An export that fails says what was done
run "a database that will not be dumped" "FAKE_PG_DUMP_FAIL=${ACME} schemas" -- acme
check '[[ $status -eq 1 && "$out" == *"the product'"'"'s schemas could not be dumped"* && "$out" != *"acme-database-password"* && -z "$(stored)" ]]' \
      "red, the connection taken out of the error, nothing uploaded"
check '[[ "$(order)" != *"cp-record"* && "$(events)" == "acme|export|failed|export not made: the product"* ]] && nothing_left' "nothing recorded but the failure on its row"
run "sign-ins that will not be dumped" "FAKE_PG_DUMP_FAIL=${ACME} auth.users" -- acme
check '[[ $status -eq 1 && "$out" == *"the sign-ins (auth.users) could not be dumped"* && -z "$(stored)" ]] && nothing_left' "red, nothing uploaded, nothing left"
run "a bucket that is not there" -bucket -- acme
check '[[ $status -eq 1 && "$out" == *"its stored documents (document-output) could not be listed (Storage answered 400: "*"Bucket not found"* && -z "$(stored)" && "$(order)" != *"age ${RECIPIENT}"* && "$(order)" != *"cp-record"* ]] && nothing_left' \
      "red: no copy without its documents, nothing sealed, uploaded or recorded"
check '[[ "$(events)" == "acme|export|failed|export not made: its stored documents"* && "$(outcome)" == "failure: its stored documents"* ]]' "the row and the outcome say so"
run "a document that will not come" FAKE_STORAGE_FETCH_STATUSES=200,403 -- acme
check '[[ $status -eq 1 && "$out" == *"the stored document invoices/INV-0001.pdf could not be fetched from document-output (Storage answered 403"* && -z "$(stored)" ]] && nothing_left' \
      "red, naming the document; nothing uploaded, nothing left"
check '[[ "$out" != *"$SERVICE_KEY"* && "$(events)" != *"$SERVICE_KEY"* ]]' "the service key in no error"
run "a Storage that stays busy" FAKE_STORAGE_LIST_STATUSES=503 MAPI_ATTEMPTS=3 -- acme
check '[[ $status -eq 1 && "$out" == *"could not be listed (Storage answered 503"* && "$(grep -c "^sleep" "$FAKE_DIR/order.log")" == 2 ]]' "given up after the attempts, red"
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
check '[[ "$(outcome)" == "failure: the copy is in the bucket as ${OBJECT}"* ]]' "and the outcome the same"

# 4b. The workflow's own steps, as the runner runs them
WF="$HERE/../../.github/workflows/fleet_export.yml"
ROTATION_STEP="Change the database passwords, one client at a time"
# step <name> [VAR=value ...]: that step of fleet_export.yml, run from the
# repository's root against the stand-ins (psql and gh on the PATH).
step() {
  local name="$1" script
  shift
  script=$(workflow_step "$WF" "$name")
  if [[ -z "$script" ]]; then out="fleet_export.yml has no step '${name}'"; status=99; return; fi
  out=$(cd "$HERE/../.." && env -u GITHUB_ACTIONS PATH="$work/bin:$PATH" FAKE_CP_URL="$CP" CLOVEERP_LIVE_DATABASE_URL="$CP" \
          GH_REPO=cloveerp/rehearsal GITHUB_RUN_ID=4242 FLEET_SLEEP="$work/bin/sleep" OUTCOME_FILE="$work/outcome" \
          CODE=acme REQUEST= JOB_STATUS=failure "$@" bash -c "$script" 2>&1)
  status=$?
}
fresh() { CURRENT="$1"; rm -rf "$FAKE_DIR" "$work/outcome"; mkdir -p "$FAKE_DIR/vault"; }
fresh "the steps before the export"
CASES=$((CASES + 1))
if [[ "$(sed -n 's/^      - name: //p' "$WF" | tr '\n' ';')" == *"Install the client tools of the live major version, and age;No database password is being changed;No release is replaying into it;Export;The request settled, and the row told;" ]]; then
  echo "  ok   $CURRENT: the wait for a new password, then the wait for a release, then the export: nothing between the release's wait and the dump"
else
  FAILED=$((FAILED + 1)); echo "  FAIL $CURRENT: the steps are not in that order"
fi
fresh "a change of database passwords under way"
gh_run fleet_secrets.yml 300
gh_job 300 "rotate_db_password for all" in_progress "${ROTATION_STEP}=in_progress" "Change them, one client at a time=queued"
step "No database password is being changed"
check '[[ $status -eq 1 && "$(grep -c "^sleep 60$" "$FAKE_DIR/order.log")" == 60 && "$out" == *"::error::a change of database passwords is still under way after an hour"* ]]' \
      "waited out, asked every minute for an hour, then red"
check '[[ "$(outcome)" == "failure: a change of database passwords was still under way after an hour, so acme was not exported; ask for the export again once it has finished" ]]' \
      "and the outcome the request is settled with says so"
fresh "a change of database passwords begun after this export"
gh_run fleet_secrets.yml 5000
gh_job 5000 "rotate_db_password for all" in_progress "No rename, and for a password no export or backup, is under way=in_progress" "${ROTATION_STEP}=queued"
step "No database password is being changed"
check '[[ $status -eq 0 && "$(grep -c "^sleep" "$FAKE_DIR/order.log")" == 0 && "$out" == *"no database password is being changed"* ]]' \
      "not waited for: it waits for this export, so the two never both wait"
fresh "a change of database passwords begun before this export, not yet at its step"
gh_run fleet_secrets.yml 300 queued
step "No database password is being changed"
check '[[ $status -eq 1 && "$out" == *"run 300: began before this run, and has \"${ROTATION_STEP}\" still to do"* ]]' "waited for: it is ahead in the queue"
fresh "a change of other secrets under way"
gh_run fleet_secrets.yml 300
gh_job 300 "patch_auth for all" in_progress "${ROTATION_STEP}=completed" "Change them, one client at a time=in_progress"
step "No database password is being changed"
check '[[ $status -eq 0 && "$(grep -c "^sleep" "$FAKE_DIR/order.log")" == 0 ]]' "not waited for: only a new password breaks the export's connection"
fresh "a change of other secrets begun before this export, still at its own wait"
gh_run fleet_secrets.yml 300 in_progress workflow_dispatch "fleet secrets: patch_auth for all"
gh_job 300 "patch_auth for all" in_progress "No rename, and for a password no export or backup, is under way=in_progress" "${ROTATION_STEP}=queued" "Change them, one client at a time=queued"
step "No database password is being changed"
check '[[ $status -eq 0 && "$(grep -c "^sleep" "$FAKE_DIR/order.log")" == 0 && "$(grep -c "runs/300/jobs" "$FAKE_DIR/gh.log")" == 0 ]]' \
      "not waited for: its title says it changes no password, though GitHub cannot yet say it skips that step"
fresh "a change of database passwords begun before this export, titled so, still at its own wait"
gh_run fleet_secrets.yml 300 in_progress workflow_dispatch "fleet secrets: rotate_db_password for all"
gh_job 300 "rotate_db_password for all" in_progress "No rename, and for a password no export or backup, is under way=in_progress" "${ROTATION_STEP}=queued"
step "No database password is being changed" POLL_SECONDS=1800
check '[[ $status -eq 1 && "$out" == *"run 300: began before this run, and has \"${ROTATION_STEP}\" still to do"* ]]' "waited for: it is ahead in the queue"

LAST="The request settled, and the row told"
fresh "the last step, the export not made, of a client that is up"
answer cp wf-status live
printf '%s\n' "failure: the product's schemas could not be dumped" > "$work/outcome"
step "$LAST"
check '[[ $status -eq 0 && "$(events)" == "acme|export|failed|export not made: the product'"'"'s schemas could not be dumped (fleet_export.yml)" && "$out" == *"acme'"'"'s row says the export was not made"* ]]' \
      "its status asked, and its row told"
check '[[ "$(tvar wf-status code)" == acme && "$(sed -n "/-- fleet: wf-status/,\$p" "$FAKE_DIR/sql.1")" == *"set statement_timeout"*"erp_meta.deployment"* ]]' "asked of the register, under a limit"
fresh "the last step, of a client being built"
answer cp wf-status building
printf '%s\n' "failure: acme is building: only a client whose database is up (built, live, suspended, or retiring once built) is exported" > "$work/outcome"
step "$LAST"
check '[[ $status -eq 0 && -z "$(events)" && "$out" == *"acme is building: its row is not told"* ]]' \
      "nothing written: a failed step would mark its build failed"
fresh "the last step, a run cancelled before the export, of a client asked for"
answer cp wf-status requested
step "$LAST" JOB_STATUS=cancelled
check '[[ $status -eq 0 && -z "$(events)" && "$out" == *"acme is requested: its row is not told"* ]]' "nothing written"
fresh "the last step, the status not known"
answer cp wf-status "ERROR:  could not connect to server"
printf '%s\n' "failure: the export stopped" > "$work/outcome"
step "$LAST"
check '[[ $status -eq 0 && -z "$(events)" && "$out" == *"::warning::acme'"'"'s status could not be read, so its row is not told"* ]]' "nothing written while it is not known"
fresh "the last step, the row told already"
printf '%s\n%s\n' "failure: the export stopped" told > "$work/outcome"
step "$LAST"
check '[[ $status -eq 0 && -z "$(events)" && "$(order)" != *"wf-status"* ]]' "not told twice, nothing asked"
fresh "the last step, with a request to settle"
answer cp wf-status suspended
answer cp wf-request claimed
printf '%s\n' "failure: the export stopped" > "$work/outcome"
step "$LAST" REQUEST=0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d
check '[[ $status -eq 0 && "$(order)" == "psql cp wf-status;event acme export failed;psql cp wf-request;psql cp wf-settle;" && "$(tvar wf-settle outcome)" == "failure: the export stopped" ]]' \
      "the row told, then the request settled with the outcome"

# 5. Nothing secret printed
run "on a runner" GITHUB_ACTIONS=true -- acme
check '[[ $status -eq 0 ]]' "exported"
for secret in "$ACME_URL" "$SERVICE_KEY" "$KEY_ID" "$SECRET" "$ENDPOINT" "$BUCKET"; do
  CASES=$((CASES + 1))
  if [[ "$(printf "%s\n" "$out" | grep -F -- "$secret" | grep -vc "^::add-mask::")" == 0 && "$(printf "%s\n" "$out" | grep -cxF -- "::add-mask::$secret")" -ge 1 ]]; then
    echo "  ok   $CURRENT: ${secret:0:12}… masked, and printed nowhere else"
  else
    FAILED=$((FAILED + 1)); echo "  FAIL $CURRENT: ${secret:0:12}… printed unmasked, or never masked"
  fi
done
check '[[ "$(printf "%s\n" "$out" | grep -nF -- "$ACME_URL" | head -n 1 | cut -d: -f1)" -lt "$(printf "%s\n" "$out" | grep -n "^exporting" | cut -d: -f1)" ]]' \
      "the connection is masked before anything else is said about the client"
check '[[ "$(cat "$work/summary") $(cat "$work/outcome") $(events)" != *"$SERVICE_KEY"* && "$(cat "$work/summary") $(cat "$work/outcome")" != *"acme-database-password"* ]]' \
      "nor in the summary, the outcome or the row"
run "outside a runner" -- acme
check '[[ $status -eq 0 && "$out" != *"::add-mask::"* && "$out" != *"acme-database-password"* && "$out" != *"$SECRET"* && "$out" != *"$SERVICE_KEY"* ]]' "no mask line, and nothing secret"

echo "$CASES checks over a client's export, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
