---
name: codebase-recon
description: Work out what an unfamiliar or legacy codebase actually does, and what is safe to change. Use for legacy modernization, replatforming, a rewrite or strangler migration, onboarding onto an inherited system, technical-debt assessment, documenting what a system does, dead-code removal, or planning a refactor on evidence instead of on reading. Builds a code property graph with Joern, then joins it to the XML, config, SQL, schema, templates and generated code the graph cannot see — which on an enterprise codebase is often half the program. Also says when NOT to build a graph, since several whole technique families measurably lose to ripgrep, and documents the ways this tooling returns a plausible, non-empty, wrong answer with no error.
---

# Joern analysis

Joern builds a **Code Property Graph** — AST, control-flow graph and program-dependence graph merged into one queryable graph — with a Scala DSL to traverse it. Its reputation is vulnerability hunting. That is one application of a general capability: asking a codebase questions that neither grep nor reading can answer.

## Before anything else

**Three questions, in order:**

1. **Could ripgrep answer this?** Often yes. Check [when-not-to.md](./when-not-to.md) — module graphs, duplicated constants and several whole technique families lose to a cheaper tool, measured.
2. **Do you have dependency jars?** Without them the call graph is **degenerate, not fuzzy** — virtually every unresolved call collapses to the same body-less stub, so the graph looks *more* precise than it is.
3. **Are the overlays there?** `cpg.metaData.overlays.l` on an empty list means no call graph, no CFG, no dataflow — returning zero, silently.

Questions 2 and 3 are mechanical, so do not check them by hand: `scripts/build-typed-cpg.sh` enforces the first and `scripts/gq.py` warns on the second every time.

## The path through a codebase you have not analysed before

Steps 1–3 are what separate a graph you can trust from one that quietly lies. They are boring, and skipping them produces no error.

**1. Get the jars — this is the pivotal step, and it is not "get it to build".**
`mvn dependency:copy-dependencies` skips compilation, plugins, codegen and tests. You need jars, not a green build. "The dependencies are unobtainable" is usually false; see [setup.md](./setup.md) for the four reasons resolution appears to fail when it hasn't.

**2. Stage the test tree.** `javasrc2cpg` silently drops any directory named exactly `test`, which is standard Maven layout. Without this, a method called only from tests is indistinguishable from a dead one.

**3. Build and verify.** Both of the above plus a post-build check:

```bash
scripts/build-typed-cpg.sh <source-dir> <out.cpg.bin> --with-tests
```

It reports the unresolved-signature rate, which is the number that tells you whether step 1 worked — expect well under 1%; a double-digit rate means the jar list is missing what the code actually calls.

**4. Prove the graph matches the source tree before asking it anything real.** One line, and it catches the whole family of silent-truncation failures:

```bash
find <src> -name '*.java' | wc -l     # compare with cpg.file.name(".*[.]java").size
```

(Not `cpg.file.size` — the overlay pass adds one synthetic file node, and that phantom can exactly mask one missing file.) A shortfall that matches the file count under `test/` directories means the frontend dropped your tests — rebuild with `--with-tests`. A shortfall that matches nothing is a finding of its own; trace it before you query.

**5. Start a server and pin the graph.**

```bash
nohup joern --server --server-host 127.0.0.1 --server-port 8080 > /tmp/joern-server.log 2>&1 &
scripts/gq.py <out.cpg.bin> -e 'cpg.method.internal.size'
```

**6. Ask the question as a join, not a ranking.** See the rule below.

## Choosing how to run a query

Two different axes get confused here. *Server vs script* is about the interaction loop; *ad-hoc vs file* is about whether the result is durable. Both matter, and they are independent.

| what you are doing | how to run it | why |
|---|---|---|
| exploring — twenty questions, each narrowing the last | resident server via `scripts/gq.py` | tens of milliseconds warm against several seconds per `joern --script`. This is what makes iterating possible at all |
| a whole-graph pass, or anything memory-hungry | isolated `joern --script -J-Xmx5g` | a heavy traversal on the shared server evicts or OOMs everyone else's work |
| a result you will cite, repeat, or hand to someone | a `.sc` file, type-checked before it runs | diffable and reviewable; see [lsp-workspace.md](./lsp-workspace.md) |
| more than one agent or terminal at once | `scripts/gq.py` only, never raw `curl` | the server is shared mutable state — see below |
| several *unrelated* codebases at once | a server each, on its own port | correctness is fine either way, but one JVM holding everything is where you run out of memory |

