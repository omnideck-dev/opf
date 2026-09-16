---
name: create-pack
description: Scaffold a new OPF pack from the template, creating subfolders for selected item kinds and enforcing the secrets gate before creating.
---

# create-pack

Scaffold a new OPF pack from the template in `templates/pack-z-template/`.
The scaffolder (`scripts/new-pack.sh`) enforces a secrets gate: it scans the
new pack for likely secrets and refuses to create it if any are found. This
skill instructs the agent to run `new-pack.sh` and to handle a refusal.

## Working directory assumption

Skills may run with the `OPF_CORE` environment variable pointing at the
opf-core checkout. If `OPF_CORE` is set, locate `new-pack.sh` and
`validate-pack.sh` under `$OPF_CORE/scripts/`, and the template under
`$OPF_CORE/templates/pack-z-template/`. Otherwise, locate them relative to
this skill if it is bundled with opf-core (for example
`<opf-core>/scripts/new-pack.sh`). If neither is available, ask the user for
the opf-core checkout path.

This matters because opf-core is typically installed once and reused across
many packs: the checkout is rarely the current working directory when this
skill runs. The new pack itself is created in the CURRENT working directory
(`new-pack.sh` scaffolds `./<name>`, not a path relative to opf-core) - `cd`
to wherever the user keeps their packs before running the scaffolder, using
the opf-core paths above only to locate the tooling itself.

## Procedure

1. **Gather pack details from the user.** Ask for:
   - **name**: lowercase `[a-z0-9._-]`, 1-64 characters, no leading or
     trailing separator, and never `.` or `..`.
   - **vendor**: the publishing namespace.
   - **description**: a one-line summary.
   - **item kinds**: which items the pack will contain (skills, tools, data,
     routines, artifacts).
   - **owner(s)**: who maintains this pack, kept to one or a small named few
     (`opf-pack-boundaries.md` Section 2) - purely for the README note in
     step 4, not a file OPF checks for anything. If the user is unsure
     whether this should be a new pack, an addition to an existing one, or
     a dependency-only bundle pack, see `<opf-core>/spec/opf-pack-boundaries.md`
     before scaffolding - splitting later is more work than deciding well
     up front.

2. **Run the scaffolder.** From the directory where the new pack should be
   created, run `bash <opf-core>/scripts/new-pack.sh <name> [vendor] -d
   "<description>" [--with <kinds>]`, where `<kinds>` is a comma-separated
   list drawn from the item kinds the user selected in step 1 (`tool`,
   `routine`, `agent`, `artifact` - omit `skill` and `data`, which the
   template already provides). The script copies the template, substitutes
   placeholder tokens, creates a `.gitkeep`-tracked subfolder for each
   requested kind, and runs the secrets gate.

3. **Verify the requested subfolders exist.** Confirm the scaffolder created
   a subfolder for each item kind the user selected in step 1. If `--with`
   was omitted or a kind was missed, create the subfolder by hand with a
   `.gitkeep` placeholder so git tracks the empty folder.

4. **Fill the manifest, and note the owner(s) in README.md.** Edit
   `manifest.json` to set `name`, `version` (`0.1.0`), `pack_format` (`1`),
   `description`, and `vendor` - the scaffolder already substitutes `name`,
   `vendor`, and `description`. Add a short "Maintained by: ..." line to
   `README.md` naming the owner(s) gathered in step 1. This is governance
   only - who to ask about a change - not something a harness checks for
   anything: creating the pack is what makes it Owned (`opf-host-layout.md`
   Section 1.3), and OPF does not prescribe a dedicated ownership file (see
   `opf-pack-boundaries.md` Section 2 for the alternatives, including
   platform-native `CODEOWNERS` for orgs that want real enforcement). A
   pack that needs many names to stay accountable is usually a sign it
   should be split, not a sign to keep adding names.

5. **Handle the secrets gate.** `new-pack.sh` runs the secrets scan itself
   after scaffolding and before printing success. If it refuses (exit 1), do
   NOT bypass it. Tell the user which file and pattern matched, and stop.
   Only if the user explicitly accepts the risk may you re-run with
   `--allow-secrets`; print the loud warning the script emits.

6. **Point the user at the next steps.** Tell them to run
   `bash <opf-core>/scripts/validate-pack.sh <pack-dir>`. CI scanning is
   already wired up by the template - no separate step needed. If/when
   they `git init` this pack (this skill does not do that for them - see
   `pack-release`'s notes on why), tell them to also run `git config
   core.hooksPath hooks` once, to enable the pre-commit scan the template
   ships at `hooks/pre-commit`. `pack-doctor` checks for exactly this and
   can fix it later if it's ever missed (for example after a fresh clone).

## Notes

- Secrets never go in a pack. The scan flags likely secrets, and `.opf-env`
  must be gitignored.
- The template's `.gitignore` already excludes `.opf-env`, `.opf-lock`, and
  `.env`. It also ships `.github/workflows/scan.yml` and `.gitlab-ci.yml`,
  both already wired to opf-core's scan template - a new pack is CI-green on
  first push with no configuration.
- The template also ships `hooks/pre-commit`, a local pre-commit scan
  (validate-pack.sh + gitleaks + the curated semgrep ruleset, each skipped
  gracefully if not available). It is NOT enabled by cloning the repo - git
  never reads `hooks/` on its own - see step 6. It is fast local feedback,
  never a substitute for the CI gate: it's bypassed by `--no-verify` and
  degrades to whatever's installed, same as install-time scanning does.
- The scaffolder refuses to create a pack that contains likely secrets unless
  `--allow-secrets` is passed at the user's explicit risk.

See `spec/opf-spec-v1.md` for the pack format and Section 7 for scanning, and `spec/opf-pack-boundaries.md` for pack sizing, ownership, and the bundle-pack pattern.