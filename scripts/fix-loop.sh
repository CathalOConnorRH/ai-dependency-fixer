#!/usr/bin/env bash
set -euo pipefail

# Main fix loop: run tests, call AI, apply fix, repeat.
# Exits with appropriate output for the GitHub Action.

MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
TEST_CMD="${TEST_CMD:?TEST_CMD is required}"
SCRIPTS_DIR="${SCRIPTS_DIR:?SCRIPTS_DIR is required}"

CONTEXT_FILE=".ai-context.json"
HISTORY_FILE=".ai-history.json"
TEST_OUTPUT_FILE=".ai-test-output.txt"

cleanup_ai_files() {
  rm -f "$CONTEXT_FILE" "$HISTORY_FILE" "$TEST_OUTPUT_FILE" ".ai-last-edits.json"
}

run_tests() {
  echo "::group::Running tests: $TEST_CMD"
  set +e
  eval "$TEST_CMD" > "$TEST_OUTPUT_FILE" 2>&1
  local exit_code=$?
  set -e
  echo "::endgroup::"

  if [[ $exit_code -eq 0 ]]; then
    echo "Tests passed."
    return 0
  else
    echo "Tests failed (exit code: $exit_code)."
    tail -50 "$TEST_OUTPUT_FILE"
    return 1
  fi
}

commit_fixes() {
  git config user.name "ai-dependency-fixer[bot]"
  git config user.email "ai-dependency-fixer[bot]@users.noreply.github.com"
  git add -A
  git commit -m "$(cat <<'EOF'
fix: auto-fix breaking changes from dependency update

Applied by ai-dependency-fixer GitHub Action.
EOF
)"
  git push
}

post_pr_comment() {
  local status="$1"
  local attempts="$2"
  local body=""

  if [[ "$status" == "fixed" ]]; then
    local edits_summary=""
    if [[ -f ".ai-last-edits.json" ]]; then
      edits_summary=$(python3 -c "
import json
with open('.ai-last-edits.json') as f:
    data = json.load(f)
print(f\"**Analysis:** {data.get('analysis', 'N/A')}\n\")
for e in data.get('edits', []):
    print(f\"- \`{e['file']}\`: updated code\")
" 2>/dev/null || echo "")
    fi

    body=$(cat <<COMMENT
### :robot: AI Dependency Fixer - Success

Tests were failing after the dependency update. AI auto-fixed the code in **${attempts} attempt(s)**.

${edits_summary}

<details>
<summary>Review the changes carefully before merging.</summary>

The AI made minimal, targeted changes to adapt the code to the new dependency version.
No tests were removed or skipped.
</details>
COMMENT
)
  elif [[ "$status" == "failed" ]]; then
    local test_errors=""
    if [[ -f "$TEST_OUTPUT_FILE" ]]; then
      test_errors=$(tail -30 "$TEST_OUTPUT_FILE" || true)
    fi

    local attempt_history=""
    if [[ -f "$HISTORY_FILE" ]]; then
      attempt_history=$(python3 -c "
import json
with open('${HISTORY_FILE}') as f:
    data = json.load(f)
for i, a in enumerate(data, 1):
    print(f'**Attempt {i}:** {a.get(\"analysis\", \"N/A\")}')
    if a.get('rejected'):
        print(f'  Rejected: {a.get(\"rejection_reason\", \"\")}')
    if a.get('apply_error'):
        print(f'  Apply error: {a.get(\"apply_error\", \"\")}')
" 2>/dev/null || echo "No history available.")
    fi

    body=$(cat <<COMMENT
### :robot: AI Dependency Fixer - Needs Manual Fix

Tests are failing after the dependency update. AI was unable to fix the code after **${attempts} attempt(s)**.

<details>
<summary>Fix attempts</summary>

${attempt_history}
</details>

<details>
<summary>Last test output</summary>

\`\`\`
${test_errors}
\`\`\`
</details>

This PR needs manual intervention.
COMMENT
)
  fi

  if [[ -n "$body" ]] && [[ -n "${GITHUB_TOKEN:-}" ]]; then
    local pr_number
    pr_number=$(python3 -c "
import json, os
with open(os.environ.get('GITHUB_EVENT_PATH', '/dev/null')) as f:
    event = json.load(f)
print(event.get('pull_request', {}).get('number', ''))
" 2>/dev/null || echo "")

    if [[ -n "$pr_number" ]]; then
      gh pr comment "$pr_number" --body "$body" 2>/dev/null || \
        echo "::warning::Failed to post PR comment"
    fi
  fi
}

# --- Main ---

# Save initial state for revert
INITIAL_SHA=$(git rev-parse HEAD)

echo "=== AI Dependency Fixer ==="
echo "Test command: $TEST_CMD"
echo "Max attempts: $MAX_ATTEMPTS"

# Initial test run
echo ""
echo "--- Initial test run ---"
if run_tests; then
  echo "result=already-passing" >> "$GITHUB_OUTPUT"
  echo "attempts=0" >> "$GITHUB_OUTPUT"
  cleanup_ai_files
  exit 0
fi

# Tests are failing, start fix loop
echo "[]" > "$HISTORY_FILE"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo ""
  echo "--- Fix attempt $attempt of $MAX_ATTEMPTS ---"

  # Gather context
  bash "$SCRIPTS_DIR/gather-context.sh" "$CONTEXT_FILE"

  # Call AI for fix
  set +e
  python3 "$SCRIPTS_DIR/ai-fix.py" "$CONTEXT_FILE" "$attempt" "$HISTORY_FILE"
  ai_exit=$?
  set -e

  if [[ $ai_exit -ne 0 ]]; then
    echo "AI fix attempt $attempt failed to generate or apply a fix."
    # Revert any partial changes from this attempt
    git checkout -- . 2>/dev/null || true
    continue
  fi

  # Re-install dependencies in case imports changed
  if [[ -n "${INSTALL_CMD:-}" ]]; then
    echo "::group::Reinstalling dependencies"
    eval "$INSTALL_CMD" 2>/dev/null || true
    echo "::endgroup::"
  fi

  # Run tests with the fix applied
  if run_tests; then
    echo ""
    echo "Tests pass after attempt $attempt!"
    commit_fixes
    post_pr_comment "fixed" "$attempt"

    echo "result=fixed" >> "$GITHUB_OUTPUT"
    echo "attempts=$attempt" >> "$GITHUB_OUTPUT"
    cleanup_ai_files
    exit 0
  fi

  # Tests still failing — update history with new test output
  python3 -c "
import json
with open('${HISTORY_FILE}') as f:
    history = json.load(f)
if history:
    with open('${TEST_OUTPUT_FILE}') as f:
        history[-1]['test_output'] = f.read()[:3000]
    with open('${HISTORY_FILE}', 'w') as f:
        json.dump(history, f, indent=2)
" 2>/dev/null || true

  # Revert changes for next attempt (start fresh each time)
  git checkout -- . 2>/dev/null || true
done

# All attempts exhausted
echo ""
echo "=== All $MAX_ATTEMPTS attempts exhausted. Reverting. ==="
git checkout -- . 2>/dev/null || true
git clean -fd 2>/dev/null || true
post_pr_comment "failed" "$MAX_ATTEMPTS"

echo "result=failed" >> "$GITHUB_OUTPUT"
echo "attempts=$MAX_ATTEMPTS" >> "$GITHUB_OUTPUT"
cleanup_ai_files
exit 1
