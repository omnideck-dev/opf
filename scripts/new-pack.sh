#!/usr/bin/env bash
#
# new-pack.sh - scaffold a new OPF pack from templates/pack-z-template/.
#
# Usage:
#   scripts/new-pack.sh <name> [vendor] [-d <description>] [--with <kinds>] [--allow-secrets]
#
# Copies the template to ./<name>, replaces placeholder tokens in all template
# text files (manifest.json, README.md, CHANGELOG.md, skills/example/SKILL.md),
# creates a .gitkeep-tracked subfolder for each item kind named in --with
# (comma-separated: tool, routine, agent, artifact - skill and data are
# already present in the template; each maps to its plural on-disk directory,
# e.g. tool -> tools/), runs a secrets gate, and prints next steps.
#
# Secrets gate: after scaffolding, the pack is scanned for likely secrets
# (gitleaks if available, otherwise a grep fallback). If findings are present
# the script REFUSES (exit 1) unless --allow-secrets is passed, which prints a
# loud warning and continues AT YOUR OWN RISK.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/secret-patterns.sh
source "$SCRIPT_DIR/secret-patterns.sh"
# shellcheck source=scripts/pack-name-pattern.sh
source "$SCRIPT_DIR/pack-name-pattern.sh"

NAME=""
VENDOR=""
DESCRIPTION=""
WITH_KINDS=""
ALLOW_SECRETS=0
POSITIONAL=()

USAGE="usage: $0 <name> [vendor] [-d <description>] [--with <kinds>] [--allow-secrets]"

# Parse options and positionals. Positionals are <name> and [vendor].
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--description)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: -d/--description requires a value" >&2
        exit 1
      fi
      DESCRIPTION="$2"
      shift 2
      ;;
    --with)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: --with requires a comma-separated list (tool,routine,agent,artifact)" >&2
        exit 1
      fi
      WITH_KINDS="$2"
      shift 2
      ;;
    --allow-secrets)
      ALLOW_SECRETS=1
      shift
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      echo "$USAGE" >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

NAME="${POSITIONAL[0]:-}"
VENDOR="${POSITIONAL[1]:-}"
if [[ "${#POSITIONAL[@]}" -gt 2 ]]; then
  echo "ERROR: too many positional arguments" >&2
  echo "$USAGE" >&2
  exit 1
fi

if [[ -z "$NAME" ]]; then
  echo "$USAGE" >&2
  exit 1
fi

if [[ "$NAME" == "." || "$NAME" == ".." ]]; then
  echo "ERROR: name must not be '.' or '..'" >&2
  exit 1
fi

if ! [[ "$NAME" =~ $OPF_NAME_PATTERN ]]; then
  echo "ERROR: name must match $OPF_NAME_PATTERN" >&2
  exit 1
fi

# Validate --with up front, before any file is created: every other input
# check in this script happens before cp -R, and this one should too, rather
# than leaving a half-scaffolded pack on disk after a typo.
REQUESTED_KINDS=()
if [[ -n "$WITH_KINDS" ]]; then
  IFS=',' read -ra RAW_KINDS <<< "$WITH_KINDS"
  for kind in "${RAW_KINDS[@]}"; do
    kind="$(echo "$kind" | tr -d '[:space:]')"
    [[ -z "$kind" ]] && continue
    case "$kind" in
      tool|routine|agent|artifact|skill|data)
        REQUESTED_KINDS+=("$kind")
        ;;
      *)
        echo "ERROR: unknown item kind for --with: $kind (expected: tool, routine, agent, artifact, skill, data)" >&2
        exit 1
        ;;
    esac
  done
fi

# Prompt for description if not provided.
if [[ -z "$DESCRIPTION" ]]; then
  if [[ -t 0 ]]; then
    printf 'Description (one-line summary): '
    IFS= read -r DESCRIPTION
  else
    IFS= read -r DESCRIPTION || true
  fi
fi
if [[ -z "$DESCRIPTION" ]]; then
  echo "ERROR: a description is required (-d/--description or prompt)" >&2
  exit 1
fi

TEMPLATE="$SCRIPT_DIR/../templates/pack-z-template"
DEST="./$NAME"

if [[ -e "$DEST" ]]; then
  echo "ERROR: destination already exists: $DEST" >&2
  exit 1
