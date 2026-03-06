#!/usr/bin/env python3
"""Call Claude API to generate a fix for failing tests after a dependency update."""

import json
import os
import sys
from pathlib import Path

import anthropic

SYSTEM_PROMPT = """You are an expert code migration assistant. A dependency has been updated \
in this project and tests are now failing. Your job is to fix the source code so that all \
tests pass with the new dependency version.

STRICT RULES:
1. Do NOT delete or skip any tests
2. Do NOT remove existing functionality or code unless it directly conflicts with the new API
3. Only modify code to be compatible with the new dependency version
4. Prefer minimal, targeted changes over large rewrites
5. If a function/method was renamed in the new version, update the call sites
6. If an API changed its signature, update the arguments
7. If a module was reorganized, update the imports
8. Do NOT add new dependencies
9. Do NOT modify lockfiles or dependency manifests

RESPONSE FORMAT:
Respond with a JSON object containing an array of file edits:
{
  "analysis": "Brief explanation of what changed in the dependency and how to fix it",
  "can_fix": true,
  "edits": [
    {
      "file": "path/to/file.py",
      "search": "exact text to find in the file",
      "replace": "replacement text"
    }
  ]
}

If you cannot determine a fix, respond with:
{
  "analysis": "Explanation of why this cannot be auto-fixed",
  "can_fix": false,
  "edits": []
}

IMPORTANT: The "search" field must contain the EXACT text currently in the file, \
including whitespace and indentation. The "replace" field contains what it should be \
changed to."""


def build_user_message(context: dict, attempt: int, previous_attempts: list) -> str:
    """Build the user message with all context for the AI."""
    parts = []

    pr_info = context.get("pr_info", {})
    if pr_info.get("title"):
        parts.append(f"## PR Title\n{pr_info['title']}")
    if pr_info.get("body"):
        parts.append(f"## PR Description\n{pr_info['body'][:1000]}")

    pkg = context.get("updated_package", "")
    if pkg:
        parts.append(f"## Updated Package\n{pkg}")

    dep_diff = context.get("dependency_diff", "")
    if dep_diff:
        parts.append(f"## Dependency Changes\n```diff\n{dep_diff[:3000]}\n```")

    test_output = context.get("test_output", "")
    if test_output:
        parts.append(f"## Test Failure Output\n```\n{test_output[:15000]}\n```")

    source = context.get("source_contents", "")
    if source:
        parts.append(f"## Relevant Source Files\n{source[:30000]}")

    if previous_attempts:
        parts.append("## Previous Fix Attempts (did not resolve all failures)")
        for i, prev in enumerate(previous_attempts, 1):
            parts.append(f"### Attempt {i}")
            parts.append(f"Edits applied:\n```json\n{json.dumps(prev.get('edits', []), indent=2)[:2000]}\n```")
            if prev.get("test_output"):
                parts.append(f"Resulting test output:\n```\n{prev['test_output'][:3000]}\n```")

    parts.append(f"\nThis is fix attempt {attempt}. Please analyze the errors and provide targeted fixes.")

    return "\n\n".join(parts)


def call_claude(context: dict, attempt: int, previous_attempts: list) -> dict:
    """Call Claude API and return the parsed response."""
    client = anthropic.Anthropic()
    model = os.environ.get("AI_MODEL", "claude-sonnet-4-20250514")

    user_message = build_user_message(context, attempt, previous_attempts)

    response = client.messages.create(
        model=model,
        max_tokens=4096,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_message}],
    )

    response_text = response.content[0].text.strip()

    # Extract JSON from the response (handle markdown code blocks)
    if "```json" in response_text:
        response_text = response_text.split("```json")[1].split("```")[0].strip()
    elif "```" in response_text:
        response_text = response_text.split("```")[1].split("```")[0].strip()

    return json.loads(response_text)


