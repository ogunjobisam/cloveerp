#!/usr/bin/env bash
#
# Every client's platform staff, kept as the control plane's list says.
#
# Staff are kept on the control plane only (20261011100000). On a client's
# own project the console's doors that add, re-rank and remove staff refuse,
# and its list is made to match the control plane's here, through two
# routines no session role can run: erp_meta.add_platform_staff_trusted()
# and erp_meta.revoke_platform_staff_trusted(). Before this, a member of
# staff who had to support a client was added on that client's console by
# hand, by its one owner, as a row naming an address and bound to nothing:
# matched by whoever confirmed that address, and, while it waited, a row that
# stopped every release to the client (release.yml, "only its owner").
#
# For each built or live client in the control plane's register (or the one
# code given), one at a time:
#
#   1. its connection string from the control plane's vault
#      (cloveerp:deployment:<ref>:db_url), masked the moment it is read and
#      refused unless it names the client's project and no other
#      deployment's; and its database must say it is a client's;
#   2. each member of the control plane's active staff, owners first, gets a
#      confirmed sign-in on the client if there is none (the project's own
#      admin API, with its secret key from the vault, and a password nobody
#      knows: they sign in with an emailed link), then a staff row at the
#      control plane's rank, bound to that sign-in;
#   3. anyone on the client's active list whom the control plane's no longer
#      names is removed, softly. Never the last owner: that is reported, and
#      the rest is kept all the same;
#   4. what changed is written on the client's row in the register, as a
#      note: how many were added, changed and removed, and what could not be
#      done. A client already in step writes nothing, and the same trouble
#      is not written twice in a row, so an hourly run does not bury the
#      builds and releases the Fleet view shows.
#
# Owners first, removals last: when the control plane hands its ownership
# from one person to another, the new owner is on the client before the old
# one is demoted or removed, so the client is never left without one.
#
# Usage: fleet_staff_sync.sh [code]
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL  the control plane (required)
#   PLATFORM_OWNER_EMAIL        the platform's owner (the repository variable
#                               CLOVEERP_PLATFORM_OWNER_EMAIL): every release
#                               to a client checks they are an owner there, so
#                               a control plane list that does not make them
#                               one is refused, and nothing is changed
#   PRODUCTION_REF, DEMO_REF    refs a client's connection must not name, as
#                               well as every other ref in the register
#   PSQL, CURL                  the commands (the rehearsal's stand-ins)
#   CLIENT_STATEMENT_TIMEOUT    each statement on a client (default 30s): the
#                               pooler drops PGOPTIONS, so it is set in SQL
#   PAUSE_SECONDS               between clients (default 5)
#   FLEET_SLEEP                 the sleep command (default sleep)
#   PGCONNECT_TIMEOUT           seconds to reach a database (default 15)
#   and the MAPI_* settings of supabase/ci/management_api.sh, whose patience
#   the admin API is asked with: a 429 or a 5xx asked again, never refused
#   at the first answer.
#
# Every value reaches SQL as a psql variable on standard input (psql
# substitutes :'name' only there, never in -c). Nothing read from the vault
# is printed: on a runner each value is masked (::add-mask::) before
# anything else is said.
#
# Exit: 0 when every client's staff matches the control plane's (a client not
# yet released the two routines is noted and left for the next train); 1
# when anything could not be made to, each said in an ::error:: line, and
# every other client kept all the same; 2 when nothing was tried.
#
# bash 3.2 and 5. Rehearsed on every build with a psql and a curl that answer
# from a script: supabase/ci/fleet_staff_sync_rehearsal.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# patient_request: the project's admin API asked with the fleet's patience.
# shellcheck source=supabase/ci/management_api.sh
. "$HERE/management_api.sh"

CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
PSQL_CMD="${PSQL:-psql}"
SLEEP_CMD="${FLEET_SLEEP:-sleep}"
PAUSE="${PAUSE_SECONDS:-5}"
TIMEOUT="${CLIENT_STATEMENT_TIMEOUT:-30s}"
ONLY="${1:-}"
RUN="${GITHUB_RUN_ID:-}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# A person's address as this script shows it: the repository is public, and
# so are its logs and summaries. The first letter and the domain say enough
# to act on; the full address is in the console.
shown() {
  local e="$1"
  if [[ "$e" == *@* ]]; then printf '%s…@%s' "${e:0:1}" "${e#*@}"; else printf '%s' "${e:0:1}…"; fi
}
# And every address read is masked in the log, whatever prints it.
mask_addresses() {
  [[ "${GITHUB_ACTIONS:-}" == true ]] || { cat > /dev/null; return 0; }
  jq -r '.[]? | (.email? // .)' 2> /dev/null | while IFS= read -r a; do [[ -z "$a" ]] || echo "::add-mask::$a"; done
}
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"
export PGAPPNAME="${PGAPPNAME:-fleet_staff_sync}"

is_code() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])?$ ]]; }
is_ref() { [[ "$1" =~ ^[a-z0-9]{20}$ ]]; }
is_uuid() { [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }

if [[ -z "$CP_URL" ]]; then
  echo "::error::CLOVEERP_LIVE_DATABASE_URL is not set, so the control plane's staff list and register cannot be read. No client's staff was changed."
  exit 2
fi
if [[ -n "$ONLY" ]] && ! is_code "$ONLY"; then
  echo "::error::'${ONLY}' is not a client's code. No client's staff was changed."
  exit 2
fi
if ! [[ "$PAUSE" =~ ^[0-9]+$ ]]; then
  echo "::error::PAUSE_SECONDS must be a whole number. No client's staff was changed."
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/fleet_staff_sync.XXXXXX")
trap 'rm -rf "$work"' EXIT

# On a runner GitHub hides a value printed after this; a terminal would show
# it, so nowhere else.
mask() {
  if [[ "${GITHUB_ACTIONS:-}" == true && -n "${1:-}" ]]; then
    echo "::add-mask::$1"
  fi
}

# What psql or an API said was wrong, on one line. Cut by character, not by
# byte (jq), so what is written in the register is never half a character.
said() {
  local first
  first=$(grep -E 'ERROR|FATAL|error|refus|answered|could not|^x ' "$work/err" 2> /dev/null | head -n 1 || true)
  [[ -n "$first" ]] || first=$(head -n 1 "$work/err" 2> /dev/null || true)
  first="${first#psql:<stdin>:*: }"
  printf '%s' "${first:-no reason given}" | tr -s ' \t' '  ' | jq -Rr '.[0:300]'
}

# The control plane: one answer per row, nothing else printed.
cp_q() { $PSQL_CMD "$CP_URL" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }
# A client: the same, with the statement timeout every statement sets.
client_q() {
  local url="$1"
  shift
  $PSQL_CMD "$url" -v ON_ERROR_STOP=1 -X -q -tA -v timeout="$TIMEOUT" "$@"
}
reg() { CLOVEERP_LIVE_DATABASE_URL="$CP_URL" PSQL="$PSQL_CMD" "$HERE/fleet_register.sh" "$@"; }

# ── The control plane's list, and the clients to keep ────────────────────────
ready=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-ready
select (to_regclass('erp_meta.deployment') is not null)::text;
SQL
) || { echo "::error::the control plane could not be read ($(said)). No client's staff was changed."; exit 1; }
if [[ "$ready" != true ]]; then
  echo "the control plane has no register of deployments yet, so there is no client whose staff to keep"
  exit 0
fi

# Owners first, then by rank: see the header.
staff=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-staff
select coalesce(jsonb_agg(jsonb_build_object('email', lower(btrim(s.email)), 'name', s.display_name, 'role', s.staff_role)
                          order by erp_meta.platform_rank(s.staff_role) desc, lower(btrim(s.email))), '[]'::jsonb)
  from erp_meta.platform_staff s
 where s.revoked_at is null;
SQL
) || { echo "::error::the control plane's staff list could not be read ($(said)). No client's staff was changed."; exit 1; }
mask_addresses <<< "$staff"
members=$(jq 'length' <<< "$staff")
owners=$(jq '[.[] | select(.role == "owner")] | length' <<< "$staff")
if [[ "$members" -eq 0 || "$owners" -eq 0 ]]; then
  # A working control plane always has an owner. A list without one is a
  # read gone wrong, and following it would remove everybody everywhere.
  echo "::error::the control plane's staff list has no owner (${members} active member(s)), which a working control plane never has. Rather than remove everyone from every client, no client's staff was changed."
  exit 1
