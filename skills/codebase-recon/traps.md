# Traps — where Joern lies to you

Every trap here returns a **plausible, non-empty, wrong answer** with no error. A missing capability is visible; a silent wrong number is not.

**This page holds the traps that bite any query, whatever you are doing.** Traps tied to one technique live with that technique — else-arm polarity in `patterns/structure.md`, vacuous relations in `patterns/behavior.md`, node-side tag queries in `patterns/channels.md` — because you need the warning where you would trip, not one file away. Read this page once before your first query; read a pattern page when you use it.

Two evidence levels. Most were re-tested on nine real Java codebases and held on all nine, so they are properties of the tool. Four are newer and reproduced only once or twice while building this skill: the `whereNot` emptier, the `<clinit>` line span, overlay loss across an unload, and unresolved signatures concentrating where a dead-code query looks. The mechanism is clear in each; the prevalence is not.

---

## The five that will bite you first

### 1. A bare CPG has no overlays, and every graph query silently returns zero

```scala
cpg.metaData.overlays.l    // List() on a raw javasrc2cpg output
```

With no overlays, `cpg.call.method` returns nothing for **every** call, `callee` is empty, there is no CFG and no dataflow. The `joern` REPL applies `DefaultOverlays` on import, which is why interactive use hides this and scripted use does not. `joern-parse --overlaysonly` NPEs in 4.0.604; `DefaultOverlays.create(path, 4000)` works.

> **Check `cpg.metaData.overlays.l` on any CPG you did not build yourself.** An empty list explains an enormous class of "the graph says there is nothing there".

> **Overlays can also be lost after the fact.** Unloading a project from a resident server and reopening it strips them — the graph comes back with an empty overlay list and no call edges, while method and call counts are unchanged and look perfectly healthy. `importCpg` re-applies them; `openProject` does not. **Re-check after any load, not only after a build.**

### 2. Count call edges with `callee`, never `methodFullName`

```scala
call.methodFullName   // the single DECLARED target
call.callee           // the actual resolved set
```

An interface call site fans out to every implementation, but `methodFullName` names only the interface. Counting it produced a published claim that a graph was inverted; the real gap was a fraction of the reported one.

**The fix over-corrects.** A large share of `callee` rows are abstract declarations rather than implementations, and counting those inflates reachability straight back. Filter them — and note that `_.isAbstract` does not exist:

```scala
val isAbstract = (m: io.shiftleft.codepropertygraph.generated.nodes.Method) =>
  m.modifier.modifierType.exists(_ == "ABSTRACT")
cpg.method.internal.flatMap(m => m.callee.internal.filterNot(isAbstract).dedup)
```

### 3. `.code` is a lossy rendering — never key on it

The receiver is dropped in three distinct syntactic positions, including a string-literal receiver (`"C001".equals(x)` renders as `this.equals(x)`) and an assignment right-hand side. On any real codebase this makes masses of distinct calls render identically, so one `.code` string conflates genuinely different calls.

> **Any analysis that hashes, fingerprints or clone-detects on `Call.code` conflates calls.** Read the receiver from `call.receiver` or `call.argument`. Match on `name`, `methodFullName`, `typeFullName` — structured properties, never a regex over rendered text.

### 4. `javasrc2cpg` silently drops nine directory names

Exact, case-sensitive path components, read out of the frontend's own bytecode:

```
.git  .mvn  .gradle  build  target  out  node_modules  .idea  test
```

`build`, `target` and `out` are defensible. **`test` is not**, and `src/test/java` is the standard Maven layout. Staging the test tree raises the internal method count by roughly half on an ordinary Maven project. Exit code 0, empty stderr, no warning.

Consequence: **a method called only from tests is indistinguishable from a dead one.**

Rename the outer `test/` *and* any `…/test/` package directory before building — `scripts/build-typed-cpg.sh --with-tests` does this and restores the tree on exit. To detect it afterwards, compare counts:

```bash
find <src> -name '*.java' | wc -l          # against cpg.file.name(".*[.]java").size
```

**Arithmetic that closes tells you what was dropped; arithmetic that does not is a finding of its own.**

> **Watch the direction of any ratio you are handed.** Staging raises the count by about 1.45×, which is a **30% loss**, not a 45% one. Both figures reached this file the wrong way round before being remeasured. Ask whether a percentage is *of the true total* or *of the smaller number*.

### 5. Without dependency jars the graph looks *more* precise, not less

The intuition is that missing types produce a fuzzy, over-approximated callee set. **The opposite happens.** Virtually every unresolved call resolves to exactly one callee — a body-less `<unresolvedSignature>` stub.

So the graph is **degenerate**: reachability shrinks, fan-out drops, every precision metric improves, and nothing looks wrong. **Resolve dependencies first**; see `setup.md`, which measures whether it worked.

Scope note: `--inference-jar-paths` fixes call *signatures*, not library *structure*. A framework class still has no methods and no members; framework **behaviour** needs `jimple2cpg` over the jar itself.

---

## The rest

**`whereNot(_.isExternal)` silently empties the traversal.** The no-arg accessor returns a non-empty iterator, which `whereNot` reads as "matched", so everything is filtered out. Use `.internal` or `.isExternal(false)`. The generalisation matters more than the instance: **inside `where`/`whereNot`, a step yielding a collection is truthy, so a no-arg property accessor inverts your filter rather than applying it.**

