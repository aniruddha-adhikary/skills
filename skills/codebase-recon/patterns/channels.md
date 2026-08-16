# Channels — joining the graph to everything it cannot see

The CPG holds the languages its frontend parses and nothing else. Measure your gap first:

```bash
find <src> -type f | sed 's/.*\.//' | sort | uniq -c | sort -rn | head
```

On a typical enterprise Java project the XML, properties, JSP, TLD and SQL files rival the Java files in number, and the wiring, the schema, the thresholds and the entry points all live in that half. Confirm it: `cpg.file.name(".*[.]properties").size` is zero while `.java` is not.

## The rule that orders this page

> **Do not read the artifact first. Find the code that reads it, derive the contract from that code, then open the file.**

Write down two things the consumer tells you that the file cannot:

- **What the code does not do.** An attribute parsed and only printed. A file loaded and never parsed. That is where the defects are.
- **Whether the consumer parses the format the extension claims.** Files named `.xml` were read as raw bytes and never parsed, so a maintainer's comment shipped inside customer email.

When no consumer exists in the repo — a descriptor read by a container you do not have — the contract is the specification. You have lost your evidence base. Say so.

## Introduce a new graph, then merge — the general procedure

Nothing here is specific to configuration. A second source of facts about the program — a rule-engine XML, a DB schema, a coverage report, a git log, a runtime trace — enters the analysis the same way, and every section below is an instance. When you meet a source these pages do not cover, run the procedure, not an analogy to JSP or SQL:

1. **Parse the artifact with a real parser for its format.** XML parser, SQL parser, a normaliser plus an HTML parser — never a regex over markup. The output is a graph of its own: the artifact's nodes, and every name it references.
2. **Choose the identity key the two graphs share.** A fully-qualified class name, a reversibly-encoded path, a `(table, column)` pair, a symbolic name resolved through a second descriptor. Prove the key on a sample before joining — print its ambiguity rate; a key that is only mostly unique silently mis-links.
3. **Merge or join on that key.** If the foreign language *lowers to the host language* — a template compiler, a code generator — run that step and rebuild **one** CPG over its output plus your source: names become resolved call edges and the join disappears. Otherwise keep two graphs and join: build the derived edge list keyed on step 2.
4. **Attach what you derived onto the CPG** so later queries cross the boundary in one traversal — tags for per-node facts, an edge list traversed alongside `JL.callEdges` for flows that alternate between the graphs (see "Attach what you derived" below).
5. **Validate the merged model before using it.** Classify every foreign name as resolved / correct-external / absent, and confirm a handful of links you know are real resolve — an unvalidated merge fails silently, exactly like a bare CPG.

Prefer merge where a compiler exists; it turns a name-equality guess into a resolved edge. Everything else is a join.

## Find the reader sites

**What you learn:** what the configuration vocabulary actually is, as opposed to what the files happen to contain. **Why it matters:** this is the list every later join needs, and it is the step where grep gives a wrong answer that looks complete.

`JL.readSites(cpg, "getProperty", "getAttribute", …)` returns `(receiverType, literalKey, location)`.

**Group by receiver type.** That grouping is the reason to use a CPG here rather than grep: one reader name serves several unrelated contracts — DOM element, HTTP session, and the application's own context all answer to `getAttribute` — and a contract that merges them is wrong. Grep cannot separate them and cannot tell you which receivers it failed to resolve. The traversal, adaptable to any reader name:

```scala
cpg.call.nameExact("getAttribute").l
  .map(c => (c.receiver.evalType.headOption.getOrElse("?"),
             c.argument.isLiteral.code.headOption.getOrElse("<dynamic>")))
  .groupBy(_._1).view.mapValues(_.map(_._2).distinct).toList
// (jakarta.servlet.http.HttpSession, List("LOGINTIMESTAMPSET", …))   ← auth contract
// (org.jdom2.Element,                List("selected", …))            ← XML contract
// (jakarta.servlet.jsp.PageContext,  List("searchresults", …))       ← page contract
```

Each receiver type is a separate contract; the `<dynamic>` entries are the keys a literal-only extraction loses (see below). For plain config keys the shape is simpler — the key is argument 1, the default argument 2:

```scala
cpg.call.nameExact("getProperty").argument(1).isLiteral.code.dedup.l
```

| you want | ask |
|---|---|
| which files are read | `JL.resourcesRead` |
| config keys | `getProperty` — arg 1 is the key, arg 2 the default |
| XML elements and attributes | `getElementsByTagName`, `getAttribute` |
| template tokens | find the substitution method, read literals at its `callIn` sites |
| SQL | `JL.sqlStatements` |