fi
# Every release to a client refuses unless the platform's owner
# (CLOVEERP_PLATFORM_OWNER_EMAIL) is an owner there, bound to a confirmed
# sign-in (release.yml). A list that does not make them an owner would
# remove or demote them on every client, and stop every client's next
# release: the two must agree before anything is followed.
platform_owner=$(printf '%s' "${PLATFORM_OWNER_EMAIL:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
if [[ -n "$platform_owner" ]] && ! jq -e --arg o "$platform_owner" 'any(.[]; .email == $o and .role == "owner")' <<< "$staff" > /dev/null; then
  echo "::error::the control plane's staff list does not make the platform's owner (CLOVEERP_PLATFORM_OWNER_EMAIL, $(shown "$platform_owner")) an owner. Every release to a client checks that this owner is there, so following the list would stop every client's next release. Make the two agree, on the control plane's console or in the variable, and the next sync carries on. No client's staff was changed."
  exit 1
fi
wanted=$(jq -c '[.[].email]' <<< "$staff")

clients=$(cp_q -v only="$ONLY" 2> "$work/err" <<'SQL'
-- fleet: cp-clients
select coalesce(jsonb_agg(jsonb_build_object('code', d.code, 'ref', d.project_ref, 'api_url', coalesce(d.api_url, ''))
                          order by d.code), '[]'::jsonb)
  from erp_meta.deployment d
 where d.status in ('built', 'live')
   and d.project_ref is not null
   and (:'only' = '' or d.code = :'only');
SQL
) || { echo "::error::the control plane's register could not be read ($(said)). No client's staff was changed."; exit 1; }
# Every ref the register knows, whatever its state, and production's and
# the demonstration's: a client's connection may name its own and no other.
all_refs=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-refs
select coalesce(string_agg(d.project_ref, ','), '') from erp_meta.deployment d where d.project_ref is not null;
SQL
) || { echo "::error::the control plane's register could not be read ($(said)). No client's staff was changed."; exit 1; }
all_refs="${all_refs},${PRODUCTION_REF:-xpzffnnhnhcqyjqcueja},${DEMO_REF:-}"

count=$(jq 'length' <<< "$clients")
if [[ "$count" -eq 0 ]]; then
  if [[ -n "$ONLY" ]]; then
    status=$(cp_q -v only="$ONLY" 2> "$work/err" <<'SQL'
-- fleet: cp-status
select coalesce((select d.status from erp_meta.deployment d where d.code = :'only'), '');
SQL
    ) || status=""
    if [[ -z "$status" ]]; then
      echo "::error::'${ONLY}' is not in the control plane's register. No client's staff was changed."
      exit 1
    fi
    echo "::notice::${ONLY} is ${status}: only a built or live client's staff is kept. Nothing was changed."
    exit 0
  fi
  echo "no built or live client in the register; nobody's staff to keep"
  exit 0
fi

echo "the control plane's staff: ${members} active, ${owners} owner(s); ${count} client(s) to keep"
{
  echo "## Staff kept as the control plane's"
  echo
  echo "The control plane's list: ${members} active member(s), ${owners} owner(s)."
  echo
  echo "| client | added | changed | removed | not done |"
  echo "|---|---|---|---|---|"
} >> "$SUMMARY"

troubled=0
skipped=0

# ── One client ───────────────────────────────────────────────────────────────
# Its words of trouble gather in TROUBLE, said at once and written on its row.
trouble() {
  # Shortened wherever an address appears, a database's own words included:
  # this goes to the public log, the summary and the register's note.
  local said_here
  said_here=$(printf '%s' "$*" | sed -E 's/([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+)/\1…@\2/g')
  echo "::error::${CODE}: ${said_here}"
  TROUBLE="${TROUBLE:+${TROUBLE}; }${said_here}"
}

