# Open Pack Format (OPF) v1: Authoring Packs

**Status:** Non-normative guidance
**Format version:** OPF v1 (`pack_format: 1`)
**Scope:** Whether a thing should be a pack at all, what belongs inside one versus in the
tool it drives or the user's own workspace, and how to name and grow a pack once it exists.
Nothing here is enforced by the validator or the schema. This is judgment, not a rule.

**Companion document:** [`opf-pack-boundaries.md`](./opf-pack-boundaries.md) covers how to
divide work across *several* packs once you have decided to build them — ownership, domain
separation, and the bundle pattern. This document sits upstream of that one: it is about
deciding what a pack is for in the first place.

---

## 1. Four homes, not one

Before asking "how should this pack be organized," ask where each piece of what you have
actually belongs. Most things that feel like pack content are not.

| Home | What lives there | Test |
|---|---|---|
| **The tool** (library, binary, service) | structural facts about how the tool works | changes exactly when the tool changes |
| **The pack** | skills, the data those skills reason from, helper tools | an agent needs it to use the tool well |
| **The user's workspace** | anything the user creates, edits, or swaps | it is *theirs*, and it changes on their schedule |
| **Documentation** | how to extend the system, why it is shaped this way | a human reads it once, an agent never needs it |

The most common authoring mistake is collapsing the first two — shipping skills inside the
library repo, or shipping the library's own reference data inside the pack. The second most
common is collapsing the second and third, which Section 4 shows is not merely untidy but
actually broken.

## 2. Structural versus editorial

When a pack drives a tool you also own, the split between them is sharper than it first
appears. Two kinds of information look similar and belong in different places.

**Structural** information describes what the tool *is*. For a component library: which
components exist, their names, their variants. For a CLI: its commands and flags. For a
data format: its schema. This changes when the tool changes, and shipping it anywhere else
guarantees drift. It belongs with the tool, published as data the pack can read.

**Editorial** information describes how to use the tool *well*. Which component to reach for
given three items rather than five. How long a heading should run. Which order to do things
in. The tool neither knows nor enforces any of it.

The test: **can someone using the tool by hand ignore this and still produce valid output?**
If yes, it is editorial, and it belongs in the pack. If no — if ignoring it produces
something the tool itself would reject — it is structural, and it belongs with the tool.

Getting this backwards is expensive in both directions. Structural data in the pack goes
stale the first time the tool ships a release. Editorial opinion in the tool makes the tool
harder to adopt for anyone who does not share the opinion.

## 3. Skills read data; they do not restate it

Once structural and editorial data are published as files, a skill's job is to read them.

A skill that hardcodes a constraint already written in a data file has created a second
source of truth. It will drift at the next release, and the failure is nasty: output that
looks reasonable, fails validation, and gives no clue why, because the skill and the
validator disagree about a rule neither of them owns.

Keep the rule in one file. Have both the skill and any validator read it. This is
mechanical, not a matter of discipline — a rule that exists in only one place cannot drift.

## 4. Installed packs are locked, so user content cannot live in them

An installed pack cannot be edited by the agent using it (main spec Section 3). Only its
owner changes it, by publishing a new version. That guarantee is load-bearing for trust, and
it has a design consequence worth stating plainly:

**Anything the user is expected to create, edit, version, or swap cannot be pack content.**

Configuration they tune, themes they author, templates they adapt, project data they
accumulate — none of it can live inside the installed pack, because the moment they ask the
agent to change it, the agent cannot. The pack's job is to ship the *skill that produces
it*; the output lands in the user's own workspace.

This is a good shape anyway. It keeps the pack small, makes the user's work portable across
pack updates, and means a pack upgrade never silently overwrites something they wrote.

If a pack's design requires a file the user edits, the design is wrong, not the lock.

## 5. Data belongs in a pack only until it needs searching

Packs can carry data, and for the right data that is the best possible home: versioned with
the skills that read it, available offline, no service to stand up, no credentials to manage.

The limit is not a file count. It is **how the agent has to get at it**.

| What the agent needs | Shape that works | Home |
|---|---|---|
| All of it, every time | one file, or a handful | pack |
| A specific piece it can name | many files plus a maintained index mapping topic → path | pack |
| A piece it has to *find* by meaning | — | external retrieval |

The third row is the boundary. Once answering a question means searching rather than
looking up, a directory of Markdown files is the wrong substrate no matter how it is
organized, and no amount of indexing fixes it — an index answers "where is X," not "what is
relevant to this question."

Rough scale, with the usual caveat that the numbers are softer than they look: a handful of
files an agent reads directly; up to a few hundred stays workable with a deliberately
maintained index; a few thousand is unwieldy regardless of indexing. Past that point the
install is a slow clone, the index is large enough to cost context on its own, and the agent
spends more effort navigating the corpus than using it.

Two reasons to move data out that have nothing to do with size:

- **Volatility.** Pack data is frozen at release and locked after install (Section 4). Data
  that changes faster than the pack ships forces a release per change, and every consumer is
  stale between releases.
- **Ownership.** If the corpus belongs to someone else — a product catalog, a knowledge
  base, a ticket system — a pack that carries a copy has forked it.