**Literal-only extraction under-reports silently.** Resource names and keys arrive as `static final` constants. `JL.constOf(cpg, type, field)` resolves them through the synthesised `<clinit>`; for a parameter, walk `method.callIn` and take the actual at the matching index. The keys that hide this way are disproportionately the interesting ones — kill switches and flags that reverse a control flow.

## Treat non-resolution as the product

**What you learn:** the wiring defects — a declared class that does not exist, a key nothing reads, a key nothing provides. **Why it matters:** these are latent runtime failures and dead configuration that no compiler and no test will ever report.

Join every declared name against the symbol table and report all four differences.

| pattern | meaning |
|---|---|
| file declares a name, no CPG node | latent `ClassNotFoundException` |
| file provides a key, nothing reads it | dead config; edits do nothing |
| code reads a key, no file provides it | undocumented required config |
| code names a table or class, nothing declares it | runtime failure |

Report a resolution **rate with its denominator** and list every failure. Classify each before shipping it — a defect in the target, a correct external, or your parser being wrong — and never ship a list that mixes the three.

**A fifth class the set difference cannot see: read but inert.** An attribute is read, assigned, and its only use is concatenation into a log line. Declared-versus-read says "fine". Only following the value to its uses, and finding none in a condition, shows that setting it to `false` does nothing.

For class references, classify **four** ways — resolved, JDK, jar-on-disk, **absent**. A two-way split is meaningless, because "we resolved it" and "we have the code" are different questions and the gap between them is the thing you want. Build the symbol table from source, not from a CPG, or the dropped `test` tree corrupts it.

## Reconstruct dynamic strings forward, never backward

**What you learn:** the set of queries a program can actually issue, when the SQL is assembled at runtime. **Why it matters:** reading the literal at the sink recovers almost nothing, so without this the entire data layer of an enterprise application is opaque.

Fold an environment of possible values forward in control-flow order: cross-product at concatenation, union at joins, unroll constant loops, cap and mark unbounded.

- **Emit a named hole, never a guess and never a failure.** A hole is a numbered placeholder standing where a value cannot be determined statically — `SELECT * FROM orders WHERE status = '__HOLE_3__'` — with the reason recorded against the number. Keep the text around it. Returning nothing whenever a leaf is non-literal reports the whole interesting population as unresolved; inventing a concrete value is a false positive.
- **A hole in the query *text* is an injection candidate.** A bind slot is a `?`; a hole is a value the program splices into the SQL string itself. You get that list for free from the reconstruction.
- **Bind parameters per call site as a correlated tuple**, not as a per-parameter product, which invents rows the program cannot issue.

**Group concatenated literals into runs of near-consecutive lines — gap ≤ 2 — before any regex.** Joining every literal in a method welds unrelated statements together and invents table names out of error messages. A count looks fine; print the names.

Then parse with a real SQL parser, substituting a distinct marker per bind slot so each maps to `(table, column, role)`.

## Look for the same declaration in a second place

**What you learn:** whether "this is declared nowhere" is true. **Why it matters:** it is the easiest false finding to publish, and the corrected version is usually sharper than the wrong one.

Before writing "X is declared nowhere", enumerate every place a declaration could live — **including inside the code**. `CREATE TABLE` and `ALTER TABLE ADD COLUMN` in Java string literals are a real schema source. Skipping this produced a confident, specific, plausible, false finding; the corrected version was sharper, because the gap between the checked-in DDL and the code turned out to be exactly the compliance surface.

Where the schema is migrations, replay them **in version order and, within a file, in statement order**. Applying all the adds, then all the renames, then all the drops loses columns.

## Attach what you derived to the graph

**What you learn:** nothing new — this is how you keep what you already found. **Why it matters:** once config facts are on the nodes, structural and configuration questions can be asked in one traversal instead of joined by hand every time.

`JL.tagMethods(cpg, rows)` — it indexes nodes into a map first, because a per-row lookup scan is quadratic.

- **Query tags from the node side**: `cpg.method.where(_.tag.name("X"))`. The reverse does not exist and is the usual compile error.
- **`save` writes into the workspace project, not back into the `.bin`.** Delete the workspace between tagging and querying and every query returns zero with no error. Abort on `cpg.tag.size == 0`.
- **Tags or a schema extension?** Ask whether you need to walk the link *transitively*. If not, tags — they cost nothing and survive save and reload. An extension costs a patched jar and a rebuild, and buys a traversable typed edge.

