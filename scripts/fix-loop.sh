#!/usr/bin/env bash
set -euo pipefail

# Main fix loop: run tests, call AI, apply fix, repeat.
# Supports two modes:
#   AI_MODE=fix         — only fix failing tests (default)
#   AI_MODE=investigate  — also proactively update code when tests pass

MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
TEST_CMD="${TEST_CMD:?TEST_CMD is required}"
SCRIPTS_DIR="${SCRIPTS_DIR:?SCRIPTS_DIR is required}"
AI_MODE="${AI_MODE:-fix}"

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

    if [[ $exit_code -eq 127 ]] || grep -qi "command not found" "$TEST_OUTPUT_FILE" 2>/dev/null; then
      echo "::error::Test runner not found. Ensure your test framework (e.g. pytest) is listed as a project dependency."
      echo "::error::If using Poetry, add pytest to [tool.poetry.group.dev.dependencies] in pyproject.toml"
      return 2
    fi

    return 1
  fi
}

commit_fixes() {
  local mode="$1"
  local commit_msg

  if [[ "$mode" == "investigate" ]]; then
    commit_msg="$(cat <<'EOF'
chore: proactively update code for new dependency version

Applied by ai-dependency-fixer GitHub Action (investigate mode).
No API contracts were changed. Tests verified passing after update.
EOF
)"
  else
    commit_msg="$(cat <<'EOF'
fix: auto-fix breaking changes from dependency update

Applied by ai-dependency-fixer GitHub Action.
EOF
)"
  fi

  git config user.name "ai-dependency-fixer[bot]"
  git config user.email "ai-dependency-fixer[bot]@users.noreply.github.com"
  git add -A
  git commit -m "$commit_msg"
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
No tests were removed or skipped. No API contracts were changed.
</details>
COMMENT
)
  elif [[ "$status" == "investigated" ]]; then
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
### :robot: AI Dependency Fixer - Proactive Update

Tests were already passing, but the AI found code that could be updated for the new dependency version.

${edits_summary}

<details>
<summary>Review the changes carefully before merging.</summary>

