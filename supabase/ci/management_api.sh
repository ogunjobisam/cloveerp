#!/usr/bin/env bash
#
# The Management API, asked patiently. Sourced, never run:
#
#   . supabase/ci/management_api.sh
#   body=$(mapi GET "/v1/projects/${ref}/postgrest") || exit 1
#
# One access token speaks for the whole fleet, and the Management API allows
# it sixty calls a minute. A train releases four clients at once, each
# reading its PostgREST settings, listing and deploying its functions and
# setting secrets, while a build polls a new project every twenty seconds:
# a busy minute answers 429, and every caller here took any answer of 400 or
# more as a verdict and stopped. A release refused because the minute was
# busy would have passed the minute after. So a 429, a 5xx, or no answer at
# all is asked again, after a pause that doubles each time and is never
# shorter than the API's own Retry-After. Any other 4xx is a verdict about
# the request (a token without the permission, a ref that is not there), and
# asking again would only hear it again, so it is never retried.
#
#   mapi METHOD PATH [BODY]
#       ${API:-https://api.supabase.com}${PATH}, with SUPABASE_ACCESS_TOKEN as
#       the bearer and BODY, when given, as JSON. Prints the answer's body on a
#       2xx and returns 0. Otherwise says in plain words what was asked, what
#       came back and how often, on stderr, and returns 1: the caller says
#       what that leaves undone.
#
#   patient_request LABEL METHOD URL BODY [curl arguments ...]
#       The same patience for another HTTP API a project serves (its auth API:
#       provision_project.sh sign-in-link); the caller gives its own headers.
#       LABEL is what the messages call the request; BODY may be empty.
#
# Environment:
#   SUPABASE_ACCESS_TOKEN  mapi's bearer. Never printed.
#   API            default https://api.supabase.com
#   CURL           the curl command (default curl); the rehearsals' stand-in
#   MAPI_ATTEMPTS  how many times a request is made at most (default 5)
#   MAPI_BACKOFF   seconds before the second attempt, doubled before each one
#                  after it (default 5: 5, 10, 20, 40)
#   MAPI_MAX_WAIT  the longest pause taken (default 300). A Retry-After longer
#                  than this is not waited out: the request is given up at once
#   MAPI_TIMEOUT   seconds one attempt may take (default 60)
#   MAPI_RETRY_ONLY_429  yes: ask again only after a 429, which says the request
#                  was not done. For a request that is not safe to repeat, such
#                  as making a project, where a 5xx or no answer may come after
#                  the work was done; the caller then finds out for itself.
#   MAPI_SLEEP     the sleep command (default sleep); the rehearsals' stand-in
#   MAPI_STATUS_FILE  when set, the last status the request was answered (000
#                  for none) is written there, for a caller that reads one
#                  refusal as a verdict of its own (provision_project.sh
#                  resend-webhook: a DELETE answered 404 was done before)
#
# bash 3.2 and later: supabase/ci/provision_project_rehearsal.sh runs it on a
# Mac as well as on a runner. No trap (it would replace the caller's), no
# mapfile, and nothing a caller's set -euo pipefail can trip over.

