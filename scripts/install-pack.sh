#!/usr/bin/env bash
#
# install-pack.sh - deterministically install or update ONE OPF pack.
#
# This is the hard-enforcement counterpart to skills/pack-install/SKILL.md:
# the skill is prose an agent follows; this script mechanically performs the
# deterministic steps (validate, stage, scan, approve, install, lock, atomic
# swap) and refuses to proceed on failure via real exit codes, not an agent's
# discretion. A harness that can run shell scripts but not skills can call
# this directly.
#
# Usage:
#   scripts/install-pack.sh <source-dir> <install-dir> [options]
#
# Options:
#   --yes                 Approve the install.sh review and any scan/validator
#                          warnings non-interactively. The caller (a human, or
#                          a skill that already showed the content to a human)
#                          is asserting that review happened. Without --yes
#                          and without a TTY, the script aborts rather than
#                          silently proceeding.
#   --config KEY=VALUE    Provide a resolved config value (repeatable).
#   --data-dir DIR        Override PACK_DATA_DIR (default: a sibling of
#                          install-dir, named from the manifest's data_dir
#                          hint, or "<install-dir>-data").
#   --allow-downgrade     Allow installing a version lower than installed.
#   -h, --help            Show this help.
#
# Scope: this script installs ONE pack. It does NOT resolve dependencies
# (spec Section 4.5) - install dependencies first, in closure order, with
# separate invocations, or use skills/pack-install for full closure handling.
#
# Exit codes: 0 success, 1 failure/abort (validation error, scan error,
# declined approval, downgrade refused, install.sh failure).
#
set -euo pipefail

usage() {
  cat <<'EOF'
usage: install-pack.sh <source-dir> <install-dir> [options]

Options:
  --yes                 Non-interactive approval for install.sh review and
                         scan/validator warnings.
  --config KEY=VALUE    Provide a resolved config value (repeatable).
  --data-dir DIR        Override PACK_DATA_DIR.
  --allow-downgrade     Allow installing a lower version than installed.
  -h, --help            Show this help.
EOF
}