The AI proactively updated internal implementation details to use current APIs from the new dependency version.
No tests were removed or skipped. No public API contracts were changed.
All tests verified passing after the update.
</details>
COMMENT
)
  elif [[ "$status" == "up-to-date" ]]; then
    body=$(cat <<COMMENT
### :robot: AI Dependency Fixer - No Changes Needed

Tests are passing and the AI reviewed the dependency changes — no code updates are needed.
The code is already compatible with the new dependency version.
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

run_fix_loop() {
  echo "[]" > "$HISTORY_FILE"

  for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    echo ""
    echo "--- Fix attempt $attempt of $MAX_ATTEMPTS ---"

    bash "$SCRIPTS_DIR/gather-context.sh" "$CONTEXT_FILE"

    set +e
    AI_MODE=fix python3 "$SCRIPTS_DIR/ai-fix.py" "$CONTEXT_FILE" "$attempt" "$HISTORY_FILE"
    ai_exit=$?
    set -e

    if [[ $ai_exit -ne 0 ]]; then
      echo "AI fix attempt $attempt failed to generate or apply a fix."
      git checkout -- . 2>/dev/null || true
      continue
    fi

    if [[ -n "${INSTALL_CMD:-}" ]]; then
      echo "::group::Reinstalling dependencies"
      eval "$INSTALL_CMD" 2>/dev/null || true
      echo "::endgroup::"
    fi

    if run_tests; then
      echo ""
      echo "Tests pass after attempt $attempt!"
      commit_fixes "fix"
      post_pr_comment "fixed" "$attempt"

      echo "result=fixed" >> "$GITHUB_OUTPUT"
      echo "attempts=$attempt" >> "$GITHUB_OUTPUT"
      cleanup_ai_files
      exit 0
    fi

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

    git checkout -- . 2>/dev/null || true
  done

  echo ""
  echo "=== All $MAX_ATTEMPTS fix attempts exhausted. Reverting. ==="
  git checkout -- . 2>/dev/null || true
  git clean -fd 2>/dev/null || true
  post_pr_comment "failed" "$MAX_ATTEMPTS"

  echo "result=failed" >> "$GITHUB_OUTPUT"
  echo "attempts=$MAX_ATTEMPTS" >> "$GITHUB_OUTPUT"
  cleanup_ai_files
  exit 1
}

run_investigation() {
  echo ""
  echo "--- Investigating dependency changes for proactive updates ---"
  echo "[]" > "$HISTORY_FILE"

  bash "$SCRIPTS_DIR/gather-context.sh" "$CONTEXT_FILE"

  set +e
  AI_MODE=investigate python3 "$SCRIPTS_DIR/ai-fix.py" "$CONTEXT_FILE" "1" "$HISTORY_FILE"
  ai_exit=$?
  set -e

  # Exit code 3 = AI found no changes needed
  if [[ $ai_exit -eq 3 ]]; then
    echo "AI investigation: no changes needed — code is already up to date."
    post_pr_comment "up-to-date" "0"
    echo "result=already-passing" >> "$GITHUB_OUTPUT"
    echo "attempts=0" >> "$GITHUB_OUTPUT"
    cleanup_ai_files
    exit 0
  fi

  if [[ $ai_exit -ne 0 ]]; then
    echo "AI investigation failed to generate or apply changes."
    git checkout -- . 2>/dev/null || true
    echo "result=already-passing" >> "$GITHUB_OUTPUT"
    echo "attempts=0" >> "$GITHUB_OUTPUT"
    cleanup_ai_files
    exit 0
  fi

  # AI applied changes — verify tests still pass
  if [[ -n "${INSTALL_CMD:-}" ]]; then
    echo "::group::Reinstalling dependencies"
    eval "$INSTALL_CMD" 2>/dev/null || true
    echo "::endgroup::"
  fi

  echo ""
  echo "--- Verifying tests still pass after proactive changes ---"
  if run_tests; then
    echo ""
    echo "Tests still pass after proactive update!"
    commit_fixes "investigate"
    post_pr_comment "investigated" "1"
    echo "result=fixed" >> "$GITHUB_OUTPUT"
    echo "attempts=1" >> "$GITHUB_OUTPUT"
    cleanup_ai_files
    exit 0
  else
    echo ""
    echo "::warning::Proactive changes broke tests — reverting all changes."
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    post_pr_comment "up-to-date" "0"
    echo "result=already-passing" >> "$GITHUB_OUTPUT"
    echo "attempts=0" >> "$GITHUB_OUTPUT"
    cleanup_ai_files
    exit 0
  fi
}

# --- Main ---

INITIAL_SHA=$(git rev-parse HEAD)

echo "=== AI Dependency Fixer ==="
echo "Mode: $AI_MODE"
echo "Test command: $TEST_CMD"
echo "Max attempts: $MAX_ATTEMPTS"

# Initial test run
echo ""
echo "--- Initial test run ---"
set +e
run_tests
initial_exit=$?
set -e

if [[ $initial_exit -eq 2 ]]; then
  echo "::error::Cannot proceed — test runner is not installed. This is a project configuration issue, not something the AI can fix."
  echo "result=failed" >> "$GITHUB_OUTPUT"
  echo "attempts=0" >> "$GITHUB_OUTPUT"
  cleanup_ai_files
  exit 1
fi

if [[ $initial_exit -eq 0 ]]; then
  if [[ "$AI_MODE" == "investigate" ]]; then
    echo ""
    echo "Tests are passing. Running investigation to check for proactive updates..."
    run_investigation
  else
    echo "result=already-passing" >> "$GITHUB_OUTPUT"
    echo "attempts=0" >> "$GITHUB_OUTPUT"
    cleanup_ai_files
    exit 0
  fi
else
  run_fix_loop
fi
