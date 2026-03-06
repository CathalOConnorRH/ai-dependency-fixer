#!/usr/bin/env python3
"""Call an LLM API to analyze dependency updates and generate safe code fixes.

Supports two modes:
- "fix": Fix failing tests after a dependency update (reactive)
- "investigate": Proactively review all dependency changes and update code (proactive)

Supports Anthropic (Claude), OpenAI, and OpenAI-compatible self-hosted models.
"""

import json
import os
import sys
from pathlib import Path

SYSTEM_PROMPT_FIX = """\
You are an expert code migration assistant. A dependency has been updated \
in this project and tests are now failing. Your job is to fix the source code so that all \
tests pass with the new dependency version.

STRICT RULES:
1. Do NOT delete or skip any tests
2. Do NOT remove existing functionality or code unless it directly conflicts with the new API
3. Do NOT change the signature, return type, or behavior of any public function, class, or method \
that other services or modules might depend on — preserve all API contracts
4. Only modify code to be compatible with the new dependency version
5. Prefer minimal, targeted changes over large rewrites
6. If a function/method was renamed in the new version, update the call sites
7. If an API changed its signature, update the arguments
8. If a module was reorganized, update the imports
9. Do NOT add new dependencies
10. Do NOT modify lockfiles or dependency manifests
11. After your changes, the code MUST function exactly as it did before — same inputs, same outputs, \
same side effects

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

If you cannot determine a fix, or if the only way to fix it would require removing code or \
changing API contracts, respond with:
{
  "analysis": "Explanation of why this cannot be auto-fixed",
  "can_fix": false,
  "edits": []
}

IMPORTANT: The "search" field must contain the EXACT text currently in the file, \
including whitespace and indentation. The "replace" field contains what it should be \
changed to."""

SYSTEM_PROMPT_INVESTIGATE = """\
You are an expert code migration assistant. A dependency has been updated in this project. \
Tests are currently passing, but the code may be using deprecated APIs, outdated patterns, \
or features that have changed in the new version. Your job is to proactively update the code \
to use the current recommended APIs from the new dependency version.

STRICT RULES — YOU MUST FOLLOW ALL OF THESE:
1. Do NOT delete or skip any tests
2. Do NOT remove any existing functionality, code, functions, classes, or methods
3. Do NOT change the signature, return type, or behavior of any public function, class, or method — \
preserve all API contracts that other services or modules might depend on
4. Do NOT change the external behavior of the code — same inputs must produce same outputs with same side effects
5. Only update internal implementation details to use the new dependency's recommended APIs
6. If a function/method was deprecated in the new version, update to its replacement while keeping \
the wrapping function's contract identical
7. If an API changed its recommended usage pattern, update the internal call while preserving the \
outer interface
8. Do NOT add new dependencies
9. Do NOT modify lockfiles or dependency manifests
10. Prefer minimal, targeted changes — do not refactor code that is not related to the dependency update
11. If no changes are needed (the code is already up to date), say so — do not make changes for the sake of it

CRITICAL: Your changes must NEVER leave the code in a broken state. If you are unsure whether a \
change is safe, do NOT make it. It is always better to leave working code alone than to risk \
breaking it.

RESPONSE FORMAT:
Respond with a JSON object containing an array of file edits:
{
  "analysis": "Brief explanation of what was updated in the dependency and what proactive changes are recommended",
  "can_fix": true,
  "edits": [
    {
      "file": "path/to/file.py",
      "search": "exact text to find in the file",
      "replace": "replacement text"
    }
  ]
}

If no changes are needed (code is already compatible and up to date), respond with:
{
  "analysis": "The code is already using current APIs and no changes are needed",
  "can_fix": false,
  "edits": []
}

If changes would require removing code or altering API contracts, respond with:
{
  "analysis": "Explanation of what changed and why it cannot be safely auto-updated",
  "can_fix": false,
  "edits": []
}

IMPORTANT: The "search" field must contain the EXACT text currently in the file, \
including whitespace and indentation. The "replace" field contains what it should be \
changed to."""

