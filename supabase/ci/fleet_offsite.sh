#!/usr/bin/env bash
#
# A database, dumped, sealed and put somewhere Supabase is not. Sourced, never
# run:
#
#   . supabase/ci/fleet_offsite.sh
#
# by supabase/ci/fleet_export.sh (one client's export, when it is leaving or
# when the owner asks) and supabase/ci/fleet_backup.sh (every database once a
# week). Supabase keeps seven days of each project's backups, inside Supabase:
# a client that leaves takes nothing with it, and a project deleted by mistake
# takes its backups with it. So a copy of each database goes to a bucket the
# owner holds, encrypted to a key the owner holds, where neither Supabase nor
# the bucket's provider can read it.
#
# What is in a copy. A tar archive, encrypted with age to the public key in
# CLOVEERP_BACKUP_AGE_RECIPIENT, holding:
#
#   product.dump     pg_dump, custom format, of the product's own schemas and
#                    the migration history, exactly as restore_drill.yml
#                    dumps them (and restores them: see there);
#   auth_users.dump  pg_dump, custom format, data only, of auth.users: the
#                    sign-ins every principal is bound to, without which a
#                    restored business has nobody who can sign in to it
#                    (pg_dump cannot put a table of another schema into the
#                    first dump: --table switches --schema off);
#   manifest.json    what was dumped, from where, when, and each file's
#                    sha256.
#
# To read one: age -d -i <the private key> <object> | tar -x
#
# Functions:
#
#   offsite_missing          one line per thing the owner must still create
#                            or correct; nothing when everything is set
#   offsite_mask             the settings masked on a runner
#   offsite_dump URL DIR NAME REF
#                            the two dumps and the manifest into DIR; on
#                            failure OFFSITE_WHY says why, in words
#   offsite_seal DIR OUT     tar and age: OUT is the only thing that leaves,
#                            and the plaintext in DIR is removed either way
#   offsite_put FILE KEY     uploaded, then asked for again: the bucket must
#                            hold exactly that many bytes under KEY
#   offsite_keys PREFIX      every key under PREFIX, one a line
#   offsite_delete KEY
#   offsite_sha256 FILE, offsite_bytes FILE
#
# Environment:
#   CLOVEERP_BACKUP_AGE_RECIPIENT  the age public key (age1…), a repository
#                                  variable: public by design
#   CLOVEERP_BACKUP_S3_ENDPOINT    https://<account>.r2.cloudflarestorage.com,
#   CLOVEERP_BACKUP_S3_BUCKET      or any S3-compatible store; the bucket; and
#   CLOVEERP_BACKUP_S3_KEY_ID      an access key that may write, list and
#   CLOVEERP_BACKUP_S3_SECRET      delete in it. Repository secrets.
#   CLOVEERP_BACKUP_S3_REGION      default auto (what R2 asks for)
#   PG_DUMP, AGE, AWS, TAR         the commands (the rehearsals' stand-ins)
#   PGCONNECT_TIMEOUT              seconds to reach a database (default 15)
#
# Nothing secret reaches an argument: the access key travels in the
# environment of the one command that needs it, and every error any command
# gives is printed with the settings taken out of it.
#
# bash 3.2 and 5: the rehearsals (fleet_export_rehearsal.sh,
# fleet_backup_rehearsal.sh) run it on a Mac as well as on a runner. No trap
# (it would replace the caller's), no mapfile.

OFFSITE_SCHEMAS="erp erp_ref erp_meta erp_ai erp_test erp_ingress public supabase_migrations"
OFFSITE_WHY=""

# In the shape age writes an X25519 public key: bech32, lower case.
offsite_is_recipient() { [[ "$1" =~ ^age1[02-9ac-hj-np-z]{58}$ ]]; }

