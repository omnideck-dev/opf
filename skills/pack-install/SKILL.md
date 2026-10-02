---
name: pack-install
description: "Install or update an OPF pack with dependency resolution and approval: resolve the dependency closure, validate, scan, approve, configure, install, atomically swap."
---

# pack-install

Install or update an OPF pack. This is the canonical operator skill for OPF
(Section 8.1 of `spec/opf-spec-v1.md`). It is an ordinary `SKILL.md` skill, so
any harness that can run skills and shell commands can use it. OPF requires
zero harness-native pack features.

Follow the procedure below in order. It is deterministic.

For a single pack with no dependencies, `scripts/install-pack.sh` in this
repo implements steps 2-10 below as a plain script with real exit codes,
for a harness that can run scripts but not skills. It does not resolve
dependency closures (step 1); this skill remains the path for that.

## Working directory assumption

Skills may run with the `OPF_ROOT` environment variable pointing at the
opf checkout. If `OPF_ROOT` is set, locate the validator and related
scripts under `$OPF_ROOT/scripts/`. Otherwise, locate the scripts relative to
this skill if it is bundled with opf (for example
`<opf>/scripts/validate-pack.sh`). If neither is available, ask the user
for the opf checkout path.

## Trust tier and install location

A pack obtained through this skill is External by definition (spec Section
3; `opf-host-layout.md` Section 1.3): installing a pack never makes it
yours to edit in place, regardless of vendor, team, org, or whatever git/
platform write access the consumer happens to have to the pack's source
repository (that access is usually broader than any one pack, so it is not
a substitute for this decision). Stage and install to a locked, vendor-
namespaced location, for example `~/.packs-external/<vendor>/<pack-name>/`
- NOT the flat, editable `~/packs/<pack-name>/` workspace.