## Infer the config schema from read sites

**What you learn:** the configuration the system genuinely requires, including the parts that appear in no file. **Why it matters:** a module reading keys nobody ships runs on defaults in production, and reading the config files cannot tell you that.

Propagate forward from each read site on three channels — intra-procedural reaching-def, cross-method field use, and the literals passed to each use — and classify each use into a constraint: legal value, type, prefix, class name.

**Do not classify on `call.code`.** A literal receiver renders as `this`, so `"true".equals(x)` reads as `this.equals(x)` and the legal value is invisible. Read `call.argument`.

This finds what the files cannot state: **keys with no file at all**, so that module silently runs on defaults while everything else is configured; and **a file maintained but never deployed**, because one module's build target lacks the copy step, so every reader takes its null branch and a subsystem is dead. Reading the file tells you the opposite of what happens.

Which file wins is decided outside every artifact, by classpath order in the build file. Report the ambiguity; do not claim to resolve it.

## Compute what only runs under a non-default setting

**What you learn:** which code paths no shipped configuration can reach. **Why it matters:** it separates dead code from code that is merely switched off, and those need opposite responses.

Seed with names assigned from a read site, then expand **once**, by two rules only: value flow, and a flag latched to a literal inside an already-gated arm. Anything looser drags in every local variable and finds nothing new. Then flag callees whose only call site in the whole graph sits inside one arm.

Require the call to appear *after* the guard before treating the rest of a method as the implicit else, or you will report code that runs in both configurations.

This is what surfaces **a flag masked by another flag** — a branch that cannot execute in any shipped configuration because an earlier gate returns first.

## Annotations are in the graph

**What you learn:** on a modern codebase, the persistence mapping and much of the wiring, without parsing anything. **Why it matters:** it is the cheapest channel available and people skip it because they assume annotations are lost.

`cpg.annotation` is populated with parameters intact. Check the count before concluding anything: a modern corpus has thousands, a 2002 one has none.

**Match on `.name`, never `.fullName`** — the frontend guesses the package, scattering one annotation across several bogus prefixes.

On an ORM codebase this replaces the SQL channel: the table, the column and its width come from annotations in one step, and chains end at a column rather than a bind slot.

## Code your frontend never sees, but a compiler can produce

**What you learn:** the behaviour of everything that is *generated* rather than written — templates, schema bindings, service stubs, mappers. **Why it matters:** it is program logic like any other, it is often where the inputs enter, and a source-only analysis reports it as absent rather than as unknown. Every "who reads this input" and "is this method dead" answer is wrong by however much of the application is generated.

**The rule: if an artifact has a compiler that emits a language your frontend parses, run the compiler and analyse its output.** You do not model the artifact. You do not write a parser for it. This applies to far more than templates:

| artifact | its compiler emits | so |
|---|---|---|
| a template language | host-language source | compile the pages, merge the result |
| `.proto`, IDL, WSDL, XSD, OpenAPI | client and model classes | the build already generates them |
| annotation processors — mappers, builders, DI components | source, at compile time | same |
| a grammar | a parser | same |
| a dependency you only have as a jar | nothing — but it is already bytecode | use a bytecode frontend instead |

### Check whether the build already produced it

Do this before compiling anything yourself. Generated sources land under `target/`, `build/` or `generated-sources/` — and **those are among the directory names the frontend silently drops**, so generated code is invisible twice over: absent from your source tree, and excluded even when present. Point the frontend at the generated directory explicitly, or stage it alongside the hand-written source before building the graph.

### Merging what a compiler produces

Build **one** graph over the generated code and your own source together, so the calls between them are ordinary edges rather than a join you maintain.

**Test provenance before relying on it.** You need to get from a generated method back to the artifact a human edits. That works when the generator encodes the source path reversibly in the name — Jasper's `tools.edit_002ditem_jsp` is `tools/edit-item.jsp` — and fails when it emits line directives your frontend discards. Check which you have before you build a report on it.

**Expect to iterate; that is the method, not a failure.** These compilers fail all-or-nothing per unit, and one unmet dependency commonly blocks hundreds at once. Attempt everything, bucket the errors by cause, fix the largest bucket, repeat. Two repairs generalise:

- **A missing declaration is a search problem, not a build problem.** The compiler resolves helper declarations off the classpath; in a multi-module repo the file it wants is a sibling module or inside a jar. Find it anywhere in the tree and put it on the classpath.
- **A missing class can be stubbed from whatever declares it.** The compiler needs the class to exist and expose the declared surface — not to work. The declaration file states exactly that surface, so generate the stub rather than building the real thing.