PROVIDER_DEFAULTS = {
    "anthropic": "claude-sonnet-4-20250514",
    "openai": "gpt-4o",
    "openai-compatible": "gpt-4o",
}


def get_system_prompt() -> str:
    mode = (os.environ.get("AI_MODE") or "fix").lower()
    if mode == "investigate":
        return SYSTEM_PROMPT_INVESTIGATE
    return SYSTEM_PROMPT_FIX


def build_user_message(context: dict, attempt: int, previous_attempts: list) -> str:
    """Build the user message with all context for the AI."""
    mode = (os.environ.get("AI_MODE") or "fix").lower()
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
        if mode == "investigate":
            parts.append(
                f"## Current Test Output (tests are passing)\n```\n{test_output[:15000]}\n```"
            )
        else:
            parts.append(f"## Test Failure Output\n```\n{test_output[:15000]}\n```")

    source = context.get("source_contents", "")
    if source:
        parts.append(f"## Relevant Source Files\n{source[:30000]}")

    if previous_attempts:
        parts.append("## Previous Attempts (did not resolve all issues)")
        for i, prev in enumerate(previous_attempts, 1):
            parts.append(f"### Attempt {i}")
            parts.append(
                f"Edits applied:\n```json\n{json.dumps(prev.get('edits', []), indent=2)[:2000]}\n```"
            )
            if prev.get("test_output"):
                parts.append(
                    f"Resulting test output:\n```\n{prev['test_output'][:3000]}\n```"
                )

    if mode == "investigate":
        parts.append(
            f"\nThis is investigation attempt {attempt}. Review the dependency changes and source files. "
            "If the code uses deprecated or changed APIs from the updated dependency, provide targeted edits "
            "to bring the code up to date. Do NOT change any public API contracts. Do NOT remove any code. "
            "If the code is already compatible and up to date, respond with can_fix: false."
        )
    else:
        parts.append(
            f"\nThis is fix attempt {attempt}. Please analyze the errors and provide targeted fixes."
        )

    return "\n\n".join(parts)


def call_anthropic(user_message: str, model: str, system_prompt: str) -> str:
    """Call the Anthropic API and return the raw response text."""
    import anthropic

    client = anthropic.Anthropic()
    response = client.messages.create(
        model=model,
        max_tokens=4096,
        system=system_prompt,
        messages=[{"role": "user", "content": user_message}],
    )
    return response.content[0].text.strip()


def call_openai(
    user_message: str, model: str, system_prompt: str, base_url: str | None = None
) -> str:
    """Call the OpenAI (or OpenAI-compatible) API and return the raw response text."""
    import openai

    kwargs = {}
    if base_url:
        kwargs["base_url"] = base_url
        api_key = os.environ.get("AI_API_KEY", "not-needed")
        kwargs["api_key"] = api_key

    client = openai.OpenAI(**kwargs)
    response = client.chat.completions.create(
        model=model,
        max_tokens=4096,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_message},
        ],
        temperature=0,
    )
    return response.choices[0].message.content.strip()


