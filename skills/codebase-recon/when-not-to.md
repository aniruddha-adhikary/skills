# When not to build a CPG

Read this before you build. If your question is here, use the cheaper tool.

Every entry below is a measured negative, established on real codebases. This page holds the decision and the reason; the magnitude is not something you act on here.

## Decision table

| Your question | Verdict | Use instead |
|---|---|---|
| Which modules depend on which? | Do not build | ripgrep over import statements |
| Where is this constant duplicated? | Do not build | ripgrep |
| Which files group into components? | Do not cluster | pairwise edge weights, or FCA |
| Which classes are risky? | Do not rank | past churn and file size |
| Does the container narrow the call graph? | No | RTA, or keep the full closure |
| What tests does this business logic need? | Not MC/DC | configuration and order coverage |
| Can a slice become LLM context? | No | audit the context you already wrote |
| Is this framework code outdated? | Cannot be answered | scope the work instead |
| Is this method dead? | Yes, after four checks | see the four checks below |

## Do not build a CPG for a module graph

`javac` forces packages to match directories, so the module graph already sits in the file paths. Ripgrep over imports recovers it.

The CPG finds slightly **fewer** edges, because it drops unused imports. You would pay for a build and lose recall.

Check this if you analyze an old checkout. The package convention weakens the further back you go.

## Do not partition a graph you derived from code

A partition forces every object into exactly one group. Code does not divide that way: a column, a class or a file often belongs to several concerns at once. The algorithm then arbitrates, and it arbitrates **silently**. You get a clean answer that hides the conflict, and you act on one half of it.

Test for overlap before you cluster. Take a grouping you already trust, then count the objects that belong to more than one group. If many do, do not partition.

Use the edge weights directly. If you need groups, use FCA (Formal Concept Analysis), which lets one object sit in several concepts.

## Do not pick a coverage criterion from a standard

Measure the shape of your decisions first, then choose.

MC/DC needs decisions that combine several conditions. Business logic is mostly single-condition decisions, so the criterion finds nothing to vary. It then generates a large suite that misses the real defects.

Cover configurations and evaluation order instead. Business risk sits **between** decisions and **after** them, not inside one.

## Do not rank files by a structural metric

Complexity, fan-in and coupling do not predict where change lands. They track size, and you can measure size for free.

The metric is not the problem. A ranking needs an oracle. Score it against a future the model never saw, or join a second channel. Without an oracle, a ranking is a story.

## Do not prune the call graph with container wiring

A container is a **registry, not a restriction**. It records which implementation gets wired. It does not stop the others from being called.

Narrowing per injection point is worse, not better. A type-resolving container cannot leave an injection point ambiguous, because an ambiguous point fails at startup. Nothing is left to narrow.

Use RTA if you need a prune. It drops types that are never instantiated, and it needs no container.

## Do not slice a method to produce context

A slice omits what a business rule depends on most. Rules turn on constants, and constants live outside a dependence closure. The slice comes back with the logic and without the thresholds, and it reads as coherent.

Use a slice to audit context instead. Give it context you already assembled, then take the gap list: the constants and callees that the context names but does not contain. Nothing else produces that list.

## Do not label code as outdated from its shape

A "compensating machinery" constellation does not mean the code is old. Kubernetes controllers, the transactional outbox and sagas all match the same shape, and all three are modern and correct. The shape detects compensation for at-least-once delivery, which describes most distributed software.

Use the constellation to scope work instead. State the claim so a reader can check it:

> These N sites exist only to serve this channel. Replacing the channel deletes M of them. Here are the lines.

## Do not report code as dead until you do four checks

Absence is a real strength of a CPG. Ripgrep finds occurrences and never finds their absence. But each check below inverts the answer when you skip it.

1. **Build with dependency jars.** An unresolved call collapses to a stub, and the caller disappears from the graph.
2. **Stage the test tree.** The frontend drops directories named `test`, so no test can call anything.
3. **Subtract container-implemented interfaces.** Homes, proxies and injected fields have no implementer in the source, by design.
4. **Search the non-Java files.** Reflection, JSP pages, tag libraries and wire protocols call methods by name, so no call edge exists.

## Also refuted, one line each

- **Betweenness centrality to pick a seam.** Ranks a DTO getter 7th; the traffic in a call graph is utilities. Articulation points on the same graph do work.
- **Mining the PDG at expression granularity.** The top pattern matches every method. Collapse to statements first.
- **`reachableByFlows` for field-level questions.** Object-granular: any write to an object defines the whole object, so every value entering a bean reaches every getter. It deceives because it finds everything true *and* everything false.
- **A backward dependence closure to reconstruct a string.** The literals are in the closure; the branch structure is not, so it emits invalid strings as fact. Interpret forward.
- **`@Qualifier` or per-injection-point narrowing.** Worse than the coarser rule. A type-resolving container cannot leave an injection point ambiguous — ambiguity is a startup crash, not a pruning opportunity.
- **`@Profile` and bean-scope exclusion.** The population is empty on legacy corpora, and the `scope="request"` hits that look like it are Struts storage lifetime, which constrains no dispatch target.
- **Dormancy to predict deletion.** Worse than random. The best predictor of "will they delete this class" is that it is short — and that is inside the noise band.
- **Coverage preservation as the safety criterion for collapsing clones.** Every coverage-adequate suite missed the fault the collapse makes possible; the killing vector adds zero coverage.
- **Clone divergence as a predictor of inconsistent fixing.** The phenomenon is real; this flag does not select for it. Half its positives have a caller that null-checks.
- **A module-level "where is the debt" dashboard.** Churn share tracks code share in every corpus measured. It is `du -sh` with extra steps.
