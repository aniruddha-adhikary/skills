# ani-skills

A Claude Code plugin marketplace. One plugin per domain, each carrying its own skills.

The thesis across all of them: **a coding agent is very good at some things and structurally bad at
others, and the things it is bad at were solved decades ago by tooling nobody points at an LLM.**
Program analysis, graph algorithms, SMT solvers, computer algebra, compilers used sideways. Old
tricks, new hat. Each skill teaches the agent to reach for the right instrument and — just as
importantly — to know when the instrument is worse than a grep.

## [modernizr](./plugins/modernizr)

<img src="./assets/banner.svg" alt="modernizr — map, split, prove" width="100%">

An agent reads files. That is the right move surprisingly often, and hopeless for a whole class of
question: whether a method is *genuinely* unused, which modules are really coupled, where a system
can be split and how small the resulting interface would be, whether a business rule can ever fire.
None of those answers is in a file you could open. They live in the relationships between files, or
in the XML, SQL and templates that are not code at all.

Program analysis has answered these since the 1970s. So: build a code property graph once, then
point classical tooling at it. **Graph algorithms** find where the domains genuinely divide, so you
can isolate one and plan around the boundary instead of guessing at it. **Formal proof and computer
algebra** show when two rules are the same rule, when a threshold is already implied by another, and
what the merged form looks like. The agent decides what to ask and what the answer means; the old
tools do the part they have always been better at.

Some of it is deliberately unorthodox. Compile the JSP pages so the presentation layer becomes
ordinary methods in the graph. Read a framework's own bytecode to derive what its config attributes
actually do. Replay database migrations in order to rebuild a schema nobody has a file for. The
common move is the same: find something that already knows the answer, and get it into the graph.

Three skills, divided by **the shape of the answer you need**:

| Skill | You need | The answer looks like |
|---|---|---|
| [codebase-recon](./skills/codebase-recon/SKILL.md) | to **locate or enumerate** — what does this do, what calls it, what is dead, what does the config actually wire | a list of methods, files and lines |
| [code-graph](./skills/code-graph/SKILL.md) | to **split or isolate** — where the domains actually divide, how small the interface between them is, what you can plan around | a boundary you can isolate one side of |
| [code-symbolic](./skills/code-symbolic/SKILL.md) | to **prove and simplify** — are these two rules the same rule, is this threshold already implied, can these be merged | a proof, and the merged form |

`codebase-recon` is the entry point: it builds a code property graph worth trusting, joins it to the XML, SQL, properties and templates the graph cannot see, and — as often as not — tells you a CPG is the wrong tool and ripgrep already answers your question. The other two consume its exports.

The plugin also ships **hooks** that block one architectural mistake (reaching the Joern server with `curl`, which silently answers about a different codebase) and advise on several trap-shaped queries.

## Install

```
/plugin marketplace add <this-repo-url>
/plugin install modernizr@ani-skills
```

Installing the plugin installs all three skills and the hooks.

For local development, symlink every skill into `~/.claude/skills`:

```bash
./scripts/link-skills.sh
```

Each entry is a symlink into this repo, so a `git pull` keeps installed skills current. Re-run it after adding or renaming a skill.

### What the skills expect on your machine

Nothing is required to read them. To run what they describe:

| For | You need |
|---|---|
| building and querying a graph | [Joern](https://docs.joern.io/installation) and a JDK |
| resolving dependencies first (do this — it decides whether your answers are real) | Maven, or the jars by any other route |
| type-checked query authoring (optional) | Coursier, scala-cli, Metals |
| `code-graph` | Python and networkx |
| `code-symbolic` | Python, `z3-solver`, `sympy`, `dd` |
| merging generated code into the graph (optional) | whatever generator your project uses; the bundled JSP example fetches Jasper via Coursier |

## Repo conventions

See [CLAUDE.md](./CLAUDE.md), also readable as `AGENTS.md`. The short version: skills stay thin and route to reference files, syntax is self-served from the tool rather than copied into the skill, and a pattern is only documented after it has been measured on a real codebase and has beaten a ripgrep baseline and a plain-read baseline.

Two rules the content follows, both learned the hard way:

- **A number belongs in a skill only if the reader acts on its magnitude.** A threshold to compare against, a parameter to set. Otherwise state the mechanism — "a container is a registry, not a restriction" is more useful and more portable than the percentage that proved it.

Measured negatives are content in their own right: knowing that betweenness centrality, community detection and MC/DC measurably fail on real code saves more time than any capability, so they are documented as carefully as the things that work.