keep_client() {
  CODE="$1"
  TROUBLE=""
  local ref="$2" api="$3"
  local added=0 changed=0 removed=0 kept=0
  local url="" service_key="" vault state kind can_add can_revoke before
  local n i email name role uid result gone reason other words st last
  local -a others key_headers

  if ! is_ref "$ref"; then
    trouble "the register gives it no project ref ('${ref}'), so nothing was changed there"
  else
    vault="cloveerp:deployment:${ref}:db_url"
    if ! url=$(reg vault-get "$vault" 2> "$work/err"); then
      url=""
      trouble "the control plane's vault could not be read for ${vault} ($(said)); nothing was changed there"
    else
      mask "$url"
      if [[ -z "$url" ]]; then
        trouble "the control plane's vault has no ${vault}, so it cannot be reached (its build from empty writes that entry); nothing was changed there"
      elif [[ "$url" != *"$ref"* ]]; then
        trouble "${vault} does not name its project (${ref}); nothing was changed there"
        url=""
      else
        IFS=',' read -r -a others <<< "$all_refs"
        for other in ${others[@]+"${others[@]}"}; do
          other="${other// /}"
          if [[ -n "$other" && "$other" != "$ref" && "$url" == *"$other"* ]]; then
            trouble "${vault} names another deployment's project (${other}); nothing was changed there"
            url=""
            break
          fi
        done
      fi
    fi
  fi

  # The address its secret key would be sent to must be its own project's,
  # exactly: the register writes https://<ref>.supabase.co and nothing else
  # (deployment_from_empty.yml), and a host that merely contains the ref
  # could be anybody's.
  api="${api%/}"
  [[ -n "$api" ]] || api="https://${ref}.supabase.co"
  if [[ -n "$url" && "$api" != "https://${ref}.supabase.co" ]]; then
    trouble "the register's address for its auth API (${api}) is not its project's, so its secret key would not be sent there; nothing was changed there"
    url=""
  fi

  if [[ -n "$url" ]]; then
    if ! state=$(client_q "$url" 2> "$work/err" <<'SQL'
-- fleet: client-state
set statement_timeout = :'timeout';
select erp.deployment_kind()
       || ' ' || (to_regprocedure('erp_meta.add_platform_staff_trusted(text,text,text,uuid)') is not null)::text
       || ' ' || (to_regprocedure('erp_meta.revoke_platform_staff_trusted(text,text)') is not null)::text;
SQL
    ); then
      trouble "its database could not be reached or read ($(said)); nothing was changed there"
      url=""
    else
      read -r kind can_add can_revoke <<< "$state"
      if [[ "$kind" != client ]]; then
        trouble "its database says it is the ${kind:-unknown} deployment, not a client's; nothing was changed there"
        url=""
      elif [[ "$can_add" != true || "$can_revoke" != true ]]; then
        echo "::notice::${CODE} has not yet been released the routines that keep its staff (20261011100000). The next train brings them, and the sync after it keeps its staff. Nothing was changed there."
        echo "| ${CODE} | | | | not released the staff routines yet |" >> "$SUMMARY"
        skipped=$((skipped + 1))
        return 0
      fi
    fi
  fi

  if [[ -n "$url" ]]; then
    if ! before=$(client_q "$url" -v emails="$wanted" 2> "$work/err" <<'SQL'
-- fleet: client-staff
set statement_timeout = :'timeout';
select jsonb_build_object(
         'staff', coalesce((select jsonb_agg(jsonb_build_object('email', lower(btrim(s.email)), 'role', s.staff_role,
                                                               'name', s.display_name, 'uid', s.auth_user_id)
                                              order by lower(btrim(s.email)))
                              from erp_meta.platform_staff s
                             where s.revoked_at is null), '[]'::jsonb),
         'users', coalesce((select jsonb_agg(jsonb_build_object('email', lower(u.email), 'id', u.id,
                                                               'confirmed', u.email_confirmed_at is not null)
                                              order by u.id)
                              from auth.users u
                             where lower(u.email) in (select jsonb_array_elements_text(:'emails'::jsonb))), '[]'::jsonb));
SQL
    ); then
      trouble "its staff list could not be read ($(said)); nothing was changed there"
      url=""
    else
      jq -c '[.staff[]?.email]' <<< "$before" | mask_addresses
    fi
  fi

  if [[ -n "$url" ]]; then
    n=$(jq 'length' <<< "$staff")
    for ((i = 0; i < n; i++)); do
      email=$(jq -r ".[$i].email" <<< "$staff")
      name=$(jq -r ".[$i].name" <<< "$staff")
      role=$(jq -r ".[$i].role" <<< "$staff")

      # The sign-in its row here is bound to, when that is one of its
      # confirmed ones; else its one confirmed sign-in; else none.
      uid=$(jq -r --arg e "$email" '
        ([.users[] | select(.email == $e and .confirmed) | .id]) as $ids
        | ([.staff[] | select(.email == $e) | .uid | select(. != null)]) as $bound
        | if ($ids | length) == 0 then ""
          elif ($bound | length) > 0 and ($bound[0] as $b | $ids | any(.[]; . == $b)) then $bound[0]
          elif ($ids | length) == 1 then $ids[0]
          else "ambiguous" end' <<< "$before")
      if [[ "$uid" == ambiguous ]]; then
        trouble "$(shown "$email") has more than one confirmed sign-in there, so which to bind is not clear; delete the one that is not theirs (Authentication, Users)"
        continue
      fi
      if [[ -z "$uid" ]] && jq -e --arg e "$email" 'any(.users[]; .email == $e)' <<< "$before" > /dev/null; then
        trouble "$(shown "$email") has a sign-in there that is not confirmed, so it was not bound; confirm it or delete it (Authentication, Users) and the next sync binds it"
        continue
      fi

      if [[ -z "$uid" ]]; then
        # A confirmed sign-in, made through the project's own admin API with
        # its secret key, read from the vault the first time it is needed.
        if [[ -z "$service_key" ]]; then
          if ! service_key=$(reg vault-get "cloveerp:deployment:${ref}:service_key" 2> "$work/err"); then
            service_key=""
          fi
          mask "$service_key"
        fi
        if [[ -z "$service_key" ]]; then
          trouble "$(shown "$email") has no sign-in there, and the control plane's vault has no cloveerp:deployment:${ref}:service_key to make one with"
          continue
        fi
        # A secret key in the new format (sb_secret_...) is not a JWT and
        # goes as apikey only; a legacy service_role key goes as a bearer
        # too, as provision_project.sh owner sends it.
        if [[ "$service_key" == sb_* ]]; then
          key_headers=(-H "apikey: ${service_key}")
        else
          key_headers=(-H "apikey: ${service_key}" -H "Authorization: Bearer ${service_key}")
        fi
        # A password nobody knows, meeting the project's rule (twelve, with
        # each kind): they sign in with an emailed link.
        result=$(jq -cn --arg email "$email" \
                   --arg pass "$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)aZ7" \
                   '{email: $email, email_confirm: true, password: $pass}')
        if uid=$(patient_request "POST /auth/v1/admin/users on ${CODE}" POST "${api}/auth/v1/admin/users" "$result" \
                   "${key_headers[@]}" 2> "$work/err"); then
          sed -n '/^!/p' "$work/err"
          uid=$(jq -r '.id // empty' <<< "$uid" 2> /dev/null || true)
        elif grep -qi 'already' "$work/err"; then
          # Made meanwhile, by another run or by hand: read it again.
          sed -n '/^!/p' "$work/err"
          uid=$(client_q "$url" -v email="$email" 2> "$work/err" <<'SQL' || true
-- fleet: client-user
set statement_timeout = :'timeout';
select coalesce(string_agg(u.id::text, ' '), '') from auth.users u
 where lower(u.email) = :'email' and u.email_confirmed_at is not null;
SQL
          )
        else
          sed -n '/^!/p' "$work/err"
          trouble "a sign-in for $(shown "$email") could not be made there ($(said))"
          continue
        fi
        result=""
        if ! is_uuid "$uid"; then
          trouble "a sign-in for $(shown "$email") was asked for there, and no single confirmed sign-in came of it ('${uid}')"
          continue
        fi
        echo "${CODE}: a confirmed sign-in made for $(shown "$email")"
      fi

      if ! result=$(client_q "$url" -v email="$email" -v name="$name" -v role="$role" -v uid="$uid" 2> "$work/err" <<'SQL'
-- fleet: client-add
set statement_timeout = :'timeout';
select erp_meta.add_platform_staff_trusted(:'email', :'name', :'role', :'uid'::uuid);
SQL
      ); then
        trouble "$(shown "$email") could not be kept as ${role} ($(said))"
        continue
      fi
      if [[ "$(jq -r '.changed' <<< "$result" 2> /dev/null)" == true ]]; then
        if jq -e --arg e "$email" 'any(.staff[]; .email == $e)' <<< "$before" > /dev/null; then
          changed=$((changed + 1))
          echo "${CODE}: $(shown "$email") kept as ${role} (changed)"
        else
          added=$((added + 1))
          echo "${CODE}: $(shown "$email") added as ${role}"
        fi
      else
        kept=$((kept + 1))
      fi
    done

    # Removed last, so a new owner is already there when an old one goes.
    gone=$(jq -c --argjson want "$wanted" '[.staff[] | .email | select(. as $e | $want | any(.[]; . == $e) | not)]' <<< "$before")
    reason="Not on the control plane's staff list (fleet_sync.yml${RUN:+, run ${RUN}})."
    n=$(jq 'length' <<< "$gone")
    for ((i = 0; i < n; i++)); do
      email=$(jq -r ".[$i]" <<< "$gone")
      if ! result=$(client_q "$url" -v email="$email" -v reason="$reason" 2> "$work/err" <<'SQL'
-- fleet: client-revoke
set statement_timeout = :'timeout';
select erp_meta.revoke_platform_staff_trusted(:'email', :'reason');
SQL
      ); then
        trouble "$(shown "$email") is not on the control plane's list and could not be removed there ($(said))"
        continue
      fi
      if [[ "$(jq -r '.revoked' <<< "$result" 2> /dev/null)" == true ]]; then
        removed=$((removed + 1))
        echo "${CODE}: $(shown "$email") removed"
      fi
    done
  fi

  echo "${CODE}: ${added} added, ${changed} changed, ${removed} removed, ${kept} already in step${TROUBLE:+; not done: ${TROUBLE}}"
  echo "| ${CODE} | ${added} | ${changed} | ${removed} | ${TROUBLE} |" >> "$SUMMARY"

  # The register: what changed, or what could not be done. Nothing when the
  # client was already in step, and not the same trouble twice in a row.
  if [[ $((added + changed + removed)) -gt 0 || -n "$TROUBLE" ]]; then
    words="staff kept as the control plane's list: ${added} added, ${changed} changed, ${removed} removed"
    st=note
    if [[ -n "$TROUBLE" ]]; then
      words="${words}; not done: ${TROUBLE}"
      st=failed
    fi
    words=$(jq -rn --arg w "$words" '$w[0:1500]')
    last=$(cp_q -v code="$CODE" 2> /dev/null <<'SQL' || true
-- fleet: cp-last-note
select coalesce((select e.status || ' ' || coalesce(e.detail, '')
                   from erp_meta.deployment_event e
                  where e.code = :'code' and e.phase = 'note' and e.detail like 'staff kept as %'
                  order by e.at desc, e.id desc limit 1), '');
SQL
    )
    if [[ "$last" == "${st} ${words}" ]]; then
      echo "${CODE}: the register already says so"
    elif ! reg event "$CODE" note "$st" "$words" > /dev/null 2> "$work/err"; then
      echo "::warning::${CODE}: what was done could not be written in the control plane's register ($(said))."
    fi
  fi

  if [[ -n "$TROUBLE" ]]; then
    troubled=$((troubled + 1))
  fi
  return 0
}

for ((c = 0; c < count; c++)); do
  if [[ "$c" -gt 0 && "$PAUSE" -gt 0 ]]; then
    $SLEEP_CMD "$PAUSE"
  fi
  keep_client "$(jq -r ".[$c].code" <<< "$clients")" \
              "$(jq -r ".[$c].ref" <<< "$clients")" \
              "$(jq -r ".[$c].api_url" <<< "$clients")"
done

if [[ "$troubled" -gt 0 ]]; then
  echo "::error::${troubled} of ${count} client(s) could not be made to match the control plane's staff list; each is said above, and written on its row in the register. Every other client was kept."
  exit 1
fi
if [[ "$skipped" -gt 0 ]]; then
  echo "every client's staff matches the control plane's, but ${skipped} of ${count} not yet released the staff routines"
else
  echo "every client's staff matches the control plane's (${count} kept)"
fi
