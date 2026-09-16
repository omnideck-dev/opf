# Open Pack Format (OPF) v1: Pack Boundaries and Ownership

**Status:** Non-normative guidance
**Format version:** OPF v1 (`pack_format: 1`)
**Scope:** How to decide what goes in one pack versus several, and how to keep a pack's ownership from decaying into a group nobody can be accountable to. Nothing here is enforced by the validator or the schema; a pack of any size or ownership shape is equally conformant. This is judgment, not a rule - the guidance below is what tends to work.

**Companion document:** [`opf-pack-authoring.md`](./opf-pack-authoring.md) sits upstream of this one: whether something should be a pack at all, what belongs inside it versus in the tool it drives or the user's own workspace, and how to name and grow a pack once it exists. Read that first if you haven't yet decided what you're building; this document assumes you have and covers dividing the result across several packs.

---

## 1. Why this needs guidance at all

The spec places no limit on what a pack can contain: one skill, or every skill an org owns, are both valid packs. Both extremes cause real, predictable problems:

- **One pack for everything.** Every change goes through the same repo, so unrelated work collides in the same PR queue. Ownership diffuses ("everyone" owns it, which means no one does). A single bad change to one corner of the pack blocks review of everything else in flight. A consumer who wants one skill has to take the whole pack, including things they never asked for and now have to keep updated.
- **One pack per tiny thing.** A consumer who wants one workflow has to discover, understand, and separately install N packs to get it. Dependency graphs sprawl. Versioning overhead multiplies: N packs means N changelogs, N release decisions, N places a breaking change can hide.

Neither extreme is wrong in every case - a single-skill pack is exactly right for something genuinely standalone, and a monolith is fine for a team of one who will never split it. The two guidelines below give a repeatable way to decide when you're not in one of those simple cases, and Section 4 (bundles) resolves the actual tension: domain-separated packs for maintenance, one thing to install for the consumer.

---

## 2. Guideline 1: one owner, or a small, named few

A pack works best with a single owner, or a small number of *named* co-owners - not "the team." This is about the pack's blast radius when something goes wrong, not about who is allowed to use it.

Why this matters in practice:

- **Review and merge overhead scales with owner count.** More owners means more people who can, and will, send changes to the same files at the same time. A pack with one owner has one person deciding what ships; a pack with ten has ten people each partially deciding, which in practice means arguments or silent overwrites.
- **Overwrite risk is real, not theoretical.** Two owners editing the same skill or tool in parallel, each unaware of the other's in-flight change, is exactly how legitimate work gets silently reverted by the next merge. Fewer owners means fewer surprise collisions.
- **Accountability needs a name, not a group.** "Who approves a change to this pack" needs an answer that resolves to a person. A pack with five equal owners and no lead has, in effect, zero owners for the purpose of a hard call.

This is governance, not a security mechanism, and OPF does not prescribe a dedicated file for it - a pack-local list would be pure record-keeping with no enforcement (anyone who can already edit the pack could edit the list too), so it isn't worth a bespoke convention. Record it wherever it is naturally read:

- **A line in `README.md`** ("Maintained by: ...") is enough for most packs - `README.md` is already the human-readable entry point (spec Section 5.3), so this adds zero new files and nobody has to remember a second place to look.
- **A platform-native `CODEOWNERS` file**, if the pack's repo lives on a platform that supports one (GitHub, GitLab), for an org that wants actual enforcement (required reviewers, auto-assignment) rather than a plain-text note. That mechanism already exists and already has teeth; a bespoke OPF equivalent would just be a weaker duplicate of it.
- **The manifest's `metadata` block** (Section 4.2's layering extension point - `metadata.owner` and similar org-specific keys are validated only as "the object exists"), for an org that wants a machine-checkable field without adopting platform `CODEOWNERS`.

None of these decide trust tier. Tier is decided by how the pack arrived for a given consumer - created or deliberately claimed means Owned, installed means External (main spec Section 3; `opf-host-layout.md` Section 1.3) - which needs no record to stay in sync, because it's determined by the action itself.

**When a pack outgrows one owner or a small few**, that is usually a sign the pack has grown to cover more than one domain (Section 3) - split it, rather than adding a fourth or fifth co-owner to hold it together.

---

## 3. Guideline 2: separate packs by domain, not by who happens to maintain them

Even when one person or team owns everything below, package by domain - by what a consumer would want on its own - not by who currently maintains it.

A domain boundary is usually visible along one of these lines:

- **Different consumers.** Would someone reasonably want X installed without Y? If yes, X and Y are different domains, even if the same person wrote both.
- **Different install/update cadence.** A pack that changes weekly and one that changes twice a year create very different review and update burdens if forced into one pack; separating them lets each move at its own pace.
- **Different subject matter.** A content-review pack, a tech-review pack, and a competitive-analysis pack are different domains even under the same owner and the same team. Bundling them because one person wrote all three optimizes for the author's convenience at the cost of every consumer who wanted only one.

