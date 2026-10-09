#!/usr/bin/env bash
#
# supabase/ci/postgres_image.sh, rehearsed with a docker that answers from a
# script: the first registry when it gives the image, the second when the
# first refuses, a later round when both refuse at first, the waits doubling,
# and a failure naming both registries' answers when neither ever gives it.
# Seconds, no docker.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/postgres_image.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The stand-in docker: `docker pull --quiet <image>` succeeds when the image's
# registry is in $work/gives, after that registry has refused as many times
# as $work/refuse-<registry> says. Every pull and wait is logged.
cat > "$work/docker" <<'D'
#!/usr/bin/env bash
image="${@: -1}"
case "$image" in public.ecr.aws/*) reg=ecr ;; *) reg=hub ;; esac
echo "pull $image" >> "$W/log"
n=$(cat "$W/refuse-$reg" 2>/dev/null || echo 0)
if [[ "$n" -gt 0 ]]; then echo $((n - 1)) > "$W/refuse-$reg"; echo "toomanyrequests from $reg" >&2; exit 1; fi
if grep -qx "$reg" "$W/gives" 2>/dev/null; then echo "$image"; exit 0; fi
echo "toomanyrequests from $reg" >&2; exit 1
D
printf '#!/usr/bin/env bash\necho "wait $1" >> "$W/log"\n' > "$work/sleep"
chmod +x "$work/docker" "$work/sleep"
export W="$work"

CASES=0
FAILED=0
check() {
  CASES=$((CASES + 1))
  if eval "$1"; then echo "  ok   $2"; else echo "  FAIL $2"; FAILED=$((FAILED + 1)); fi
}
fresh() { rm -f "$work"/log "$work"/gives "$work"/refuse-*; touch "$work/log"; }
go() { out=$(DOCKER="$work/docker" PULL_SLEEP="$work/sleep" PULL_ROUNDS=4 PULL_WAIT=3 "$SCRIPT" 2> "$work/err"); code=$?; }

fresh; echo ecr > "$work/gives"; echo hub >> "$work/gives"; go
check '[[ $code -eq 0 && "$out" == "public.ecr.aws/supabase/postgres:17.6.1.167" && $(grep -c pull "$work/log") -eq 1 ]]' \
      "Amazon's registry first, and nothing else asked when it gives the image"

fresh; echo hub > "$work/gives"; go
check '[[ $code -eq 0 && "$out" == "supabase/postgres:17.6.1.167" && ! $(grep wait "$work/log") ]]' \
      "Docker Hub in the same round when Amazon's refuses, with no wait"

fresh; echo ecr > "$work/gives"; echo 2 > "$work/refuse-ecr"; go
check '[[ $code -eq 0 && "$out" == public.ecr.aws/* && "$(grep wait "$work/log" | tr "\n" " ")" == "wait 3 wait 6 " ]]' \
      "a later round when both refuse at first, the wait doubling"

fresh; go
check '[[ $code -ne 0 && -z "$out" && $(grep -c pull "$work/log") -eq 8 && $(grep -c wait "$work/log") -eq 3 ]]' \
      "every round asked of both, no wait after the last, and nothing printed for docker run"
check 'grep -q "could not be pulled from either registry in 4 rounds" "$work/err" && grep -q "public.ecr.aws/supabase/postgres:17.6.1.167: toomanyrequests from ecr" "$work/err" && grep -q "^  supabase/postgres:17.6.1.167: toomanyrequests from hub" "$work/err"' \
      "the failure names what each registry answered last"

check '[[ -z "$(grep -rn "postgres:17\.6" "$HERE/../../.github/workflows" | grep -v "github runner, supabase/postgres")" ]]' \
      "no workflow pulls the image by name: each runs what this script pulled"

echo
if [[ "$FAILED" -gt 0 ]]; then
  echo "postgres image: ${FAILED} of ${CASES} case(s) failed"
  exit 1
fi
echo "postgres image: ${CASES}/${CASES} cases passed"
