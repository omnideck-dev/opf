---
name: pack-release
description: Ship a new version of a pack the user already owns - decide the version bump from a plain-language description of the change, update the CHANGELOG, validate, and commit with confirmation. For non-technical pack owners who don't know semver or git.
---

# pack-release

Ship a new version of an existing, already-created pack. This is the
follow-up to `create-pack`: once a pack exists, this is how its owner
publishes a change to it. Assume the owner does not know what semver is,
does not write changelog entries, and does not use git directly - the
agent runs this procedure on their behalf and only surfaces the decisions
that actually need a human (what changed, whether to commit).

Do not confuse this with `pack-install`/`install-pack.sh`, which is the
*consumer* side: installing/updating a pack instance into a harness.
`pack-release` is the *author* side: shipping a new version of a pack you
maintain.

## Ownership assumption

This skill assumes the pack is Owned for the current user: created via
`create-pack`, or deliberately claimed as a co-maintainer (moved into the
owned workspace, with any stale `.opf-lock` removed - Owned packs don't
carry one, since nothing installs them). If the pack still has an
`.opf-lock` file, or the user seems unsure whether this is really theirs to
edit, stop and confirm before committing on their behalf - shipping a
change to a pack you don't actually maintain is exactly the External-tier
boundary `opf-host-layout.md` Section 1.3 exists to enforce, even though
this skill never touches install-time tier logic itself.

## Working directory assumption

Skills may run with the `OPF_ROOT` environment variable pointing at the
opf checkout. If `OPF_ROOT` is set, locate `bump-pack-version.sh` and
`validate-pack.sh` under `$OPF_ROOT/scripts/`. Otherwise, locate them
relative to this skill if it is bundled with opf (for example
`<opf>/scripts/bump-pack-version.sh`). If neither is available, ask the
user for the opf checkout path.

## Procedure

1. **Figure out what changed.** If it isn't already obvious from the
   conversation (for example, you just finished editing the pack for the
   user), ask in plain language - never ask the user to name a semver level
   directly:
   - "Did you fix something that was broken?" -> patch
   - "Did you add something new, without changing how existing things work?"
     -> minor
   - "Did you remove or rename something, or change something in a way that
     could break how others already use this pack (required config, a
     renamed skill/tool, etc.)?" -> major
   If more than one applies, use the highest that applies (major beats minor
   beats patch).

2. **Write the changelog entry yourself.** Compose one or more short, plain
   bullet points describing the change, from what you (or the user,
   described in their own words) actually did. Do not ask the user to write
   changelog copy.

3. **Run the bump script.**
   `bash <opf>/scripts/bump-pack-version.sh <pack-dir> <major|minor|patch> --note "<bullet>" [--note "<bullet>" ...]`
   This updates `manifest.json`'s `version` field and prepends the entry to
   `CHANGELOG.md`. Report the old and new version to the user in plain
   terms ("this ships as 1.3.0, since it adds a new capability").

4. **Validate.** Run `bash <opf>/scripts/validate-pack.sh <pack-dir>`.
   Translate any errors or warnings into plain language - do not paste raw
   script output at a non-technical user. Do not proceed to commit past an
   error. For a warning, explain what it means and ask whether to proceed.

5. **Get explicit confirmation before committing.** Show the user a short,
   human-readable summary of what will be committed (the version bump, the
   changelog line(s), and any other files that changed since the last
   commit). Do not commit without this confirmation - a git commit is a
   visible, semi-permanent action the user may not realize is happening on
   their behalf.

6. **Commit, but do not push without a separate confirmation.** If
   approved: `git add` the changed files (the pack's own files - never a
   broad `git add -A` across an unrelated working tree) and commit with a
   message naming the pack and new version. Committing and pushing are
   different levels of visibility (a push can trigger CI and becomes
   visible to others); ask separately before pushing, even if the user
   already approved the commit.

7. **Tell them what happens next.** CI scanning is already wired into every
   pack created from the template (`.github/workflows/scan.yml` /
   `.gitlab-ci.yml`) - once pushed, it runs automatically. No manual CI step
   is needed.

## Notes

- Never bump the version without also recording a changelog entry (step 2);
  a version bump with no explanation is not useful to the pack's future
  users.
- If the pack directory is not a git repository, stop and tell the user -
  this skill does not initialize git for them; that is a separate, more
  foundational decision than shipping a version.
- `bump-pack-version.sh` only edits `manifest.json` and `CHANGELOG.md`. It
  does not validate or commit; those are separate steps in this procedure so
  each has its own real exit code / confirmation point.

See `skills/create-pack/SKILL.md` for scaffolding a new pack, and
`spec/opf-spec-v1.md` for the manifest/version semantics.