# patient_request LABEL METHOD URL BODY [curl arguments ...]
patient_request() {
  local label="$1" method="$2" url="$3" body="$4"
  shift 4
  local curl_cmd="${CURL:-curl}"
  local attempts="${MAPI_ATTEMPTS:-5}" backoff="${MAPI_BACKOFF:-5}"
  local max_wait="${MAPI_MAX_WAIT:-300}" timeout="${MAPI_TIMEOUT:-60}" sleeper="${MAPI_SLEEP:-sleep}"
  local work out status answer after wait attempt=1
  local only429="${MAPI_RETRY_ONLY_429:-no}"

  if ! [[ "$attempts" =~ ^[1-9][0-9]*$ && "$backoff" =~ ^[0-9]+$ && "$max_wait" =~ ^[0-9]+$ && "$timeout" =~ ^[1-9][0-9]*$ ]]; then
    echo "x MAPI_ATTEMPTS, MAPI_BACKOFF, MAPI_MAX_WAIT and MAPI_TIMEOUT must be whole numbers; ${label} was not asked." >&2
    return 2
  fi
  work=$(mktemp -d "${TMPDIR:-/tmp}/mapi.XXXXXX") || { echo "x no temporary directory; ${label} was not asked." >&2; return 2; }

  while :; do
    : > "$work/headers"
    : > "$work/stderr"
    # The status on a line of its own after the body (-w), the headers in a
    # file (-D) for Retry-After. No --fail: every status is read here.
    if [[ -n "$body" ]]; then
      out=$($curl_cmd -sS -X "$method" -D "$work/headers" -w '\n%{http_code}' --max-time "$timeout" \
              "$@" -H "Content-Type: application/json" --data "$body" "$url" 2> "$work/stderr") || true
    else
      out=$($curl_cmd -sS -X "$method" -D "$work/headers" -w '\n%{http_code}' --max-time "$timeout" \
              "$@" "$url" 2> "$work/stderr") || true
    fi
    if [[ "$out" == *$'\n'* ]]; then
      status="${out##*$'\n'}"
      answer="${out%$'\n'*}"
    else
      status="$out"
      answer=""
    fi
    [[ "$status" =~ ^[0-9][0-9][0-9]$ ]] || status=000
    if [[ -n "${MAPI_STATUS_FILE:-}" ]]; then printf '%s' "$status" > "$MAPI_STATUS_FILE" 2> /dev/null || true; fi

    case "$status" in
      2??)
        printf '%s' "$answer"
        rm -rf "$work"
        return 0 ;;
      429) : ;;
      5??|000)
        if [[ "$only429" == yes ]]; then
          echo "x ${label} answered ${status}; not asked again, because the request may already have been done" >&2
          rm -rf "$work"
          return 1
        fi ;;
      *)
        echo "x ${label} answered ${status}: $(printf '%s' "$answer" | head -c 300)" >&2
        rm -rf "$work"
        return 1 ;;
    esac

    if [[ "$attempt" -ge "$attempts" ]]; then
      if [[ "$status" == 000 ]]; then
        echo "x ${label} had no answer on any of ${attempts} attempt(s), so nothing more was asked: $(head -c 300 "$work/stderr" | tr '\n' ' ')" >&2
      else
        echo "x ${label} answered ${status} on each of ${attempts} attempt(s), so the API is refusing for now (its rate limit, or an outage); nothing more was asked: $(printf '%s' "$answer" | head -c 300)" >&2
      fi
      rm -rf "$work"
      return 1
    fi

    # Twice as long each time, and never less than the API asked for.
    wait=$(( backoff * (1 << (attempt - 1)) ))
    if [[ "$wait" -gt "$max_wait" ]]; then
      wait="$max_wait"
    fi
    after=$(tr -d '\r' < "$work/headers" | grep -i '^retry-after:' | tail -n 1 | sed 's/^[^:]*:[[:space:]]*//' || true)
    if [[ "$after" =~ ^[0-9]+$ ]]; then
      if [[ "$after" -gt "$max_wait" ]]; then
        echo "x ${label} answered ${status} and asked for ${after} s before another try, longer than MAPI_MAX_WAIT (${max_wait} s); nothing more was asked." >&2
        rm -rf "$work"
        return 1
      fi
      if [[ "$after" -gt "$wait" ]]; then
        wait="$after"
      fi
    fi
    echo "! ${label} answered ${status} on attempt ${attempt} of ${attempts}; asking again in ${wait} s" >&2
    $sleeper "$wait"
    attempt=$((attempt + 1))
  done
}

# mapi METHOD PATH [BODY]
mapi() {
  local method="${1:-}" path="${2:-}" body="${3:-}"
  if [[ -z "$method" || "$path" != /* ]]; then
    echo "x usage: mapi METHOD /PATH [BODY]" >&2
    return 2
  fi
  if [[ -z "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
    echo "x SUPABASE_ACCESS_TOKEN is not set, so the Management API was not asked ${method} ${path}." >&2
    return 2
  fi
  patient_request "${method} ${path}" "$method" "${API:-https://api.supabase.com}${path}" "$body" \
    -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}"
}
