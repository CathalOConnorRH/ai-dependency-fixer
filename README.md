# AI Dependency Fixer

A reusable GitHub Action that automatically fixes breaking changes from dependency update PRs (Renovate, Dependabot, etc.) using AI.

## How It Works

```
Renovate opens PR → Tests fail → AI analyzes errors → Generates fix → Tests pass → Commits fix
```

1. Triggers on PRs from Renovate or Dependabot
2. Runs your test suite to check if the update breaks anything
3. If tests fail, gathers context (dependency diff, error output, relevant source files)
4. Sends context to Claude (Anthropic) to generate targeted code fixes
5. Applies the fix and re-runs tests
6. Retries up to N times with accumulated context from previous attempts
7. If tests pass, commits and pushes the fix to the PR branch
8. If all attempts fail, reverts changes and posts a comment explaining what was tried

## Safety Guardrails

- Will NOT delete or skip tests
- Will NOT remove existing functionality
- Will NOT modify lockfiles or dependency manifests
- Will NOT add new dependencies
- Rejects AI edits larger than a configurable line limit
- Reverts all changes if unable to fix after max attempts
- All fixes are committed to the PR branch for human review before merge

## Supported Languages

Auto-detects language and test commands for:

| Language | Test Command | Install Command |
|----------|-------------|-----------------|
| Node.js (npm/yarn/pnpm) | `npm test` / `yarn test` / `pnpm test` | `npm ci` / `yarn install` / `pnpm install` |
| Python (pytest) | `pytest` | `pip install` / `poetry install` |
| Go | `go test ./...` | `go mod download` |
| Rust | `cargo test` | `cargo fetch` |
| Java (Maven) | `mvn test -B` | `mvn dependency:resolve` |
| Java (Gradle) | `./gradlew test` | `./gradlew dependencies` |
| Ruby | `bundle exec rake test` | `bundle install` |

Override with `test-command` and `install-command` inputs if needed.

## Quick Start

### 1. Add an Anthropic API key to your repo secrets

Go to **Settings → Secrets and variables → Actions → New repository secret**

- Name: `ANTHROPIC_API_KEY`
- Value: Your Anthropic API key from [console.anthropic.com](https://console.anthropic.com/)

### 2. Add the workflow to your repo

Create `.github/workflows/ai-dependency-fix.yml`:

```yaml
name: AI Dependency Fix

on:
  pull_request:
    types: [opened, synchronize]

jobs:
  ai-fix:
    if: >
      github.actor == 'renovate[bot]' ||
      github.actor == 'dependabot[bot]'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.head_ref }}
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}

      - uses: your-org/ai-dependency-fixer@v1
        with:
          ai-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

### 3. That's it

The next time Renovate or Dependabot opens a PR that breaks tests, the action will attempt to fix it automatically.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `ai-api-key` | Yes | - | Anthropic API key |
| `max-attempts` | No | `3` | Max fix attempts before giving up |
| `test-command` | No | `auto` | Test command (`auto` for detection) |
| `install-command` | No | `auto` | Install command (`auto` for detection) |
| `max-diff-lines` | No | `200` | Max lines in AI edit (safety limit) |
| `ai-model` | No | `claude-sonnet-4-20250514` | Claude model to use |
| `github-token` | No | `${{ github.token }}` | Token for PR comments |

## Outputs

| Output | Description |
|--------|-------------|
| `result` | `fixed`, `already-passing`, or `failed` |
| `attempts` | Number of fix attempts made |

## Cost

Typical cost per dependency PR: **$0.05 - $0.15** (1-3 Claude API calls depending on context size and attempts needed).

## License

Apache-2.0