YES=0
DATA_DIR_OVERRIDE=""
ALLOW_DOWNGRADE=0
CONFIG_KV=()
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      YES=1
      shift
      ;;
    --config)
      [[ $# -ge 2 ]] || { echo "ERROR: --config requires KEY=VALUE" >&2; exit 1; }
      CONFIG_KV+=("$2")
      shift 2
      ;;
    --data-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --data-dir requires a value" >&2; exit 1; }
      DATA_DIR_OVERRIDE="$2"
      shift 2
      ;;
    --allow-downgrade)
      ALLOW_DOWNGRADE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

SOURCE_DIR="${POSITIONAL[0]:-}"
INSTALL_DIR_ARG="${POSITIONAL[1]:-}"
if [[ -z "$SOURCE_DIR" || -z "$INSTALL_DIR_ARG" ]]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-pack.sh"
# shellcheck source=scripts/secret-patterns.sh
source "$SCRIPT_DIR/secret-patterns.sh"

SOURCE_DIR="$(cd "$SOURCE_DIR" 2>/dev/null && pwd)" || {
  echo "ERROR: source directory does not exist or is not accessible: $SOURCE_DIR" >&2
  exit 1
}

INSTALL_PARENT="$(cd "$(dirname "$INSTALL_DIR_ARG")" 2>/dev/null && pwd)" || {
  echo "ERROR: install directory's parent does not exist: $(dirname "$INSTALL_DIR_ARG")" >&2
  exit 1
}
INSTALL_DIR="$INSTALL_PARENT/$(basename "$INSTALL_DIR_ARG")"

semver_cmp() {
  # Prints -1, 0, or 1 for $1 <=> $2 per semver precedence (build metadata ignored).
  python3 - "$1" "$2" <<'PY'
import re, sys

def parse(v):
    m = re.match(r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$', v)
    if not m:
        raise SystemExit(f"invalid semver: {v}")
    major, minor, patch, pre = m.groups()
    return (int(major), int(minor), int(patch), pre)

def pre_key(pre):
    if pre is None:
        return None
    parts = []
    for ident in pre.split('.'):
        parts.append((0, int(ident)) if ident.isdigit() else (1, ident))
    return parts

a_major, a_minor, a_patch, a_pre = parse(sys.argv[1])
b_major, b_minor, b_patch, b_pre = parse(sys.argv[2])
a_core, b_core = (a_major, a_minor, a_patch), (b_major, b_minor, b_patch)

if a_core != b_core:
    print(-1 if a_core < b_core else 1)
elif a_pre is None and b_pre is None:
    print(0)
elif a_pre is None:
    print(1)
elif b_pre is None:
    print(-1)
else:
    ak, bk = pre_key(a_pre), pre_key(b_pre)
    print(0 if ak == bk else (-1 if ak < bk else 1))
PY
}

confirm() {
  # confirm "prompt" - honors --yes; otherwise requires an interactive TTY answer.
  local prompt="$1"
  if [[ $YES -eq 1 ]]; then
    return 0
  fi
  if [[ -t 0 ]]; then
    local ans
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
    return $?
  fi
  echo "ERROR: non-interactive and no --yes; refusing to proceed without explicit approval." >&2
  return 1
}

# --- Stage --------------------------------------------------------------------
# Staged (and .opf-env/.opf-lock stripped) before validation, not after: once
# copied, nothing but this script's own next few lines touches STAGING_DIR, so
# there's no window for a path-escaping symlink to be swapped into SOURCE_DIR
# between a "validate the source" step and the copy that would otherwise
# follow it unvalidated.
STAGING_DIR="${INSTALL_DIR}.new"
if [[ -e "$STAGING_DIR" ]]; then
  echo "ERROR: staging directory already exists: $STAGING_DIR (a previous install may have failed mid-way; inspect and remove it manually)." >&2
  exit 1
fi
echo "==> Staging pack into $STAGING_DIR"
cp -R "$SOURCE_DIR" "$STAGING_DIR"
rm -f "$STAGING_DIR/.opf-env" "$STAGING_DIR/.opf-lock"
trap 'rm -rf "$STAGING_DIR"' EXIT

# --- Validate the staged pack ------------------------------------------------
echo "==> Validating staged pack"
set +e
"$VALIDATOR" "$STAGING_DIR"
validator_rc=$?
set -e
if [[ $validator_rc -eq 1 ]]; then
  echo "ERROR: validation failed; aborting install." >&2
  exit 1
elif [[ $validator_rc -eq 2 ]]; then
  confirm "Validator produced warnings (above). Proceed anyway?" || { echo "Aborted." >&2; exit 1; }
elif [[ $validator_rc -ne 0 ]]; then
  echo "ERROR: validator exited with unexpected status $validator_rc; aborting install." >&2
  exit 1
fi

MANIFEST="$STAGING_DIR/manifest.json"
read_field() {
  python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print(v if v is not None else "")' "$MANIFEST" "$1"
}
PACK_NAME="$(read_field name)"
PACK_VERSION="$(read_field version)"
DATA_DIR_HINT="$(read_field data_dir)"

CONFIG_ENTRIES="$(python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for e in (m.get("config") or []):
    if isinstance(e, dict) and e.get("name"):
        print(f"{e['name']}\t{1 if e.get('required') else 0}")
PY
)"

DEP_COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("dependencies") or []))' "$MANIFEST")"
if [[ "$DEP_COUNT" -gt 0 ]]; then
  echo "NOTE: manifest declares $DEP_COUNT dependencies. This script does not resolve"
  echo "NOTE: dependencies (spec Section 4.5); install each one first, in closure"
  echo "NOTE: order, or use skills/pack-install for full closure handling."
fi

