# Security

OPF's premise is that someone else's code is going to run on your machine -
a skill, a tool, an `install.sh`. This document describes what opf-core does
about that by default, what it deliberately does not do, and what an
adopting org can turn on to go further. The normative contract lives in
[`spec/opf-spec-v1.md`](spec/opf-spec-v1.md) Section 7-8 and
[`spec/opf-host-layout.md`](spec/opf-host-layout.md) Section 2.6; this is the
operator-facing summary and the reporting process.

## Reporting a vulnerability

Please report suspected vulnerabilities in opf-core's spec, schema, or
tooling privately rather than opening a public issue: open a
[GitHub Security Advisory](https://github.com/rlnorthcutt/opf-core/security/advisories/new)
on this repository. Include the affected file(s)/script(s), a minimal
reproducing pack if applicable, and the impact you'd expect (what a
malicious pack author or a compromised dependency could do). If you don't
have GitHub Advisory access, open a regular issue asking for a private
channel rather than posting exploit details.

This covers opf-core itself (the spec, schema, scripts, skills, CI
templates). It does not cover any specific pack you installed from a
third party - report that to the pack's own vendor/repository.

## Threat model, in one paragraph

A pack is adversarial input: the manifest, scripts, and descriptor files
inside it are written by someone you may not know, and the only thing OPF
verifies about a `vendor` string is that it's a string (spec Section 3 -
"a namespace, not a verified identity"). The jobs of everything below are:
(1) make a confirmed-dangerous pack fail loudly before anything in it runs,
(2) make the one kind of content that's allowed to run arbitrary code
(`install.sh`) something a human actually looks at first, and (3) make sure
a bad install can't corrupt or silently replace a good one.

## What's built in

### A deterministic scan runs before anything executes

Every install (`scripts/install-pack.sh`, or the `pack-install` skill) and
every pack's own CI run the same scan, in the same order, on the staged
copy - before it ever touches the final install location:

1. **Manifest schema validation** - required fields, semver, `pack_format`,
   charset. A manifest that fails this is rejected outright; it's the floor
   every other check sits on top of (spec Section 4, 7).
2. **Path safety (zip-slip)** - every file under the pack root, including
   resolved symlink targets, must resolve inside the pack root. Runs even
   with zero scanning tools installed.
3. **Static dangerous-pattern analysis** - [`ci/semgrep-opf-rules.yml`](ci/semgrep-opf-rules.yml),
   a curated, registry-independent ruleset mapped to spec Section 7.2's
   categories: credential/secret-file access, piping a download into a
   shell, base64-to-shell, `eval` of constructed strings, `subprocess`
   with `shell=True`, writes outside the pack root into system paths,
   crontab edits. It works fully offline and is the actual CI-blocking
   gate. `semgrep --config auto` (the public registry ruleset) also runs as
   a non-blocking, best-effort supplementary pass.
4. **Secrets scanning** - `gitleaks` where installed, a shared regex
   fallback (`scripts/secret-patterns.sh`) where it isn't. Either way, a
   pack containing a likely secret is refused, not just flagged.
5. **Scan coverage is content-based, not extension-based.** A descriptor
   file (`tool.json`, `routine.json`) is JSON, but a field inside it can be
   a command the harness will later execute - those fields are in scope for
   the same dangerous-pattern scan as any script. `scan.exclude` can skip
   content-scanning specific paths (e.g. a large wiki dataset), but it can
   never exempt a file that looks executable (shebang, or a `.sh`/`.py`
   extension) and it never applies to secrets scanning or structural
   validation.

This is static analysis, not an LLM: results are reproducible and can't be
argued out of a decision by adversarial content inside the pack itself
(spec Section 7, opening paragraph).

### Three severities, one contract

| Severity | Meaning | What happens |
|---|---|---|
| `error` | A confirmed dangerous pattern (secret access, path escape, a scan tool failure) | Install refused. No override short of removing the content. |
| `warning` | Suspicious but not confirmed-dangerous | Install proceeds only after explicit acknowledgment - a human (or a `--yes` caller asserting review already happened) has to say yes. No silent pass-through. |
| `info` | Style, network usage, non-blocking notes | Recorded and shown. Never blocks. |