If the user says this pack is actually theirs - they created it, or they
are deliberately becoming a co-maintainer - this skill is the wrong tool
for that: `create-pack` handles the first case, and claiming co-maintainer
status is a deliberate move into the owned workspace (dropping any stale
`.opf-lock` in the process, since Owned packs don't carry one), not
something this skill does on the user's behalf.

This exact directory layout is itself a non-normative recommendation (a
harness with its own install-location scheme, for example a git-native
harness with auto-discovery, MAY use a different location entirely), but
the underlying rule - installed means locked, until deliberately claimed -
applies regardless of which location scheme a harness uses.

## Procedure

1. **Resolve the dependency closure.** This is the FIRST step. Resolve the
   transitive, depth-first dependency closure per spec Section 4.5:
   - For each dependency declared in the manifest's `dependencies` array,
     fetch its manifest from its declared `url` if it is not already
     installed.
   - Skip already-installed dependencies whose version satisfies the declared
     range.
   - Refuse on cycles (a pack that transitively depends on itself is invalid).
   - If a dependency of the same `vendor/name` is installed but its version
     does not satisfy the range, report the conflict and STOP. Do not
     auto-upgrade.
   - Present the FULL closure (all packs and all their `install.sh` scripts)
     as ONE review/approval, not one prompt per pack. Serial approve dialogs
     train users to click through and destroy the approval gate.
   - Install dependencies first, each through the same procedure below, then
     install the target pack.
   - Record the resolved closure in `.opf-lock`.
   - Atomicity is per-pack: a failed dependency leaves earlier successful
     installs in place; the target pack is not installed.

2. **Validate the manifest.** Run the validator on the staging directory:
   `bash <opf>/scripts/validate-pack.sh <staging-dir>`. Reject the
   install on any validation failure. Do not proceed past this step on
   failure.

3. **Stage the pack.** Copy the incoming pack into a temporary staging
   directory, for example `<pack>.new`, as a sibling of the final install
   path.

4. **Scan the staging copy.** Run the static scan on the staging directory:
   - `semgrep scan --config <opf>/ci/semgrep-opf-rules.yml --severity ERROR --error --exclude .opf-env --exclude .opf-lock <staging>`
     (the curated OPF ruleset - error-class findings here stop the install)
   - `semgrep scan --config auto --error --exclude .opf-env --exclude .opf-lock <staging>`
     (the registry ruleset - not curated to OPF's categories, so findings are
     surfaced as warnings requiring acknowledgment, not a hard block)
   - `gitleaks detect --source <staging> --no-git --redact` (if installed;
     skip gracefully with a note if absent).
   Error-class findings from the curated ruleset stop the install here.
   Warnings (from the registry ruleset, or from the curated ruleset's
   WARNING-severity rules) are surfaced for user acknowledgment before
   continuing. If the manifest declares `scan.exclude` patterns, resolve
   them with `scripts/resolve-scan-excludes.py <manifest> <staging>` and
   pass each printed path as an additional `--exclude` to both semgrep
   calls above - it already drops any path that is an executable file type
   (spec Section 7.3, rule (a)), so its output is always safe to exclude.
   `scan.exclude` applies to content scanning only; never skip gitleaks or
   any structural check because of it. Exclude the installer's own state
   files from the scan: pass `--exclude .opf-env --exclude .opf-lock` to
   semgrep and use gitleaks path
   exclusions for `.opf-env` and `.opf-lock`.

5. **Obtain explicit user approval for `install.sh`.** Show the full text of
   `install.sh` on a first install. On an update, show the diff against the
   previously installed (and previously approved) version. Do not run
   `install.sh` without explicit approval. A pack with no `install.sh` does
   not require this step. If the user declines approval, ABORT: remove the
   staging directory and leave the previous pack intact.

6. **Resolve configuration.** Prompt the user for any required config entries
   declared in the manifest's `config` block (Section 4.4). Store the resolved
   values outside the pack root (for example the harness secret store or a
   config location adjacent to the runtime data directory). Secrets never go
   in the pack.

7. **Write `.opf-env` into the staging directory.** Use `KEY=value` lines, one
   per line. Include the five `PACK_*` variables plus the resolved config
   values as `CONFIG_*` variables:

   ```
   PACK_ROOT=<staging-dir>
   PACK_NAME=<pack-name>
   PACK_DATA_DIR=<runtime-data-dir>
   PACK_VERSION=<pack-version>
   PACK_INSTALL_DIR=<final-installed-path>
   CONFIG_<KEY>=<resolved-value>
   ```

   | Variable | Meaning |
   |---|---|
   | `PACK_ROOT` | The staging directory. |
   | `PACK_NAME` | The pack name from the manifest. |
   | `PACK_DATA_DIR` | The runtime data directory for the pack. |
   | `PACK_VERSION` | The pack version from the manifest. |
   | `PACK_INSTALL_DIR` | The FINAL installed path. |
   | `CONFIG_<KEY>` | Resolved config values as env vars. |

8. **Run `install.sh`.** Run it with cwd = the staging directory,
   `PACK_ROOT` = the staging directory, and `PACK_INSTALL_DIR` = the FINAL
   installed path (Section 8.4). Treat a non-zero exit as a failed install.

9. **Write `.opf-lock` into the staging directory** on success (exit 0). Use
   this JSON template:

   ```json
   {
     "name": "<pack-name>",
     "version": "<pack-version>",
     "installed_at": "<ISO-8601 date>",
     "source": {
       "type": "git",
       "url": "<source-url>",
       "commit": "<commit-sha>"
     },
     "checksums": {
       "manifest.json": "sha256:<hash>"
     },
     "dependencies": [
       { "vendor": "<vendor>", "name": "<name>", "version": "<resolved-version>" }
     ],
     "data_dir": "<runtime-data-dir>"
   }
   ```

   Record the version, install date, source (including the commit SHA when the
   source is git), checksums, the resolved dependency closure array, and
   `data_dir`.

10. **Swap.** Replace the installed pack with the staged directory using two
    renames: rename the installed pack to `<pack>.old`, rename the staging
    directory to the installed path, then delete `<pack>.old` (Section 8.1.1).
    On any failure before the swap, remove the staging directory; the
    previously installed pack is left untouched.

## Version and downgrade semantics

- Compare versions with a semver-aware comparator, not string comparison.
- Refuse downgrades by default: if the incoming version is lower than the
  installed `.opf-lock` version, refuse unless the user explicitly confirms
  the downgrade.

## Notes

- `.opf-env` and `.opf-lock` are excluded from the scan. The installer never
  scans its own state files.
- Install is atomic per pack: no partial state is ever visible. The old pack
  remains intact on any failure.
- `install.sh` must be idempotent and fail-safe. A non-zero exit means the
  install failed and must be reported to the user.

See `spec/opf-spec-v1.md` Section 8.1 for the normative procedure and Section
4.5 for dependency resolution.