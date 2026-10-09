#!/usr/bin/env bash
#
# A deployment's database built from a template, or the reason it was not,
# with nothing committed: deployment_from_empty.yml with method template.
#
#   1. the template the control plane's register holds for exactly this
#      checkout's migrations (template_register.sh match);
#   2. fetched from where it is kept (template_register.sh fetch);
#   3. restored in one transaction (template_restore.sh), against the dump's
#      sha256 and the fingerprint the register holds for it.
#
# The owner's decision of 9 October: no paid rehearsal, so the first client
# built with method template is the template's live proof, and a template
# that fails before anything is committed must not cost that client its
# build. So when any of the three fails before the restore commits (no
# template registered, a fetch that fails, a dump whose sha256 is not the
# registered one, a restore whose one transaction rolled back), this says so
# and answers method=from_empty: the build carries on in the same run by
# replaying every migration into a database exactly as it found it.
#
# Whether anything was committed is asked of the database, never assumed from
# an exit code: no product schema, and no migration recorded. Only a failure
# after something was committed (the restore committed and a step after it
# failed), or a database that cannot be asked, stops the build (exit 1),
# because a replay over it would not be a build from empty; the Fleet view's
# Retry carries on from what is recorded.
#
# Usage: template_build.sh <database url> <owner email> <template dir>
#
# Prints, last, one line each, for the workflow to read:
#   method=template|from_empty   the way the database is built
#   committed=yes|no             whether anything of a template was committed
#   template_sha256=, template_git_sha=, template_run=
#                                the template chosen (empty when none was)
#   fell_back=<why>              when a template was asked for and the build
#                                carries on from_empty: one line, nothing secret
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL   the control plane, for the register
#   GH_TOKEN, GH_REPO, CLOVEERP_BACKUP_S3_*
#                                to fetch it (template_register.sh)
#   PSQL                         the command (default psql)
#   TEMPLATE_REGISTER, TEMPLATE_RESTORE
#                                the scripts (default: beside this; the
#                                rehearsal's stand-ins)
#
# Nothing secret is printed: what the scripts say they have already redacted,
# and the database's connection string is taken out of anything said here.
#
# bash 3.2 and 5 (supabase/ci/template_build_rehearsal.sh runs it on a Mac).
set -euo pipefail

DB="${1:?usage: template_build.sh <database url> <owner email> <template dir>}"
OWNER="${2:?usage: template_build.sh <database url> <owner email> <template dir>}"
DIR="${3:?usage: template_build.sh <database url> <owner email> <template dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSQL_CMD="${PSQL:-psql}"
REGISTER_CMD="${TEMPLATE_REGISTER:-$HERE/template_register.sh}"
RESTORE_CMD="${TEMPLATE_RESTORE:-$HERE/template_restore.sh}"
PRODUCT_SCHEMAS="erp erp_ref erp_meta erp_ai erp_test erp_ingress"