def call_llm(context: dict, attempt: int, previous_attempts: list) -> dict:
    """Route to the configured LLM provider and return the parsed response."""
    provider = (os.environ.get("AI_PROVIDER") or "anthropic").lower()
    default_model = PROVIDER_DEFAULTS.get(provider, PROVIDER_DEFAULTS["openai"])
    model = os.environ.get("AI_MODEL") or default_model
    system_prompt = get_system_prompt()

    user_message = build_user_message(context, attempt, previous_attempts)

    if provider == "anthropic":
        response_text = call_anthropic(user_message, model, system_prompt)
    elif provider in ("openai", "openai-compatible"):
        base_url = os.environ.get("AI_BASE_URL") or None
        response_text = call_openai(
            user_message, model, system_prompt, base_url=base_url
        )
    else:
        raise ValueError(
            f"Unknown AI provider: '{provider}'. "
            "Supported providers: anthropic, openai, openai-compatible"
        )

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
            return False, "Invalid edit: missing file or search field"

        filepath = edit["file"]

        if not Path(filepath).exists():
            return False, f"File does not exist: {filepath}"

        blocked_patterns = [
            "package-lock.json",
            "yarn.lock",
            "pnpm-lock.yaml",
            "poetry.lock",
            "Pipfile.lock",
            "Cargo.lock",
            "go.sum",
            "Gemfile.lock",
        ]
        if any(filepath.endswith(p) for p in blocked_patterns):
            return False, f"Refusing to edit lockfile: {filepath}"

        blocked_manifests = [
            "package.json",
            "pyproject.toml",
            "requirements.txt",
            "Pipfile",
            "Cargo.toml",
            "go.mod",
            "pom.xml",
            "build.gradle",
            "build.gradle.kts",
            "Gemfile",
        ]
        if any(filepath.endswith(p) for p in blocked_manifests):
            return False, f"Refusing to edit dependency manifest: {filepath}"

        search_text = edit.get("search", "")
        replace_text = edit.get("replace", "")

        if replace_text.strip() == "" and search_text.strip() != "":
            return (
                False,
                f"Refusing to delete code block in {filepath} — replacement is empty",
            )

        search_lines = search_text.count("\n") + 1
        replace_lines = replace_text.count("\n") + 1
        if search_lines > 3 and replace_lines < search_lines * 0.5:
            return False, (
                f"Refusing edit in {filepath} — replacement is significantly shorter than original "
                f"({replace_lines} lines vs {search_lines} lines), which suggests code removal"
            )

        total_lines += replace_lines

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
            normalized_content = " ".join(content.split())
            normalized_search = " ".join(search.split())
            if normalized_search not in normalized_content:
                return False, f"Search text not found in {filepath}:\n{search[:200]}"

            import re

            pattern = re.escape(normalized_search).replace(r"\ ", r"\s+")
            match = re.search(pattern, content)
            if match:
                content = content[: match.start()] + replace + content[match.end() :]
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

    provider = os.environ.get("AI_PROVIDER") or "anthropic"
    model = os.environ.get("AI_MODEL") or PROVIDER_DEFAULTS.get(provider, "")
    mode = (os.environ.get("AI_MODE") or "fix").lower()
    mode_label = "investigation" if mode == "investigate" else "fix"
    print(
        f"Calling AI for {mode_label} attempt {attempt} (provider={provider}, model={model})..."
    )
    try:
        result = call_llm(context, attempt, previous_attempts)
    except json.JSONDecodeError as e:
        print(f"::error::Failed to parse AI response as JSON: {e}")
        sys.exit(2)
    except Exception as e:
        print(f"::error::AI API call failed: {e}")
        sys.exit(2)

    print(f"AI analysis: {result.get('analysis', 'N/A')}")

    if not result.get("can_fix") and mode == "investigate":
        print("AI found no changes needed — code is already up to date.")
        sys.exit(3)

    valid, reason = validate_response(result, max_diff_lines)
    if not valid:
        print(f"::warning::AI response rejected: {reason}")
        previous_attempts.append(
            {
                "edits": result.get("edits", []),
                "analysis": result.get("analysis", reason),
                "rejected": True,
                "rejection_reason": reason,
            }
        )
        with open(history_file, "w") as f:
            json.dump(previous_attempts, f, indent=2)
        sys.exit(2)

    print(f"Applying {len(result['edits'])} edit(s)...")
    success, error = apply_edits(result["edits"])
    if not success:
        print(f"::warning::Failed to apply edits: {error}")
        previous_attempts.append(
            {
                "edits": result["edits"],
                "analysis": result.get("analysis", ""),
                "apply_error": error,
            }
        )
        with open(history_file, "w") as f:
            json.dump(previous_attempts, f, indent=2)
        sys.exit(2)

    previous_attempts.append(
        {
            "edits": result["edits"],
            "analysis": result.get("analysis", ""),
        }
    )
    with open(history_file, "w") as f:
        json.dump(previous_attempts, f, indent=2)

    with open(".ai-last-edits.json", "w") as f:
        json.dump(result, f, indent=2)

    print("Edits applied successfully.")


if __name__ == "__main__":
    main()
