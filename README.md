# opf-core

[![opf-core self-test](https://github.com/omnideck-dev/opf/actions/workflows/self-test.yml/badge.svg)](https://github.com/omnideck-dev/opf/actions/workflows/self-test.yml)
[![OPF spec](https://img.shields.io/badge/OPF--spec-v1-blueviolet.svg)](spec/opf-spec-v1.md)
[![License: Apache 2.0](https://img.shields.io/github/license/omnideck-dev/opf)](LICENSE)

**A harness-agnostic package format for AI agent skills, tools, data, and routines** - bundled into one portable, versioned unit that installs the same way everywhere, with security scanning built in rather than bolted on.

## What is OPF, and why does it matter

### The problem

Every agent harness invents its own way to package and move skills, tools, and data around. The open [Agent Skills format](https://agentskills.io) standardizes a single skill *file* - frontmatter plus markdown - but says nothing about bundling several items together, versioning them, installing or updating them, resolving dependencies between packs, or scanning them for anything dangerous before they run. MCP (Model Context Protocol) standardizes how a client calls a tool at *runtime* - it says nothing about how the tool's own source gets packaged, distributed, or trusted at rest.

Between "one skill file" and "a running tool call" there's a real gap, and there's no standard answer to it yet. Most teams fill it with copy-pasted folders and ad hoc git-clone conventions: no update path, no dependency model, no version tracking, and - the part that actually matters - no security gate before someone else's code runs on your machine.

### Why OPF

- **Harness-agnostic.** Zero native pack code. A pack installs, updates, and removes via plain shell scripts and skills - any harness that can run shell commands and skills can use it.
- **Builds on open standards instead of competing with them.** Skills use the Agent Skills format as-is; tools can embed a standard MCP server config block; dependency ranges use node-semver syntax. OPF is the packaging layer *above* these, not a replacement for any of them.
- **Security-scanned by default, not by convention.** Every install runs a deterministic, non-LLM static scan before anything executes. See [Security](#security).
- **Git-native.** A pack is a directory with a manifest; distribution is git. No registry to stand up before you can start.
- **Locked by default.** An installed pack can't be silently edited by the agent that's using it - only its owner changes it, by publishing a new version.

## What's in this repo

opf-core ships the spec, the reference tooling, and four operator skills.

### Skills

| Skill | What it does |
|---|---|
| [`create-pack`](skills/create-pack/) | Scaffold a new pack from the template: subfolders for the item kinds you pick, CI already wired, secrets gate enforced before it lets you finish. |
| [`pack-install`](skills/pack-install/) | Install or update a pack: resolve dependencies, validate, scan, get your approval on anything it wants to run, then swap it in atomically. |
| [`pack-release`](skills/pack-release/) | Ship a new version of a pack you own: decides the version bump from a plain-language description of what changed, writes the changelog, commits with your confirmation. Built for pack owners who don't know semver or git. |
| [`pack-doctor`](skills/pack-doctor/) | Diagnose packs already installed: a stale install lock, unregistered items, checksum drift, missing dependencies. Reports in plain language, fixes only what's safe to fix automatically. |

### Docs

| Doc | What it's for |
|---|---|
| [`spec/opf-spec-v1.md`](spec/opf-spec-v1.md) | The normative spec: manifest schema, pack layout, lifecycle scripts, the security-scanning contract. |
| [`spec/opf-host-layout.md`](spec/opf-host-layout.md) | Non-normative: recommended on-disk layout, the Owned/External trust tier, distribution topology for an adopting org. |
| [`spec/opf-pack-authoring.md`](spec/opf-pack-authoring.md) | Non-normative: whether something should be a pack at all, structural vs. editorial data, the locked-pack/user-workspace boundary, naming. |
| [`spec/opf-pack-boundaries.md`](spec/opf-pack-boundaries.md) | Non-normative: how to decide what goes in one pack vs. several, ownership, the bundle-pack pattern. |
| [`schema/v1/manifest.schema.json`](schema/v1/manifest.schema.json) | The JSON Schema every `manifest.json` validates against. |
| [`TODO.md`](TODO.md) | Open implementation and ecosystem work. |

## Security

Every install, and every CI run, passes a deterministic scan first - static analysis, not an LLM, so results are reproducible and can't be talked out of by adversarial content in the pack itself.

- **Structural floor, always on.** Manifest-schema validation and path-safety (zip-slip) checks run even with zero scanning tools installed.
- **Curated ruleset - the real gate.** [`ci/semgrep-opf-rules.yml`](ci/semgrep-opf-rules.yml) maps directly to the spec's dangerous-pattern categories - credential access, pipe-to-shell, obfuscated exec, and more - works fully offline, and is what actually blocks a bad pack.
- **Registry ruleset - best-effort.** `semgrep --config auto` also runs, as a supplementary, non-blocking pass (it needs network access to semgrep's registry, which not every environment has).
- **Secrets scanning.** `gitleaks` where it's installed, a regex fallback where it isn't - either way, a pack containing a likely secret is refused.
- **Three severities, one contract.** `error` blocks install. `warning` requires explicit acknowledgment. `info` is recorded and shown, never blocking. The same validator and the same rules run on your machine and in CI, so what passes locally passes the pipeline.
- **Optional pre-commit hook, for fast local feedback.** The template ships `hooks/pre-commit` (enable once per clone with `git config core.hooksPath hooks`) running the same validator, gitleaks, and curated ruleset before a commit lands. It's convenience, not a security boundary - bypassed by `--no-verify`, and not re-enabled automatically on a fresh clone (`pack-doctor` checks for that and can fix it). CI is still the enforced gate.

See spec Section 7 and [`spec/opf-host-layout.md`](spec/opf-host-layout.md) Section 2.6 for the full contract.

## Using this repo

Two ways to adopt opf-core, and they compose - most orgs start with the first and add the second once they outgrow the defaults.

**1. Install it into your harness, then make and share packs.** Point your harness at this repo (a git-native harness with skill auto-discovery needs nothing more than the clone; otherwise set the `OPF_CORE` environment variable to the checkout path). No fork needed. Skim [`spec/opf-pack-authoring.md`](spec/opf-pack-authoring.md) and [`spec/opf-pack-boundaries.md`](spec/opf-pack-boundaries.md) before scaffolding your first few packs - deciding what should be a pack at all, and what goes in one pack versus several, is cheaper to get right up front than to split apart later.

**2. Fork and adapt it for your team or org.** opf-core is public and harness-agnostic by design - forking is expected, not a workaround. Common adaptations (all documented in [`spec/opf-host-layout.md`](spec/opf-host-layout.md) Section 2):

- Merge `templates/pack-z-template/` into your fork if a separate template repo is more indirection than you need.
- Vendor `spec/` and `schema/` into a private repo if your infra can't reach GitHub at build/validate time.
- Point the CI templates' `OPF_CORE_REPO` / `opf-core-repo` inputs at your fork, so every pack's CI resolves scan rules from it instead of upstream.
- Extend `ci/semgrep-opf-rules.yml` with org-specific rules; start a `pack-common` repo for shared skills/tools once a second pack needs one.

Either way, [`spec/opf-spec-v1.md`](spec/opf-spec-v1.md) is the normative contract - adopt as much or as little of this repo's tooling as you want, as long as you honor the spec.

## Getting started

Each flow below is a skill - run it through whatever skill-invocation your harness uses. Every skill has a script fallback for a harness that can run shell commands but not skills.

| Task | Skill | Script fallback |
|---|---|---|
| Create a pack | `create-pack` | `scripts/new-pack.sh <name> [vendor] -d "<description>"` |
| Install or update a pack | `pack-install` | `scripts/install-pack.sh <source-dir> <install-dir>` |
| Ship a new version | `pack-release` | `scripts/bump-pack-version.sh <pack-dir> <bump-kind>` |
| Diagnose installed packs | `pack-doctor` | `scripts/pack-doctor.sh --owned-root <dir> --external-root <dir>` |

Validating a pack directly (used internally by every skill above): `scripts/validate-pack.sh <pack-dir>`.

## Testing

```
scripts/e2e-smoke-test.sh
```

Runs the create → validate → install → update → downgrade lifecycle end to end in a throwaway temp directory, plus the security/atomicity guarantees the spec claims and `pack-doctor`'s diagnose/fix behavior. Uninstall isn't covered yet (see `TODO.md`). Prints which of semgrep/gitleaks/shellcheck are installed, since their absence changes which code paths run; CI (`self-test.yml`) runs it both ways on every push/PR so the real scanner paths are exercised even when your local machine doesn't have those tools.

## Status

OPF v1 spec is frozen (`spec/`). Reference implementation: Omnideck. See [`TODO.md`](TODO.md) for open work.

## License

Apache 2.0.