PASSWORD_IN_URL=""
if [[ "$DB" =~ ^[a-z]+://[^:/@]+:([^@]+)@ ]]; then PASSWORD_IN_URL="${BASH_REMATCH[1]}"; fi
OWNER_LOWER=$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')
OWNER_SHOWN="${OWNER_LOWER:0:1}…@${OWNER_LOWER##*@}"
# What a script said, with the connection string, its password and the
# owner's whole address taken out (the scripts take them out themselves; this
# is the second pair of hands).
scrub() {
  local text="$1"
  text="${text//"${DB}"/[the database]}"
  if [[ -n "$PASSWORD_IN_URL" ]]; then text="${text//"${PASSWORD_IN_URL}"/[hidden]}"; fi
  text="${text//"${OWNER}"/${OWNER_SHOWN}}"
  text="${text//"${OWNER_LOWER}"/${OWNER_SHOWN}}"
  printf '%s' "$text"
}
# One line, nothing secret, no longer than a register note takes.
one_line() {
  scrub "$1" | tr -s ' \t\r\n' '    ' | sed 's/^ *//; s/ *$//' | cut -c 1-300
}
# show <file> [>&2]: a script's output, scrubbed.
show() {
  [[ -s "$1" ]] || return 0
  scrub "$(cat "$1")"
  echo
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sha=""; git_sha=""; run_id=""
finish() {
  # finish <method> <committed> [why it fell back]
  echo "method=$1"
  echo "committed=$2"
  echo "template_sha256=${sha}"
  echo "template_git_sha=${git_sha}"
  echo "template_run=${run_id}"
  echo "fell_back=${3:-}"
}
fall_back() {
  local why
  why=$(one_line "$1")
  why="${why%.}"
  echo "- no template restored: ${why}. Nothing of it was committed, so the build carries on from_empty in this run, replaying every migration."
  finish from_empty no "$why"
  exit 0
}
# The last thing a script said that was not a progress line ("- ..."): why it stopped.
why_from() {
  grep -v '^- ' "$1" | grep -v '^[[:space:]]*$' | sed 's/^x //' | tail -n 1
}

# ── 1. The template registered for these migrations ──────────────────────────
set +e
"$REGISTER_CMD" match > "$work/match.out" 2> "$work/match.err"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  why=$(why_from "$work/match.err")
  if [[ "$rc" -eq 3 ]]; then
    fall_back "${why:-no template is registered for these migrations}"
  fi
  fall_back "the register could not be asked for a template (${why:-it exited ${rc}})"
fi
sha=$(sed -n 's/^dump_sha256=//p' "$work/match.out" | tail -n 1)
git_sha=$(sed -n 's/^git_sha=//p' "$work/match.out" | tail -n 1)
run_id=$(sed -n 's/^proving_run_id=//p' "$work/match.out" | tail -n 1)
key=$(sed -n 's/^storage_key=//p' "$work/match.out" | tail -n 1)
fingerprint=$(sed -n 's/^fingerprint=//p' "$work/match.out" | tail -n 1)
if ! [[ "$sha" =~ ^[0-9a-f]{64}$ && "$git_sha" =~ ^[0-9a-f]{40}$ && -n "$key" && -n "$fingerprint" ]]; then
  sha=""; git_sha=""; run_id=""
  fall_back "the register's answer did not name a dump, a commit, where it is kept and its fingerprint"
fi
echo "- the template made at ${git_sha:0:12} (dump ${sha:0:12}, proved by run ${run_id:-?}) is registered for these migrations"

# ── 2. Fetched ───────────────────────────────────────────────────────────────
set +e
"$REGISTER_CMD" fetch "$key" "$DIR" > "$work/fetch.out" 2> "$work/fetch.err"
rc=$?
set -e
show "$work/fetch.out"
if [[ "$rc" -ne 0 ]]; then
  fall_back "the template made at ${git_sha:0:12} could not be fetched ($(why_from "$work/fetch.err"))"
fi

# ── 3. Restored, in one transaction ──────────────────────────────────────────
set +e
TEMPLATE_SHA256="$sha" TEMPLATE_FINGERPRINT="$fingerprint" \
  "$RESTORE_CMD" "$DB" "$DIR" "$OWNER" > "$work/restore.out" 2> "$work/restore.err"
rc=$?
set -e
show "$work/restore.out"
show "$work/restore.err" >&2
if [[ "$rc" -eq 0 ]]; then
  finish template yes
  exit 0
fi

# It did not finish. Whether anything was committed, the database says: a
# product schema, or a migration recorded, is something; neither is nothing.
ask() { $PSQL_CMD "$DB" -v ON_ERROR_STOP=1 -X -q -tA -c "$1" 2> "$work/ask.err"; }
schemas_there=$(ask "select count(*) from pg_catalog.pg_namespace where nspname = any (string_to_array('${PRODUCT_SCHEMAS}', ' '))") || schemas_there=""
history_there=$(ask "select to_regclass('supabase_migrations.schema_migrations') is not null") || history_there=""
recorded=0
if [[ "$history_there" == t ]]; then
  recorded=$(ask "select count(*) from supabase_migrations.schema_migrations") || recorded=""
fi
if ! [[ "$schemas_there" =~ ^[0-9]+$ && "$recorded" =~ ^[0-9]+$ && ( "$history_there" == t || "$history_there" == f ) ]]; then
  echo "x the template did not restore (it exited ${rc}), and the database cannot be asked whether anything of it was committed ($(one_line "$(cat "$work/ask.err")")). This run stops rather than replay over it; Retry from the Fleet view carries on from what the database holds." >&2
  finish template unknown
  exit 1
fi
if [[ "$schemas_there" -gt 0 || "$recorded" -gt 0 ]]; then
  echo "x the template was restored (${schemas_there} product schema(s), ${recorded} migration(s) recorded), and then a step after it failed (it exited ${rc}). The database is not as the build found it, so this run stops; Retry from the Fleet view carries on from what is recorded." >&2
  finish template yes
  exit 1
fi

why=$(why_from "$work/restore.err")
refused=$(grep -m 1 'ERROR:' "$work/restore.err" | sed 's/^.*ERROR: *//' || true)
case "$rc" in
  2) fall_back "the template made at ${git_sha:0:12} was refused before anything was sent: ${why}" ;;
  3) fall_back "the restore's one transaction did not commit: ${refused:-${why}}" ;;
  *) fall_back "the restore stopped (it exited ${rc}: ${refused:-${why}})" ;;
esac
