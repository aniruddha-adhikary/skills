# Structure — what depends on what, what is dead, where to cut

Call `JL.*` for the recurring traversals — `gq.py` loads `scripts/joernlib.scala` into the session the first time a query mentions it, and `joern --script` takes it via `--import`. The long traversals live there so they cost you nothing to read:

```bash
scripts/gq.py <cpg> -e 'JL.health(cpg)'        # root, files, methods, overlays
scripts/gq.py <cpg> -e 'JL.callEdgeDelta(cpg)'  # resolved vs declared, both directions
``` Against a resident server via `gq.py` the library is not loaded — use the inline traversals on this page, which run anywhere, and adapt them; the `JL.*` names tell you where the full version lives.

## Before any graph algorithm, check the two call-graph projections

*Everything below rests on the call graph being right. Two ways of reading it disagree, and the wrong one has been published as a finding more than once.*

```
JL.callEdgeDelta(cpg)   // resolved=… declared=… onlyResolved=… onlyDeclared=…
```

`methodFullName` is the **declared** target, so an interface call site collapses to one edge instead of fanning out to its implementations. It under-counts — and the two projections disagree in **both** directions, so neither alone is right. Use `JL.callEdges`, which resolves through `callee` and drops abstract declarations. Leaving those in inflates reachability straight back, because they are a large fraction of raw callee rows.

## Attribute nodes to modules

*Every module-level answer — coupling, ownership, extraction order — needs each node assigned to a module first. Get this wrong and every later count is quietly short.*

`JL.typeToModule(cpg)` and `JL.fileOfMethod(m)`. The fallback in `fileOfMethod` is not defensive padding: `<init>` and `<clinit>` report `filename == "<empty>"`, the literal string, so `.isEmpty` is false and whole modules come up short in every module-level count with nothing empty-looking to notice.

## Reconstruct the integration graph, not the call graph

**What you learn:** which parts of the system actually depend on each other, when they never call each other at all. **Why it matters:** in an enterprise system the real architecture is usually the data. Teams that share a table are coupled as tightly as teams that share a method, and nothing in the code says so — so extraction plans built on the call graph pick the wrong module first.

1. `JL.sqlStatements(cpg)`, then parse each with a real SQL parser for table names.
2. Build the module × table matrix, then reader→writer edges.
3. **Subtract the static call and type pairs.** What remains is coupling with no other evidence.

**Split DDL from DML**, or the module holding the bootstrap becomes a writer of every table.

This inverts extraction plans. Modules with a call-graph cut of *zero* turn out to have several foreign writers on tables they read, so a call-graph-only ordering picks the wrong module first.

Two censuses fall out of the same matrix: a table written and never read is an unenforced audit claim; a table read and never written means the reading predicate is provably false. **Refute a phantom five ways before publishing** — grep the name, check the DDL, check fragment-built names, check dynamic-SQL holes, check the bootstrap seeder.

## Query for absence

**What you learn:** that somebody built the Right Way To Do It and nobody adopted it. **Why it matters:** this is the highest-value thing to know before starting a cleanup, and it is the one question grep structurally cannot answer — grep finds occurrences, never their absence.

`JL.uncalled(cpg)`.

**Read the four preconditions in `when-not-to.md` first.** Each inverts the answer. Then run the funnel and **report the funnel, not just the survivors**:

```
raw zero-callIn  →  minus framework entrypoints  →  minus dispatch channels  →  survivors
```

Classify entrypoints by **type hierarchy**, not a name blocklist — a servlet callback counts only if the owner extends the servlet base class or a descriptor names it. The first two funnel stages, adaptable to whatever framework the codebase extends:

```scala
val entryOwners = cpg.typeDecl.internal
  .filter(_.inheritsFromTypeFullName.exists(_.contains("Servlet"))).fullName.toSet
val raw = cpg.method.internal.filterNot(_.name.startsWith("<"))
  .filter(_.callIn.isEmpty).l
val survivors = raw.filterNot(m =>
  entryOwners.contains(m.typeDecl.fullName.headOption.getOrElse("")))
(raw.size, survivors.size)   // report both ends of the funnel
```