offsite_missing() {
  local recipient="${CLOVEERP_BACKUP_AGE_RECIPIENT:-}" endpoint="${CLOVEERP_BACKUP_S3_ENDPOINT:-}"
  local bucket="${CLOVEERP_BACKUP_S3_BUCKET:-}"
  if [[ -z "$recipient" ]]; then
    echo "an age key pair (age-keygen), its public key (age1…) in the repository variable CLOVEERP_BACKUP_AGE_RECIPIENT and its private key kept by the owner, off GitHub"
  elif ! offsite_is_recipient "$recipient"; then
    echo "the repository variable CLOVEERP_BACKUP_AGE_RECIPIENT, which is not an age public key (age1 and fifty-eight letters and digits, as age-keygen prints it)"
  fi
  if [[ -z "$endpoint" || -z "$bucket" ]]; then
    echo "a bucket in an S3-compatible store (Cloudflare R2 works), named in the repository secrets CLOVEERP_BACKUP_S3_ENDPOINT (https://<account>.r2.cloudflarestorage.com) and CLOVEERP_BACKUP_S3_BUCKET"
  else
    if ! [[ "$endpoint" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$ ]]; then
      echo "the repository secret CLOVEERP_BACKUP_S3_ENDPOINT, which is not an https address of a host alone (https://<account>.r2.cloudflarestorage.com)"
    fi
    if ! [[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
      echo "the repository secret CLOVEERP_BACKUP_S3_BUCKET, which is not a bucket's name (3 to 63 lower-case letters, digits, dots and hyphens)"
    fi
  fi
  if [[ -z "${CLOVEERP_BACKUP_S3_KEY_ID:-}" || -z "${CLOVEERP_BACKUP_S3_SECRET:-}" ]]; then
    echo "an access key for that bucket that may write, list and delete objects, in the repository secrets CLOVEERP_BACKUP_S3_KEY_ID and CLOVEERP_BACKUP_S3_SECRET"
  fi
}

offsite_in_actions() { [[ "${GITHUB_ACTIONS:-}" == true ]]; }

offsite_mask() {
  local v
  offsite_in_actions || return 0
  for v in "${CLOVEERP_BACKUP_S3_ENDPOINT:-}" "${CLOVEERP_BACKUP_S3_BUCKET:-}" \
           "${CLOVEERP_BACKUP_S3_KEY_ID:-}" "${CLOVEERP_BACKUP_S3_SECRET:-}"; do
    if [[ -n "$v" ]]; then echo "::add-mask::${v}"; fi
  done
}

# offsite_redact <text> [more secrets]: the text with every setting, and
# anything else given, taken out; on one line, at most 300 characters.
offsite_redact() {
  local text="$1" s
  shift
  for s in "${CLOVEERP_BACKUP_S3_SECRET:-}" "${CLOVEERP_BACKUP_S3_KEY_ID:-}" \
           "${CLOVEERP_BACKUP_S3_ENDPOINT:-}" "${CLOVEERP_BACKUP_S3_BUCKET:-}" "$@"; do
    if [[ -n "$s" ]]; then text="${text//"${s}"/[hidden]}"; fi
  done
  printf '%s' "$text" | tr -s ' \t\r\n' '    ' | cut -c 1-300
}

offsite_sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

offsite_bytes() { wc -c < "$1" | tr -d ' '; }

# offsite_aws <aws arguments>: the store asked, its key in the environment
# of this one command only. Nothing paged, no instance metadata looked for,
# and checksums only where the store asks for them (R2 refuses some of the
# newer CLI's defaults).
offsite_aws() {
  env AWS_ACCESS_KEY_ID="${CLOVEERP_BACKUP_S3_KEY_ID:-}" \
      AWS_SECRET_ACCESS_KEY="${CLOVEERP_BACKUP_S3_SECRET:-}" \
      AWS_DEFAULT_REGION="${CLOVEERP_BACKUP_S3_REGION:-auto}" \
      AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
      AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
      AWS_EC2_METADATA_DISABLED=true AWS_PAGER="" \
      ${AWS:-aws} "$@" --endpoint-url "${CLOVEERP_BACKUP_S3_ENDPOINT:-}" --no-cli-pager
}

# offsite_dump <url> <dir> <name> <ref>: product.dump, auth_users.dump and
# manifest.json in dir. The url is the database's own, already masked and
# checked by the caller.
offsite_dump() {
  local url="$1" dir="$2" name="$3" ref="$4" s err taken version
  local -a schemas
  taken=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  schemas=()
  for s in $OFFSITE_SCHEMAS; do schemas+=("--schema=${s}"); done
  # A lock the dump cannot have within a minute is a release replaying into
  # this database: given up, rather than queued in front of the release.
  if ! err=$(PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}" ${PG_DUMP:-pg_dump} "$url" --format=custom --no-owner \
               --lock-wait-timeout=60s "${schemas[@]}" --file="${dir}/product.dump" 2>&1); then
    OFFSITE_WHY="the product's schemas could not be dumped ($(offsite_redact "$err" "$url"))"
    return 1
  fi
  if ! err=$(PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}" ${PG_DUMP:-pg_dump} "$url" --format=custom --no-owner \
               --lock-wait-timeout=60s --data-only --table=auth.users --file="${dir}/auth_users.dump" 2>&1); then
    OFFSITE_WHY="the sign-ins (auth.users) could not be dumped ($(offsite_redact "$err" "$url"))"
    return 1
  fi
  version=$(${PG_DUMP:-pg_dump} --version 2> /dev/null | head -n 1 || true)
  if ! jq -n --arg name "$name" --arg ref "$ref" --arg taken "$taken" --arg version "$version" \
           --arg schemas "$OFFSITE_SCHEMAS" \
           --arg p "$(offsite_sha256 "${dir}/product.dump")" --arg a "$(offsite_sha256 "${dir}/auth_users.dump")" \
           '{format: "cloveerp.offsite.v1", database: $name, project_ref: $ref, taken_at: $taken,
             pg_dump: $version,
             files: {"product.dump": {sha256: $p, holds: ($schemas | split(" ")), restore: "as restore_drill.yml restores it"},
                     "auth_users.dump": {sha256: $a, holds: ["auth.users"], data_only: true}}}' \
         > "${dir}/manifest.json"; then
    OFFSITE_WHY="the manifest could not be written"
    return 1
  fi
}

# offsite_seal <dir> <out>: the three files tarred and encrypted to the
# owner's key; the plaintext removed whatever happens.
offsite_seal() {
  local dir="$1" out="$2" err rc=0
  if ! err=$(${TAR:-tar} -C "$dir" -cf "${dir}/copy.tar" manifest.json product.dump auth_users.dump 2>&1); then
    OFFSITE_WHY="the dumps could not be put together ($(offsite_redact "$err"))"
    rc=1
  elif ! err=$(${AGE:-age} -r "${CLOVEERP_BACKUP_AGE_RECIPIENT:-}" -o "$out" "${dir}/copy.tar" 2>&1); then
    OFFSITE_WHY="the copy could not be encrypted ($(offsite_redact "$err"))"
    rc=1
  elif [[ ! -s "$out" ]]; then
    OFFSITE_WHY="the encrypted copy is empty"
    rc=1
  fi
  rm -f "${dir}/copy.tar" "${dir}/product.dump" "${dir}/auth_users.dump" "${dir}/manifest.json"
  return "$rc"
}

# offsite_put <file> <key>: uploaded, then the store asked how many bytes it
# holds under that key, which must be the file's.
offsite_put() {
  local file="$1" key="$2" err bytes held
  bytes=$(offsite_bytes "$file")
  if ! err=$(offsite_aws s3 cp "$file" "s3://${CLOVEERP_BACKUP_S3_BUCKET:-}/${key}" --only-show-errors 2>&1); then
    OFFSITE_WHY="the copy could not be uploaded as ${key} ($(offsite_redact "$err"))"
    return 1
  fi
  if ! held=$(offsite_aws s3api head-object --bucket "${CLOVEERP_BACKUP_S3_BUCKET:-}" --key "$key" --output json 2>&1); then
    OFFSITE_WHY="the copy was uploaded as ${key}, and the store could not then be asked for it ($(offsite_redact "$held"))"
    return 1
  fi
  held=$(jq -r '.ContentLength // empty' <<< "$held" 2> /dev/null || true)
  if [[ "$held" != "$bytes" ]]; then
    OFFSITE_WHY="the store holds ${held:-nothing} bytes under ${key}, not the ${bytes} uploaded"
    return 1
  fi
}

# offsite_keys <prefix>: every key under it, one a line; fails, saying why
# in OFFSITE_WHY, when the store cannot be asked. Call it with its output
# redirected, not inside $( ), or OFFSITE_WHY is lost with the subshell.
offsite_keys() {
  local out
  if ! out=$(offsite_aws s3api list-objects-v2 --bucket "${CLOVEERP_BACKUP_S3_BUCKET:-}" --prefix "$1" --output json 2>&1); then
    OFFSITE_WHY="the store could not list ${1} ($(offsite_redact "$out"))"
    return 1
  fi
  if [[ -z "$out" ]]; then return 0; fi
  if ! jq -r '(.Contents // [])[].Key' <<< "$out" 2> /dev/null; then
    OFFSITE_WHY="the store's list of ${1} could not be read"
    return 1
  fi
}

offsite_delete() {
  local err
  if ! err=$(offsite_aws s3 rm "s3://${CLOVEERP_BACKUP_S3_BUCKET:-}/${1}" --only-show-errors 2>&1); then
    OFFSITE_WHY="${1} could not be deleted ($(offsite_redact "$err"))"
    return 1
  fi
}
