#!/usr/bin/env bash
#
# Every value a screen writes is read by something.
#
# The twin of app_columns.sh. That one refuses a name a screen READS off a door
# that does not return it; this one refuses a value a screen WRITES that nothing
# reads.
#
# It is the worse half of the same defect. A name the door does not return
# renders as an em dash or a zero, and somebody eventually asks about it. A
# control that writes a value nothing consults renders perfectly: the field
# saves, the toast says saved, the value is still there the next time the screen
# is opened, and the behaviour it promises never happens. Nobody asks about a
# setting that looks like it worked.
#
# One audit on 16 September found the class repeating. An entire approval-bands
# screen that changed who approves nothing. The account determination matrix and
# its "record a deliberate override". A location's capacity, under the words
# "Holds at most", which put-away has never consulted, and its count_class,
# which cycle counting has never consulted. Four fields on erp.release_area that
# nothing tests. "Sourcing split %", which splits nothing. A reason code's
# requires_note and requires_approval, enforced by nothing. The repository had
# hit the same class by hand twice before — 20260904360000 says "erp.scan_rule
# WAS READ BY NOTHING" — and each time the instance was fixed and the next one
# left uncovered.
#
# No suite can see this class, and that is not an oversight: every one of those
# columns HAS a suite. A suite that writes a setting and reads it back proves
# the write. It agrees, perfectly, with a product that never consults the value
# again. Neither can TypeScript help: the field is on the form, the door takes
# the argument, the argument reaches the column, and every type lines up.
#
# So erp.assert_write_only_columns() derives both halves FROM THE BUILT
# DATABASE: the columns a maintenance door can write, by walking
# pg_get_functiondef one or two hops into the erp.* routines it delegates to,
# and the names anything anywhere uses in a position that changed an outcome —
# a where, a case, a join predicate, an order by, an arithmetic expression, an
# assignment, an argument handed on. A column in the first set and not the
# second is refused unless erp_meta.write_only_column says, in writing, why it
# is written anyway.
#
# The migration 20260916400000 carries the scope this covers and the imprecision
# it accepts, at length, including why `select *` and to_jsonb(t) are not
# counted as reads.
#
# Usage: supabase/ci/write_only_columns.sh
# Reads PSQL from the environment like run_checks.sh. Prints the count.
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"

# The check reads the built database. Without psql there is no database to read,
# and a check that cannot run must say so rather than exit clean.
psql_bin="${PSQL_CMD%% *}"
if ! command -v "$psql_bin" >/dev/null 2>&1; then
  echo "write_only_columns.sh: '$psql_bin' is not on PATH." >&2
  echo "  This check asks the built database which columns a door can write and" >&2
  echo "  which names anything reads to decide something; neither can be answered" >&2
  echo "  from the migration text. Point PSQL at a database built from" >&2
  echo "  supabase/migrations (see .github/workflows/schema.yml) and run it again." >&2
  exit 127
fi

$PSQL_CMD -tAc "select erp.assert_write_only_columns();"

# The register, listed rather than counted, so a reader of the build log can see
# what is written into the dark today without opening the database. A row is
# either a deliberate note, label or hand-off, or a gap whose reason says so.
$PSQL_CMD -tAc "
  select format('  %s.%s.%s — %s', schema_name, table_name, column_name,
                left(rationale, 110))
    from erp_meta.write_only_column
   order by schema_name, table_name, column_name;"
