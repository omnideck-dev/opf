# __PACK_NAME__

__DESCRIPTION__

A pack in the Open Pack Format (OPF). A pack is a manifest plus embedded
files, containing one or more items: skills, tools, data, routines, or
artifacts. Packs install, update, and remove with zero native harness code.

See `spec/opf-spec-v1.md` in the opf-core repository for the format.

## Contents

- `manifest.json` - the OPF v1 manifest.
- `skills/` - skills in this pack.
- `data/` - data shipped with this pack.
- `.github/workflows/scan.yml`, `.gitlab-ci.yml` - CI scanning, already wired
  to opf-core's validator and scan template. No setup needed.
- `hooks/pre-commit` - a local pre-commit security scan (fast feedback, not
  a substitute for CI - see below).

## Install

Install this pack with the `pack-install` skill, or `scripts/install-pack.sh`
for a harness that runs scripts but not skills - never by copying this
folder by hand. If `manifest.json` declares `dependencies`, only
`pack-install` resolves the closure (installing each one first, in order,
per spec Section 4.5); `install-pack.sh` alone does not - it installs only
this pack and prints a `NOTE` about the skipped dependencies. Either way
requires opf-core's tooling to be reachable by your harness (a checkout,
with `OPF_CORE` set if your harness needs it) - see opf-core's own README
for that one-time setup. If a dependency's skills don't show up after
install, run `pack-doctor` to diagnose why.

## Validate

```
scripts/validate-pack.sh .
```

## Enable the pre-commit hook

Not automatic - git never reads `hooks/` on its own. Once per clone:

```
git config core.hooksPath hooks
```

This runs `validate-pack.sh` plus, where installed, `gitleaks` and the
curated semgrep ruleset before each commit, refusing it on an error-class
finding. It degrades gracefully (a NOTE, not a failure) for whatever
isn't installed or configured, and it's bypassed by `git commit
--no-verify`. It's convenience and fast feedback, not the enforced gate -
that's CI. Run `scripts/pack-doctor.sh` after cloning this pack if you're
not sure whether this is set.