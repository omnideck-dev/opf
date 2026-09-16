#!/usr/bin/env bash
#
# pack-doctor.sh - scan installed packs for placement, registration, lock,
# and dependency problems, report them, and optionally fix the safe ones.
#
# Usage:
#   scripts/pack-doctor.sh [options]
#
# Options:
#   --owned-root DIR      A root to scan for Owned packs: flat layout,
#                          <root>/<name>/manifest.json (repeatable).
#                          Default: ~/packs
#   --external-root DIR   A root to scan for External packs: vendor-nested
#                          layout, <root>/<vendor>/<name>/manifest.json
#                          (repeatable). Default: ~/.packs-external
#   --native-root DIR     The harness's native per-type tree (contains
#                          skills/, tools/, routines/, agents/, artifacts/),
#                          used to check symlink registration (spec
#                          opf-host-layout.md Section 1.4). Optional: not
#                          every harness uses this pattern; omitting it
#                          just skips the registration check with a NOTE.
#   --only PACK_NAME       Scope --fix to only this pack (repeatable). Without
#                          it, --fix applies to every pack with a fixable
#                          finding. Report-only runs always cover every pack
#                          regardless of --only.
#   --fix                  Apply safe, reversible fixes after confirmation:
#                          remove a stale .opf-lock left behind in an owned
#                          workspace, or create/remove a native-tree
#                          symlink. Everything else (collisions, dependency
#                          gaps, checksum drift) is reported only - those
#                          need a human decision, not a mechanical fix.
#   --yes                  Skip confirmation prompts for --fix.
#   -h, --help
#
# What this checks, per discovered pack:
#   - manifest/structural validity (delegates to validate-pack.sh)
#   - placement: trust tier (spec Section 3; opf-host-layout.md Section 1.3)
#     is decided by HOW a pack arrived - created/claimed means Owned,
#     pack-install means External - not by OWNERS, vendor, or repo
#     permissions, none of which this script has any way to verify anyway.
#     .opf-lock is the one artifact the install procedure actually writes,
#     so its presence is a real (if imperfect) signal that a pack went
#     through pack-install: a pack that HAS a lock but sits under an owned
#     (editable) root looks like an installed pack nobody finished claiming
#     - claiming means moving it AND dropping the stale lock, since Owned
#     packs don't carry one. The reverse (no lock, sitting under an
#     external root) is NOT flagged: it just means not-yet-installed,
#     which is unremarkable.
#   - registration (only with --native-root): does each item (skill, tool,
#     routine, agent, artifact) have a native-tree entry that resolves to
#     THIS pack's copy? Missing, dangling, or pointing at a different pack
#     are each reported distinctly. This is the check that catches "the
#     pack is somewhere the harness doesn't look," independent of tier.
#   - lock drift: does .opf-lock's recorded checksums match the pack's
#     current on-disk content?
#   - dependencies: is each declared dependency (vendor/name) findable among
#     the scanned packs? Version RANGE SATISFACTION is not evaluated here
#     (that requires a real node-semver range engine - spec Section 4.5
#     explicitly says a harness MUST reject a range it cannot parse rather
#     than guess, and this tool does not implement one); found/not-found
#     and the versions on each side are reported so a human can judge.
#   - pre-commit hook wiring: if the pack is a git repo and ships
#     hooks/pre-commit (from templates/pack-z-template/), is
#     core.hooksPath actually set to "hooks" for THIS clone? git never
#     reads hooks/ on its own, so a fresh clone or a co-maintainer's
#     checkout silently gets none of the hook's protection until this is
#     set - a one-line, always-safe fix.
#
# What this does NOT do: install anything, run any pack's install.sh, move
# any pack, or resolve a dependency that's missing. Moving a pack between
# tiers is now always a deliberate human act (see above), not a fix this
# tool guesses at; installing goes through pack-install, with its own
# approval gates - a diagnostic tool must not silently gain the power to
# install code or relocate a pack based on an inference it can't verify.
#
# Exit codes: 0 clean, 1 at least one error-class finding, 2 warnings only.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-pack.sh"
CHECKSUMS_SCRIPT="$SCRIPT_DIR/compute-pack-checksums.py"

