# Open Pack Format (OPF) v1: Host Layout and Distribution Topology

**Status:** Non-normative companion
**Format version:** OPF v1 (`pack_format: 1`)
**Scope:** A recommended profile for how a harness lays out packs on disk and how an adopting organization distributes supporting infrastructure. This document is NOT normative. The normative contract lives in `opf-spec-v1.md`. Omnideck follows this profile.

This companion doc carries two things that the spec deliberately keeps out of the normative contract: the recommended host layout profile (Section 1) and the recommended distribution topology (Section 2). A harness may adopt the spec without adopting this profile.

---

## 1. Host layout profile

This is a reference and suggestions doc, not a requirement. It is the profile Omnideck follows. A harness may adopt the spec without adopting any of these suggestions.

### 1.1 Two top-level roots

Two top-level roots: `~/packs/` (no dot: the user's own, browsable, git-friendly pack workspace) and `~/.packs-external/` (dot: hidden, locked, installed-from-elsewhere). The dot prefix signals that the contents are not yours to edit; the "packs" stem keeps the folder visually associated with `packs/`. The root/home of `~` may depend on whether the user is in a different workspace or project, but the structure is maintained relative to the home.

**Persistent, harness-owned storage.** The external/installed root (and any `PACK_DATA_DIR`) SHOULD live on persistent storage the user owns and can write to, and SHOULD NOT live inside a harness's own config or state directory. Installed packs are the one tier with no local authoring history behind them — an Owned pack can be re-created from its source and a cloned pack re-cloned, but an installed pack that evaporates leaves the consumer with no reconstruction path. Harness config/state trees are also commonly restricted (read-only, provisioner-owned, or policy-denied to agents), which makes recommending pack storage there a trap even when it looks like the tidier lifetime.

Layout organized by provenance tier:

```
<native-root>/
  artifacts/
    okf-app.html                      # standalone owned item, fully editable
  data/
    my-data/
  skills/
    quick-notes/
  tools/
  routines/
    pack-sync/
      routine.json

  packs/
    okf-kit/
      manifest.json                   # vendor: okf -- you created this via
      artifacts/okf-app.html          # create-pack, so it's Owned
      data/wiki/
      skills/okf-skill/

  .packs-external/
    okf/
      other-team-kit/                 # SAME vendor (okf) as okf-kit above,
        manifest.json                 # but you got this via pack-install --
        artifacts/ data/ skills/ tools/ routines/   # still External regardless
    acme/
      onboarding-kit/                 # a different vendor, same reason:
        manifest.json                 # installed, not created -- External
        artifacts/ data/ skills/ tools/ routines/
```

Two `.packs-external/` entries above share nothing except the reason they're there: both arrived via `pack-install`, not `create-pack`. One happens to carry the same vendor string as the Owned example (`okf`); one doesn't. Vendor namespace, team, and org are irrelevant to the tier - see Section 1.3.

**Owned packs are flat; only External packs are vendor-namespaced.** `~/packs/<pack-name>/` has no vendor or team subdirectory - `okf-kit/`, not `okf/okf-kit/` or `<team>/okf-kit/` - because you are the one naming your own Owned packs and can simply avoid picking a name that collides with another Owned pack of yours. `~/.packs-external/<vendor>/<pack-name>/` DOES nest by vendor, because you don't control what a third-party publisher names their pack, and two different external publishers choosing the same pack name is a real collision you have no other way to avoid. That vendor namespace exists to prevent collisions between publishers you don't control - it is not a general "organize packs by team or org" convention, even when your own Owned packs happen to live in a team-owned git group upstream. Where the pack's source repository lives is provenance (recorded in `.opf-lock`, Section 9.1 of the main spec); it has no bearing on this directory layout.

### 1.2 Folder conventions

Items live in named folders at a root (system root, project/workspace root, whatever the harness uses), for example `skills/quick-notes/`, `tools/pdf-convert/`. This is a good-practice suggestion, not part of the spec. The spec does not prescribe where standalone items live; a harness defines its own locations.

### 1.3 Provenance tiers

Two trust tiers, determined by HOW a pack arrived for a given consumer, not as a fixed property of the pack itself - the same pack can be Owned for the person who created it and External for every other consumer who installs it, including a teammate:

- **Owned**: this consumer created the pack (via `create-pack`), or deliberately claimed it - moved or cloned it into their own editable workspace with intent to co-maintain it, removing any stale `.opf-lock` in the process (see below). Editable in place; the user (or their agent) is the update path. Standalone owned items live directly in their native per-type folder: no pack, no indirection, editable in place.
- **External**: this consumer obtained the pack via `pack-install` (or an equivalent install action) and never separately claimed it. Locked/read-only for this consumer by default, under `~/.packs-external/<vendor>/<pack-name>/`. Updated only by the pack owner pushing new versions; this consumer never edits in place. "Clone to customize" is the only path to Owned, landing as a standalone item in the native folder (or into an owned pack afterward, with materialize-and-symlink).

**Tier is about the action taken, not source, vendor, team, or org.** Installing a pack never makes it yours to edit, regardless of who published it - not "does this pack belong to my team/org," not the manifest `vendor` field, which the spec vocabulary already notes is "a namespace, not a verified identity," and not whatever git/platform write access the consumer happens to have to wherever the pack's source repository lives (that access is often broader than any one pack - a whole team or group, not a per-pack grant - so it is not a substitute for this decision). A pack authored under your own team's vendor namespace, living in a repo your org controls, is still External to you if you obtained it by installing it: you have exactly the same read-only relationship to it that you'd have to a stranger's pack, until you take the deliberate step of claiming it. The reverse also holds - a pack under someone else's vendor namespace is Owned by you the moment you create it, or deliberately claim co-maintainership of it, regardless of vendor. A harness MUST default an installed pack to External; locked is the safe default, and matches the spec's "installed packs are locked by default" guarantee (Section 1 of the main spec).

**Locked, as a testable predicate.** A harness that enforces the locked/editable contract via filesystem permissions MUST test permission bits, not `access(2)`-style writability checks — a root-run CI job or system cron passes an `access(2)`-style check regardless of file mode, so a shell `-w` test disagrees with a developer shell about whether the same pack is locked. Under that predicate, a pack is locked when no file beneath the pack root, excluding VCS metadata directories, carries an owner-write bit, and the tree is non-empty. The predicate SHOULD NOT include the pack root directory's own mode bit: a host's own update path needs to recognize a read-only-file pack as locked in order to unlock it for a pull and re-lock it afterward, and a directory-bit requirement would fight that path. A harness MUST use one shared predicate across all of its own tooling - installer, updater, doctor, validator alike; two of a harness's own tools disagreeing about whether the same pack is locked is an implementation defect, not a property of the pack. This is optional: OPF does not require filesystem-level lock enforcement, only that a harness choosing to enforce it this way does so consistently.

**Claiming co-maintainer status is one deliberate act, not a file to keep in sync.** There is no `OWNERS`-style membership list to check: a consumer becomes Owned for a pack by moving or cloning it into their own editable workspace, at which point they should also remove any `.opf-lock` the pack is carrying - Owned packs don't carry one (there is no installer writing it), so a lingering lock is a sign the claim was started but never finished. `scripts/pack-doctor.sh` treats exactly that combination (a lock, sitting under an owned root) as one confidently-detectable placement inconsistency, and offers to remove the stale lock, never to move the pack - which direction a mismatch should resolve in is a decision only the consumer can make. A harness that enforces the locked predicate above gains a second: an External pack that fails it is a confidently-detectable finding too - report it, the same as a stale lock; do not silently `chmod` the pack back to locked without telling the consumer, since an unexpected write bit may be there for a reason.

**A harness that doesn't use this directory layout still owes the tier semantics.** The `~/packs/` / `~/.packs-external/` split is one recommended way to realize Owned-vs-External on disk; it is not the only conformant one, and Section 2.6's harness-integration case study already covers a harness (for example a git-native one with auto-discovery and reset-on-update) that manages installs in its own location instead. Whatever the mechanism, it still needs the same rule above - installed means locked by default, created or deliberately claimed means editable - to decide whether in-place edits are allowed or a read-only/reset posture applies. The lock guarantee is what matters, not which folder name expresses it.

### 1.4 Symlink materialization

Symlinks are suggested in one specific situation: when a pack is created and existing items are moved into the pack folder. In that case the system/tool/script SHOULD leave a symlink at each item's old location pointing into the pack folder, so that existing references (paths in configs, routines, tools, user muscle memory) do not break.

This is a suggestion (SHOULD), not a requirement, and it applies only to that create-pack move situation. Harnesses that manage references differently, or have no per-type native locations, do not need symlinks at all.

Create Pack moves real files into `~/packs/<pack-name>/<type>/` and leaves a symlink at each old native location. The pack folder is self-contained from creation (ready to git-push or zip-export, the natural place for `git init`). Nothing referencing native paths breaks.

Back in the native tree, a symlink:

`<native-root>/artifacts/okf-app.html -> <native-root>/packs/okf-kit/artifacts/okf-app.html`

This assumes a filesystem where symlinks are reliable; any surface without reliable symlinks owns an alternative.

### 1.5 Symlink lifecycle

Symlink lifecycle is enforced at delete time, nowhere else, and only in the create-pack move situation above. Deleting an item deletes its symlink; deleting a pack deletes every member's symlink plus the pack folder. A dangling symlink is a bug. Out-of-band edits are the user's responsibility; no drift scanning (a filesystem-wide consistency check is separate scope).

### 1.6 Native-tree collision rule

When materializing an item into a native per-type location and the name already exists (from another pack or a standalone item), the harness MUST refuse and report, suggesting the namespaced form `<pack>-<item>`. It must never silently overwrite. This rule applies in the same create-pack move situation as the symlink suggestion.

### 1.7 External packs

External packs are never symlinked into the native tree; they live hidden under `~/.packs-external/<vendor>/<pack-name>/`, locked, and "clone to customize" is the only path to Owned.

### 1.8 Migration notes

If a harness previously stored runtime data inside the pack root, migrating to the mutable-state split (spec Section 4.2) means moving that data to the runtime data directory outside the pack root. This is a one-time, user-visible migration; the spec itself defines no migration machinery.

**Rename note.** The two-tier model replaces an earlier three-tier model. The External tier was formerly called "contrib"; the `~/.contrib/` folder is now suggested as `~/.packs-external/`. Existing installs under `~/.contrib/` can be moved to `~/.packs-external/` at the harness's discretion.

---

## 2. Distribution topology: core, common, template

OPF defines the pack format. Adopting organizations also need supporting infrastructure around packs: where the scan rules live, how a new pack is scaffolded, and where shared content is stored. This section defines a recommended three-repo topology for that infrastructure. It is a pattern, not a requirement: a single-harness user can keep everything in one repo and ignore the split. The three repos are opf-core, pack-common, and pack-z-template. Scope note: pack-common is per user or per organization, never global. There is no shared global content repo in this topology. opf-core is a public repo anyone can use or fork; adopters create their own pack-common and pack-* repos.

**Variant topology: template folded into core.** A single-org, single-VCS deployment (for example a private GitLab group with one vendor namespace) can merge opf-core and pack-z-template into one repo while keeping pack-common separate: the template lives at `templates/` inside the same repo that hosts the CI include and the scan rules. Since a CI `include:`/`uses:` resolves at pipeline-creation time regardless of which repo's `templates/` a pack was scaffolded from, "scaffold already wired to CI" stays atomic even with core and template merged. This sits between the single-repo case above (everything merged) and the full three-repo split; pick whichever point on that spectrum matches how many teams and VCS boundaries actually exist.

**Vendoring the spec.** An org on VPN-only or otherwise offline infrastructure, unable to rely on GitHub fetches at build or validate time, MAY vendor the spec and schema (`spec/`, `schema/`) into its own private core repo, with a short doc noting the sync procedure and preserving the Apache-2.0 attribution. This is a sanctioned adoption path, not a fork of the format: the org still tracks and re-syncs against upstream opf-core; it is not maintaining a divergent spec.

**Local extensions to a vendored doc.** An org that vendors this companion doc and extends it with local policy (for example an appended "host-layout override, normative for this deployment" section) should keep that extension in a separate, non-vendored file that the re-sync procedure doesn't touch, and have the vendored doc (or its sync note) reference it. A re-sync that overwrites the vendored file wholesale - the natural implementation of "sync procedure," e.g. a `cp` from upstream - silently deletes anything appended directly to it, with no conflict and no error.

**Harness-integration case study.** The harness-integration layer (who calls `install-pack.sh`/the `pack-install` skill, where resolved config values are stored, how a human approves an `install.sh` diff) is deliberately unspecified by OPF, since it is harness-specific. A harness with git-native skill auto-discovery and reset-on-update behavior can satisfy the "locked by default" guarantee (Section 1.3) even more strongly than checksum auditing: if the harness always resets installed packs to the tracked git ref, a consumer cannot drift from what was published, with zero OPF-specific harness code required.

### 2.1 opf-core

The infrastructure repo. It is public and harness-agnostic so any adopter can use it directly or fork it. It holds the reusable pieces that every pack depends on. Contents:

- `docs/`: this plan document plus an operator runbook covering installing packs and responding to scan failures.
- `ci/`: reusable pipeline templates. `ci/pack-scan.gitlab-ci.yml` is a GitLab CI template; `.github/workflows/scan.yml` is the equivalent GitHub reusable workflow, called via `uses:` from a consuming pack's own workflow.
- `templates/`: canonical pack skeletons.
- `scripts/`: `new-pack.sh` scaffolds a new pack from pack-z-template (name, vendor, description, and item kinds via flags, including `--with tool,routine,agent,artifact`; prompts interactively for the description if it is omitted). `install-pack.sh` deterministically installs or updates a single pack (validate, stage, scan, approve, install, lock, atomic swap) - the scriptable, mechanically-enforced counterpart to the `pack-install` skill for harnesses that can run scripts but not skills. It does not resolve dependency closures (spec Section 4.5), which remains the skill's job. `bump-pack-version.sh` deterministically bumps a pack's `manifest.json` version (major/minor/patch) and prepends a `CHANGELOG.md` entry - the scriptable counterpart to the `pack-release` skill, which decides the bump size and changelog wording on the pack owner's behalf. `ci-install-scanners.sh` installs semgrep/gitleaks/shellcheck, shared by both CI templates so they can't silently drift to different tool versions. `secret-patterns.sh` and `pack-name-pattern.sh` are shared regexes sourced by the scripts above. `e2e-smoke-test.sh` is the end-to-end regression suite, run by `.github/workflows/self-test.yml` on every push/PR.
- `skills/`: the canonical operator skills `pack-install/`, `create-pack/`, and `pack-release/`. `pack-install` installs a pack (spec Section 8.1) - the consumer side. `create-pack` scaffolds a new pack and checks for secrets before creating it: it flags likely secrets (keys, tokens, passwords) in the pack contents and refuses to create a pack that contains them. `pack-release` is the author side: it ships a new version of a pack the user already owns, deciding the semver bump from a plain-language description of the change (never asking the owner to name a bump level or write changelog copy themselves), then validates and commits with confirmation - written for pack owners who are assumed not to know semver or git.
- `routines/`: scheduled task templates, each a subfolder with a `routine.json` descriptor, for example a nightly staleness check.

The key mechanism is that every pack's CI config is a two-line include of core's scan pipeline. On GitLab the include is `include: project: opf-core, file: ci/pack-scan.gitlab-ci.yml`. On GitHub the pack has one job that uses the opf-core reusable workflow. The rationale is explicit: scan rules are single-sourced. A new dangerous-pattern rule or a tool version bump is fixed once in core, and every pack inherits it on the next pipeline run. Without this, each pack carries its own copy of the scan config and the copies drift apart. This is the same pattern as shared CI templates in any organization, and it is deliberately not overkill: the scan config is the security surface, and a security surface must have exactly one source of truth. One GitHub constraint applies: reusable workflows must be public or in the same organization as the pack that uses them.

### 2.2 pack-common

The per-user or per-organization shared-content repo. It holds content that is reused across multiple packs. Contents: `skills/` (SKILL.md folders), shared `scripts/`, `data/` (with a `manifest.json` declaring it a data-only pack), and `templates/`. One rule is stated prominently: a skill, script, or dataset moves into common only when a second pack needs it. There is no speculative sharing. Duplicate once, then promote on second use. The rationale is that premature sharing creates coupling and review burden for content nobody else consumes yet. Packs depend on common via the manifest `dependencies` field, using a vendor, name, version range, and source url (spec Section 3.2, Section 3.5).

### 2.3 pack-z-template

The minimal skeleton repo used by `new-pack.sh`. Contents: a placeholder `manifest.json` (name, version, and `pack_format` are filled in by the scaffolder), `README.md`, `CHANGELOG.md`, the two-line CI include, one example skill folder (SKILL.md plus optional `scripts/`), an empty `data/` folder, and a `.gitignore` that includes `.opf-env` and `.opf-lock`. The rationale is that a new pack goes from proposal to CI-green in one command, with the scan pipeline already wired. The "z-" prefix is a naming convention so the template sorts last in repo listings; adopters may rename it.

### 2.4 Validator

The validator script (`scripts/validate-pack.sh` in opf-core) is the enforcement point for format consistency. It checks: `manifest.json` schema (required fields, semver, `pack_format`), directory layout (`artifacts/`, `data/`, `skills/` and so on, presence and placement), zip-slip-safe paths, the lifecycle script contract (executable bit, no surprising network use), `README.md` presence (a warning, not an error), `contents` against the actual folders (a warning, not an error), and secrets: if an `.opf-env` file exists it must be listed in `.gitignore`, and the scan flags likely secrets (keys, tokens, passwords). Exit codes are 0 for pass, 1 for error (CI-blocking), and 2 for warning. The same validator runs locally and in CI, so a pack that passes locally passes CI. The pack-install skill invokes the validator as its first step. Implementation note: start as a bash script calling `jsonschema` plus the available language tools from the opf-core scan profile (Section 2.6), then promote to a small CLI (python or go, single binary) once the checks outgrow bash.

### 2.5 Scan staging notes

The scan runs on the staged/incoming copy in a temporary location before it replaces the installed pack. Because install is atomic (spec Section 8.1), the staged copy is a temporary sibling directory, for example `<pack>.new`, and the scan runs there before any replacement. On failure the staging directory is removed and the old pack remains intact.

### 2.6 opf-core scan profile

This section is the companion to spec Section 7. It is non-normative: it recommends tooling and a graceful-degradation contract, while the normative guarantee (a deterministic, non-LLM scan runs before install; error blocks, warning flags, info records) lives in the spec.

**Graceful degradation contract.** Tools that are not installed are skipped (a `command -v` check) with a note in the scan report. The manifest-schema and zip-slip path checks are the floor and run with zero tools installed; they are the only checks that must always run. `semgrep` (if present) is the only cross-language requirement, and even it degrades gracefully. No specific tool is required to be installed. This graceful degradation is meant for install time on an arbitrary harness machine whose available tools cannot be predicted. It does NOT apply to opf-core's own CI templates (`ci/pack-scan.gitlab-ci.yml`, `.github/workflows/scan.yml`): those install `semgrep` and `gitleaks` themselves rather than silently skipping them, because they are meant to be the single-sourced security gate every pack's repo inherits, and a silent no-op there would be a much larger blind spot than on one developer's machine.

**CI scan templates MUST NOT execute content from the pack under scan; they parse, lint, and detect only.** `ci/pack-scan.gitlab-ci.yml` and `.github/workflows/scan.yml` run the validator, shellcheck, semgrep, and gitleaks against the pack's own files - all of which read and analyze pack content, none of which run it. This is a load-bearing property, not an incidental fact: a pack's `install.sh`, `tool.json` entry points, and any other executable content stay untrusted, unexecuted data to these pipelines. A future change that adds a "smoke-run the pack" step to either template would break this invariant and MUST NOT be merged without re-deriving the security posture from scratch.

**CI scanning and install-time scanning are complementary, not substitutes.** CI scanning (the opf-core CI templates, run in a pack's own repo) protects the pack repository: it catches a dangerous pattern or a leaked secret before a commit merges or a release ships. It does nothing for a consumer who installs a pack from a source that never ran that CI - a malicious fork, a contrib repo with no CI at all, a zip handed over directly. Consumer protection is entirely the install-time scan (`skills/pack-install` step 4, or `scripts/install-pack.sh`'s scan step), run on the machine doing the installing, independent of whatever the source repo's CI did or didn't do. A harness or org relying only on upstream CI passing is not actually protecting its own installs.

**Recommended tools.**

| Language | Lint / format | Typecheck | Security |
|---|---|---|---|
| shell | `shellcheck` (+ `shfmt` format check) | n/a | `shellcheck` severity rules |
| python | `ruff` (lint + format) | `mypy` | `bandit` or `semgrep` |
| go | `go vet` | `go vet` | `gosec`, `semgrep` |
| js/ts | `eslint` (+ `typescript-eslint`) | `tsc --noEmit` | `semgrep` |
| php | `php -l` (syntax) | `PHPStan` | `PHPStan` security rules |
| ruby | `rubocop` | n/a | `brakeman` |

`gitleaks` is the recommended secrets-detection tool for the scan. `semgrep` is the recommended cross-language engine for the dangerous-pattern checks in spec Section 7.1.