The same validator and the same rules run locally (`scripts/validate-pack.sh`,
`scripts/install-pack.sh`) and in CI, so a pack that passes on your machine
passes the pipeline, and vice versa.

### `install.sh` is reviewed, not statically gated

A lifecycle script is arbitrary exec by definition - static analysis of it
isn't a meaningful gate, so OPF doesn't pretend it is. Instead:

- Full text is shown on first install; a **diff** against the previously
  approved version is shown on update (the primary defense against a
  benign v1 followed by a malicious v1.1).
- Nothing runs without explicit approval (`confirm()` in
  `scripts/install-pack.sh`). Run it non-interactively with no `--yes` and
  it refuses rather than silently proceeding - it fails closed, not open.
- `install.sh` runs from an **empty environment** plus exactly what spec
  Section 8.4 documents (the `PACK_*` variables and declared `config`
  values) - not whatever happens to be exported in the shell that invoked
  the installer. A CI job's deploy token or your own `SSH_AUTH_SOCK` isn't
  there for the script to find.
- It still runs as your user, with your filesystem permissions, and can do
  anything your user can do. Approval-plus-diff is the control here, not a
  sandbox. See "What this does not do" below.

### Nothing partial is ever visible

Install is atomic: the incoming pack is staged into a sibling `<pack>.new`
directory, scanned and approved there, and only swapped into the real
location after `install.sh` exits 0 and `.opf-lock` is written. Any failure
before the swap leaves the previously installed pack completely untouched
and removes the staging directory. Runtime/mutable state lives outside the
pack root (`PACK_DATA_DIR`), so an update-by-replace never destroys it and
a checksum over the pack root stays meaningful (spec Section 5.2, 8.1).

### Installed packs are locked by default

A pack you installed (as opposed to one you created or deliberately
claimed) is **External**: read-only for you by default, under
`~/.packs-external/<vendor>/<pack-name>/`. The only path back to editable is
a deliberate "clone to customize" act, never a passive file edit (spec
Section 3; `opf-host-layout.md` Section 1.3). A harness that enforces this
via filesystem permissions has a normative predicate for "locked" (mode
bits, not `access(2)`/writability checks, which a root-run job would pass
regardless of mode) so its own tools can't disagree about whether the same
pack is locked.

### Provenance is observed, not declared

`.opf-lock` records where a pack actually came from - a git commit SHA, an
archive digest, or a local path - at install time. A pack's declared
`vendor` string is never treated as identity; what matters for drift
detection is the recorded source and the per-file sha256 checksums taken
at install time (spec Section 9.1).

## What this does not do

Being direct about the edges matters more than a clean-looking list of
features:

- **No sandboxing or execution isolation.** Nothing here runs a pack's
  code in a container, VM, or restricted syscall environment. `install.sh`
  runs as your user. The control is "a human reviewed this text and its
  diff," not "this code can't do anything bad even if reviewed badly."
- **CI scanning protects the pack's repo, not your install.** A pack's own
  CI catches problems before a commit merges there - it does nothing for a
  fork, a zip someone handed you, or a contrib repo with no CI at all.
  Install-time scanning (on the machine doing the installing) is what
  actually protects *you*; relying on "their CI is green" is not a
  substitute (host-layout doc, Section 2.6).
- **Vendor strings are not verified identity.** The same vendor name on two
  packs from different sources is not an ownership or trust signal.
- **No rollback history.** A successful update removes the previous
  version's files; "rollback" today means reinstalling an older copy you
  kept yourself with `--allow-downgrade`.
- **Dependency closure resolution is comparatively less field-tested** than
  the single-pack install path - see `TODO.md` before relying on it for
  packs with real dependency graphs.