**Where it goes instead:** an MCP server, a semantic search endpoint, or a plain API. Which
one matters less than the move itself.

**The pack does not disappear when the data leaves — it slims down to the interface.** What
stays is worth more than the corpus did: skills that know how to query the source well,
domain vocabulary, the conventions for interpreting results, and a small curated index of
what exists and how to ask for it. That last piece is the pattern worth reaching for first,
because it often defers the migration entirely: keep a short map in the pack, put the bulk
behind a service, and let the agent consult the map before it queries.

Endpoints and credentials are workspace or harness configuration, never pack content, for
the reason in Section 4.

## 6. Installing a pack is not free

A library you never import costs nothing. **An installed pack costs agent attention
permanently.** Every skill in it carries a description the agent weighs on every relevant
turn, and skill-selection accuracy degrades as the candidate set grows.

This is specific to agent packaging and has no real analogue in ordinary package management,
which is why intuitions carried over from npm or pip mislead here. It pushes toward:

- **Smaller packs than package-manager instinct suggests.** A consumer who wanted one
  workflow should not be carrying five unrelated ones into every conversation.
- **Domain separation genuinely mattering**, rather than being a tidiness preference
  (`opf-pack-boundaries.md` Section 3).
- **Bundles over mega-packs.** A bundle installs several packs; it does not merge them, so
  a consumer can still take only what they need.

**Trigger collision** is the sharp edge of the same problem. Two installed packs with skills
covering similar ground will compete, and the loser is whichever the harness happens not to
pick. When a pack supersedes an older one, retiring the old skills is part of shipping the
new pack, not a cleanup task for later.

## 7. Naming: three namespaces, three jobs

A pack has three names and they need not be the same string.

| Namespace | Job |
|---|---|
| **Repository name** | discovery and sorting wherever the repo is browsed; signalling that this is an installable pack rather than a library |
| **`vendor`** | scoping — who this came from, and disambiguation from another vendor's pack of the same name |
| **`name`** | what a person types, reads in a dependency entry, and says out loud |

A prefix convention such as `pack-` earns its place on the **repository** name. Distribution
is git-native, so the repo listing is a real discovery surface, and a prefix groups packs
together and distinguishes them from libraries in the same namespace — a distinction
newcomers routinely get wrong.

The same prefix is redundant in the manifest. `acme/pack-widgets` says "pack" twice: once in
the word, once in the fact that it is a pack manifest. Dependency entries carry `vendor`,
`name`, and `url` as separate fields (main spec Section 4.5), so the repository name travels
in the `url` while `name` stays clean.

Two further notes:

- **Name by job, not by component.** Nobody's job is "use the grid library." Packs named for
  what the consumer is trying to do are found; packs named for their internals are not.
- **Generic names are safe inside a vendor and risky outside it.** `acme/print` is
  unambiguous in context. If a cross-vendor registry ever exists, the vendor field protects
  you structurally but will not stop someone typing the bare name and getting a stranger's
  pack.

## 8. Versioning across the boundary

A pack that drives an external tool depends on that tool's shape, and the two ship on
different schedules by design. Three mechanisms keep them honest:

1. **Declare the supported range** in the manifest's `metadata` block, using the same
   node-semver syntax as `dependencies`.
2. **Vendor the tool's structural data** pinned to that range, rather than fetching it at
   runtime. A pinned copy is not drift; an unpinned copy is.
3. **Make the mismatch a reported failure.** If the pack's helper tooling can see which
   version of the tool is actually present, it should say so when the answer falls outside
   the declared range. Silent version skew produces bugs nobody can locate.

Same rule as Section 3, one level up: the disagreement you can detect is cheap, and the one
you cannot is expensive.

## 9. Build packs when they have content

A pack with a manifest and no items is not a placeholder, it is overhead: a changelog, a
release decision, a README that says "coming soon," and a dependency entry that resolves to
nothing useful. Mapping out five packs is a good planning exercise. Creating five packs is
not.

Ship the one that has content. Create the next when it has content of its own. Create a
bundle when there are at least two packs to bundle — a bundle with a single dependency is
indirection, not convenience.

For pack owners who want the mechanics handled, `create-pack` scaffolds a pack and
`pack-release` decides the version bump and writes the changelog from a plain-language
description of what changed.

## 10. Putting it together

1. **Sort each piece into one of four homes** (Section 1) before organizing anything.
2. **Structural data ships with the tool; editorial data ships with the pack** (Section 2) —
   the test is whether a hand-user could ignore it.
3. **Skills read their data files and never restate them** (Section 3).
4. **Nothing the user edits can live in an installed pack** (Section 4) — the pack ships the
   skill that produces it.
5. **Bundle data the agent reads or looks up; externalize data it has to search** (Section
   5), and keep the curated map even after the corpus leaves.
6. **Installing costs attention, so packs run smaller than package-manager instinct
   suggests** (Section 6), and superseded skills get retired deliberately.
7. **Prefix the repo, not the manifest; name by job** (Section 7).
8. **Declare and pin the tool version, and report mismatches** (Section 8).
9. **Create a pack when it has content** (Section 9).

Then read [`opf-pack-boundaries.md`](./opf-pack-boundaries.md) for how to divide the result
across several packs, and how to bundle them back into one install.
