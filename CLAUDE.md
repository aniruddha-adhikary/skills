# Repository conventions

Read by Claude Code as `CLAUDE.md` and by other agents as `AGENTS.md` — the same file under two names.

This repo is a **Claude Code plugin marketplace**. Each plugin covers one domain and carries its own skills. Plugins are the grouping mechanism — there are no bucket folders.

## Layout

```
skills/<skill>/SKILL.md             the skill itself — this is where you edit
  patterns/*.md                     loaded on demand, one family per file
  scripts/                          executed, never read into context
.claude-plugin/marketplace.json     lists every plugin, source is a local path
plugins/<plugin>/
  .claude-plugin/plugin.json        plugin manifest, lists its skills
  hooks/hooks.json                  optional; plugin-scoped hooks, live on install
  skills/<skill>                    SYMLINK to ../../../skills/<skill>
scripts/link-skills.sh              symlink every skill into ~/.claude/skills
AGENTS.md                           symlink to this file, for agents that look for that name
```

**Skills live at the repo root, in `skills/`.** A plugin cannot reference a path containing `..` — validation rejects it as traversal — so each plugin carries a symlink per skill instead. Edit under `skills/`; the plugin picks the change up through the link, and one skill can belong to several plugins without being copied.

Currently one plugin, **modernizr**, with three skills: `codebase-recon` (build and query a code property graph, and join it to the config, SQL and templates it cannot see), `code-graph` (graph algorithms over its export), and `code-symbolic` (solvers and computer algebra over its extracted facts). The two siblings depend on the first and say so in their frontmatter, because Claude Code has no formal skill-dependency field.

Adding a plugin means a directory under `plugins/` **and** an entry in `.claude-plugin/marketplace.json`. Adding a skill means a directory under `skills/`, a symlink to it under that plugin's `skills/`, **and** an entry in its `plugin.json`. Run `claude plugin validate . --strict` after touching either manifest.

Re-run `scripts/link-skills.sh` after adding, renaming, or removing a skill.

## Conventions

**Never write the maintainer's email address into any file.** Author and owner fields carry the name only.

**A skill is thin by default.** `SKILL.md` routes and teaches how to think. Detail lives in sibling reference files that load only when the task needs them. Syntax and API surface are self-served from the tool's own help, completion, and docs — writing them down means maintaining a copy that goes stale.

**Put the index in `SKILL.md`, not in a separate file.** An index file is itself a lookup. The router names the question and the page that answers it, and nothing else stands between them.

**A script costs no context until it runs; a code block costs it every time.** Long, fiddly, reusable mechanics belong in `scripts/`. What stays on the page is the shortest traversal that shows the shape, so a reader can adapt it when their question differs from the library function — which is most of the time.

**Write instructions, not a report.** A number earns its place only if the reader acts on its magnitude: a threshold, a parameter, a value to compare against. Otherwise give the mechanism, which also transfers to codebases nobody measured. Do not name the corpora — the measurement belongs in `research/`, and a corpus name lends unearned authority to a figure the reader cannot check.

**Warn where the reader would trip.** A trap that bites any query goes in the traps page; a trap tied to one technique goes with that technique, even if it means repeating a clause. One repeated sentence is cheaper than a cross-reference.

**Verify before asserting.** Every query in a skill must have been executed, and every script exercised on the path being claimed. Three defects shipped in this repo from skipping that, including a dependency-resolution step whose flag made it silently never run.

**Skills are written from measured results.** A pattern is documented after it has been probed on a real codebase and has beaten both a ripgrep baseline and a plain-read baseline. An empty section is more honest than a plausible one.

**Verticals earn their own skill.** New capability starts as a reference file under an existing skill. It graduates to a sibling skill only when it has a real workflow that a reference file can no longer hold.

## Deferred on purpose

These are absent by choice, not oversight. Add them when the repo is published, not before:

- `docs/` — human-facing pages per skill, published
- changesets and `package.json` versioning
- CI running `claude plugin validate --strict`
- per-plugin `README.md`
- an eval suite that discriminates — see `CLAUDE.local.md`.