**The server holds several CPGs at once and `importCpg` switches the active one.** Loading and then querying is two round trips, so anyone else's `importCpg` in between silently reassigns `cpg` and your query answers about the wrong codebase — plausibly, with no error. `gq.py` avoids this rather than detecting it: projects are addressable by name, so it binds `cpg` to the graph you named and never reads the global. Two agents then query two graphs on one server with no coordination, each getting the right graph's answers.

What that does *not* fix is memory. Nothing evicts anything, so graphs accumulate — each resident CPG holds gigabytes of heap, and several Joern JVMs on one machine will eventually get one of them OOM-killed mid-work. Share a server when you are asking many questions of the **same** graph — that is where the warm-query win comes from. Give genuinely unrelated work its own server and port, and run `gq.py <cpg> --unload` when you are finished with a graph.

## What a query looks like

A query is a **traversal**, not a search: start at a node set, narrow it with predicates, then step along edges. Every example below runs as written.

Start somewhere and filter:

```scala
cpg.method.internal.name("do(Get|Post)").fullName.l
```

`internal` means declared in this codebase rather than in a library — you will use it constantly. `.l` materializes; without a terminal step you get an `Iterator` back and it looks like the query found nothing.

Step across an edge — here from a method to what it calls:

```scala
cpg.method.internal.name("doPost").callee.internal.name.dedup.l
// List(doGet, performAction, upload, addMessage, find, …)
```

Cross from one representation to another. The same node has an AST, a control-flow graph and a dependence graph hanging off it, and stepping between them is where the power is:

```scala
cpg.method.internal.name("doPost").ast.isControlStructure.controlStructureType.groupCount.l
// List((THROW,5), (TRY,7), (IF,6), (WHILE,1), (CATCH,10))
```

Ask for what is *absent*, which is the question grep cannot answer:

```scala
cpg.method.internal.filterNot(_.name.startsWith("<")).filter(_.callIn.isEmpty).size
```

And the shape that produces most real findings — pull a value out of the code so you can join it against something outside the graph:

```scala
cpg.call.name("getParameter").argument.isLiteral.code.dedup.l
// List("skin", "X-XSRF-TOKEN", "params", "nextpage", …)
```

Those literals are the names an HTML form posts. Match them against the form fields in the markup and you have connected two languages the graph cannot see across. That join, in its many forms, is what `patterns/` is about.

## The rule that predicts whether a CPG will help with your question

> **Join two independent channels, or rank against an oracle. A ranking with neither is a story.**

An **oracle** is a ground truth you can score against — what maintainers actually fixed later, a passing test, a schema. A **channel** is an independent source of facts: config × code, SQL × schema, clone × call-graph, static × dynamic — joins of that shape produce verified findings. Betweenness, community detection and complexity metrics produce numbers nobody can act on, because a single channel gives an ordering with no ground truth; two give a **disagreement**, and a disagreement is evidence. A temporal holdout — scoring today's ranking against changes made after your analysis snapshot — is a cheaper oracle than a second channel.

Whatever the second channel is — config, schema, trace, coverage, history — it enters the analysis by one procedure: parse it with a real parser, choose the identity key both sides share, merge or join on that key, attach the result to the graph, validate the links. [channels.md](./patterns/channels.md) opens with the procedure and works the instances.

## Do not memorize the syntax — self-serve it

The DSL is large and version-specific. Memorized snippets go stale, and the examples in these files were verified against one version, not yours.

- **Tab-completion after a dot** enumerates valid next steps; `help` lists command families.
- **Type-check before you run.** A Scala LSP with the Joern jars on the classpath catches a bad step instantly.
- **`.l` materializes.** A traversal without a terminal step returns an `Iterator` — the commonest reason a query "returns nothing".
- **Match on structured properties** — `name`, `methodFullName`, `typeFullName`, `receiver` — **never a regex over `.code`**, which is a lossy rendering of a tree you have already parsed.
- **When a step does not exist, the compiler says so immediately.** `cpg.call.internal` and `_.isAbstract` both look reasonable and neither is real. A 50 ms round trip settles it; guessing in a long script does not.

## Which of the three skills you want

They divide by **the shape of the answer you need**, not by tool:

| you need | skill | the answer looks like |
|---|---|---|
| to **locate or enumerate** — where is this, what calls it, what is missing, what does the config actually wire | `codebase-recon` | a list of methods, files and lines |
| to **cut or group** — where to split, how big the facade is, which parts genuinely overlap | `code-graph` | a boundary: a set of nodes to break, or groups that may overlap |
| to **decide** — is this redundant, are these two the same program, do these agree | `code-symbolic` | yes, no, or the exact set of inputs on which they differ |

The order is usually that order, and each hands the next its input. Build a graph worth trusting, export it, then either cut it or prove things about it. Going straight to the third without the first tends to mean proving something about code that is not the code that runs.

## Find the pattern for your question

| Your question | Page |
|---|---|
| What depends on what? Which modules are coupled? | [structure](./patterns/structure.md) — integration graph, module attribution |
| What is dead? Did anyone adopt this abstraction? | [structure](./patterns/structure.md) — absence, the dead-code funnel |
| Where is the duplication? Is it safe to collapse? | [structure](./patterns/structure.md) — fingerprints, proving a collapse safe |
| Where do I cut to extract a service? | [structure](./patterns/structure.md) — articulation points, min-cut |
| What breaks if I change this? | [structure](./patterns/structure.md) — three-set blast radius |
| Why is only 3% of the program reachable? | [structure](./patterns/structure.md) — the entrypoint ladder |
| I have a second source (XML rules, schema, trace, coverage) — how do I merge it with the graph? | [channels](./patterns/channels.md) — the general merge procedure |
| What does this XML / properties / descriptor actually do? | [channels](./patterns/channels.md) — contract from the consumer |
| What SQL can this program issue? Which column does it write? | [channels](./patterns/channels.md) — forward reconstruction, holes |
| Which config keys exist? Which are dead, missing, or undeployed? | [channels](./patterns/channels.md) — inference from read sites |
| Is this class reference real? What is dangling? | [channels](./patterns/channels.md) — the four defect classes |
| Which form field reaches which column? | [channels](./patterns/channels.md) — routing, not name equality |
| How do I attach what I derived back onto the graph? | [channels](./patterns/channels.md) — tags vs schema extension |
| What are the business rules and their thresholds? | [structure](./patterns/structure.md) + [behavior](./patterns/behavior.md) |
| Does anything actually read what this computes? | [behavior](./patterns/behavior.md) — observability closure |
| There is no spec — how do I know this is wrong? | [behavior](./patterns/behavior.md) — metamorphic relations |
| Which tests should I generate? | [behavior](./patterns/behavior.md) — distinguishing inputs, config coverage |
| Is my finding real, or is it noise? | [behavior](./patterns/behavior.md) — calibrate the null |
| Where do I cut? What groups overlap? Should I cluster? | the **`code-graph`** skill — graph algorithms over an export |
| Is this threshold redundant? Do these configs behave the same? | the **`code-symbolic`** skill — z3, BDDs, sympy over extracted facts |
| **Should I be using a CPG at all?** | [when-not-to](./when-not-to.md) — **read this first** |

## Reference files

| File | Use when |
|---|---|
| [setup.md](./setup.md) | Building a graph worth trusting, and running the server. **Before anything non-trivial.** |
| [traps.md](./traps.md) | **Before trusting any number.** Ways Joern returns a plausible, non-empty, wrong answer. |
| [when-not-to.md](./when-not-to.md) | Measured negatives. If your question is here, use the cheaper tool. |
| [lsp-workspace.md](./lsp-workspace.md) | Type-checking queries before you run them. Worth it for long scripts and DSL discovery. |

| Script | What it does |
|---|---|
| `scripts/build-typed-cpg.sh` | Jars, test-tree staging, build, then checks its own work |
| `scripts/gq.py` | Server client that binds the CPG by name, so a concurrent load cannot redirect your query |
| `scripts/joernlib.scala` | The recurring traversals. Call `JL.*` — `gq.py` loads it on demand, `joern --script` takes `--import` |
| `scripts/merge-jsp.sh` | Compiles JSP pages to servlets and builds one graph over pages and source together |
| `scripts/export-graph.sc` | One extraction to flat TSVs — calls, modules, SQL, field access. Input for `code-graph`. |
| `scripts/new-query-workspace.sh` | Scaffolds a type-checked workspace, versions read off the installed jars |

## Provenance

Every claim here is measured, not recalled: ~35 probes against nine real Java codebases totalling 3.2M SLOC, under a protocol where each negative is classified by root cause and each claim verified against source. Several entries correct earlier ones.