def validate_response(result: dict, max_diff_lines: int) -> tuple[bool, str]:
    """Validate the AI response passes safety checks."""
    if not result.get("can_fix"):
        return False, result.get("analysis", "AI indicated it cannot fix this issue")

    edits = result.get("edits", [])
    if not edits:
        return False, "No edits provided"

    total_lines = 0
    for edit in edits:
        if not edit.get("file") or not edit.get("search"):
            return False, f"Invalid edit: missing file or search field"

        filepath = edit["file"]

        if not Path(filepath).exists():
            return False, f"File does not exist: {filepath}"

        # Block edits to lockfiles and dependency manifests
        blocked_patterns = [
            "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
            "poetry.lock", "Pipfile.lock", "Cargo.lock",
            "go.sum", "Gemfile.lock",
        ]
        if any(filepath.endswith(p) for p in blocked_patterns):
            return False, f"Refusing to edit lockfile: {filepath}"

        replace_text = edit.get("replace", "")
        total_lines += replace_text.count("\n") + 1

    if total_lines > max_diff_lines:
        return False, f"Edit too large ({total_lines} lines > {max_diff_lines} max)"

    return True, ""


def apply_edits(edits: list) -> tuple[bool, str]:
    """Apply the edits to the files. Returns success and error message."""
    for edit in edits:
        filepath = edit["file"]
        search = edit["search"]
        replace = edit.get("replace", "")

        try:
            content = Path(filepath).read_text()
        except Exception as e:
            return False, f"Cannot read {filepath}: {e}"

        if search not in content:
            # Try with normalized whitespace as fallback
            normalized_content = " ".join(content.split())
            normalized_search = " ".join(search.split())
            if normalized_search not in normalized_content:
                return False, f"Search text not found in {filepath}:\n{search[:200]}"

            # Find the original text by matching normalized form
            import re
            pattern = re.escape(normalized_search).replace(r"\ ", r"\s+")
            match = re.search(pattern, content)
            if match:
                content = content[:match.start()] + replace + content[match.end():]
            else:
                return False, f"Could not match normalized text in {filepath}"
        else:
            content = content.replace(search, replace, 1)

        Path(filepath).write_text(content)

    return True, ""


def main():
    context_file = sys.argv[1] if len(sys.argv) > 1 else ".ai-context.json"
    attempt = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    history_file = sys.argv[3] if len(sys.argv) > 3 else ".ai-history.json"
    max_diff_lines = int(os.environ.get("MAX_DIFF_LINES", "200"))

    with open(context_file) as f:
        context = json.load(f)

    previous_attempts = []
    if Path(history_file).exists():
        with open(history_file) as f:
            previous_attempts = json.load(f)

    print(f"Calling AI for fix attempt {attempt}...")
    try:
        result = call_claude(context, attempt, previous_attempts)
    except json.JSONDecodeError as e:
        print(f"::error::Failed to parse AI response as JSON: {e}")
        sys.exit(2)
    except Exception as e:
        print(f"::error::AI API call failed: {e}")
        sys.exit(2)

    print(f"AI analysis: {result.get('analysis', 'N/A')}")

    valid, reason = validate_response(result, max_diff_lines)
    if not valid:
        print(f"::warning::AI response rejected: {reason}")
        # Save to history
        previous_attempts.append({
            "edits": result.get("edits", []),
            "analysis": result.get("analysis", reason),
            "rejected": True,
            "rejection_reason": reason,
        })
        with open(history_file, "w") as f:
            json.dump(previous_attempts, f, indent=2)
        sys.exit(2)

    print(f"Applying {len(result['edits'])} edit(s)...")
    success, error = apply_edits(result["edits"])
    if not success:
        print(f"::warning::Failed to apply edits: {error}")
        previous_attempts.append({
            "edits": result["edits"],
            "analysis": result.get("analysis", ""),
            "apply_error": error,
        })
        with open(history_file, "w") as f:
            json.dump(previous_attempts, f, indent=2)
        sys.exit(2)

    # Save successful attempt to history (test result added by fix-loop.sh)
    previous_attempts.append({
        "edits": result["edits"],
        "analysis": result.get("analysis", ""),
    })
    with open(history_file, "w") as f:
        json.dump(previous_attempts, f, indent=2)

    # Save edits for PR comment
    with open(".ai-last-edits.json", "w") as f:
        json.dump(result, f, indent=2)

    print("Edits applied successfully.")


if __name__ == "__main__":
    main()
