# ani-skills

A Claude Code plugin marketplace. One plugin per domain, each carrying its own skills.

## [modernizr](./plugins/modernizr)

You have inherited a system nobody understands. The people who wrote it have gone, the tests assert
what it does rather than what it should, and half the behaviour lives in XML, SQL and templates
rather than in the code. You have been asked whether it can be split up, what is safe to delete, and
what it actually does.

Three skills for answering that on evidence instead of on reading. They divide by **the shape of the
answer you need**:

| Skill | You need | The answer looks like |
|---|---|---|
| [codebase-recon](./skills/codebase-recon/SKILL.md) | to **locate or enumerate** — what does this do, what calls it, what is dead, what does the config actually wire | a list of methods, files and lines |
| [code-graph](./skills/code-graph/SKILL.md) | to **cut or group** — where to split a monolith, how large the facade is, which parts genuinely overlap | a boundary: nodes to break, or groups that may overlap |
| [code-symbolic](./skills/code-symbolic/SKILL.md) | to **decide** — is this threshold redundant, are these two configurations the same program, do these formulas agree | yes, no, or the exact inputs on which they differ |

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
