#!/usr/bin/env bash
#
# ci-install-scanners.sh - install semgrep/gitleaks/shellcheck/jsonschema for
# opf's CI scan templates.
#
# Single source of truth for scanner installation, called by both
# ci/pack-scan.gitlab-ci.yml and .github/workflows/scan.yml, which both
# already check out this repo before running their scan step. Keeping the
# install logic in one script (rather than duplicated per-CI-system YAML)
# means the two templates cannot silently drift to different tool versions
# or different install behavior.
#
# Versions can be overridden via SHELLCHECK_VERSION / GITLEAKS_VERSION
# environment variables (both CI templates export these); otherwise the
# defaults below are used. Bump the defaults here periodically.
#
set -euo pipefail

SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-0.10.0}"
GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.21.2}"

SUDO=""
if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

pip install --disable-pip-version-check --quiet semgrep jsonschema

# GitHub Releases is the primary path (pins an exact version); constrained
# runners that can't reach github.com (private/VPN-only infra) fall back to
# apt, which is version-unpinned but reachable. Either way the tool ends up
# on PATH; callers only check `command -v`, not the version.
if ! command -v shellcheck >/dev/null 2>&1; then
  if curl -sSfL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
    | $SUDO tar -xJ -f - -C /usr/local/bin --strip-components=1 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck" 2>/dev/null; then
    $SUDO chmod +x /usr/local/bin/shellcheck
  elif command -v apt-get >/dev/null 2>&1; then
    echo "NOTE: GitHub release fetch for shellcheck failed; falling back to apt-get (unpinned version)." >&2
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq --no-install-recommends shellcheck >/dev/null
  else
    echo "ERROR: could not install shellcheck (GitHub unreachable and apt-get not available); install it manually." >&2
    exit 1
  fi
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  if curl -sSfL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    | $SUDO tar -xz -f - -C /usr/local/bin gitleaks 2>/dev/null; then
    $SUDO chmod +x /usr/local/bin/gitleaks
  elif command -v apt-get >/dev/null 2>&1 && apt-cache show gitleaks >/dev/null 2>&1; then
    echo "NOTE: GitHub release fetch for gitleaks failed; falling back to apt-get (unpinned version)." >&2
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq --no-install-recommends gitleaks >/dev/null
  else
    echo "ERROR: could not install gitleaks (GitHub unreachable and no apt package available); install it manually." >&2
    exit 1
  fi
fi
