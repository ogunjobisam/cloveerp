#!/usr/bin/env bash
#
# Pulls the PostgreSQL image every workflow runs and prints the name it was
# pulled under, for `docker run`:
#
#   image=$(supabase/ci/postgres_image.sh)
#   docker run -d ... "$image"
#
# The image is Supabase's 17.6, pinned: the one the product is verified
# against and the major version live runs. It is published in two registries,
# and each refuses an unauthenticated runner now and then: Docker Hub when a
# runner's address has pulled too often ("toomanyrequests", three times in a
# row on compat, 9 October), Amazon's public registry when a second's pulls
# are too many ("Rate exceeded", main's build the same evening). So each
# round asks Amazon's first and Docker Hub second, and a round that gets
# neither waits longer before the next; after the last the run fails, saying
# what each registry answered. Rehearsed by postgres_image_rehearsal.sh.
#
#   DOCKER        the command (default docker; the rehearsal's stand-in)
#   PULL_ROUNDS   how many rounds (default 5)
#   PULL_WAIT     seconds before the second round, doubled each round after
#                 (default 10, so 10, 20, 40, 80)
#   PULL_SLEEP    the command that waits (default sleep; the rehearsal's)
set -uo pipefail

TAG="17.6.1.167"
IMAGES=("public.ecr.aws/supabase/postgres:${TAG}" "supabase/postgres:${TAG}")
DOCKER_CMD="${DOCKER:-docker}"
ROUNDS="${PULL_ROUNDS:-5}"
WAIT="${PULL_WAIT:-10}"
SLEEP_CMD="${PULL_SLEEP:-sleep}"

last=()
for ((round = 1; round <= ROUNDS; round++)); do
  last=()
  for image in "${IMAGES[@]}"; do
    if out=$($DOCKER_CMD pull --quiet "$image" 2>&1); then
      echo "pulled ${image} (round ${round})" >&2
      echo "$image"
      exit 0
    fi
    last+=("${image}: $(printf '%s' "$out" | tail -n 1)")
  done
  if ((round < ROUNDS)); then
    echo "neither registry gave the image in round ${round}; asking again in ${WAIT}s" >&2
    $SLEEP_CMD "$WAIT"
    WAIT=$((WAIT * 2))
  fi
done

echo "::error::the PostgreSQL image could not be pulled from either registry in ${ROUNDS} rounds; the last answers:" >&2
printf '  %s\n' "${last[@]}" >&2
exit 1