**`cpg.file.size` is not a file count.** The overlay pass adds one synthetic node, so the total is always one more than the source files — and that phantom exactly fills the gap left by one excluded file, which makes a wrong count look right. Count `cpg.file.name(".*[.]java").size`.

**`javasrc2cpg` emits no `INTERFACE` modifier.** Filtering on it reports zero interfaces in a codebase full of them. Token-test the declaration header in `TypeDecl.code` — that field holds the header, not a body rendering, so the usual `.code` warning does not apply here.

**Filter `isExternal(false)` before counting anything type-shaped.** `cpg.method.parameter` includes synthetic external stub parameters, which are `ANY` by construction. That produced a published claim that a quarter of a program was untyped; the internal figure was zero, and no jars were needed.

**`<unresolvedSignature>(N)` collapses overloads.** Genuine overloads resolve to one name on a jar-less graph, so type-resolution failure erases overload identity. Add `lineNumber` to any key, or supply jars.

**Field reads are not `identifier` nodes.** `cpg.identifier.name("MAX_SIZE")` returns nothing for a field; it is an `<operator>.fieldAccess` call. Almost no `static final` constant ever appears as an identifier, and the empty result reads exactly like "this does not occur".

**Constants live in a synthesised `<clinit>`.** Field initialisers are moved into a per-class `<clinit>`, so no intra-procedural closure reaches them — a slicer will report the constant unreachable. Use `JL.constOf`, and note it is incomplete on its own: a constant can live in a supertype.

**`<clinit>.filename` is the literal string `"<empty>"`, not `""`.** So `.isEmpty` returns **false** and the obvious guard silently fails. Use `meth.typeDecl.filename`. *An imprecise description of this trap once caused the bug it warns about.*

**A synthesised `<clinit>` spans the whole class body.** Its line range covers the class, not the initialisers, so summing method line spans double-counts every class with a field initialiser, and every git hunk appears to touch it. Exclude it from size, density and line-range matching.

**Every `<clinit>` has zero `callIn`.** The JVM invokes it; no source calls it. A naive dead-code query emits one false positive per class with a field initialiser. `<init>` is not affected.

**Explicit `static {}` bodies are dropped.** Field initialisers reach `<clinit>`; explicit static blocks do not. Anything registered only there looks never-constructed. `javap` recovers it, but only where compiled classes exist — which on legacy code is usually nowhere.

**`annotation.fullName` is import-guessed.** Annotations are retained with their parameters, and field injection is fully recoverable, but the frontend guesses the package and scatters one annotation across several bogus prefixes. **Match on `annotation.name`.**

**A low global unresolved rate does not mean low *where your query looks*.** Unresolved signatures concentrate on private generic helpers, which is exactly the population a dead-code query examines — so a graph with an excellent overall rate still had a caller, in its own file, for half of the private zero-caller methods sampled. Two causes: a self-call rendered as an unresolved stub, and dropped `static {}` blocks leaving no call node at all. **Sample your own result set for the trap rate; the graph-wide average measures a different population.**

**Generic interfaces defeat signature-equality matching, silently.** Pairing an interface method with its implementations by comparing signatures drops every generic one: the frontend erases the parameter type on the declaration and keeps the concrete type on the implementation, so the signatures differ and the pair vanishes with no error. Match on name and **arity**.

**Modifier sets differ per frontend.** `cpg.method.isPublic` matches nothing on Python, because `pysrc2cpg` emits only `VIRTUAL`. Ask what your frontend emits before filtering: `cpg.method.internal.map(m => (m.name, m.modifier.modifierType.l)).l`.

**A static method inherited from a superclass is not linked.** The call resolves only to a stub, so "who reads this parameter" comes back empty for most of its call sites. Fall back to a simple-name match when a callee is a body-less stub.

**`reachableByFlows` is object-granular: any write to an object counts as defining the whole object.** `order.setClientId(x)` counts as a definition of `order`, so every value entering a bean reaches every getter. Recall is perfect and precision is terrible, which is why it deceives — it finds everything true *and* everything false. For a field-level question, follow the specific field's accesses instead of asking object-level flow to answer it.

**Joern and the JVM name anonymous inner classes incompatibly.** Breaks any join against JaCoCo, `javap` or a stack trace, and the mismatch reads as *unsoundness* rather than as a naming difference.

---

## The server, not the graph

**The server is shared mutable state.** A load-then-query is two round trips, and a concurrent `importCpg` reassigns the active CPG in between. This produced a published wrong number. `scripts/gq.py` avoids it by binding the CPG by name; if you must hand-roll, return the graph's identity inside the payload query:

```scala
cpg.metaData.root.l.mkString   // returned alongside your result, in one call
```

---

## The pattern behind all of these

Every trap above is the same mistake: **trusting a rendered or derived view instead of the structured source.** `.code` instead of `receiver`. `methodFullName` instead of `callee`. A node id instead of `fullName`. A reopened project instead of a freshly imported one.

The defence is a habit, not a checklist: **when a result is empty, prove it against a known positive before believing it; when a result is a number, ask which derived view produced it.**