usage() {
  # Print the header comment (lines 2 through the line before `set -...`)
  # rather than a hardcoded line range: a fixed range silently goes stale
  # - and cuts --help off mid-sentence - every time the header comment
  # grows, which it has more than once.
  awk 'NR==1 {next} /^set -/ {exit} {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
}

OWNED_ROOTS=()
EXTERNAL_ROOTS=()
NATIVE_ROOT=""
ONLY=()
FIX=0
YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owned-root)
      [[ $# -ge 2 ]] || { echo "ERROR: --owned-root requires a value" >&2; exit 1; }
      OWNED_ROOTS+=("$2"); shift 2 ;;
    --external-root)
      [[ $# -ge 2 ]] || { echo "ERROR: --external-root requires a value" >&2; exit 1; }
      EXTERNAL_ROOTS+=("$2"); shift 2 ;;
    --native-root)
      [[ $# -ge 2 ]] || { echo "ERROR: --native-root requires a value" >&2; exit 1; }
      NATIVE_ROOT="$2"; shift 2 ;;
    --only)
      [[ $# -ge 2 ]] || { echo "ERROR: --only requires a value" >&2; exit 1; }
      ONLY+=("$2"); shift 2 ;;
    --fix) FIX=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) echo "ERROR: unexpected positional argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ ${#OWNED_ROOTS[@]} -eq 0 ]]; then OWNED_ROOTS=("$HOME/packs"); fi
if [[ ${#EXTERNAL_ROOTS[@]} -eq 0 ]]; then EXTERNAL_ROOTS=("$HOME/.packs-external"); fi

confirm() {
  local prompt="$1"
  if [[ $YES -eq 1 ]]; then return 0; fi
  if [[ -t 0 ]]; then
    local ans
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
    return $?
  fi
  echo "ERROR: non-interactive and no --yes; refusing to apply fixes without explicit approval." >&2
  return 1
}

# --- Scan: one python3 pass computes the full report as JSON -----------------
# A function, not a one-shot: --fix needs to re-scan between applying
# dangling-symlink-removal fixes and applying symlink-creation fixes,
# because removing a dangling symlink can turn an item's status from
# "dangling" to "missing," which only a fresh scan will recognize.
PY_ARGS=()
for r in "${OWNED_ROOTS[@]}"; do PY_ARGS+=(--owned-root "$r"); done
for r in "${EXTERNAL_ROOTS[@]}"; do PY_ARGS+=(--external-root "$r"); done
if [[ -n "$NATIVE_ROOT" ]]; then PY_ARGS+=(--native-root "$NATIVE_ROOT"); fi

run_scan() {
  local out_path="$1"
  python3 - "$out_path" "$VALIDATOR" "$CHECKSUMS_SCRIPT" "${PY_ARGS[@]}" <<'PY'
import argparse, json, os, subprocess, sys

p = argparse.ArgumentParser()
p.add_argument("out_path")
p.add_argument("validator")
p.add_argument("checksums_script")
p.add_argument("--owned-root", action="append", default=[])
p.add_argument("--external-root", action="append", default=[])
p.add_argument("--native-root", default=None)
args = p.parse_args()

# Absolute, right away: a symlink's relative target resolves relative to
# the symlink's OWN directory, not the process cwd, so a relative root here
# would silently produce a dangling create_symlink fix the moment the
# native root and the pack root aren't the same relative depth.
owned_roots = [os.path.abspath(r) for r in args.owned_root]
external_roots = [os.path.abspath(r) for r in args.external_root]
native_root = os.path.abspath(args.native_root) if args.native_root else None

ITEM_KINDS = ["skills", "tools", "routines", "agents", "artifacts"]


def read_manifest(pack_dir):
    try:
        with open(os.path.join(pack_dir, "manifest.json")) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def discover(root, nested):
    """nested=False: <root>/<name>/manifest.json. nested=True (external):
    <root>/<vendor>/<name>/manifest.json."""
    found = []
    if not os.path.isdir(root):
        return found
    if not nested:
        for name in sorted(os.listdir(root)):
            pack_dir = os.path.join(root, name)
            if os.path.isfile(os.path.join(pack_dir, "manifest.json")):
                found.append(pack_dir)
    else:
        for vendor in sorted(os.listdir(root)):
            vendor_dir = os.path.join(root, vendor)
            if not os.path.isdir(vendor_dir):
                continue
            for name in sorted(os.listdir(vendor_dir)):
                pack_dir = os.path.join(vendor_dir, name)
                if os.path.isfile(os.path.join(pack_dir, "manifest.json")):
                    found.append(pack_dir)
    return found


packs = []
seen_realpaths = set()
for root in owned_roots:
    for pack_dir in discover(root, nested=False):
        rp = os.path.realpath(pack_dir)
        if rp in seen_realpaths:
            continue
        seen_realpaths.add(rp)
        packs.append({"path": pack_dir, "root_kind": "owned-root"})
for root in external_roots:
    for pack_dir in discover(root, nested=True):
        rp = os.path.realpath(pack_dir)
        if rp in seen_realpaths:
            continue
        seen_realpaths.add(rp)
        packs.append({"path": pack_dir, "root_kind": "external-root"})

# Index every discovered pack by (vendor, name) for the dependency check.
by_vendor_name = {}
for pack in packs:
    manifest = read_manifest(pack["path"]) or {}
    key = (manifest.get("vendor") or "", manifest.get("name") or "")
    by_vendor_name.setdefault(key, []).append((pack["path"], manifest.get("version") or ""))


def compute_checksums(pack_dir):
    # Shared with install-pack.sh's .opf-lock writer (scripts/compute-pack-
    # checksums.py) so the two can't silently disagree about what counts as
    # drift.
    return json.loads(subprocess.run(
        [sys.executable, args.checksums_script, pack_dir],
        capture_output=True, text=True, check=True,
    ).stdout)


results = []
fixes = []

for pack in packs:
    pack_dir = pack["path"]
    manifest = read_manifest(pack_dir)
    findings = []  # list of {severity, message}
    pack_fixes = []

    def add(severity, message):
        findings.append({"severity": severity, "message": message})

    if manifest is None:
        add("error", "manifest.json missing or not valid JSON; skipping further checks for this pack")
        results.append({"path": pack_dir, "vendor": None, "name": None, "findings": findings, "fixes": []})
        continue

    vendor = manifest.get("vendor")
    name = manifest.get("name") or os.path.basename(pack_dir)

    # --- (a) delegate structural/manifest validity to validate-pack.sh -----
    try:
        proc = subprocess.run([args.validator, pack_dir], capture_output=True, text=True)
        if proc.returncode == 1:
            add("error", "validate-pack.sh reported error(s):\n" + proc.stdout.strip())
        elif proc.returncode == 2:
            add("warning", "validate-pack.sh reported warning(s):\n" + proc.stdout.strip())
        elif proc.returncode != 0:
            add("warning", f"validate-pack.sh exited with unexpected status {proc.returncode}")
    except OSError as exc:
        add("warning", f"could not run validate-pack.sh: {exc}")

    # --- (b) placement: has this pack been installed, and where does it sit? ---
    lock_path = os.path.join(pack_dir, ".opf-lock")
    has_lock = os.path.isfile(lock_path)
    structural = "owned" if pack["root_kind"] == "owned-root" else "external"
    if has_lock and structural == "owned":
        add(
            "warning",
            f"this pack has a .opf-lock (it went through pack-install at some point) but "
            f"sits under an owned root - looks like a claim that was started (moved into "
            f"the editable workspace) but never finished (the stale lock was never "
            f"removed). Owned packs don't carry a lock; if this is really yours now, the "
            f"fix is to remove .opf-lock, not to move the pack",
        )
        pack_fixes.append({"type": "remove_stale_lock", "path": lock_path})
    # The reverse (no lock, sitting under an external root) is deliberately
    # NOT flagged: it just means not yet installed, which is unremarkable.

    # --- (c) native-tree registration (only if --native-root given) --------
    if native_root:
        for kind in ITEM_KINDS:
            kind_dir = os.path.join(pack_dir, kind)
            if not os.path.isdir(kind_dir):
                continue
            for item in sorted(os.listdir(kind_dir)):
                if item.startswith("."):
                    # .gitkeep and similar: a git-tracking placeholder for
                    # an otherwise-empty kind folder (new-pack.sh's --with
                    # creates these), not a real item. Every pack's empty
                    # folders would otherwise "collide" on the same name.
                    continue
                item_path = os.path.join(kind_dir, item)
                # skills/tools/routines/agents are always subfolders (the
                # descriptor = subfolder rule), but artifacts can be plain
                # files (spec Section 5.4: "no descriptor required; opaque
                # files") - accept either rather than requiring a directory.
                if not os.path.exists(item_path):
                    continue
                native_entry = os.path.join(native_root, kind, item)
                if not os.path.lexists(native_entry):
                    add(
                        "warning",
                        f"{kind}/{item} is not registered in the native tree "
                        f"({native_entry} does not exist) - a harness that discovers items "
                        f"from the native tree will not see it",
                    )
                    pack_fixes.append({
                        "type": "create_symlink", "native_path": native_entry, "target": item_path,
                    })
                    continue
                if os.path.islink(native_entry):
                    link_target = os.path.realpath(native_entry)
                    if not os.path.exists(native_entry):
                        add("warning", f"{kind}/{item}'s native-tree entry ({native_entry}) is a dangling symlink")
                        pack_fixes.append({"type": "remove_symlink", "native_path": native_entry})
                    elif link_target != os.path.realpath(item_path):
                        add(
                            "error",
                            f"{kind}/{item}'s native-tree entry ({native_entry}) resolves to a "
                            f"DIFFERENT pack's copy ({link_target}) - a naming collision; resolve "
                            f"by renaming one of them (spec opf-host-layout.md Section 1.6), not "
                            f"by re-pointing the symlink automatically",
                        )
                else:
                    kind_word = "directory" if os.path.isdir(native_entry) else "file"
                    add(
                        "info",
                        f"{kind}/{item}'s native-tree entry ({native_entry}) is a real {kind_word}, "
                        f"not a symlink to this pack - cannot verify it's the same item",
                    )

    # --- (d) .opf-lock drift ------------------------------------------------
    if has_lock:
        try:
            with open(lock_path) as fh:
                lock = json.load(fh)
        except (OSError, ValueError):
            add("warning", ".opf-lock exists but is not valid JSON")
            lock = None
        if lock is not None:
            recorded = lock.get("checksums") or {}
            actual = compute_checksums(pack_dir)
            recorded_set, actual_set = set(recorded), set(actual)
            changed = sorted(f for f in (recorded_set & actual_set) if recorded[f] != actual[f])
            added = sorted(actual_set - recorded_set)
            removed = sorted(recorded_set - actual_set)
            total = len(changed) + len(added) + len(removed)
            if total:
                examples = (changed + added + removed)[:5]
                more = f" (+{total - len(examples)} more)" if total > len(examples) else ""
                add(
                    "warning",
                    f".opf-lock checksums differ from on-disk content for {total} file(s): "
                    f"{', '.join(examples)}{more} - expected under the rolling-release profile "
                    f"(spec Section 9.2) if this pack tracks a ref rather than tagged versions; "
                    f"otherwise investigate before trusting this copy",
                )
    else:
        add("info", "no .opf-lock; this pack may not have gone through pack-install")

    # --- (e) dependency existence (not range satisfaction) ------------------
    for dep in manifest.get("dependencies") or []:
        if not isinstance(dep, dict):
            continue
        dep_key = (dep.get("vendor") or "", dep.get("name") or "")
        dep_range = dep.get("version") or "?"
        matches = by_vendor_name.get(dep_key)
        if not matches:
            add(
                "warning",
                f"dependency {dep_key[0]}/{dep_key[1]} (range {dep_range}) was not found among "
                f"scanned packs - install it via pack-install, or scan its root too",
            )
        else:
            versions = ", ".join(v for _, v in matches)
            add(
                "info",
                f"dependency {dep_key[0]}/{dep_key[1]} (range {dep_range}) found, installed "
                f"version(s): {versions} - range satisfaction not evaluated, verify manually",
            )

    # --- (f) pre-commit hook shipped but not wired for this clone -----------
    git_marker = os.path.join(pack_dir, ".git")
    hook_script = os.path.join(pack_dir, "hooks", "pre-commit")
    if os.path.exists(git_marker) and os.path.isfile(hook_script):
        try:
            out = subprocess.run(
                ["git", "-C", pack_dir, "config", "--get", "core.hooksPath"],
                capture_output=True, text=True, timeout=5,
            )
            configured = out.stdout.strip().rstrip("/") if out.returncode == 0 else None
        except (OSError, subprocess.SubprocessError):
            configured = None
        if configured != "hooks":
            add(
                "warning",
                "this pack ships hooks/pre-commit (a local pre-commit security scan) but "
                "core.hooksPath is not set to 'hooks' for this clone, so git never runs it - "
                "a fresh clone or a co-maintainer's checkout needs this set once",
            )
            pack_fixes.append({"type": "set_hooks_path", "path": pack_dir})

    results.append({"path": pack_dir, "vendor": vendor, "name": name, "findings": findings, "fixes": pack_fixes})
    fixes.extend({**f, "pack": name} for f in pack_fixes)

with open(args.out_path, "w") as fh:
    json.dump({"results": results, "fixes": fixes, "native_root": native_root}, fh)
PY
}

print_report() {
  local out_path="$1"
  python3 - "$out_path" <<'PY'
import json, sys

with open(sys.argv[1]) as fh:
    data = json.load(fh)

if not data.get("native_root"):
    print("NOTE: no --native-root given; skipping native-tree registration checks "
          "(not every harness uses this pattern - see opf-host-layout.md Section 1.4)")

sev_rank = {"error": 2, "warning": 1, "info": 0}
worst = 0
for pack in data["results"]:
    label = f"{pack['vendor']}/{pack['name']}" if pack["vendor"] else (pack["name"] or pack["path"])
    print(f"\n== {label} ({pack['path']}) ==")
    if not pack["findings"]:
        print("  OK: no issues found")
        continue
    for f in pack["findings"]:
        worst = max(worst, sev_rank.get(f["severity"], 0))
        tag = {"error": "ERROR", "warning": "WARNING", "info": "NOTE"}[f["severity"]]
        for i, line in enumerate(f["message"].splitlines()):
            print(f"  {tag}:  {line}" if i == 0 else f"           {line}")

print()
if worst == 2:
    print("FAIL: at least one pack has an error-class finding")
elif worst == 1:
    print("PASS (with warnings)")
else:
    print("PASS")
PY
}

exit_code_for() {
  local out_path="$1"
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
sev_rank = {"error": 2, "warning": 1, "info": 0}
worst = 0
for pack in data["results"]:
    for f in pack["findings"]:
        worst = max(worst, sev_rank.get(f["severity"], 0))
sys.exit(1 if worst == 2 else 2 if worst == 1 else 0)
' "$out_path"
}

fixes_of_type() {
  # fixes_of_type OUT_PATH TYPE... - prints matching fixes as TSV.
  local out_path="$1"; shift
  python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
wanted = set(sys.argv[2:])
for f in data["fixes"]:
    t = f["type"]
    if t not in wanted:
        continue
    pack = f["pack"]
    if t == "create_symlink":
        a, b = f["native_path"], f["target"]
    elif t == "remove_symlink":
        a, b = f["native_path"], ""
    elif t == "remove_stale_lock":
        a, b = f["path"], ""
    elif t == "set_hooks_path":
        a, b = f["path"], ""
    else:
        continue
    print(pack + "\t" + t + "\t" + a + "\t" + b)
' "$out_path" "$@"
}

apply_fixes() {
  # apply_fixes OUT_PATH TYPE... - applies only fixes of the given type(s),
  # so the caller controls ordering.
  local out_path="$1"; shift
  local applied=0
  while IFS=$'\t' read -r pack_name ftype a b; do
    [[ -z "$ftype" ]] && continue
    if [[ ${#ONLY[@]} -gt 0 ]]; then
      match=0
      for want in "${ONLY[@]}"; do [[ "$want" == "$pack_name" ]] && match=1; done
      [[ $match -eq 0 ]] && continue
    fi
    case "$ftype" in
      create_symlink)
        if [[ -e "$a" || -L "$a" ]]; then
          # Another pack's fix in this same run (or something already there)
          # claimed this native path first - a real collision between two
          # unregistered items sharing an id, not something to silently
          # overwrite. Report and move on; a re-run after resolving the
          # collision by hand will pick this back up.
          echo "SKIP: $pack_name: native path already exists, resolve the collision manually: $a" >&2
          continue
        fi
        confirm "Create native-tree symlink for $pack_name: $a -> $b ?" || { echo "Skipped $pack_name."; continue; }
        mkdir -p "$(dirname "$a")"
        ln -s "$b" "$a"
        echo "Linked $a -> $b"
        applied=1
        ;;
      remove_symlink)
        confirm "Remove dangling symlink for $pack_name: $a ?" || { echo "Skipped $pack_name."; continue; }
        rm -f "$a"
        echo "Removed dangling symlink $a"
        applied=1
        ;;
      remove_stale_lock)
        confirm "Remove stale .opf-lock for $pack_name (completing an in-progress claim): $a ?" \
          || { echo "Skipped $pack_name."; continue; }
        rm -f "$a"
        echo "Removed stale lock $a"
        applied=1
        ;;
      set_hooks_path)
        confirm "Enable the pre-commit hook for $pack_name (git config core.hooksPath hooks in $a) ?" \
          || { echo "Skipped $pack_name."; continue; }
        git -C "$a" config core.hooksPath hooks
        echo "Set core.hooksPath=hooks for $a"
        applied=1
        ;;
    esac
  done < <(fixes_of_type "$out_path" "$@")
  return $((1 - applied))
}

# --- Run it -------------------------------------------------------------------
REPORT_JSON="$(mktemp)"
trap 'rm -f "$REPORT_JSON"' EXIT

run_scan "$REPORT_JSON"
print_report "$REPORT_JSON"

if [[ $FIX -eq 1 ]]; then
  echo
  echo "==> Applying fixes"
  # Dangling-symlink removal before symlink creation, re-scanning between:
  # removing a dangling symlink can turn an item's status from "dangling"
  # to "missing," which only a fresh scan recognizes as a create_symlink
  # fix. remove_stale_lock and set_hooks_path have no such ordering
  # dependency on anything, so they ride along with whichever phase runs
  # first.
  if apply_fixes "$REPORT_JSON" remove_symlink remove_stale_lock set_hooks_path; then
    run_scan "$REPORT_JSON"
  fi
  apply_fixes "$REPORT_JSON" create_symlink || true
  run_scan "$REPORT_JSON"
  echo
  echo "==> Report after fixes"
  print_report "$REPORT_JSON"
fi

exit_code_for "$REPORT_JSON"