A useful test: **if you can imagine a consumer wanting X without wanting Y, X and Y belong in different packs.** If X commonly needs Y's shared content (a common skill, a shared script), that's what the `dependencies` field is for (Section 4.5) - domain separation and shared content are not in tension; dependencies are how a domain-separated pack still gets to reuse another pack's content instead of duplicating it.

This guideline trades a small amount of author convenience (more repos, more manifests to keep current) for a large amount of consumer flexibility (install exactly what you need) and blast-radius containment (a change to competitive-analysis cannot block a content-review release). Section 4 addresses the resulting "now I have to install five things instead of one" friction directly.

---

## 4. The bundle pattern: composing domains back into one install

Guideline 2 produces more packs. That is correct for maintenance, but a team lead who wants "the standard marketing setup, installed in one step" for a new hire shouldn't have to know and separately install five packs. The dependency mechanism (spec Section 4.5) already provides the answer, with no new spec mechanism required: **a pack whose only real content is its `dependencies` array.**

A bundle pack:

- Has few or no items of its own (`skills/`, `tools/`, `routines/`, `agents/`, `artifacts/` are typically empty or absent; a `README.md` explaining what the bundle is for is still expected, same as any pack).
- Declares a `dependencies` entry for every domain pack (and any shared `pack-common`) the bundle represents.
- Is installed like any other pack; installing it installs the full dependency closure, in the order Section 4.5 defines (dependencies first, transitively, depth-first).

Example - a `marketing` bundle covering a shared-content pack plus four domain packs:

```json
{
  "pack_format": 1,
  "name": "marketing",
  "version": "1.4.0",
  "description": "Bundle: the standard marketing team install (no content of its own).",
  "vendor": "acme",
  "dependencies": [
    { "vendor": "acme", "name": "pack-common",           "version": "^2.0.0", "url": "https://github.com/acme/pack-common" },
    { "vendor": "acme", "name": "content-draft",         "version": "^1.0.0", "url": "https://github.com/acme/content-draft" },
    { "vendor": "acme", "name": "content-review",        "version": "^1.0.0", "url": "https://github.com/acme/content-review" },
    { "vendor": "acme", "name": "competitive-analysis",  "version": "^1.0.0", "url": "https://github.com/acme/competitive-analysis" },
    { "vendor": "acme", "name": "messaging",             "version": "^1.0.0", "url": "https://github.com/acme/messaging" }
  ]
}
```

A new hire, or a new project, installs `marketing` once and gets all five. Each member pack keeps its own owner, its own release cadence, and can still be installed on its own by a consumer who only needs `competitive-analysis`.

### The gotcha: "updating the bundle updates everything" needs the ranges to mean it

It's tempting to assume that bumping the bundle's own version and re-releasing it automatically pulls fresh versions of every member. That is **not** automatic, and getting it wrong produces a bundle that looks current but silently isn't:

- Spec Section 4.5 is explicit: *"A dependency already installed at a version satisfying the range is NOT reinstalled."* If a consumer already has `content-review` at `1.2.0` and the range is still `^1.0.0`, a bundle re-release changes nothing for them - the installed version already satisfies the range, so nothing about it looks out of date to the installer.
- To make "update the bundle" actually mean "update the members," the bundle owner has real update work to do whenever a member ships something worth pulling forward: bump that member's declared range in the bundle's own manifest (a patch/minor/major bump to the bundle, using `pack-release` like any other change) so the range no longer already includes what's installed.
- The alternative is to put the member packs on the rolling-release profile (spec Section 9.2): under that profile, `version` is informational and a same-version reinstall still re-syncs to the tracked ref, so "update the bundle" (which re-triggers installation of the whole closure) picks up whatever main currently is, without needing a manifest edit per member release. This is the natural fit for an org that already runs the rest of its estate on the rolling profile.

Either way, decide this up front and document it in the bundle's own `README.md`: "update this bundle to get pinned member versions, bumped deliberately" reads very differently to a consumer than "update this bundle to always get the latest of everything," and both are legitimate choices.

### Bundles nest

A bundle can depend on another bundle; Section 4.5's depth-first transitive resolution already handles this with no special case, and cycle detection already refuses a pack that transitively depends on itself. A `company-wide` bundle depending on `marketing`, `sales`, and `support` bundles is a normal, supported shape.

---

## 5. Putting it together

None of this is enforced, and none of it should be. The guidance compresses to:

1. **One owner or a small named few per pack** (Section 2) - if you need a sixth co-owner to keep a pack running, split it instead.
2. **Separate packs by domain, not by author** (Section 3) - "would someone want X without Y" is the test.
3. **Bundle domains back together for consumers who want one install** (Section 4) - and be deliberate about whether "update the bundle" means "get pinned things I chose" or "get whatever's current," because the dependency-resolution rule (already-satisfying versions are not reinstalled) means those are genuinely different setups, not two names for the same thing.