fi

cp -R "$TEMPLATE" "$DEST"

# Replace placeholder tokens in ALL template text files.
# __PACK_NAME__, __VENDOR__, __DESCRIPTION__.
# Escaped for use as sed replacement text: a "/" would otherwise break the
# s/.../.../ delimiter (aborting the substitution), and a bare "&" would be
# interpreted by sed as "insert the matched text", silently corrupting the
# output. NAME is already constrained to a safe charset by validation above;
# VENDOR and DESCRIPTION are free text and need this regardless.
sed_escape_replacement() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//&/\\&}"
  s="${s//\//\\/}"
  printf '%s' "$s"
}
ESC_NAME="$(sed_escape_replacement "$NAME")"
ESC_VENDOR="$(sed_escape_replacement "$VENDOR")"
ESC_DESCRIPTION="$(sed_escape_replacement "$DESCRIPTION")"
find "$DEST" -type f -print0 | while IFS= read -r -d '' f; do
  case "$f" in
    *.json|*.md|*/.gitignore) ;;
    *) continue ;;
  esac
  sed -i \
    -e "s/__PACK_NAME__/$ESC_NAME/g" \
    -e "s/__VENDOR__/$ESC_VENDOR/g" \
    -e "s/__DESCRIPTION__/$ESC_DESCRIPTION/g" \
    "$f"
done

# --- Create subfolders for requested item kinds -----------------------------
# Kinds were already validated above, before scaffolding began. --with values
# stay singular for CLI ergonomics; on-disk directories are plural (spec
# Section 5), so each requested kind maps to its plural directory name here.
for kind in "${REQUESTED_KINDS[@]:-}"; do
  dir=""
  case "$kind" in
    tool)     dir="tools" ;;
    routine)  dir="routines" ;;
    agent)    dir="agents" ;;
    artifact) dir="artifacts" ;;
    skill|data|"")
      : # already present in the template, or an empty placeholder entry
      ;;
  esac
  if [[ -n "$dir" ]]; then
    mkdir -p "$DEST/$dir"
    touch "$DEST/$dir/.gitkeep"
  fi
done

# --- Secrets gate ----------------------------------------------------------
echo "Scanning $DEST for secrets..."
findings=0
if command -v gitleaks >/dev/null 2>&1; then
  if ! gitleaks detect --source "$DEST" --no-git --redact -v >/tmp/opf-gitleaks.out 2>&1; then
    echo "gitleaks found potential secrets:"
    cat /tmp/opf-gitleaks.out
    findings=1
  fi
else
  # grep fallback. Exclude .git, data/, and binary files (grep -I). A single
  # recursive grep instead of one grep process per file.
  grep -rIE -n --exclude-dir=.git --exclude-dir=data "$OPF_SECRET_GREP_PATTERN" "$DEST" 2>/dev/null || true
  if grep -rIqE --exclude-dir=.git --exclude-dir=data "$OPF_SECRET_GREP_PATTERN" "$DEST" 2>/dev/null; then
    findings=1
  fi
fi

if [[ "$findings" -ne 0 ]]; then
  if [[ "$ALLOW_SECRETS" -eq 1 ]]; then
    echo
    echo "WARNING: potential secrets were found in $DEST but --allow-secrets was passed."
    echo "WARNING: You are proceeding AT YOUR OWN RISK. Do not publish this pack."
    echo
  else
    echo
    echo "ERROR: potential secrets were found in $DEST." >&2
    echo "ERROR: Remove the secrets and re-run, or pass --allow-secrets AT YOUR OWN RISK." >&2
    echo "ERROR: Refusing to create the pack." >&2
    exit 1
  fi
else
  echo "No secrets detected."
fi

ABS_DEST="$(cd "$DEST" && pwd)"
echo
echo "Created pack at $ABS_DEST"
echo
echo "Next steps:"
echo "  1. Edit $ABS_DEST/manifest.json (set vendor, etc.) if needed."
echo "  2. Run scripts/validate-pack.sh $ABS_DEST"
echo "  (CI scanning is already wired up: .github/workflows/scan.yml and"
echo "  .gitlab-ci.yml both call opf's scan template.)"
echo
echo "Note: the secrets gate ran on this pack. Re-run it before publishing if you"
echo "add files after scaffolding."