# --- Update / downgrade decision ---------------------------------------------
IS_UPDATE=0
if [[ -e "$INSTALL_DIR" ]]; then
  if [[ ! -f "$INSTALL_DIR/.opf-lock" ]]; then
    echo "ERROR: $INSTALL_DIR already exists but has no .opf-lock; refusing to overwrite an unmanaged directory." >&2
    exit 1
  fi
  IS_UPDATE=1
  INSTALLED_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$INSTALL_DIR/.opf-lock")"
  cmp="$(semver_cmp "$PACK_VERSION" "$INSTALLED_VERSION")"
  if [[ "$cmp" -lt 0 && $ALLOW_DOWNGRADE -ne 1 ]]; then
    echo "ERROR: incoming version $PACK_VERSION is lower than installed version $INSTALLED_VERSION; refusing downgrade (pass --allow-downgrade to override)." >&2
    exit 1
  fi
fi

# --- Data dir -----------------------------------------------------------------
# data_dir is an attacker-controlled manifest field (schema/validator restrict
# it to a single safe segment, but jsonschema/validate-pack.sh may not be
# available at call time) - reject anything that isn't a plain single-segment
# name before it's used in a path join, rather than trusting the manifest.
if [[ -n "$DATA_DIR_HINT" ]]; then
  if [[ "$DATA_DIR_HINT" == "." || "$DATA_DIR_HINT" == ".." || "$DATA_DIR_HINT" == */* ]]; then
    echo "ERROR: manifest data_dir must be a single path segment, not '.', '..', or contain '/' (got: $DATA_DIR_HINT)." >&2
    exit 1
  fi
fi
if [[ -n "$DATA_DIR_OVERRIDE" ]]; then
  PACK_DATA_DIR="$DATA_DIR_OVERRIDE"
elif [[ -n "$DATA_DIR_HINT" ]]; then
  PACK_DATA_DIR="$(dirname "$INSTALL_DIR")/$DATA_DIR_HINT"
else
  PACK_DATA_DIR="${INSTALL_DIR}-data"
fi
# Not created here: creating it this early would put a filesystem side
# effect (mkdir -p from an attacker-influenced path) before the pack has
# been scanned or approved. It's created later, right before install.sh
# runs (the first point that actually needs it to exist).

# --- Scan -----------------------------------------------------------------------
echo "==> Scanning staged pack"
scan_errors=0
scan_warnings=0

# Shared by every tool-outcome check below: bumps the given counter
# (scan_errors or scan_warnings) and sets the given per-tool result
# variable to $3, unless it's already "error" - an error finding always
# wins over a later warning for the same tool, never the reverse.
record_finding() {
  local -n _result="$1"
  local -n _counter="$2"
  [[ "$_result" == "error" ]] || _result="$3"
  _counter=$((_counter + 1))
}

# Per-tool scan outcome, recorded into .opf-lock's "scan" block (spec Section
# 9.1) so a consumer can tell from the lock alone whether the full scan ran,
# rather than inferring it from absence. "error" is not a possible recorded
# result: any error-class finding below aborts the install (scan_errors
# check, further down) before .opf-lock is ever written, so only "clean",
# "warning", and "skipped" are reachable at that point.
SCAN_SEMGREP_VERSION=""
SCAN_SEMGREP_CURATED_RESULT="skipped"
SCAN_SEMGREP_CURATED_REASON="semgrep not installed"
SCAN_SEMGREP_REGISTRY_RESULT="skipped"
SCAN_SEMGREP_REGISTRY_REASON="semgrep not installed"
SCAN_GITLEAKS_VERSION=""
SCAN_GITLEAKS_RESULT="skipped"
SCAN_GITLEAKS_REASON="not installed"

# scan.exclude (spec Section 7.3) applies to content scanning ONLY, never to
# secrets scanning (gitleaks, below) or structural validation (already run).
# resolve-scan-excludes.py pre-filters out any matched path that is an
# "executable file type" (rule (a): exclusions never apply to those), so
# passing its output straight to semgrep --exclude cannot violate rule (a).
SCAN_EXCLUDE_ARGS=()
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  SCAN_EXCLUDE_ARGS+=(--exclude "$rel")
done < <(python3 "$SCRIPT_DIR/resolve-scan-excludes.py" "$MANIFEST" "$STAGING_DIR" 2>/dev/null || true)

OPF_RULESET="$SCRIPT_DIR/../ci/semgrep-opf-rules.yml"
if command -v semgrep >/dev/null 2>&1; then
  SCAN_SEMGREP_VERSION="$(semgrep --version 2>/dev/null | head -n1)"
  if [[ -f "$OPF_RULESET" ]]; then
    SCAN_SEMGREP_CURATED_RESULT="clean"
    SCAN_SEMGREP_CURATED_REASON=""
    echo "--- semgrep (curated OPF ruleset) ---"
    # One invocation, not three: --quiet still prints findings (it only
    # suppresses banners/progress), and --json-output writes the same scan's
    # structured results to a file alongside that text, so the ERROR/WARNING
    # severities present can be read back without re-running semgrep per
    # severity (spec Section 7.1 only needs to know whether each severity
    # class is present, not match counts). A nonzero exit here (with no
    # --error flag, this can only mean semgrep itself failed to run, not
    # "findings exist" - verified empirically) or unparseable JSON is
    # treated as an error-class failure: a scan that didn't run is not a
    # clean one (spec Section 7.1's "no silent clean bill of health").
    # Placed beside the staging directory (a location this script already
    # knows is writable), not via plain `mktemp`'s default $TMPDIR: this
    # script must not trust ambient environment state it didn't itself set
    # (same reasoning as the attacker-influenced data_dir handling above) -
    # an invoking shell with a stale or nonexistent $TMPDIR would otherwise
    # make the installer itself fail before it ever gets to scanning.
    SEMGREP_JSON_OUT="$(mktemp "$INSTALL_PARENT/.opf-scan-json.XXXXXX")"
    semgrep_curated_rc=0
    semgrep scan --config "$OPF_RULESET" --quiet --json-output="$SEMGREP_JSON_OUT" --exclude .opf-env --exclude .opf-lock "${SCAN_EXCLUDE_ARGS[@]}" "$STAGING_DIR" || semgrep_curated_rc=$?
    read -r semgrep_has_error semgrep_has_warning < <(python3 - "$SEMGREP_JSON_OUT" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    severities = {r.get("extra", {}).get("severity") for r in data.get("results", [])}
except (OSError, ValueError):
    print("1 1")  # unparseable output: fail closed on both severities
else:
    print(f"{1 if 'ERROR' in severities else 0} {1 if 'WARNING' in severities else 0}")
PY
    )
    rm -f "$SEMGREP_JSON_OUT"
    if [[ $semgrep_curated_rc -ne 0 ]]; then
      echo "ERROR: semgrep (curated OPF ruleset) exited $semgrep_curated_rc; treating a failed scan as an error, not a clean one." >&2
      record_finding SCAN_SEMGREP_CURATED_RESULT scan_errors error
    elif [[ "$semgrep_has_error" == "1" ]]; then
      echo "ERROR: semgrep (curated OPF ruleset) reported an error-class finding (above); refusing to install." >&2
      record_finding SCAN_SEMGREP_CURATED_RESULT scan_errors error
    fi
    # spec Section 7.1 requires a warning-class finding to block until the
    # user explicitly confirms; printing it (above) is not acknowledgment.
    if [[ "$semgrep_has_warning" == "1" ]]; then
      echo "WARNING: semgrep (curated OPF ruleset) reported a warning-class finding (above)."
      record_finding SCAN_SEMGREP_CURATED_RESULT scan_warnings warning
    fi
  else
    echo "NOTE: curated OPF ruleset not found at $OPF_RULESET; skipping it."
    SCAN_SEMGREP_CURATED_REASON="curated ruleset file not found"
  fi
  SCAN_SEMGREP_REGISTRY_RESULT="clean"
  SCAN_SEMGREP_REGISTRY_REASON=""
  if ! semgrep scan --config auto --error --quiet --exclude .opf-env --exclude .opf-lock "${SCAN_EXCLUDE_ARGS[@]}" "$STAGING_DIR"; then
    echo "WARNING: semgrep (registry auto ruleset) reported findings (above). Treated as"
    echo "WARNING: warnings requiring acknowledgment, since the auto ruleset is not"
    echo "WARNING: curated to OPF's dangerous-pattern categories (the curated OPF"
    echo "WARNING: ruleset above is the hard block for those)."
    record_finding SCAN_SEMGREP_REGISTRY_RESULT scan_warnings warning
  fi
else
  echo "NOTE: semgrep not installed; skipping dangerous-pattern static analysis."
fi

if command -v gitleaks >/dev/null 2>&1; then
  SCAN_GITLEAKS_VERSION="$(gitleaks version 2>/dev/null | head -n1)"
  if ! gitleaks detect --source "$STAGING_DIR" --no-git --redact -v; then
    echo "ERROR: gitleaks detected likely secrets in the staged pack; refusing to install." >&2
    record_finding SCAN_GITLEAKS_RESULT scan_errors error
  else
    SCAN_GITLEAKS_RESULT="clean"
    SCAN_GITLEAKS_REASON=""
  fi
else
  echo "NOTE: gitleaks not installed; falling back to a pattern grep for likely secrets"
  echo "NOTE: (mirrors the fallback in scripts/new-pack.sh)."
  # A single recursive grep instead of one grep process per file. No
  # .opf-env/.opf-lock exclusion needed here: both were already removed
  # from STAGING_DIR's root above and aren't written again until after this
  # scan step, so neither exists yet for this pass to see.
  grep -rIE -n --exclude-dir=.git "$OPF_SECRET_GREP_PATTERN" "$STAGING_DIR" 2>/dev/null || true
  if grep -rIqE --exclude-dir=.git "$OPF_SECRET_GREP_PATTERN" "$STAGING_DIR" 2>/dev/null; then
    scan_errors=$((scan_errors + 1))
  fi
fi

if [[ $scan_errors -gt 0 ]]; then
  echo "ERROR: scan found $scan_errors error-class finding(s); aborting install." >&2
  exit 1
fi

if [[ $scan_warnings -gt 0 ]]; then
  confirm "Scan produced warnings (above). Proceed anyway?" || { echo "Aborted." >&2; exit 1; }
fi

# --- install.sh approval --------------------------------------------------------
INSTALL_SCRIPT="$STAGING_DIR/install.sh"
if [[ -f "$INSTALL_SCRIPT" ]]; then
  echo "==> install.sh present; approval required."
  if [[ $IS_UPDATE -eq 1 && -f "$INSTALL_DIR/install.sh" ]]; then
    echo "--- diff against previously installed install.sh ---"
    diff -u "$INSTALL_DIR/install.sh" "$INSTALL_SCRIPT" || true
  else
    echo "--- full text of install.sh ---"
    cat "$INSTALL_SCRIPT"
  fi
  echo "--- end install.sh ---"
  confirm "Approve and run install.sh above?" || { echo "Aborted: install.sh not approved." >&2; exit 1; }
fi

# --- Resolve config -------------------------------------------------------------
declare -A CONFIG_VALUES=()
for kv in "${CONFIG_KV[@]:-}"; do
  [[ -z "$kv" ]] && continue
  CONFIG_VALUES["${kv%%=*}"]="${kv#*=}"
done

missing_required=()
config_env_assignments=()
if [[ -n "$CONFIG_ENTRIES" ]]; then
  while IFS=$'\t' read -r cname crequired; do
    [[ -z "$cname" ]] && continue
    if [[ -n "${CONFIG_VALUES[$cname]+x}" ]]; then
      config_env_assignments+=("CONFIG_${cname}=${CONFIG_VALUES[$cname]}")
    elif [[ "$crequired" == "1" ]]; then
      missing_required+=("$cname")
    fi
  done <<< "$CONFIG_ENTRIES"
fi

if [[ ${#missing_required[@]} -gt 0 ]]; then
  echo "ERROR: missing required config value(s): ${missing_required[*]}" >&2
  echo "ERROR: provide each with --config NAME=value." >&2
  exit 1
fi

# --- Create the data dir ----------------------------------------------------------
# Created here, not earlier: everything above this point (validate, scan,
# install.sh approval, config resolution) has now passed, so this is the
# first point that actually needs PACK_DATA_DIR to exist.
mkdir -p "$PACK_DATA_DIR"

# --- Write .opf-env --------------------------------------------------------------
{
  echo "PACK_ROOT=$STAGING_DIR"
  echo "PACK_NAME=$PACK_NAME"
  echo "PACK_DATA_DIR=$PACK_DATA_DIR"
  echo "PACK_VERSION=$PACK_VERSION"
  echo "PACK_INSTALL_DIR=$INSTALL_DIR"
  for kv in "${config_env_assignments[@]:-}"; do
    [[ -z "$kv" ]] && continue
    echo "$kv"
  done
} > "$STAGING_DIR/.opf-env"

# --- Run install.sh ---------------------------------------------------------------
if [[ -f "$INSTALL_SCRIPT" ]]; then
  echo "==> Running install.sh"
  ENV_ARGS=(
    PATH="$PATH"
    HOME="${HOME:-/root}"
    PACK_ROOT="$STAGING_DIR"
    PACK_NAME="$PACK_NAME"
    PACK_DATA_DIR="$PACK_DATA_DIR"
    PACK_VERSION="$PACK_VERSION"
    PACK_INSTALL_DIR="$INSTALL_DIR"
  )
  if [[ ${#config_env_assignments[@]} -gt 0 ]]; then
    ENV_ARGS+=("${config_env_assignments[@]}")
  fi
  # A small, explicitly safe allowlist beyond PACK_*/config: none of these
  # can carry a credential, and their absence causes real (not security-
  # relevant) breakage in otherwise-correct install.sh scripts - TMPDIR-
  # aware temp-file creation on a sandbox where plain /tmp isn't writable,
  # locale-dependent tools misbehaving under no locale at all, TERM-aware
  # output. Forwarded only when the installer's own environment actually
  # sets them, so nothing is fabricated.
  for safe_var in TMPDIR LANG LC_ALL TERM; do
    [[ -n "${!safe_var:-}" ]] && ENV_ARGS+=("$safe_var=${!safe_var}")
  done
  # env -i: start install.sh from an EMPTY environment, not this process's
  # inherited one, plus exactly ENV_ARGS above. That is PATH and HOME
  # (both forwarded from the invoking shell - install.sh cannot function
  # without a PATH to resolve commands on, and many tools misbehave with
  # no HOME at all; neither is a credential, but note this is a stricter
  # read than spec Section 8.4's literal list, which names only the PACK_*
  # vars and declared config), the small allowlist above, and the PACK_*/
  # config values spec Section 8.4 actually documents. The installer's own
  # environment commonly carries things beyond all of that which install.sh
  # has no business seeing (CI secrets, cloud/API tokens, SSH agent
  # sockets). Without -i, `env` only overlays ENV_ARGS onto the inherited
  # environment rather than replacing it, so every one of those would
  # otherwise be readable to an install.sh that just runs `env` or
  # `printenv`.
  #
  # Deliberately NOT `bash -c '...'`: verified on a real host that `bash -c`
  # can still pick up that host's own ambient process-manager state (a
  # systemd --user session's environment, in one observed case) regardless
  # of `env -i` - something specific to the `-c` invocation form, not to
  # env -i's own semantics. Execing the pack's own install.sh directly (it
  # already has its own `#!/usr/bin/env bash` shebang) avoids that path
  # entirely; verified clean on the same host that reproduced the leak.
  set +e
  ( cd "$STAGING_DIR" && exec env -i "${ENV_ARGS[@]}" ./install.sh )
  install_rc=$?
  set -e
  if [[ $install_rc -ne 0 ]]; then
    echo "ERROR: install.sh exited $install_rc; install failed." >&2
    exit 1
  fi
  echo "install.sh exited 0."
fi

# --- Write .opf-lock ----------------------------------------------------------------
echo "==> Writing .opf-lock"
SOURCE_TYPE="local"
SOURCE_URL=""
SOURCE_COMMIT=""
if git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SOURCE_TYPE="git"
  SOURCE_URL="$(git -C "$SOURCE_DIR" config --get remote.origin.url 2>/dev/null || true)"
  SOURCE_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)"
fi

python3 - "$SCRIPT_DIR/compute-pack-checksums.py" "$STAGING_DIR" "$PACK_NAME" "$PACK_VERSION" "$INSTALL_DIR" "$PACK_DATA_DIR" "$SOURCE_TYPE" "$SOURCE_URL" "$SOURCE_COMMIT" "$SOURCE_DIR" \
  "$SCAN_SEMGREP_VERSION" "$SCAN_SEMGREP_CURATED_RESULT" "$SCAN_SEMGREP_CURATED_REASON" \
  "$SCAN_SEMGREP_REGISTRY_RESULT" "$SCAN_SEMGREP_REGISTRY_REASON" \
  "$SCAN_GITLEAKS_VERSION" "$SCAN_GITLEAKS_RESULT" "$SCAN_GITLEAKS_REASON" <<'PY'
import json, os, subprocess, sys, datetime

(compute_checksums_script, staging, name, version, install_dir, data_dir,
 source_type, source_url, source_commit, source_dir,
 semgrep_version, semgrep_curated_result, semgrep_curated_reason,
 semgrep_registry_result, semgrep_registry_reason,
 gitleaks_version, gitleaks_result, gitleaks_reason) = sys.argv[1:19]

checksums = json.loads(subprocess.run(
    [sys.executable, compute_checksums_script, staging],
    capture_output=True, text=True, check=True,
).stdout)

source = {"type": source_type}
if source_url:
    source["url"] = source_url
if source_commit:
    source["commit"] = source_commit
if source_type == "local":
    source["path"] = source_dir

# Recorded per spec Section 9.1 so graceful degradation (spec Section 7,
# host-layout Section 2.6) is visible from .opf-lock alone rather than
# inferred from absence. "error" never appears here: an error-class finding
# aborts the install before this script runs at all.
def tool_entry(result, reason, version=None, ruleset=None):
    entry = {"result": result}
    if version:
        entry["version"] = version
    # `ruleset` is attached whenever one is named, including a "skipped"
    # result (e.g. semgrep not installed): spec Section 9.1 asks for "the
    # ruleset reference" as its own always-present field, separate from the
    # per-tool outcome - it says which ruleset this entry is FOR, not that
    # the ruleset ran. `result` is what says whether it ran.
    if ruleset:
        entry["ruleset"] = ruleset
    if result == "skipped" and reason:
        entry["reason"] = reason
    return entry

scan = {
    "semgrep": tool_entry(semgrep_curated_result, semgrep_curated_reason, semgrep_version, "opf-core-v1"),
    "semgrep_registry": tool_entry(semgrep_registry_result, semgrep_registry_reason, semgrep_version, "auto"),
    "gitleaks": tool_entry(gitleaks_result, gitleaks_reason, gitleaks_version),
}

lock = {
    "name": name,
    "version": version,
    "installed_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source": source,
    "dependencies": [],
    "data_dir": data_dir,
    "checksums": checksums,
    "scan": scan,
}

with open(os.path.join(staging, ".opf-lock"), "w") as fh:
    json.dump(lock, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

# --- Swap ------------------------------------------------------------------------
echo "==> Swapping staged pack into place"
if [[ -e "$INSTALL_DIR" ]]; then
  OLD_DIR="${INSTALL_DIR}.old"
  rm -rf "$OLD_DIR"
  mv "$INSTALL_DIR" "$OLD_DIR"
  if mv "$STAGING_DIR" "$INSTALL_DIR"; then
    rm -rf "$OLD_DIR"
  else
    # Restore the previous install so "old pack remains intact on failure"
    # (spec Section 8.1) actually holds. This covers the common case, a
    # same-filesystem rename failing atomically (permissions, quota); a
    # cross-filesystem partial copy failing mid-transfer is not handled.
    echo "ERROR: failed to move staged pack into place; restoring previous install." >&2
    mv "$OLD_DIR" "$INSTALL_DIR"
    exit 1
  fi
else
  mv "$STAGING_DIR" "$INSTALL_DIR"
fi
trap - EXIT

echo
echo "Installed $PACK_NAME $PACK_VERSION at $INSTALL_DIR"
echo "PACK_DATA_DIR: $PACK_DATA_DIR"
