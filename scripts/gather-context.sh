#!/usr/bin/env bash
set -euo pipefail

# Gather context about the dependency update and failing tests.
# Outputs a JSON file at $1 with all the context needed for the AI.

OUTPUT_FILE="${1:-.ai-context.json}"
BASE_BRANCH="${GITHUB_BASE_REF:-main}"

gather_dependency_diff() {
  git diff "origin/${BASE_BRANCH}...HEAD" -- \
    '*.lock' 'package.json' 'package-lock.json' 'yarn.lock' 'pnpm-lock.yaml' \
    'pyproject.toml' 'requirements*.txt' 'Pipfile.lock' 'poetry.lock' \
    'go.mod' 'go.sum' 'Cargo.toml' 'Cargo.lock' \
    'pom.xml' 'build.gradle' 'build.gradle.kts' \
    'Gemfile' 'Gemfile.lock' \
    2>/dev/null | head -500
}

gather_changed_files() {
  git diff --name-only "origin/${BASE_BRANCH}...HEAD" 2>/dev/null
}

gather_pr_info() {
  if [[ -n "${GITHUB_EVENT_PATH:-}" ]] && [[ -f "${GITHUB_EVENT_PATH}" ]]; then
    python3 -c "
import json, sys
with open('${GITHUB_EVENT_PATH}') as f:
    event = json.load(f)
pr = event.get('pull_request', {})
print(json.dumps({
    'title': pr.get('title', ''),
    'body': pr.get('body', '')[:2000] if pr.get('body') else '',
    'author': pr.get('user', {}).get('login', ''),
    'branch': pr.get('head', {}).get('ref', '')
}))
" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

find_importing_files() {
  local dep_name="$1"
  local results=""

  # Python imports
  results+=$(grep -rl "import ${dep_name}\|from ${dep_name}" --include='*.py' . 2>/dev/null | head -20 || true)
  # JS/TS imports
  results+=$(grep -rl "require(['\"]${dep_name}\|from ['\"]${dep_name}" --include='*.js' --include='*.ts' --include='*.jsx' --include='*.tsx' . 2>/dev/null | head -20 || true)
  # Go imports
  results+=$(grep -rl "\".*${dep_name}" --include='*.go' . 2>/dev/null | head -20 || true)
  # Rust use
  results+=$(grep -rl "use ${dep_name}" --include='*.rs' . 2>/dev/null | head -20 || true)

  echo "$results" | sort -u | head -15
}

extract_updated_package() {
  local pr_title
  pr_title=$(gather_pr_info | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))" 2>/dev/null || echo "")

  # Renovate format: "Update dependency <name> to <version>"
  # Dependabot format: "Bump <name> from <v1> to <v2>"
  python3 -c "
import re, sys
title = '''${pr_title}'''
# Renovate
m = re.search(r'[Uu]pdate (?:dependency )?(\S+)', title)
if m:
    print(m.group(1))
    sys.exit(0)
# Dependabot
m = re.search(r'[Bb]ump (\S+)', title)
if m:
    print(m.group(1))
    sys.exit(0)
print('')
" 2>/dev/null || echo ""
}

read_file_contents() {
  local files="$1"
  local max_chars=50000
  local total=0

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    [[ ! -f "$file" ]] && continue

    local size
    size=$(wc -c < "$file")
    if (( total + size > max_chars )); then
      break
    fi
    total=$((total + size))

    echo "=== FILE: $file ==="
    cat "$file"
    echo ""
  done <<< "$files"
}

# Main
DEP_DIFF=$(gather_dependency_diff)
CHANGED_FILES=$(gather_changed_files)
PR_INFO=$(gather_pr_info)
UPDATED_PKG=$(extract_updated_package)
TEST_OUTPUT=""
[[ -f ".ai-test-output.txt" ]] && TEST_OUTPUT=$(head -c 30000 .ai-test-output.txt)

IMPORTING_FILES=""
if [[ -n "$UPDATED_PKG" ]]; then
  IMPORTING_FILES=$(find_importing_files "$UPDATED_PKG")
fi

SOURCE_CONTENTS=$(read_file_contents "$IMPORTING_FILES")

python3 -c "
import json, sys

context = {
    'pr_info': json.loads('''${PR_INFO}'''),
    'updated_package': '''${UPDATED_PKG}''',
    'dependency_diff': $(python3 -c "import json; print(json.dumps('''${DEP_DIFF}'''[:5000]))"),
    'changed_files': '''${CHANGED_FILES}'''.strip().split('\n'),
    'test_output': open('.ai-test-output.txt').read()[:30000] if __import__('os').path.exists('.ai-test-output.txt') else '',
    'importing_files': '''${IMPORTING_FILES}'''.strip().split('\n') if '''${IMPORTING_FILES}''' else [],
    'source_contents': '''$(echo "$SOURCE_CONTENTS" | python3 -c "import sys; print(sys.stdin.read().replace('\\\\','\\\\\\\\').replace(\"'''\",\"\\\\'''\"))")'''
}

with open('${OUTPUT_FILE}', 'w') as f:
    json.dump(context, f, indent=2)
" 2>/dev/null || {
  # Fallback: simpler context gathering
  python3 << 'PYEOF'
import json, os

context = {
    "test_output": "",
    "dependency_diff": "",
    "changed_files": [],
    "source_contents": ""
}

if os.path.exists(".ai-test-output.txt"):
    with open(".ai-test-output.txt") as f:
        context["test_output"] = f.read()[:30000]

PYEOF
}

echo "Context gathered at ${OUTPUT_FILE}"
