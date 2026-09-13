#!/usr/bin/env bash
# Every free-text field in a form must say what belongs in it: a placeholder,
# a hint, or both. A box labelled "Code" with nothing beside it is a guess.
set -euo pipefail
cd "$(dirname "$0")/../.."

bad=$(python3 - <<'PY'
import glob, re
bad = []
for f in glob.glob('src/**/*.tsx', recursive=True):
    txt = open(f).read()
    for m in re.finditer(r'\{[^{}]*kind:\s*"text"[^{}]*\}', txt):
        block = m.group(0)
        if 'hint:' in block or 'placeholder:' in block:
            continue
        if 'name: string' in block or 'name:' not in block or 'label:' not in block:
            continue  # a type declaration, not a field
        bad.append(f"{f}:{txt[:m.start()].count(chr(10)) + 1}: {' '.join(block.split())}")
print('\n'.join(bad))
PY
)

if [ -n "$bad" ]; then
  echo "Text fields with no placeholder and no hint:"
  echo "$bad"
  exit 1
fi
echo "form fields: every text field explains itself"