- **The pre-commit hook is convenience, not enforcement.** It's bypassed by
  `git commit --no-verify` and isn't enabled on a fresh clone until someone
  runs `git config core.hooksPath hooks` - CI is the actual gate.
- **Graceful degradation is real degradation.** On a machine with no
  `semgrep`/`gitleaks` installed, install-time scanning falls back to the
  structural floor (manifest + path safety) plus a regex secrets fallback.
  `.opf-lock`'s `scan` block records which scanners actually ran so this is
  at least visible, not silent (spec Section 9.1) - but a machine with
  nothing installed is genuinely less protected than CI.

## How to strengthen this for your deployment

Roughly in order of effort-to-value:

1. **Install the real scanners locally**: `scripts/ci-install-scanners.sh`
   installs the pinned versions of `semgrep`/`gitleaks`/`shellcheck` that CI
   uses. Without them, local installs and `validate-pack.sh` runs degrade
   to the structural floor.
2. **Enable the pre-commit hook on every clone**: `git config core.hooksPath
   hooks` once per clone of a pack scaffolded from `pack-z-template` (or let
   `pack-doctor` catch and fix it for you - it checks exactly this). Fast
   local feedback, especially for secrets, where the real fix is "don't
   commit it" rather than "clean it up after."
3. **Wire the CI gate on every pack repo you maintain.** GitHub:
   `.github/workflows/scan.yml` via `uses:`. GitLab:
   `include: project: opf-core, file: ci/pack-scan.gitlab-ci.yml`. This is
   the single-sourced security gate - a pack repo with no CI wired gets
   none of this automatically, no matter how good opf-core's tooling is.
4. **Run `pack-doctor` periodically** against your owned and external
   roots. It catches a stale `.opf-lock` left behind in a claimed pack,
   checksum drift against what was actually installed, missing native-tree
   registration, and (per #2) a pre-commit hook that's shipped but not
   wired for a given clone.
5. **Actually read the `install.sh` diff on update**, don't reflexively
   pass `--yes` in contexts a human should be reviewing. `--yes` is for a
   caller that already showed the content to a human (a skill, a wrapper
   UI) or genuinely trusts the source - not a default habit.
6. **Extend the curated ruleset for your org.** `ci/semgrep-opf-rules.yml`
   is deliberately small and offline-only; fork it and add rules for
   patterns specific to your stack (a known-bad internal API, a disallowed
   outbound host, etc.) rather than waiting for upstream.
7. **Don't run installs from a shell loaded with secrets you wouldn't want
   a pack to see.** `install.sh` itself no longer inherits your shell's
   environment, but everything *before* that point (the install script you
   invoke it from, a CI job) still can - keep deploy tokens and API keys
   out of the environment you launch installs from where you can.
8. **If your infra can't reach GitHub at build/validate time**, vendor
   `spec/` and `schema/` into a private repo rather than forking the format
   (host-layout doc, Section 2, "Vendoring the spec") - keeps you on the
   same contract instead of drifting.
9. **If you enforce the locked/External predicate via filesystem
   permissions**, use the normative one (mode bits, checked consistently
   across your own installer/updater/doctor) rather than inventing your
   own - `opf-host-layout.md` Section 1.3 spells it out, including the
   `access(2)` pitfall that makes a root-run job disagree with a developer
   shell about whether the same pack is locked.
10. **Keep pinned tool versions current.** `ci-install-scanners.sh` pins
    `shellcheck`/`gitleaks` versions so CI can't silently drift to a
    different tool version mid-flight; bump them deliberately on your own
    schedule rather than never.

## Where this is defined, if you need the normative text

- Scan contract, severities, lifecycle script approval: `spec/opf-spec-v1.md` Section 7-8
- Trust tiers, locked predicate, host layout: `spec/opf-host-layout.md` Section 1
- Recommended scanning tools and the graceful-degradation contract: `spec/opf-host-layout.md` Section 2.6
- Open gaps and what's not yet field-tested: `TODO.md`, "Before relying on this for real use"