Then rescue virtual dispatch: an internal supertype with the same name and arity that *is* called, or an external supertype plus a same-shaped call.

The entrypoint set is the part that does not automate. Deriving it from descriptors rather than typing it in moves the class-level answer sharply and the method-level answer barely, so **measure at the granularity you will report** or the verdict flips.

**Sample your own survivors for the trap rate.** A low global unresolved-signature rate does not mean low where your query looks: unresolved signatures concentrate on exactly the private helpers a dead-code query examines, so spot-checking the safest-looking subset is where you find that half of them have a caller in their own file.

## Give an abstraction a behavioural denominator

**What you learn:** how much of a migration is actually left. **Why it matters:** "12 classes extend BaseDAO" is meaningless without knowing how many *should*. The denominator turns a count into a completion percentage somebody can plan against.

Count the classes that do the thing — call into the JDBC API, emit log output, touch XML — then count how many of those use the abstraction, and report the ratio. The nominal denominator is greppable and useless; the behavioural one is where the gap is.

```scala
val doers    = cpg.typeDecl.internal
  .filter(_.method.call.methodFullName("java\\.sql\\..*").nonEmpty).fullName.toSet
val adopters = doers.filter(fn => cpg.typeDecl.fullNameExact(fn)
  .inheritsFromTypeFullName.exists(_.contains("BaseDAO")))
(doers.size, adopters.size)   // classes that touch JDBC vs. those that do it the Right Way
```

And **trust the hierarchy over the javadoc**. A grep for `extends BaseDAO` returned only hits inside `BaseDAO`'s own comment, describing a migration that never happened. A reader concludes "half migrated, here is why the rest stalled" — coherent, cited, wrong.

## Find duplication

**What you learn:** where the same logic lives in several places, and — more usefully — where those copies have silently drifted apart. **Why it matters:** a bug fixed in one copy and not the others is a live defect, and it is invisible to anyone reading either copy on its own.

`JL.fingerprint(m, level)` and `JL.cloneClasses(cpg)`. Level 1 keeps literals and names, level 2 erases them and keeps call names, level 3 is shape only. The parenthesised pre-order walk matters: without closing markers, `a + (b*c)` collides with `(a+b)*c`.

- **Level-2 equality is a machine-checkable certificate** that nothing but literals and names differ — the only proof in the clone family. It fires rarely; do not build a workflow that assumes it.
- For near-clones, shingle the level-2 token stream at k=4 and threshold Jaccard around 0.62. Lower and the try/finally skeleton fuses unrelated code into one cluster; report such a cluster as "this skeleton recurs", not as one duplicated function.
- **Verify your trivia filter by fingerprinting what it discarded.** It will confirm the intent — identical getters and setters — and also show you the real duplication it swept out.
- **Rank by fix asymmetry, not by size.** Take the union minus the intersection of each member's guard, control-structure and throw features. Real bugs sit in the middle of a size-sorted list and at the top of an asymmetry-sorted one.

Before collapsing clones you have to show the difference between them cannot change behaviour — call that property congruence. Prove it in three tiers and **never skip the middle one**: diff the bodies to find what differs; check `callIn` to see whether an input reaching that difference can actually occur, and whether a caller already guards against it; only then execute both versions. Congruence is a property of the clone class **plus its call context** — two bodies that differ can still be congruent because no caller ever exercises the difference, and identical-looking bodies can diverge on an input a new caller introduces. Mechanical congruence predictors err in both directions; the graph localises the obligation, it does not discharge it.

Mine below method granularity too. Frequent subgraphs over **statement-level** dependence find fragments recurring across otherwise-different methods, most of them in methods a whole-method clone detector calls unique. Mining at expression granularity is vacuous: the top pattern matches every method.

## Extract business rules

**What you learn:** the actual conditions under which the system does something, as one expression per outcome. **Why it matters:** this is what a rewrite has to reproduce and what nobody can state from memory. The rules are spread across a class hierarchy by design, and the thresholds are somewhere else again.

`JL.pathCondition(node)` gives the conjunction guarding a node, outermost first, with else arms negated, so `else if` chains materialise for free. Run it from every return and every effect site. To survey where the numeric rules live before extracting them one by one:

```scala
cpg.method.internal.ast.isControlStructure.controlStructureType("IF")
  .condition.code.filter(_.matches(".*[<>]=? *\\d.*")).dedup.l
// List("initialDelay >= 0", "period <= 0", "args.length >= 2", …)
```

Two failure modes, both silent and both producing plausible output:

- **Compare against the child you arrived from.** Walking up, you must ask which arm of each `if` you came out of. A pointer that lags by one never matches the else block, so every else arm is emitted un-negated and you get conditions like `SIDE_BUY.equals(side) && SIDE_SELL.equals(side)` — a conjunction nothing can satisfy, which is the tell that the polarity is wrong rather than the code being strange.
- **In guard-clause style the AST nesting is empty.** `if (x == null) return;` makes guards siblings, not ancestors, so the whole codebase reports as unguarded. Use `controlledBy` and take polarity from arm containment.

Thresholds are almost never literals in the condition. `JL.initConstants(cpg)` recovers them from the synthesised `<clinit>`; without that join your inventory is a small fraction of the real one. Group them by **value**, and the actionable output is a warning *against* deduplication — the same number is often two unrelated business quantities.

## Find the seam

**What you learn:** the narrowest interface between the piece you want to extract and everything else. **Why it matters:** it converts "we should break up the monolith" into a named list of methods and a facade size, which is the difference between a proposal and a plan.

Export the call graph and work outside — the one place where leaving the CPG is correct. `scripts/export-graph.sc` writes the TSVs and the **`code-graph`** skill has the algorithms, including which famous ones measurably fail here.

- **Articulation points, ranked by how many methods they detach.** The raw list is long and mostly noise; the ranking makes it usable.
- **Minimum node cut** for facade size, recomputed on three contractions: full, minus shared infrastructure, minus infrastructure and DTOs.
- Compare the call cut against the DB coupling before choosing an extraction order. They invert.

**Stop using boundary-edge counts to size a facade** — they overestimate by more than an order of magnitude. And betweenness centrality is a null on the same graph, because in a call graph the traffic is utilities. A cut answers "what must I break?"; centrality answers "what looks busy?".

## Size a blast radius honestly

**What you learn:** what a proposed change can reach, *and* what you cannot bound. **Why it matters:** every tool silently assumes a closed world and hands back one confident number. A reviewer can act on an admitted gap; they cannot act on a number that was wrong by three orders of magnitude.

Three sets, never one number: **must review** (single-target paths), **should review** (through a polymorphic site), **cannot bound** (unresolved sites plus everything upstream of them, with reasons).

The naive reverse-reachability answer understates by orders of magnitude, because external callers arrive through the interface. The gap is a property of the framework, not of the method — on a corpus with no container, the naive answer and the must-review set agree exactly.

**Bound at 2 hops and print the per-hop curve.** An unbounded closure reaches half a codebase and most of its files, and the blow-up regime is indistinguishable from the tractable one until you look at the curve. Report overrides alongside callers — a changed method reached only through an interface has no callers at all, and the override channel is the CPG's only real contribution.

## Model the framework, or measure almost nothing

**What you learn:** why your reachability number is single digits. **Why it matters:** in a container-driven application almost nothing is called from `main`, so a naive answer looks like a finding about the code when it is a fact about your entrypoint set.

Report which rung you are on:

1. `main` and declared targets only
2. plus descriptor-declared entrypoints
3. plus resolved dispatch through `callee` — **the largest single gain**
4. plus public methods of container-declared classes

Quote rung 3 as the conservative number; rung 4 is sound but its seed set can itself be a large share of the program. Exclude `<clinit>` from the denominator.

A synthetic corpus reads high at rung 1, so **any technique validated only there looks far less valuable than it is.**

## Separate vendored code from yours

**What you learn:** which source in the tree is actually a third-party copy. **Why it matters:** it is often a large share of the files, it distorts every codebase-wide metric, and nobody has a list.

Bucket typeDecls by package root and count references in and out. Outbound zero with inbound non-zero is vendored. This found a forked copy of a framework class sitting inside that framework's own package. No lexical method computes it — counting imports cannot distinguish "this tree imports the application" from "the application imports this tree".
