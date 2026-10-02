# Open Pack Format (OPF) v1: Specification

**Status:** Normative specification
**Format version:** OPF v1 (`pack_format: 1`)
**Scope:** A harness-agnostic pack standard. Any agent harness, CLI tool, or editor can adopt the format.
**Companions:** `opf-host-layout.md` (non-normative) carries the recommended host layout profile and the distribution topology. `opf-pack-authoring.md` (non-normative) carries guidance on whether something should be a pack at all and what belongs inside one versus in the tool it drives or the user's own workspace. `opf-pack-boundaries.md` (non-normative) carries guidance on pack sizing, ownership, and the bundle-pack pattern - a judgment call the spec deliberately does not constrain. Where this spec points to a companion doc, the details live there.

**Hard requirement: zero native pack code.** OPF requires no harness-native pack features. Validation, scanning, install, and state tracking are all performed by scripts and skills that any harness able to run shell commands and skills can execute. A harness needs no native pack code to install, update, or remove a pack.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY in this document are to be interpreted as described in RFC 2119.

---

## 1. Motivation

A **single, standardized way to package and move any functional primitive**: artifacts, skills, custom tools, data, and routines, as one item or as a curated collection, so that:

- A user can back up or share one thing (a skill, a tool).
- An organization can define a **preset working state**: "every new install for this team starts with these skills, these tools, these routines already configured", like Ansible provisions a machine to a known state, rather than each teammate hand-configuring their own install.
- Eventually, packs can be **discovered, rated, and installed from a community library**, and published/updated **as git repositories**, not just ad-hoc file downloads.
- None of this should let a user (or the agent, acting on the user's behalf) accidentally break something they installed from a trusted source: installed packs are locked by default.

The format is defined by files on disk and a documented contract, not by any single product's internal models. Any harness can implement a reader/writer.

---

## 2. Conformance

This section defines what it means for a harness to "support OPF v1". A conforming implementation MUST:

- Reject a manifest that fails `manifest.schema.json`.
- Reject any path that escapes the pack root after normalization.
- Run a deterministic, non-LLM scan before install and refuse to install on any error-class finding.
- Obtain explicit user approval before executing a lifecycle script, showing the full script text on first install and a diff on update.
- Treat a non-zero lifecycle script exit as an install failure.
- Leave the previously installed pack intact on any failure.
- Keep runtime state outside the pack root.
- Record observed provenance (including the commit SHA when the source is git) in `.opf-lock`.
- Provide the five `PACK_*` environment variables (`PACK_ROOT`, `PACK_NAME`, `PACK_DATA_DIR`, `PACK_VERSION`, `PACK_INSTALL_DIR`) to lifecycle scripts.

A conforming implementation SHOULD:

- Write `.opf-lock` and `.opf-env`.
- Support `uninstall.sh`.
- Refuse downgrades by default.

Everything else in this spec is an optional profile. This section defines what "supports OPF v1" means.

---

## 3. Vocabulary

| Term | Meaning |
|---|---|
| **Item** | One functional primitive: a reusable **artifact**, a **skill**, a custom **tool**, some **data**, a **routine** (a scheduled/recurring task template), or an **agent profile**. |
| **Pack** | The one distributable unit: a manifest plus zero or more embedded files, containing one or more items. Single item or many, same format. |
| **Harness** | Any software that reads, installs, or executes packs (a CLI, an editor, an agent product). |
| **Vendor** | The publishing namespace a pack is authored under. It is DECLARED in the manifest as the author's choice. It is a namespace, not a verified identity. A shared vendor string is not an ownership signal - see Trust tier below. |
| **Provenance** | Where a pack came from and its trust tier. Provenance is OBSERVED at install time and recorded in `.opf-lock` (Section 9.1). |
| **Trust tier** | The two provenance tiers, determined by HOW a pack arrived for a given consumer, not by its vendor, team, or org: **Owned** (created by this consumer, or deliberately claimed into their own editable workspace with intent to maintain it; editable in place, and the consumer or their agent is the update path) and **External** (arrived via install; locked/read-only for the consumer by default, updated only by the pack owner pushing new versions). A pack sharing the consumer's vendor namespace, team, or org is still External if it arrived by installing rather than creating or deliberately claiming it - installing something never makes it yours to edit in place. Becoming a co-maintainer of an existing External pack is a deliberate act, not a passive file edit or an inherited permission. The mechanics live in the companion doc; the spec only requires recording a source. |
| **Locked / editable** | Per-item (and per-pack) flag: whether the agent or user can modify it in place, versus needing to clone it into their own owned space first. |
| **Lifecycle script** | An optional executable (`install.sh`, and optionally `uninstall.sh`) run by the harness at a defined point. |

Item kinds in scope: Artifact, Skill, Tool, Data, Routine (scripts run by cron), and Agent profile. **Skill is a special case**: the open Agent Skills format (`SKILL.md`, YAML frontmatter, optional `scripts/`, `references/`, `assets/`) is already adopted across other agent products with its own registry (skills.sh). Skill packaging defaults to wrapping or adopting that format rather than inventing a new one. Each skill lives in its own subfolder, `skills/<skill-id>/SKILL.md`, both in the native tree and inside packs. The skill-id MUST match `^[a-z0-9]+(-[a-z0-9]+)*$` (lowercase alphanumerics and single hyphens, no leading, trailing, or consecutive hyphens) and MUST equal the SKILL.md `name` field, per the open Agent Skills format (agentskills.io). This is a distinct, stricter grammar than the manifest `name`/`vendor` charset (Section 4.1); see the cross-reference table in Section 5.4. **Validators MUST enforce the Agent Skills name grammar for skill items and MUST enforce name==folder-name** (the skill-id and the SKILL.md `name` field matching exactly); a validator that instead applies the manifest's charset to skill items, or treats a mismatch as advisory, is not conformant. A skill item is exactly `skills/<name>/SKILL.md` at depth 1; a nested `skills/<name>/<sub>/SKILL.md` is invalid, and validators MUST reject it regardless of what the manifest `contents` declares (folders are still the truth for existence, but not for depth).

**Items are not in a pack by default.** Creating a skill, tool, routine, or artifact produces a standalone item; packing is an explicit act (via `create-pack` or by hand). Standalone items live wherever the harness keeps user-created things; the spec does not prescribe the location. A named-folder convention is suggested in the reference doc.

There is no distinct "Script" item kind. A script belongs in `tools/` (generic or random scripts/tools), in `routines/` (if invoked by a cron/scheduler), or inside the skill's own folder (if unique to that skill).

---

## 4. Manifest metadata and `manifest.json` schema

The manifest is the single required metadata file at the pack root. It is JSON, named `manifest.json`, and carries a `pack_format` field identifying the OPF spec version the manifest conforms to. JSON is chosen because it is strict, typed, and has a canonical parser in every major language. The `pack_format` field lets a harness reject manifests written against a newer or incompatible spec version.

The manifest serves two purposes: **discovery and UX** (what the pack is, what it looks like in a list or card view) and **declared capability** (dependencies, contents). A manifest that fails schema validation is rejected outright; this is the floor of the security scan (Section 7).

### 4.1 Required fields

| Field | Required | Type | Notes |
|---|---|---|---|
| `name` | Yes | string | Lowercase `[a-z0-9._-]`. Used for identity and state keys. |
| `version` | Yes | string | Semver. The comparison of the incoming manifest version against the installed `.opf-lock` version is what tells pack-install it is an update versus a fresh install. |
| `pack_format` | Yes | integer | OPF spec version this manifest conforms to. For OPF v1 this is `1`. |
| `description` | Yes | string | One-line summary for card/list views. |

### 4.2 Optional fields

| Field | Required | Type | Notes |
|---|---|---|---|
| `vendor` | No | string | The publishing namespace, DECLARED by the author. A namespace, not verified. Omitted for local packs with no declared namespace. |
| `homepage` | No | string | Project home page. |
| `repository` | No | string | Git or other source URL. |
| `license` | No | string | SPDX identifier or `proprietary`. |
| `categories` | No | array of string | Browse/filter grouping. OPTIONAL and non-load-bearing: helpful for discovery and UI; nothing validates against it and packs work fully without it. |
| `images` | No | array of string | First = card thumbnail; the rest populate the detail carousel. OPTIONAL and non-load-bearing, same as `categories`. |
| `dependencies` | No | array of object | Each entry has four required fields: `vendor`, `name`, `version` (a semver range, in [node-semver range syntax](https://github.com/npm/node-semver#ranges), for example `^1.2.3`, `~1.2.3`, or `>=1.0.0 <2.0.0`), and `url` (the source repository URL where the dependency pack can be fetched if not already installed). A relative path, `file://` URL, or a private-registry URL (SSH, or CI-job-token-gated) is acceptable for local, monorepo, or private-infrastructure dependencies. An optional `ref` field records the git ref a rolling consumer tracks (Section 9.2); it is informational and does not affect resolution. Dependencies are other packs. Dependencies key on the declared `vendor/name`, so forks and mirrors do not change identity. |
| `contents` | No | object | Declared item kinds and their identifiers, for example `"contents": { "skills": ["report-format"], "routines": ["pack-sync"] }`. Keys are plural, matching the directory names (Section 5). OPTIONAL. The validator checks `contents` against the actual folders as a WARNING, not an error; folders are the truth. |
| `data_dir` | No | string | Preferred name for the runtime data directory (Section 5.2). Optional hint. |
| `config` | No | array of object | Required/optional configuration entries (Section 4.4). |
| `metadata` | No | object | Free-form key/value object for org-specific annotations. Non-load-bearing; never validated beyond being an object if present. Example: `"metadata": { "reviewed-by": "security-team", "internal-id": "PKG-1042" }`. |

**Extensibility (layering).** Unknown top-level manifest fields MUST be preserved by implementers and MUST NOT cause validation errors; the validator MAY warn about them. This is the layering extension path: an org adds its own fields without forking the schema. `metadata` is the sanctioned place for arbitrary org annotations; any other unknown field is preserved and ignored. The normative manifest schema is published as a versioned artifact (`manifest.schema.json`) alongside the spec, and validators SHOULD validate against it.

### 4.3 JSON example

```json
{
  "pack_format": 1,
  "name": "weekly-report",
  "version": "1.1.0",
  "description": "Generates a weekly status report.",
  "vendor": "acme",
  "license": "MIT",
  "homepage": "https://example.com/weekly-report",
  "repository": "https://github.com/acme/weekly-report",
  "categories": ["reporting", "automation"],
  "images": ["card.png", "detail-1.png"],
  "dependencies": [
    { "vendor": "myorg", "name": "pack-common", "version": "^1.0.0", "url": "https://github.com/myorg/pack-common" }
  ],
  "contents": {
    "skills": ["report-format"],
    "tools": [],
    "routines": ["weekly-report"],
    "agents": ["weekly-editor"]
  },
  "data_dir": "weekly-report-data",
  "config": [
    {
      "name": "REPORT_EMAIL",
      "description": "Email address to send the weekly report to.",
      "required": true
    }
  ]
}
```

### 4.4 `config` block (secrets and configuration)

The optional `config` block lists configuration entries the pack needs. Each entry has:

| Field | Required | Type | Notes |
|---|---|---|---|
| `name` | Yes | string | Environment variable name exposed to scripts, routines, and tools at run time. |
| `description` | No | string | Human-readable explanation shown when prompting the user. |
| `required` | No | bool | Whether the value is mandatory. Default false. |

At install time the harness or the pack-install skill prompts the user for these values during the install procedure (Section 8.1) and stores them OUTSIDE the pack root (a harness-defined location, for example the harness secret store or a config location adjacent to the runtime data directory). The resolved values are exposed to `install.sh` as environment variables AND at run time to routines and tools via a harness-defined mechanism, stored outside the pack root. Secrets NEVER go in the pack. The pack-install-written environment file is named `.opf-env` (gitignored), not `.env`, so users are not tempted to paste keys into a file that looks like a standard dotenv. Packs must not contain secrets; the scan flags likely secrets; `.opf-env` must be gitignored.

### 4.5 Dependency resolution

Dependency `version` ranges use [node-semver range syntax](https://github.com/npm/node-semver#ranges) (caret `^`, tilde `~`, comparator sets like `>=1.0.0 <2.0.0`, and OR-joined ranges with `||`). This is the de facto cross-language standard for range syntax, with compatible parsers available in effectively every language a harness might be written in, which matters for a format whose entire premise is harness-agnostic interop. A harness MUST reject a `version` range it cannot parse rather than guessing.

When a pack is installed, its dependencies are installed FIRST, before the pack itself. Resolution is transitive and depth-first: each dependency's own dependencies are resolved before that dependency is installed. For example, installing `pack-tech-sme`, which depends on `pack-common`, which depends on `pack-core`, installs in this order: `pack-core`, then `pack-common`, then `pack-tech-sme`.

- A dependency already installed at a version satisfying the range is NOT reinstalled.
- The `url` field is used to fetch a dependency that is not installed. If a dependency of the same `vendor/name` is installed but its version does not satisfy the range, the installer reports the conflict and stops. It does not auto-upgrade.
- Cycles are detected and refused. A pack that transitively depends on itself is invalid.
- Dependencies are scanned and installed through the same pack-install procedure (validation, scan, approval) as any pack. There is no separate "dependency install" path.
- `.opf-lock` records the resolved dependency closure (the `vendor/name` and resolved version of each dependency, plus the resolved commit for a rolling dependency that declares `ref`; Section 9.2) alongside the pack's own version.

**Atomicity is PER-PACK, not per-closure.** Each pack in the dependency closure is installed atomically on its own. A failed dependency leaves earlier successful dependency installs in place; the target pack is not installed. The installer does not roll back dependencies that already succeeded.

**Implementation note.** The installer SHOULD present the resolved dependency closure and all lifecycle scripts as a single review (one approval), not one prompt per pack. Serial approve dialogs train users to click through and destroy the approval gate.

**The bundle pattern.** A pack MAY consist of nothing but a `dependencies` array (no items of its own): installing it installs its full dependency closure in one step. This is a composition pattern built entirely out of the mechanism above, not a distinct pack kind - see `opf-pack-boundaries.md` for when to use it and for the update-semantics gotcha (an already-satisfying installed version is not reinstalled, so "update the bundle" only cascades to members if the bundle's own ranges are bumped, or the members run the rolling profile of Section 9.2).

---

## 5. Directory layout of a pack

A pack is a directory. The only required file is `manifest.json`. Everything else is optional and additive.

```
<pack-root>/
  manifest.json          # REQUIRED manifest (Section 4)
  README.md              # human-readable overview (entry point)
  artifacts/             # distributed content: user-facing outputs and templates
  data/                  # pack-owned content, replaced on update, checksummed
  skills/                # SKILL.md folders, one subfolder per skill
  tools/                 # tool subfolders, one per tool (tool.json descriptor)
  routines/              # routine subfolders, one per routine (routine.json descriptor)
  agents/                # agent items (optional AGENT.md, see Section 10)
  install.sh             # optional lifecycle script (Section 8)
  uninstall.sh           # optional lifecycle script (Section 11)
  .opf-lock              # harness-written installed-state file, not part of the pack
  .opf-env               # harness-written env file (gitignored), not part of the pack
```

All entity directories are plural (`skills/`, `tools/`, `routines/`, `agents/`, `artifacts/`), matching the ecosystem convention (Claude Skills, `pi`'s auto-discovery) and matching `packs/` at the host-layout level (Section 13). `data/` is the one exception, since it already reads as a mass noun rather than a countable collection.

A harness MAY present pack items in per-type native locations via symlinks; see the reference doc.

**Descriptor = subfolder rule.** An item is a subfolder when it contains a known descriptor file: `SKILL.md` for skills, `tool.json` for tools, `routine.json` for routines, and `AGENT.md` (or a harness-defined agent format) for agents. Artifacts and data are plain files or folders with no descriptor. This gives uniform recognition for agnostic-repo import (Section 6): a folder containing a known descriptor file is an item.

### 5.1 `artifacts/`

Distributed content: user-facing outputs and templates the pack produces, such as a generated report template, a rendered document skeleton, a spreadsheet template, or a diagram source. Files here are treated as opaque by the harness; the pack's own scripts and docs define their meaning. `artifacts/` is distributed content and is treated as read-only by the contract.

### 5.2 `data/` and runtime data

`data/` is pack-owned content: it is replaced on update and covered by checksums. Files are opaque to the harness; the harness does not parse them. Runtime/mutable state belongs in `PACK_DATA_DIR` outside the pack root.

A pack whose `data/` IS its primary payload (for example a knowledge or content pack: a wiki, a curated dataset) is fully conformant as-is; nothing above requires such a pack to also use `PACK_DATA_DIR`. `PACK_DATA_DIR` is only needed when runtime mutation exists — when something writes new or changed state after install, not merely when `data/` is large or central to the pack's purpose.

Runtime/mutable state lives OUTSIDE the pack root. `PACK_DATA_DIR` points to a harness/user-chosen location outside the pack directory. The harness or skill resolves it, defaulting to a sibling of the pack folder, for example `<pack>-data`. The pack MAY declare a preferred name in the manifest `data_dir` field (Section 4.2). A pack whose `data/` is intended as a seed may have `install.sh` copy or link it into `PACK_DATA_DIR`, providing the mutable mechanism itself. Consumers of an installed external pack treat the pack as immutable/read-only, and the pack owner updates data by pushing new versions. Because runtime data lives outside the pack root, update-by-replace never destroys runtime data, and checksums cover the whole pack root meaningfully.

**Example layout.** A complete install looks like this: the pack root, a sibling runtime data directory, and the harness-written `.opf-lock` (Section 9.1) inside the pack root:

```
weekly-report/                  # pack root (installed)
  manifest.json
  .opf-lock                     # its data_dir field is the ABSOLUTE path below
  skills/report-format/
  routines/weekly-report/

weekly-report-data/              # PACK_DATA_DIR: sibling of the pack root
  report.db
```

See Section 9.1 for the full `.opf-lock` contents, including the `data_dir` field recorded as this absolute sibling path.

### 5.3 `README.md`

The human-readable overview and entry point, analogous to `SKILL.md` or a standard `README.md`. It explains what the pack does, what it contains, how to use it, and any caveats. It is not parsed by the harness except as documentation. A pack without `README.md` is valid but discouraged (the validator flags a missing `README.md` as a warning, not an error).

### 5.4 Per-type descriptor conventions (standalone recognition)

Every descriptor-bearing item kind needs a minimal, standalone, self-describing descriptor that identifies it without a pack manifest: a folder or file that says "I am a Tool" (or Routine, Agent) the way `SKILL.md` does for Skill. These descriptors are what make an unpackaged repo importable (Section 6) and what let a pack's `contents` be verified against its folders. Artifact and data items need no descriptor; they are recognized by folder presence or user mapping. Per the descriptor = subfolder rule (Section 5), each descriptor-bearing item is a subfolder containing its descriptor file.

| Item kind | Descriptor | Location |
|---|---|---|
| Skill | `SKILL.md` (open Agent Skills format) | `skills/<skill-id>/SKILL.md` |
| Tool | manifest-style descriptor, `tool.json` | `tools/<tool-id>/tool.json` |
| Routine | manifest-style descriptor, `routine.json` | `routines/<routine-id>/routine.json` |
| Agent | `AGENT.md` (or harness-defined agent format) | `agents/<agent-id>/AGENT.md` |
| Artifact / Data | no descriptor required; opaque files | `artifacts/`, `data/` |

Tool and routine descriptors are manifest-style JSON files that declare the item's name, description, and any entry point or schedule. They are deliberately minimal so a repo can be recognized without a pack manifest. An agent item is a subfolder `agents/<agent-id>/` containing `AGENT.md` (or a harness-defined agent format), per the descriptor = subfolder rule; `AGENT.md` itself is an optional convention (Section 10) with no required structure, and the internal structure of an agent folder remains loose.

**Routine descriptor (`routine.json`):** a routine is a subfolder `routines/<name>/` containing `routine.json` (the descriptor), plus an optional `README.md` and optional script file(s) kept self-contained in the same subfolder. Four fields are defined now: `schedule` (a 5-field cron expression), `command` (the command to run), `enabled` (bool), and the optional `script` (a path to a script file relative to the routine folder, for routines that run a script kept self-contained in their subfolder). Everything else about routines is left loose.

**Tool descriptor (`tool.json`) and MCP:** a tool item is a subfolder `tools/<name>/` containing `tool.json`, with optional scripts and MCP configuration alongside. A tool item MAY embed a standard MCP server configuration block (for example an `mcpServers`-style JSON object) inside `tool.json`, so standard MCP clients can consume it directly. `tool.json` adds harness-specific fields around that block. This is one short paragraph of guidance; the exact shape of harness-specific fields is the harness's choice.

**Descriptor fields are executable content, not metadata.** A descriptor (`tool.json`, `routine.json`) is JSON, but its fields can name or contain content the harness will eventually execute; the descriptor is not exempt from either of Section 7's checks just because it is a manifest-style file rather than a script:

- **Containment.** A descriptor field whose value is a path into the item's own files (for example `routine.json`'s `script`) MUST resolve inside that item's own subfolder after normalization — no `../` escape, no absolute path. Validators MUST enforce this the same way path-safety is enforced elsewhere (Section 7).
- **Scan coverage.** A descriptor field whose value is a command or expression to be executed (for example `routine.json`'s `command`, or a harness-defined `tool.json` entry-point field) is in scope for the Section 7.2 dangerous-pattern scan the same as any other file's content. Descriptor JSON files are not a blind spot: a scanner limited to specific script languages or extensions MUST NOT skip `tool.json`/`routine.json` on the theory that "JSON isn't code" — the dangerous content lives in a string value, not in JSON structure, so a scanner that reads file content as text (rather than only parsing known script languages) already covers it.

**Name grammar cross-reference.** The manifest `name`/`vendor` grammar (Section 4.1) and the skill-id grammar (Section 3) are intentionally different, and a validator MUST NOT apply one where the other is called for:

| Identifier | Grammar | Where enforced |
|---|---|---|
| Manifest `name` / `vendor` | `^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$`, 1-64 chars | `manifest.schema.json`, `scripts/pack-name-pattern.sh` |
| Skill-id (`skills/<skill-id>/`) | `^[a-z0-9]+(-[a-z0-9]+)*$`, must equal SKILL.md `name` | `manifest.schema.json` (`contents.skills` items), `scripts/validate-pack.sh` |
| Tool-id / routine-id / agent-id | folder existence only; no character-set grammar defined | `scripts/validate-pack.sh` (contents-vs-folder check) |

A pack `name` legally containing `.` or `_` (for example `pack_core.core`) cannot be mirrored as a skill-id: the two grammars are not interchangeable.

---

## 6. Importing an unpackaged ("agnostic") repo

Not every repo a user pulls from carries a pack manifest: someone's GitHub collection of skills and scripts with no pack awareness must be covered, for all descriptor-bearing kinds from the start.

- Each descriptor-bearing item kind has a minimal, standalone, self-describing descriptor identifying it without a pack manifest (Section 5.4): a folder or file that says "I am a Tool" (or Routine, Agent) the way `SKILL.md` does for Skill. Skill, Tool, Routine, and Agent have these descriptors defined in Section 5.4. Artifact and data items are recognized by folder presence or user mapping.
- Import walks the cloned repo, recognizes whichever descriptors it finds (a repo can mix kinds), and synthesizes a `manifest.json` from what it found rather than requiring the source to author one.
- Because it arrived from outside, the result lands as an External pack, locked by default, through the same security scan: an absent manifest is a reason for MORE caution, not less.
- Manifest-present and agnostic import are the same mechanism: a manifest is authored up front by the source, or inferred at import time from recognized descriptors.
- An agnostic import gets a vendor: the importer infers the vendor from the source repo owner or org when known, otherwise it prompts the user. The inferred value is written INTO the synthesized manifest as its declared vendor. It is declared, not derived thereafter.

The External tier and its location are described in the host layout companion doc.

---

## 7. Security scanning on import and install

Every import or install passes a deterministic scan by default: static analysis, not an LLM, so results are reproducible and cannot be talked out of a decision by adversarial content in the pack. The pack-install skill runs the scan before install. The scan runs on the staged/incoming copy in a temporary location before it replaces the installed pack. Findings carry one of three severities: **error** blocks install, **warning** flags the finding for user acknowledgment, and **info** is recorded and shown but never blocks. The manifest-schema and path-safety checks run even with zero tools installed; they are the floor. Recommended tooling lives in the companion doc (`opf-host-layout.md`, "opf-core scan profile"); no specific tool is required to be installed.

- **Manifest schema validation** (Section 4): required fields present, types correct, `version` valid semver, `name` in the allowed charset, `dependencies` well-formed. A manifest that fails is rejected outright. This is the floor; every other check is additive.
- **Zip-slip path validation**: any embedded file path (from a manifest, an index, or an archive) MUST resolve inside the intended install directory. The harness MUST reject any path that escapes the pack root after normalization. This obligation falls primarily on whatever unpacks an archive (zip/tar) into the pack root: the extractor MUST refuse or normalize any entry path that would resolve outside the destination directory before writing it to disk. A reference implementation's post-extraction directory walk (checking that no file or symlink already inside the extracted pack root resolves outside it) is a secondary sweep for symlinks planted inside a legitimately extracted pack; it cannot detect an entry that already escaped the pack root during a naive extraction, because such a file is no longer inside the tree being walked.
- **Static analysis of script content** for dangerous patterns (credential/secret file access, known-malicious signatures). See Section 7.2 for the contract and the companion doc for the recommended tooling. Static analysis fully gates skills, tools, routines, and data content. It does NOT gate `install.sh` (Section 8).
- **Dependency checks**: dependencies are other packs, declared by `vendor/name`, a version range, and a source `url`. The scanner validates that the dependency declarations are well-formed; resolution and install order follow Section 4.5. Advisory scanning of third-party packages is out of scope.
- **Vendor/pack-name collision check**: if `<vendor>/<pack-name>` already exists, surface it to the user rather than silently overwriting; offer an editable alternative (for example `<pack-name>-2`). Renaming on collision changes the pack's declared identity and breaks dependency references keyed to the original name, so the installer MUST warn about this specifically and let the user choose: install under the new name or abort. Vendor identity is not verified, so the same strings likely means unrelated publishers.
- **Secrets**: packs must not contain secrets. Secrets are flagged by the scan. The validator checks that an `.opf-env` file, if present, is listed in `.gitignore`. The create-pack skill checks for secrets before creating a pack.

### 7.1 Severity classes

Findings are classified into three severity classes:

| Severity | Meaning | Action |
|---|---|---|
| **error** | Blocks install. A confirmed dangerous pattern (secret access, arbitrary exec, path escape). | Install is refused. |
| **warning** | Flagged for the user. A suspicious pattern that does not meet the error bar. | Install proceeds only with explicit user acknowledgment; the finding is recorded. |
| **info** | Informational. Style issues, unused variables, non-blocking notes, network usage. | Recorded and shown in a report; never blocks. |

The mapping of a specific finding to a severity is the harness's policy, but the three classes exist and `error` findings block by default. Severity decisions (what blocks versus what flags) belong to the harness's install-time policy; the scan itself is purely behavior-based, flagging what scripts DO (credential access found by static analysis), not what a manifest declares. A manifest declaration grants nothing and is not part of OPF. The validator exit-code contract (a machine-readable 0/1/2 mapping onto pass/error/warning) is non-normative and lives in the companion doc (`opf-host-layout.md`, Section 2.4).

**No silent clean bill of health, for any conformance tool.** This applies beyond the install-time scan: any validator, doctor, or diagnostic tool that reports pack conformance MUST treat a required field that is missing, empty, or unparseable as a finding, never as an implicit pass. Exit status alone MUST NOT be relied on to distinguish "checked and clean" from "not checked" — a tool that cannot evaluate a check MUST say so, not stay silent.

### 7.2 Cross-language dangerous patterns

Independent of language, the scan SHOULD look for these dangerous patterns using `semgrep` (or an equivalent cross-language engine) where available:

- Credential/secret file access (reading `~/.ssh`, keychains, cloud credential files). Reading `.opf-env` is expected behavior and is not flagged.
- Subprocess/exec/spawn of arbitrary commands.
- Path traversal and zip-slip.
- Obfuscation (base64-heavy payloads, eval of constructed strings, dynamic import of remote content).

Network usage is NOT a gate. Permissions and capabilities are entirely the harness's business; packs do not declare them. Static analysis may NOTE network usage as an informational finding (for example a tool or routine that calls `curl`), but network usage never blocks install.

### 7.3 Scan coverage and practical limits

The scan covers ALL files, including `data/`, with practical limits:

- Files above a size threshold (harness-configurable, default 10 MB) are checksummed but not content-scanned.
- Known non-executable binary/static types (for example jpg, png, gif, mov, mp4, mp3, pdf, sqlite, woff, woff2, zip, tar, gz) are checksummed but not content-scanned.
- Everything else is content-scanned.

An optional manifest field `scan.exclude` is an array of path patterns excluded from content scanning. Patterns support both glob-style matches (for example `data/wiki/articles/*`) and exact paths. Rules: (a) exclusions never apply to executable file types, so an executable file is always scanned regardless of exclusion; (b) excluded files are still checksummed; (c) the validator warns if an exclusion pattern matches nothing in the pack.

**Which layers honor `scan.exclude`.** It applies to content scanning (the Section 7.2 dangerous-pattern scan) ONLY. Secrets scanning and structural/manifest validation (Section 7's other checks: schema validation, path safety, `contents`-vs-folder checks, and everything in Section 7 outside 7.2) NEVER honor `scan.exclude` and MUST run against every file regardless of any exclusion pattern. A pack cannot use `scan.exclude` to hide a secret or to bypass structural validation; the field's effect is confined to the one scan layer it names.

**Executable file type**, for rule (a): a file is executable if it has a shebang line (first bytes `#!`), OR its extension is in a normative executable-extensions list (`.sh`, `.py`), OR'd together. This closes a specific evasion: a shebang'd script with no extension, or a misleading one, placed under an excluded path would otherwise skip content scanning entirely. A compiled binary is unaffected by this rule: it is already checksummed-but-not-content-scanned under the known-binary-type exclusion above, and pattern-based content scanning of a binary blob is not meaningful regardless of how it is invoked (directly, or via a wrapper shell script, which is itself scanned as usual).

This addresses the common cases, not all. An obviously-executable file type is always scanned regardless of extension. Scan time scales with pack size; these exclusions keep it bounded. The content-scan size/type thresholds above are a scanning concern only, distinct from any VCS/LFS size policy an org applies to its own repositories; the two are unrelated knobs that happen to operate on similar file-size boundaries.

---

## 8. Lifecycle scripts

Lifecycle scripts are the only executable content the spec defines. They are optional: a pack with no scripts is fully valid and is the safest kind of pack. The harness runs them through a canonical operator skill rather than raw harness behavior.

### 8.1 The pack-install skill

OPF defines one canonical operator skill, shipped in opf-core: `pack-install`. It is an ordinary skill (`SKILL.md` format), so any harness that can run skills and shell commands can use it. OPF requires zero harness-native pack features: validation, scanning, install, and state tracking are all performed by scripts and skills that any harness able to run shell commands and skills can execute.

**pack-install procedure** (deterministic, in order):

1. Validate the manifest against `manifest.schema.json`; reject on failure.
2. Stage the incoming pack into a temporary staging directory, for example `<pack>.new`.
3. Run the scan on the staging copy. Error-class findings stop the install here; warnings are surfaced for user acknowledgment.
4. Obtain explicit user approval for `install.sh` (full text shown on first install; a diff against the previously installed version on update).
5. Resolve configuration: prompt the user for any required config entries (per the `config` block, Section 4.4); resolved values are stored outside the pack root.
6. Write `.opf-env` into the staging directory (`PACK_ROOT`, `PACK_NAME`, `PACK_DATA_DIR`, `PACK_VERSION`, `PACK_INSTALL_DIR`, plus resolved config values as env vars).
7. Run `install.sh` with cwd = the staging directory, `PACK_ROOT` = staging directory, and `PACK_INSTALL_DIR` = the FINAL installed path (see Section 8.4).
8. On success (exit 0): write `.opf-lock` into the staging directory (version, date, source incl. commit SHA, checksums, dependency closure, `data_dir`).
9. Swap: replace the installed pack with the staged directory (see Section 8.1.1). On any failure before the swap, remove the staging directory; the previously installed pack is untouched.

`.opf-env` and `.opf-lock` are excluded from the scan, the same exclusion that applies to checksums in Section 9.1. The installer never scans its own state files.

**Scan vs lifecycle scripts.** Static analysis does NOT gate `install.sh`. The policy: a pack with NO lifecycle script installs on a clean scan; a pack WITH `install.sh` requires explicit user approval before the skill runs it. The skill shows the script's full text before first install, and on update shows the DIFF against the previously installed (and thus previously approved) version. The reason: a bash install script is arbitrary exec by definition, so static analysis of it is not a meaningful gate; approval-plus-diff is. Static analysis still fully gates skills, tools, routines, and data content. This diff-on-update is the primary defense against the benign-v1/malicious-v1.1 attack.

**Failure semantics (atomicity).** Install is atomic. The incoming pack is staged into a temporary sibling directory (for example `<pack>.new`), `install.sh` runs there with `PACK_ROOT` pointing at the staging dir, and only on success (install.sh exit 0, lock written) is the installed pack swapped in. On any failure the old pack remains intact and the staging directory is removed. Combined with the mutable-state split (Section 5.2), "nothing partial is committed" is true: no partial state is ever visible.

### 8.1.1 The swap

The swap is two renames: rename the installed pack to `<pack>.old`, rename the staging directory to the installed path, then delete `<pack>.old`. There is a brief window between the two renames during which the installed path does not exist. This is the honest cost of directory replacement on POSIX filesystems: a single `rename()` cannot replace a non-empty directory.

### 8.2 `install.sh`

- Optional. Runs once at install time, from the staging directory, after the static scan has passed and after explicit user approval (Section 8.1).
- Must be idempotent: running it twice must be safe and must not corrupt state. This is what makes update work: updating a pack means replacing the pack files with the new version and re-running `install.sh`.
- Fail-safe: a non-zero exit code means the install failed. The harness MUST treat a non-zero exit as a failed install and report it to the user; it MUST NOT silently continue.
- Runs as an unprivileged user. It MUST NOT assume root, a specific working directory, or a specific shell beyond POSIX-ish bash.
- Working directory: the staging directory during install, with `PACK_ROOT` pointing at the staging directory. The script receives inputs via environment variables (Section 8.4) and via the staging directory as its working directory. It MUST NOT read arbitrary host paths. The final installed directory is known only via `PACK_INSTALL_DIR` (Section 8.4).
- May copy seed data from `data/` into `PACK_DATA_DIR` on first install. It must be idempotent: it must never overwrite existing data in `PACK_DATA_DIR`.

### 8.3 Script contract

Every lifecycle script (`install.sh`, `uninstall.sh`) MUST:

- Be executable (mode `+x`) and use a shebang, conventionally `#!/usr/bin/env bash`.
- Be POSIX-ish bash. It may use bashisms, but must not depend on non-POSIX tools beyond what the harness declares available. OPF v1 lifecycle scripts are POSIX bash; a Windows-native or browser-based harness must either provide a POSIX layer or treat lifecycle scripts as unsupported (the rest of OPF still applies).
- Exit `0` on success and non-zero on failure. The harness MUST treat any non-zero exit as failure.
- Avoid surprising network use; any network use is reported to the user as an informational finding. There is no normative "no network" rule.
- During install, write only inside the staging directory (`PACK_ROOT`). After install, scripts and routines treat the installed pack root as read-only and write only to `PACK_DATA_DIR`. Writes anywhere else are a violation and SHOULD be blocked or flagged by the harness.
- Not assume it runs as root, not assume a TTY, and not read from stdin (the harness may run it with stdin closed).

### 8.4 Environment variables provided to scripts

The harness MUST provide these environment variables to `install.sh` when it runs it:

| Variable | Meaning |
|---|---|
| `PACK_ROOT` | Absolute path to the staging directory during install. |
| `PACK_NAME` | The pack's `name` from the manifest. |
| `PACK_DATA_DIR` | Absolute path to the runtime data directory, OUTSIDE the pack root. |
| `PACK_VERSION` | The version being installed. |
| `PACK_INSTALL_DIR` | Absolute path to the FINAL installed location of the pack (the path after the swap). |

In addition, the pack-install skill MUST write an `.opf-env` file in the staging directory (gitignored) containing these `PACK_*` values (`PACK_ROOT`, `PACK_NAME`, `PACK_DATA_DIR`, `PACK_VERSION`, `PACK_INSTALL_DIR`) BEFORE running `install.sh`. Scripts or agents that run outside the harness-native flow read this file. Configuration values declared in the manifest `config` block (Section 4.4) are also exposed as environment variables at run time.

`install.sh` MUST use `PACK_INSTALL_DIR` (not `PACK_ROOT`) when registering absolute paths (cron entries, MCP server registrations, symlinks), because `PACK_ROOT` points at the staging directory, which ceases to exist after the swap. This is the fix for silent registration breakage: paths registered against `PACK_ROOT` would dangle once the staging directory is removed.

Precedence is explicit: harness-provided environment overrides the `.opf-env` file. The `.opf-env` file is written before `install.sh` from values the skill computed (the incoming manifest version and resolved paths); it is NOT derived from `.opf-lock`, which is written only after `install.sh` succeeds.

---

## 9. Versioning and installed state

- The manifest `version` field MUST be valid semantic versioning (semver): `MAJOR.MINOR.PATCH`, optionally with pre-release/build suffixes. Pre-release versions sort per semver in version comparisons. Versions never carry a leading `v` (`1.0.0`, not `v1.0.0`); this matches both the manifest schema's `version` pattern and node-semver's canonical (non-loose) form used for dependency ranges (Section 4.5).
- The version is the single source of truth for install/update decisions. The comparison of the incoming manifest version against the installed `.opf-lock` version tells pack-install whether this is an update or a fresh install. No other mechanism (file mtimes, hashes) triggers anything.
- Update = replace the pack files with the new version, re-run `install.sh` (which MUST be idempotent), and rewrite `.opf-lock`. There is no separate update script and no per-version migration. Update does NOT run the previous version's `uninstall.sh`; `install.sh` is responsible for reconciling registrations left by prior versions.
- If the incoming version equals the installed version, a reinstall is allowed and simply re-runs `install.sh`. A pack whose manifest version does not change between updates is treated as a same-version reinstall (replace files, re-run `install.sh`, rewrite the lock), which supports a rolling-release workflow with git main as the distribution channel. Adopters who want tagged releases can simply version their manifests.
- `.opf-lock` is the only version-of-record. The `.opf-env` file (Section 8.4) is a delivery mechanism, not a second tracking system.
- Harnesses SHOULD compare versions with a semver-aware comparator, not string comparison.
- A downgrade (incoming version lower than installed) is a distinct operation. The harness SHOULD refuse a downgrade by default unless the user explicitly requests it.

**Spec versioning.** This is OPF v1. The `pack_format` field in the manifest is the spec-compatibility version. The spec's own version equals `pack_format`: both are `1`.

### 9.1 Installed-state file (`.opf-lock`)

The harness SHOULD record installed state in a file at the pack root named `.opf-lock` (JSON). It records the installed version, install date, resolved source, the runtime data directory location, checksums, and the resolved dependency closure (the `vendor/name` and resolved version of each dependency, per Section 4.5) so that version tracking and audits have a reliable baseline. It is written by the harness, not shipped with the pack, and is not part of the distributable content. It is written only after `install.sh` succeeds.

```json
{
  "name": "weekly-report",
  "version": "1.1.0",
  "installed_at": "2026-09-09T23:19:00Z",
  "source": {
    "type": "git",
    "url": "https://github.com/acme/weekly-report",
    "commit": "abc123def456"
  },
  "dependencies": [
    { "vendor": "myorg", "name": "pack-common", "version": "1.2.0" }
  ],
  "data_dir": "/home/user/packs/weekly-report-data",
  "checksums": {
    "manifest.json": "sha256:...",
    "data/report.db": "sha256:...",
    "tools/report.sh": "sha256:..."
  }
}
```

**Provenance.** Provenance is OBSERVED, not declared. `.opf-lock` records the resolved source at install time, via a `source.type` of `git`, `archive`, or `local`:

- `git`: `{"type": "git", "url": ..., "commit": ...}` — the repository URL and commit SHA.
- `archive`: `{"type": "archive", "path": ..., "digest": "sha256:..."}` — the archive's filename/path and a content digest, since a digest is the only integrity handle available when there is no commit to record.
- `local`: `{"type": "local", "path": ...}` — a path on the installing machine, no VCS or archive origin.

Vendor identity is declared in the manifest (Section 4.2) and is not verified; provenance is what the lock records.

**Delivery mechanism does not affect trust tier.** A pack installed from a zip archive is External exactly as a pack installed from git is: Section 1.3 of the host-layout doc already establishes that tier follows the action (installed vs. created/claimed), not the source, and that holds regardless of what kind of source it was. An archive with no git remote also has no update path (no sync, no drift-refusal-on-pull): the locked-by-default guarantee is enforced only by the documented convention that the consumer doesn't edit it, not by any live channel back to a publisher. Treat archive delivery as a degraded channel: installable, but without git's ongoing integrity story.

The checksums cover pack content. Installer-written state files (`.opf-lock`, `.opf-env`) are EXCLUDED from checksums: they are written after the scan and change post-install. The lock file stays inside the pack root and is gitignored. Because runtime data lives outside the pack root (Section 5.2), the pack root should not change after install, so the checksums cover the whole pack root meaningfully. The size and type exclusions in Section 7.3 apply to content scanning only, not to checksums. Checksums detect modification of the INSTALLED copy between install and a later update (tampering or drift); they are NOT compared against the source repo on update, because content changing at a fixed version is normal under a rolling-release workflow. The harness MAY verify checksums on update to detect tampering between install and update.

**Recording the scan outcome.** `.opf-lock` SHOULD also record what the Section 7 scan actually did — which tools ran, their versions, the ruleset reference, and a per-tool outcome (or an explicit `"skipped"` when a tool was unavailable, per the graceful-degradation contract in the host-layout companion doc, Section 2.6):

```json
"scan": {
  "semgrep": { "version": "1.78.0", "ruleset": "opf-core-v1", "result": "clean" },
  "semgrep_registry": { "version": "1.78.0", "ruleset": "auto", "result": "clean" },
  "gitleaks": { "result": "skipped", "reason": "not installed" }
}
```

The two `semgrep` entries are distinct because Section 7's scan runs semgrep twice against two different configs with two different consequences: `semgrep` is the curated, offline, CI-blocking ruleset (Section 7.2); `semgrep_registry` is the supplementary registry `auto` config, which only ever warns (Section 7.3's "Network usage is NOT a gate" sibling rule - a runner unable to reach the registry must not fail the pipeline on that). A `result` of `"error"` is not actually reachable in a written `.opf-lock`: an error-class finding aborts the install before the lock is written at all, so only `"clean"`, `"warning"`, and `"skipped"` appear in practice.

Without this, graceful degradation to the structural floor (manifest schema and path-safety checks, which always run) is silent: nothing in the installed pack or the install output reveals that the scanning layer never ran. A consumer should be able to tell from `.opf-lock` alone whether the full scan ran, not have to infer it from absence.

### 9.2 Rolling release profile

Some organizations distribute packs by tracking a git ref (typically `main`) rather than tagging releases: `version` becomes informational, and git itself is the distribution channel. The same-version-reinstall behavior above already permits this; this subsection consolidates what that implies rather than introducing anything new:

- **`version` is informational.** The manifest still MUST carry a valid semver `version` (Section 4.1), but under this profile it commonly does not change between updates; git main (or a declared `ref`) is the actual distribution channel.
- **`.opf-lock` and checksum verification are OPTIONAL under this profile.** Both are already phrased as SHOULD/MAY above; a rolling adopter MAY treat git history itself as the integrity mechanism instead of maintaining `.opf-lock` or verifying checksums on update.
- **Downgrade and same-version-reinstall collapse into one operation: "sync to ref."** There is no meaningful "downgrade" when the version doesn't change; refusing or allowing a sync is a git operation (checking out an older commit), not a version comparison.
- **Dependency ranges remain structurally required and validated** (Section 4.5); resolution is still range-based. A dependency MAY additionally declare an optional `ref` field recording what a rolling consumer actually tracks, for example:

  ```json
  { "vendor": "myorg", "name": "pack-common", "version": "*", "url": "https://github.com/myorg/pack-common", "ref": "main" }
  ```

  `ref` is informational and MUST NOT override range-based resolution: it does not change how a version is chosen, only what a rolling consumer's `.opf-lock` records (the resolved commit) once resolution completes. A harness operating in this profile MAY resolve `ref` to a commit and record it in the lock's dependency entry, alongside or instead of `version`.

---

## 10. Agent items and the `AGENT.md` convention

OPF defines one thing about agent items: a folder location, `agents/`, where agent items live. That is all that is normative. How a harness represents an agent inside that folder is the harness's choice.

### 10.1 `AGENT.md` is optional

`AGENT.md` is an OPTIONAL convention: a plain markdown file that names and describes the agent. It has no required frontmatter, no defined fields, and no schema. A harness may write whatever format it wants in its agent folders (its own JSON, YAML, markdown, frontmatter, or none). OPF neither requires nor suggests frontmatter.

A short example of a plain `AGENT.md` with no frontmatter:

```markdown
# Weekly Editor

You are the weekly report editor. You receive a draft report and you:

1. Check it against the report template in `artifacts/report-template.md`.
2. Fix formatting and tone.
3. Summarize changes for the author.
```

### 10.2 Location

Agent items live under `agents/`. A pack MAY contain zero or more agent items. A common layout is one folder per agent, for example `agents/<name>/`, but OPF does not mandate the internal structure.

### 10.3 Import and interpretation

For agnostic-repo import (Section 6), an agent item is recognized by the presence of `agents/<agent-id>/AGENT.md` (or a harness-defined agent format). How the harness interprets the content is the harness's job. If a harness cannot interpret the content, it imports the files as opaque and lets the user map them.

---

## 11. Uninstall

Uninstall is harness-dependent. The minimum model: removing the pack folder removes the pack; `.opf-lock` and `.opf-env` live inside the folder and go with it. Removing the pack folder does NOT remove `PACK_DATA_DIR`; the harness or user decides whether to preserve or delete the data directory. `uninstall.sh` may not delete `PACK_DATA_DIR` silently: if it removes data, it must surface that to the user. The user (or harness) may need to unregister things the pack registered (routines, tools).

`uninstall.sh` is OPTIONAL, with the same contract as `install.sh` (Section 8.3): it runs from the pack root, must be idempotent, and a non-zero exit means a reported failure. It exists to unregister routines and tools the pack registered. The minimum uninstall remains "remove the folder"; `uninstall.sh` is an additional cleanup step, not a requirement. `uninstall.sh` receives the same environment variable set as `install.sh` (Section 8.4), with `PACK_ROOT` equal to the installed pack path (there is no staging during uninstall).

---

## 12. Reference implementation

Omnideck is the reference implementation and ships OPF. This statement is non-normative.

---

## 13. Host layout

The recommended host layout profile (the `~/packs/` and `~/.packs-external/` roots, provenance tiers, symlink materialization and its lifecycle, and the native-tree collision rule) is non-normative and lives in the host layout companion doc.

---

## 14. Distribution topology

The recommended three-repo distribution topology (opf-core, pack-common, pack-z-template), including the CI include mechanism, the validator, create-pack, and new-pack.sh, is non-normative and lives in the host layout companion doc.

---

## Appendix A: Per-language static analysis tools

The per-language tool table and the graceful-degradation contract for the scan have moved to the companion doc (`opf-host-layout.md`, "opf-core scan profile"). The normative guarantee is in Section 7.

Container images referenced by a pack SHOULD be pinned by digest, not tag: registries deny unauthenticated tag pulls, and tags are mutable.