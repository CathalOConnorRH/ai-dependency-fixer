#!/usr/bin/env bash
set -euo pipefail

# Detect project language, test command, and install command.
# Outputs are set as GitHub Actions step outputs.

detect_test_cmd() {
  if [[ -f "package.json" ]]; then
    if [[ -f "yarn.lock" ]]; then
      echo "yarn test"
    elif [[ -f "pnpm-lock.yaml" ]]; then
      echo "pnpm test"
    else
      echo "npm test"
    fi
  elif [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]] || [[ -f "requirements.txt" ]]; then
    if [[ -f "pyproject.toml" ]] && grep -q "poetry" pyproject.toml 2>/dev/null; then
      echo "poetry run pytest"
    else
      echo "pytest"
    fi
  elif [[ -f "go.mod" ]]; then
    echo "go test ./..."
  elif [[ -f "Cargo.toml" ]]; then
    echo "cargo test"
  elif [[ -f "pom.xml" ]]; then
    echo "mvn test -B"
  elif [[ -f "build.gradle" ]] || [[ -f "build.gradle.kts" ]]; then
    echo "./gradlew test"
  elif [[ -f "Gemfile" ]]; then
    echo "bundle exec rake test"
  else
    echo ""
  fi
}

detect_install_cmd() {
  if [[ -f "package.json" ]]; then
    if [[ -f "yarn.lock" ]]; then
      echo "yarn install --frozen-lockfile"
    elif [[ -f "pnpm-lock.yaml" ]]; then
      echo "pnpm install --frozen-lockfile"
    else
      echo "npm ci"
    fi
  elif [[ -f "pyproject.toml" ]]; then
    if grep -q "poetry" pyproject.toml 2>/dev/null; then
      echo "poetry install --with dev 2>/dev/null || poetry install"
    else
      echo "pip install -e '.[dev]' 2>/dev/null || pip install -e . 2>/dev/null || pip install -r requirements.txt 2>/dev/null || true"
    fi
  elif [[ -f "requirements.txt" ]]; then
    echo "pip install -r requirements.txt"
  elif [[ -f "go.mod" ]]; then
    echo "go mod download"
  elif [[ -f "Cargo.toml" ]]; then
    echo "cargo fetch"
  elif [[ -f "pom.xml" ]]; then
    echo "mvn dependency:resolve -B"
  elif [[ -f "build.gradle" ]] || [[ -f "build.gradle.kts" ]]; then
    echo "./gradlew dependencies"
  elif [[ -f "Gemfile" ]]; then
    echo "bundle install"
  else
    echo "true"
  fi
}

if [[ "${INPUT_TEST_COMMAND}" == "auto" ]]; then
  TEST_CMD=$(detect_test_cmd)
  if [[ -z "$TEST_CMD" ]]; then
    echo "::error::Could not detect test command. Set 'test-command' input explicitly."
    exit 1
  fi
else
  TEST_CMD="${INPUT_TEST_COMMAND}"
fi

if [[ "${INPUT_INSTALL_COMMAND}" == "auto" ]]; then
  INSTALL_CMD=$(detect_install_cmd)
else
  INSTALL_CMD="${INPUT_INSTALL_COMMAND}"
fi

echo "Detected test command: $TEST_CMD"
echo "Detected install command: $INSTALL_CMD"

echo "test_cmd=$TEST_CMD" >> "$GITHUB_OUTPUT"
echo "install_cmd=$INSTALL_CMD" >> "$GITHUB_OUTPUT"
