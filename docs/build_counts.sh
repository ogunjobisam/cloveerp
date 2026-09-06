#!/usr/bin/env bash
#
# The documents quote the database.
#
# README.md and docs/ARCHITECTURE.md carry figures — migrations, doors, tables,
# suites, decisions, the Part 5 totals — and for months they carried the
# figures of the day they were written. A number nothing checks is a number
# that drifts, and this repository's own architecture document said so about
# itself while quoting 49 migrations against 259 on disk.
#
# So the figures are held in markers:
#
#     <!-- count:doors -->543<!-- /count -->
#
# and this script reads the built database and either rewrites every marker
# (--write), refuses when any marker disagrees with the database (--check, the
# CI step), or prints the figures as JSON (--json) for the Word document's
# builder. The words around the markers are written by a person; the numbers
# inside them are not.
#
# Usage: docs/build_counts.sh --check | --write | --json
# Reads PSQL from the environment like the CI scripts (a psql command line
# pointed at the built database); the migration count is read from the
# repository.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
mode="${1:---check}"

migrations=$(ls "$here"/supabase/migrations/*.sql | wc -l | tr -d ' ')
sql_lines=$(cat "$here"/supabase/migrations/*.sql | wc -l | tr -d ' ')

# One row, one query, every figure the documents quote. Each is a count over
# the catalogue or a register, never a literal.
json=$($PSQL_CMD -tAc "
select jsonb_build_object(
  'migrations', ${migrations},
  'sql_lines', ${sql_lines},
  'erp_tables', (select count(*) from pg_tables where schemaname = 'erp'),
  'erp_views', (select count(*) from pg_views where schemaname = 'erp'),
  'ref_tables', (select count(*) from pg_tables where schemaname = 'erp_ref'),
  'meta_tables', (select count(*) from pg_tables where schemaname = 'erp_meta'),
  'ai_tables', (select count(*) from pg_tables where schemaname = 'erp_ai'),
  'ingress_functions', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'erp_ingress'),
  'doors', (select count(*) from erp.door_manifest()),
  'doors_writing', (select count(*) from erp.door_manifest() where is_writer),
  'api_only_doors', (select count(*) from erp_meta.api_only_door),
  'doors_pending_screen', (select count(*) from erp_meta.api_only_door where caller = 'pending_screen'),
  'assertions', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'erp' and p.proname like 'assert\_%'),
  'suites', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'erp_test' and p.proname like '%\_suite' and p.proname not like 'assert\_%'),
  'catalogue_checks', (select count(*) from erp.ci_check_catalogue()),
  'diagnostic_checks', (select count(*) from erp_meta.diagnostic_check),
  'diagnostic_checks_in_ci', (select count(*) from erp_meta.diagnostic_check where runs_in_ci),
  'policies', (select count(*) from pg_policies where schemaname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_ingress')),
  'triggers', (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_ingress') and not t.tgisinternal),
  'enums', (select count(*) from pg_type t join pg_namespace n on n.oid = t.typnamespace where n.nspname in ('erp', 'erp_ref', 'erp_meta') and t.typtype = 'e'),
  'product_decisions', (select count(*) from erp_ref.product_decision),
  'product_decision_bindings', (select count(*) from erp_ref.product_decision_check),
  'policy_decisions', (select count(*) from erp_meta.policy_decision),
  'policy_decisions_open', (select count(*) from erp_meta.policy_decision where status = 'open'),
  'part5_total', (select count(*) from erp_ref.part5_capability),
  'part5_built', (select count(*) from erp_ref.part5_capability where status = 'built'),
  'part5_partial', (select count(*) from erp_ref.part5_capability where status = 'partial'),
  'part5_absent', (select count(*) from erp_ref.part5_capability where status = 'absent'),
  'modules', (select count(*) from erp_ref.module),
  'legislation_packs', (select count(*) from erp_ref.legislation_pack),
  'locales_with_strings', (select count(distinct locale) from erp_ref.resource),
  'en_strings', (select count(*) from erp_ref.resource where locale = 'en'),
  'de_strings', (select count(*) from erp_ref.resource where locale = 'de'),
  'help_topics', (select count(*) from erp_ref.help_topic),
  'job_handlers', (select count(*) from erp_ref.job_handler where is_current),
  'platform_components', (select count(*) from erp_ref.platform_component),
  'platform_dependencies', (select count(*) from erp_ref.platform_dependency),
  'definer_allowances', (select count(*) from erp_meta.security_definer_allowance),
  'write_allowances', (select count(*) from erp_meta.public_write_allowance),
  'promotable_surfaces', (select count(*) from erp_meta.promotable_surface),
  'spec_version', 'v1.6'
);")

if [[ "$mode" == "--json" ]]; then
  echo "$json"
  exit 0
fi

python3 - "$mode" "$json" "$here/docs/what_has_been_built/counts.json" "$here/README.md" "$here/docs/ARCHITECTURE.md" <<'PY'
import json, re, sys
mode, payload = sys.argv[1], json.loads(sys.argv[2])
counts_path, files = sys.argv[3], sys.argv[4:]
pat = re.compile(r'<!-- count:([a-z0-9_]+) -->(.*?)<!-- /count -->', re.S)
drift, unknown = [], []
# The Word document's builder reads counts.json rather than the database, so
# the file is written here (--write) and compared here (--check): a stale
# counts.json is a document quoting a build that no longer exists.
try:
    held_counts = json.load(open(counts_path))
except FileNotFoundError:
    held_counts = {}
for key, want in payload.items():
    if held_counts.get(key) != want:
        drift.append((counts_path, key, held_counts.get(key), want))
if mode == "--write":
    with open(counts_path, "w") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write("\n")
for path in files:
    src = open(path).read()
    def sub(m):
        key, held = m.group(1), m.group(2)
        if key not in payload:
            unknown.append((path, key))
            return m.group(0)
        want = str(payload[key])
        if held != want:
            drift.append((path, key, held, want))
        return f"<!-- count:{key} -->{want}<!-- /count -->"
    out = pat.sub(sub, src)
    if mode == "--write" and out != src:
        open(path, "w").write(out)
for path, key in unknown:
    print(f"{path}: marker {key} names a figure the script does not compute", file=sys.stderr)
if unknown:
    sys.exit(1)
if mode == "--check":
    for path, key, held, want in drift:
        print(f"{path}: {key} says {held}, the database says {want}", file=sys.stderr)
    if drift:
        print(f"CLOVEERP_DOCUMENTS_DRIFTED: {len(drift)} figure(s) disagree with the database; run docs/build_counts.sh --write", file=sys.stderr)
        sys.exit(1)
    n = sum(len(pat.findall(open(p).read())) for p in files)
    print(f"documents: {n} figures agree with the database")
elif mode == "--write":
    print(f"documents: {len(drift)} figure(s) rewritten")
else:
    print(f"usage: {sys.argv[0]} --check | --write | --json", file=sys.stderr)
    sys.exit(2)
PY
