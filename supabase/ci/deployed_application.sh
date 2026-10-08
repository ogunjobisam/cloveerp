#!/usr/bin/env bash
# What the application Worker runs, and the record of it.
#
#   deployed_application.sh read   <environment>
#   deployed_application.sh record <environment> <sha> <note>
#
# The environment is application-production or application-staging, after
# CLOVEERP_APP_ROUTES. app.yml records every deploy as a GitHub deployment
# of that environment, marked successful; read prints the newest one's
# commit and "recorded". Before the first record was kept it prints the
# commit of the newest app run whose Deploy step passed, and "fallback":
# that run ran on main's head, at or after the commit it shipped. It prints
# nothing when neither says.
#
# Every call is an assignment, so a GitHub API call that fails fails this
# script. A caller must never read silence as "nothing is deployed": app.yml
# would then ship backwards. Read by app.yml (never backwards) and by the
# schema build's compat job (the application the Worker runs keeps every
# door it calls).
set -euo pipefail

mode="${1:?read or record}"
environment="${2:?application-production or application-staging}"
R="repos/${GITHUB_REPOSITORY:?}"

case "$mode" in
  read)
    ids=$(gh api "${R}/deployments?environment=${environment}&per_page=50" \
            --jq 'sort_by(.created_at) | reverse | .[].id')
    for id in $ids; do
      state=$(gh api "${R}/deployments/${id}/statuses?per_page=1" --jq '.[0].state // ""')
      if [[ "$state" == success ]]; then
        sha=$(gh api "${R}/deployments/${id}" --jq '.sha')
        echo "${sha} recorded"
        exit 0
      fi
    done
    runs=$(gh api --paginate "${R}/actions/workflows/app.yml/runs?branch=main&status=completed&per_page=100" \
             --jq '.workflow_runs[].id')
    for id in $runs; do
      n=$(gh api "${R}/actions/runs/${id}/jobs" \
            --jq '[.jobs[].steps[] | select(.name == "Deploy" and .conclusion == "success")] | length')
      if [[ "$n" -gt 0 ]]; then
        sha=$(gh api "${R}/actions/runs/${id}" --jq '.head_sha')
        echo "${sha} fallback"
        exit 0
      fi
    done
    ;;
  record)
    sha="${3:?the commit the Worker runs}"
    note="${4:?what deployed it}"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::'${sha}' is not a full commit" >&2; exit 1; }
    production=false
    [[ "$environment" == application-production ]] && production=true
    id=$(jq -n --arg ref "$sha" --arg env "$environment" --arg note "$note" --argjson prod "$production" \
           '{ref: $ref, environment: $env, auto_merge: false, required_contexts: [],
             description: $note, production_environment: $prod}' \
         | gh api -X POST "${R}/deployments" --input - --jq '.id')
    [[ "$id" =~ ^[0-9]+$ ]] || { echo "::error::GitHub made no deployment record for ${sha}" >&2; exit 1; }
    gh api -X POST "${R}/deployments/${id}/statuses" -f state=success \
      -f "log_url=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-0}" > /dev/null
    echo "recorded ${sha} as deployment ${id} of ${environment}"
    ;;
  *)
    echo "usage: deployed_application.sh read <environment> | record <environment> <sha> <note>" >&2
    exit 2
    ;;
esac
