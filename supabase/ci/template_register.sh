#!/usr/bin/env bash
#
# The control plane's register of templates (erp_meta.provisioning_template,
# 20261012070000), from a workflow: template.yml records each template it has
# made and proved, and deployment_from_empty.yml finds and fetches the one to
# restore a client from (supabase/ci/template_make.sh and template_restore.sh
# say what a template is).
#
# A template is restored only when it MATCHES: it was made from migrations
# that are exactly this checkout's. The register answers the newest template
# recorded for this checkout's newest migration and count
# (erp_meta.provisioning_template_for); git says whether the commit it was
# made from has this checkout's supabase/migrations. Anything less (a template
# one migration behind, or one made from a migration since edited) would
# restore a schema the next release does not expect.
#
# Where a template is kept is its storage key:
#
#   s3:<key>                      in the owner's bucket
#                                 (CLOVEERP_BACKUP_S3_*, as fleet_offsite.sh
#                                 reaches it), when one is configured;
#   artifact:<run id>:<name>      an artifact of the template.yml run that
#                                 made it, kept ninety days.
#
# Either way it is one tar of fingerprint.tsv, manifest.json, migrations.tsv
# and template.dump, holding nothing secret (the template is what the public migrations build);
# what makes it safe to restore is that its dump's sha256 is the one this
# register holds, which template_restore.sh refuses to do without.
#
# Usage: template_register.sh <command> ...   with CLOVEERP_LIVE_DATABASE_URL set
#
#   ready                     exit 0 when the control plane has the register,
#                             its recorder and its lookup; 3, saying so, when
#                             not yet
#   match                     the template registered for this checkout's
#                             migrations, when its commit's migrations are
#                             this checkout's: prints git_sha=, dump_sha256=,
#                             storage_key=, proving_run_id= and fingerprint=
#                             (the register's, compact JSON); exit 3, saying
#                             why, when there is none
#   fetch <storage key> <dir> the template unpacked into <dir> (empty or
#                             absent): the four files and nothing else
#   record <dir> <storage key>
#                             the template in <dir> recorded, with the run
#                             that proved it (GITHUB_RUN_ID); says whether the
#                             register recorded it, had it already (replay) or
#                             renewed where it is kept
#
# Every value reaches SQL as a psql variable on standard input (as
# fleet_register.sh does it), and nothing secret is printed: the connection
# string never, the bucket's settings masked and taken out of any error.
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL      the control plane (not for fetch)
#   MIGRATIONS_DIR                  this checkout's migrations (default:
#                                   supabase/migrations beside this)
#   PSQL, GIT, GH, AWS              the commands (the rehearsal's stand-ins)
#   GH_TOKEN, GH_REPO               for an artifact
#   CLOVEERP_BACKUP_S3_*            for a bucket (fleet_offsite.sh)
#
# bash 3.2 and 5 (supabase/ci/template_register_rehearsal.sh runs it on a Mac).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$HERE/../migrations}"
CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
PSQL_CMD="${PSQL:-psql}"
GIT_CMD="${GIT:-git}"
GH_CMD="${GH:-gh}"
RECORDER="erp_meta.record_provisioning_template(text,text,integer,text,jsonb,text,text)"
LOOKUP="erp_meta.provisioning_template_for(text,integer)"

refuse() {
  echo "x $*" >&2
  exit 2
}
none() {
  echo "$*" >&2
  exit 3
}

q() { $PSQL_CMD "$CP_URL" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }

# Whatever psql said, with the connection string and its password taken out,
# on one line.
PASSWORD_IN_URL=""
if [[ "$CP_URL" =~ ^[a-z]+://[^:/@]+:([^@]+)@ ]]; then PASSWORD_IN_URL="${BASH_REMATCH[1]}"; fi
redact() {
  local text="$1"
  if [[ -n "$CP_URL" ]]; then text="${text//"${CP_URL}"/[the control plane]}"; fi
  if [[ -n "$PASSWORD_IN_URL" ]]; then text="${text//"${PASSWORD_IN_URL}"/[hidden]}"; fi
  printf '%s' "$text" | tr -s ' \t\r\n' '    ' | cut -c 1-400
}
need_cp() { [[ -n "$CP_URL" ]] || refuse "CLOVEERP_LIVE_DATABASE_URL is not set; the register of templates cannot be reached."; }

is_key() {
  local key="$1"
  if [[ "$key" =~ ^s3:(templates/[A-Za-z0-9._/-]+)$ ]]; then
    [[ "/${BASH_REMATCH[1]}/" != *"/../"* ]]
  else
    [[ "$key" =~ ^artifact:[0-9]{1,20}:[A-Za-z0-9._-]{1,200}$ ]]
  fi
}

# The newest version and how many, from the directory, as template_make.sh
# reads them.
local_migrations() {
  local f base n=0 newest=""
  for f in "$MIGRATIONS_DIR"/*.sql; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    [[ "$base" =~ ^([0-9]+)_[A-Za-z0-9_-]+\.sql$ ]] || refuse "$base is not named <version>_<name>.sql."
    n=$((n + 1))
    if [[ -z "$newest" || "${BASH_REMATCH[1]}" > "$newest" ]]; then newest="${BASH_REMATCH[1]}"; fi
  done
  [[ "$n" -gt 0 ]] || refuse "$MIGRATIONS_DIR holds no migration."
  echo "$newest $n"
}

register_ready() {
  local have
  have=$(q <<SQL
select (to_regclass('erp_meta.provisioning_template') is not null)::text || ' ' || (to_regprocedure('${RECORDER}') is not null)::text
       || ' ' || (to_regprocedure('${LOOKUP}') is not null)::text;
SQL
)
  [[ "$have" == "true true true" ]]
}

cmd="${1:-}"; shift || true
case "$cmd" in
  ready)
    need_cp
    register_ready ||
      none "the control plane has no register of templates yet (20261012070000: erp_meta.provisioning_template, ${RECORDER%%(*} and ${LOOKUP%%(*}); a template can be recorded once it is released."
    echo "register of templates: ready"
    ;;

  match)
    need_cp
    here=$(local_migrations)
    read -r newest count <<< "$here"
    if ! register_ready; then
      none "the control plane has no register of templates yet (20261012070000)"
    fi
    work_err="$(mktemp)"
    trap 'rm -f "$work_err"' EXIT
    # The register's own lookup: the newest template recorded for exactly
    # this newest migration and count, or null.
    if ! found=$(q -v newest="$newest" -v count="$count" 2> "$work_err" <<'SQL'
select coalesce(erp_meta.provisioning_template_for(:'newest', :'count'::integer)::text, '');
SQL
); then
      refuse "the register could not be asked for a template ($(redact "$(cat "$work_err")"))."
    fi
    if [[ -z "$found" ]]; then
      none "no template is registered for these migrations (${count}, the newest ${newest})"
    fi
    sha=$(jq -r '.git_sha // empty' <<< "$found" 2> /dev/null || true)
    dump=$(jq -r '.dump_sha256 // empty' <<< "$found" 2> /dev/null || true)
    key=$(jq -r '.storage_key // empty' <<< "$found" 2> /dev/null || true)
    run=$(jq -r '.proving_run_id // empty' <<< "$found" 2> /dev/null || true)
    fingerprint=$(jq -cS '.fingerprint // empty' <<< "$found" 2> /dev/null || true)
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ && "$dump" =~ ^[0-9a-f]{64}$ && "$run" =~ ^[0-9]{1,20}$ ]] ||
       ! is_key "$key" || [[ "$(jq -r 'type' <<< "${fingerprint:-null}" 2> /dev/null)" != object ]]; then
      none "the template registered for these migrations (${count}, the newest ${newest}) is not in a form a build restores from"
    fi
    # The commit it was made from, fetched if this checkout lacks it; and its
    # migrations, compared with this checkout's by git.
    if ! $GIT_CMD -C "$REPO" cat-file -e "${sha}^{commit}" 2> /dev/null; then
      $GIT_CMD -C "$REPO" fetch -q --no-tags --depth=1 origin "$sha" > /dev/null 2>&1 || true
    fi
    if ! $GIT_CMD -C "$REPO" cat-file -e "${sha}^{commit}" 2> /dev/null; then
      none "the template registered for these migrations (${count}, the newest ${newest}) was made at ${sha:0:12}, which this repository does not have"
    fi
    if ! $GIT_CMD -C "$REPO" diff --quiet "$sha" HEAD -- supabase/migrations 2> /dev/null; then
      none "the template registered for these migrations (${count}, the newest ${newest}) was made at ${sha:0:12}, from migrations that are not this checkout's"
    fi
    echo "git_sha=${sha}"
    echo "dump_sha256=${dump}"
    echo "storage_key=${key}"
    echo "proving_run_id=${run}"
    echo "fingerprint=${fingerprint}"
    ;;

  fetch)
    key="${1:?usage: template_register.sh fetch <storage key> <dir>}"
    dir="${2:?usage: template_register.sh fetch <storage key> <dir>}"
    is_key "$key" || refuse "'${key}' is not a template's storage key (s3:templates/... or artifact:<run id>:<name>)."
    if [[ -e "$dir" && -n "$(ls -A "$dir" 2> /dev/null)" ]]; then
      refuse "$dir is not empty; a template is unpacked into an empty directory."
    fi
    mkdir -p "$dir"
    tarball="$dir/template.tar"
    case "$key" in
      s3:*)
        # shellcheck source=supabase/ci/fleet_offsite.sh
        . "$HERE/fleet_offsite.sh"
        offsite_mask
        if [[ -z "${CLOVEERP_BACKUP_S3_ENDPOINT:-}" || -z "${CLOVEERP_BACKUP_S3_BUCKET:-}" ||
              -z "${CLOVEERP_BACKUP_S3_KEY_ID:-}" || -z "${CLOVEERP_BACKUP_S3_SECRET:-}" ]]; then
          refuse "the template is kept in the bucket, and the bucket's settings (CLOVEERP_BACKUP_S3_ENDPOINT, _BUCKET, _KEY_ID, _SECRET) are not all here."
        fi
        if ! err=$(offsite_aws s3 cp "s3://${CLOVEERP_BACKUP_S3_BUCKET}/${key#s3:}" "$tarball" --only-show-errors 2>&1); then
          refuse "the template could not be fetched from the bucket ($(offsite_redact "$err"))."
        fi
        ;;
      artifact:*)
        rest="${key#artifact:}"
        run="${rest%%:*}"
        name="${rest#*:}"
        if ! err=$($GH_CMD run download "$run" --name "$name" --dir "$dir/artifact" 2>&1); then
          refuse "the template could not be fetched from run ${run}'s artifact ${name}; an artifact is kept ninety days ($(printf '%s' "$err" | tr -s ' \t\r\n' '    ' | cut -c 1-200))."
        fi
        [[ -s "$dir/artifact/template.tar" ]] || refuse "run ${run}'s artifact ${name} holds no template.tar."
        mv "$dir/artifact/template.tar" "$tarball"
        rm -rf "$dir/artifact"
        ;;
    esac
    [[ -s "$tarball" ]] || refuse "the template fetched is empty."
    # The four files and nothing else: no path that climbs out, no link.
    if ! listing=$(tar -tf "$tarball" 2> /dev/null); then
      refuse "the template fetched is not a tar archive."
    fi
    expected=$(printf '%s\n' fingerprint.tsv manifest.json migrations.tsv template.dump)
    if [[ "$(printf '%s\n' "$listing" | sed 's|^\./||' | LC_ALL=C sort)" != "$expected" ]]; then
      refuse "the template fetched holds $(printf '%s' "$listing" | tr '\n' ' ' | cut -c 1-200), not exactly fingerprint.tsv, manifest.json, migrations.tsv and template.dump."
    fi
    tar -xf "$tarball" -C "$dir"
    rm -f "$tarball"
    for f in fingerprint.tsv manifest.json migrations.tsv template.dump; do
      [[ -f "$dir/$f" && ! -L "$dir/$f" ]] || refuse "the template's $f did not unpack as a file."
    done
    echo "fetched: template.dump $(wc -c < "$dir/template.dump" | tr -d ' ') bytes, $(grep -c . "$dir/migrations.tsv" | tr -d ' ') migrations"
    ;;

  record)
    need_cp
    dir="${1:?usage: template_register.sh record <dir> <storage key>}"
    key="${2:?usage: template_register.sh record <dir> <storage key>}"
    is_key "$key" || refuse "'${key}' is not a template's storage key."
    run="${GITHUB_RUN_ID:-}"
    [[ "$run" =~ ^[0-9]+$ ]] || refuse "GITHUB_RUN_ID is not set: a template is recorded with the run that proved it."
    manifest="$dir/manifest.json"
    jq -e '.format == "cloveerp.template.v1"' "$manifest" > /dev/null 2>&1 || refuse "$manifest is not a template's manifest."
    git_sha=$(jq -r '.git_sha' "$manifest")
    newest=$(jq -r '.newest_version' "$manifest")
    count=$(jq -r '.migration_count' "$manifest")
    dump=$(jq -r '.files["template.dump"].sha256' "$manifest")
    fingerprint=$(jq -c '.fingerprint' "$manifest")
    [[ "$git_sha" =~ ^[0-9a-f]{40}$ && "$newest" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ && "$dump" =~ ^[0-9a-f]{64}$ ]] ||
      refuse "the manifest does not name a commit, a newest migration, a count and a dump's sha256."
    register_ready ||
      none "the control plane has no register of templates yet (20261012070000); the template was not recorded."
    work_err="$(mktemp)"
    trap 'rm -f "$work_err"' EXIT
    # The control plane's recorder, and only there: anywhere else it refuses
    # CLOVEERP_NOT_THE_CONTROL_PLANE, and a template it holds already is a
    # replay, or renewed where it is kept.
    if ! answer=$(q -v git_sha="$git_sha" -v newest="$newest" -v count="$count" -v dump="$dump" \
                    -v fingerprint="$fingerprint" -v key="$key" -v run="$run" 2> "$work_err" <<'SQL'
select erp_meta.record_provisioning_template(:'git_sha', :'newest', :'count'::integer, :'dump', :'fingerprint'::jsonb, :'key', :'run')::text;
SQL
); then
      refuse "the control plane did not record the template ($(redact "$(grep -m 1 'ERROR' "$work_err" || cat "$work_err")"))."
    fi
    outcome=$(jq -r '.outcome // empty' <<< "$answer" 2> /dev/null || true)
    case "$outcome" in
      recorded) said="recorded" ;;
      replay) said="recorded already, exactly so (nothing changed)" ;;
      renewed) said="recorded already; where it is kept and the run that proved it renewed" ;;
      *) refuse "the control plane answered something that is not a recorded template (outcome '${outcome}')." ;;
    esac
    echo "register: the template made at ${git_sha:0:12} (${count} migrations, the newest ${newest}; dump ${dump:0:12}) ${said}, kept as ${key}, proved by run ${run}"
    echo "outcome=${outcome}"
    ;;

  *)
    echo "usage: template_register.sh ready|match|fetch|record ..." >&2
    exit 2
    ;;
esac