**Partial output is still worth merging.** The units that did compile are real methods in the graph. Report the ratio alongside any finding that depends on them.

`scripts/merge-jsp.sh` is this loop implemented for one instance, JSP — it prints the error buckets and generates stubs from the tag descriptors. Read it as the worked example when you need to do the same for another generator:

```bash
scripts/merge-jsp.sh <webapp-dir> out.cpg.bin --src <app-src> --project <repo-root>
```

### When there is no compiler you can run

Normalise, then parse. Blank every non-host construct — the delimiters and everything between them — with the *same number of spaces*, so byte offsets and line numbers survive and still point at the original file. Then hand the result to a parser for whatever the file now looks like.

Skip the normalisation and a lenient parser silently loses most of your files and exits zero, because one unmatched delimiter turns the rest of the document into a single text node.

Where both routes were measured on the same input they produced the same end-to-end result. Compiling earns its place on per-record correctness and on resolving where things are dispatched to, not on completion rate — so if the cheap route answers your question, take it.

## Resolve the stringly-typed seam by routing

**What you learn:** which reader receives which form field. **Why it matters:** matching on name alone is right about half the time, which is worse than useless because the wrong half looks exactly like the right half.

`request.getParameter("clientId")` links markup to code by a *literal*, not a symbol, so the obvious join is on the name — and **name equality alone is a coin flip.** Resolve the form action through the deployment descriptor to a class, keep only readers in that class, and the join becomes exact. Keep filter mappings out of the routing table, or one wildcard filter claims every form in the application.

Where the codebase reads parameters through its own helpers, discover them structurally to a fixpoint: a method is an accessor if it passes **one of its own parameters at the name index** of a known accessor. Positional precision is not optional — "any argument matches" pulls in a third of the codebase.

## Framework contracts

**What you learn:** what the framework does with each attribute in its config. **Why it matters:** without it you are guessing at the semantics of the file that decides how the application is wired.

Three tiers, cheapest first.

1. **The interpreter ships with the application.** Read its reflection call sites. They give you the class, the method, the parameter types, whether it must be static, and what the return value means. The dispatch table is itself data in the corpus, so nothing is assumed. Start here.
2. **The framework is a jar.** Build a CPG of the bytecode, then run dataflow from each reflection sink back to the config-model getters. Use reachability, not one-hop dataflow, which finds almost nothing and looks like a tool limit. Do not text-parse a disassembly — one such parser shipped three silent bugs, each a plausible non-empty wrong answer.
3. **Hand-write it**, and record that you did.

Know the boundary: derivation works when the parser's intermediate store is **a descriptor on disk**, and fails when it is a **runtime map** the engine reads back later. A better dataflow engine does not close that gap.

**When the descriptor is not wiring but logic** — an XML rule engine, a workflow definition, anything where the file decides *order and branching* and the Java only supplies step bodies — the program is split across two languages and neither half analyses alone. The call graph shows every handler reachable from one dispatch loop and none of the real control flow; the XML shows the flow and none of the behaviour. Run the general procedure from the top of this page with the engine's contract as the identity key: derive which element attribute names a class, what order the engine visits nodes in, and what a returned value makes it do next, then materialise the descriptor's edges onto the graph — tags on the handler methods, or an edge list you traverse alongside `JL.callEdges` — and trace flows over the merged model. Any path, reachability or dead-code answer computed on the Java half alone reports the XML half's logic as absent.

Contracts are stable across major versions, so version per config-schema family, not per release. Detect the schema by **root element, not filename** — a glob for the conventional filename finds almost none of a real project's config files. And separate "is this my schema?" from "is this framework running?": a jar on the classpath is not evidence of use.

## What config buys, and what it does not

*Set expectations before you spend effort here — most of what the config channel gives you does not look like a call edge.*

**Most config wiring is injection**, which adds no call edge at all. Its value is *negative knowledge*: it invalidates "never assigned", "dead setter" and "always null" on every container-managed field. Any evaluation scoring a config channel on edges recovered scores its largest contribution at zero.

When a descriptor's value is itself a symbolic name, look for a second descriptor that defines it before calling the reference dangling — frameworks routinely resolve one config file's names in another. A one-hop model reports masses of dangling references that are not dangling, and the second hop usually also pins the exact method.

And distinguish **absent from the descriptor** from **never registered**. Two analyses independently concluded a rule never fires when it was registered unconditionally in Java, outside the config path.
