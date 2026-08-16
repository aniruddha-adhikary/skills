---
name: code-graph
description: Decide where to break a system apart, on evidence. Use when splitting a monolith, planning a strangler or service extraction, sizing the facade an extraction would need, finding seams or bounded contexts, judging which modules are genuinely coupled, grouping or clustering code — or when reaching for centrality, Louvain, community detection or clustering, since those measurably fail on code and this says what to use instead. Runs graph algorithms over an export from a code property graph; build one with the codebase-recon skill first.
---

# Graph algorithms on code

Decomposition questions — where to cut, how big the interface is, what genuinely overlaps — are graph problems, and graph theory answered them long before anyone asked an LLM. Export the code property graph and point the classical algorithms at it. Several famous ones fail badly on code; this says which, and what to use instead.

**Depends on `codebase-recon`.** Build a graph worth trusting and export it first:

```bash
scripts/build-typed-cpg.sh <src> out.cpg.bin --with-tests        # codebase-recon
joern --script scripts/export-graph.sc --param cpgPath=out.cpg.bin --param outDir=g/
```

That writes `calls.tsv`, `modules.tsv`, `sql.tsv`, `fields.tsv`. Everything here works on those, so you pay one extraction and then iterate in seconds.

**Key on `fullName`, never a node id.** Flatgraph ids are dense positional indices, so inserting one method renumbers a large share of the graph. And read the TSVs with `QUOTE_NONE` — a code column contains double quotes, and a CSV reader treats them as quotes even in a TSV and silently merges rows.

## Which of the three skills you want

They divide by **the shape of the answer you need**, not by tool:

| you need | skill | the answer looks like |
|---|---|---|
| to **locate or enumerate** — where is this, what calls it, what is missing, what does the config actually wire | `codebase-recon` | a list of methods, files and lines |
| to **cut or group** — where to split, how big the facade is, which parts genuinely overlap | `code-graph` | a boundary: a set of nodes to break, or groups that may overlap |
| to **decide** — is this redundant, are these two the same program, do these agree | `code-symbolic` | yes, no, or the exact set of inputs on which they differ |

The order is usually that order, and each hands the next its input. Build a graph worth trusting, export it, then either cut it or prove things about it. Going straight to the third without the first tends to mean proving something about code that is not the code that runs.

## What this actually finds

Concrete shapes, so you recognise one when you have it:

- **A whole subsystem hiding behind a single method.** An articulation point whose removal detaches a couple of dozen methods across a handful of classes — the natural first extraction, and it does not look special in any file.
- **A facade far smaller than the boundary suggests.** Counting the edges crossing a module boundary says the interface is huge; the actual minimum cut is a handful of methods. That is the difference between "we cannot extract this" and a two-week job.
- **Modules coupled only through a shared table.** No call edge, no type reference, nothing in the code says they are related — and changing one breaks the other. The call graph reports these as independent, which is worse than reporting nothing.
- **A table that is really three concerns.** A concept lattice splits it along the modules that touch each column, contradicting the declared schema — and each split is checkable against the queries.
- **An extraction order that inverts when you look at data instead of calls.** Modules with a call-graph cut of zero look free to extract; ranked by how many other modules write the tables they read, the ordering reverses. A call-graph-only plan picks the wrong one first.
- **A helper reimplemented privately in several modules.** Textually different, structurally identical, so a text or whole-method clone detector calls each one unique. Statement-level shape mining finds it.
- **A "god class" that does not decompose.** Worth knowing: when clustering hands back your package layout, that is usually the honest answer and not a tuning failure.

## The projection is the work; the algorithm is the easy part

None of this is Joern-specific. What decides your answer is **what you make the nodes and what you make the attributes**, and that is a modelling choice per question.

| your question | nodes | attributes or edges |
|---|---|---|
| where do I cut to extract this? | methods | calls |
| which modules are really coupled? | modules | tables read and written |
| what are the bounded contexts? | modules | `TABLE.COLUMN` touched |
| which classes belong together? | classes | fields accessed, or co-occurring calls |
| which methods do the same thing? | methods | token shingles of the erased AST |

**Attributes must be fine enough to overlap and coarse enough to share.** At table granularity a lattice restates "everyone reads the main table". At Java-field granularity nothing is shared at all, because fields are encapsulated by design. When the result is degenerate at either extreme, change the attribute set — not the algorithm.

**Run an overlap census before you cluster.** Take a grouping you already trust and count what fraction of objects belong to more than one group. Three lines. A high fraction means a partition has to arbitrate between memberships, and it does so silently: you get a clean answer that hides the conflict and act on half of it.

## What works, and what measurably does not

| you want | reach for | verdict |
|---|---|---|
| a seam to extract behind | articulation points, ranked by methods detached | **works** |
| the size of the facade | minimum node cut with a super-source and super-sink | **works** |
| groups that may overlap | formal concept analysis — a concept lattice | **works** |
| recurring shapes | frequent subgraph mining over dependence, at **statement** granularity | **works** |
| near-duplicate sets at scale | MinHash and LSH to block, then rescore exactly | **works** — costs recall, never precision |
| "the important nodes" | betweenness centrality | **fails** — ranks a DTO getter high; the traffic in a call graph is utilities |
| a decomposition | Louvain, Leiden, spectral | **fails** — hands back your package layout or your schema |
| overlapping communities | clique percolation | **fails** — splits nothing |

The pattern is worth internalising: **the small hand-rolled thing over an export wins; reaching for a famous algorithm loses.** Community detection assumes a partition exists, and code does not partition. Centrality assumes traffic implies importance, and in a call graph traffic means "utility".

## The two that need nothing but a call graph

**A seam, ranked by what it detaches.** The raw articulation-point list is long and mostly noise; the ranking makes it usable.

```python
import csv, networkx as nx
g = nx.Graph()
with open("g/calls.tsv") as f:
    next(f)
    for a, b in csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
        g.add_edge(a, b)
big = g.subgraph(max(nx.connected_components(g), key=len)).copy()
for a in nx.articulation_points(big):
    h = big.copy(); h.remove_node(a)
    frags = sorted(nx.connected_components(h), key=len, reverse=True)
    print(sum(len(f) for f in frags[1:]), a)      # sort on the first column
```

**The facade you would have to write.** Join a super-source to everything inside the group and a super-sink to everything outside, then cut:

```python
h = g.copy()
h.add_edges_from(("S", m) for m in inside)             # `inside` is your grouping —
h.add_edges_from(("T", m) for m in set(g) - inside)    # modules.tsv, or anything else
print(sorted(nx.minimum_node_cut(h, "S", "T")))
```

On one module that returns a 57-method cut against 409 boundary edges. **Do not size a facade by counting boundary edges** — it overestimates by an order of magnitude.

## Overlapping groups: a concept lattice

Ten lines, and it beat every clustering algorithm tried, because it lets an object sit in several concepts:

```python
import itertools
def concepts(ctx):                      # ctx: object -> set(attributes)
    objs, out = sorted(ctx), set()
    universe = set().union(*ctx.values())
    for k in range(len(objs) + 1):
        for combo in itertools.combinations(objs, k):
            attrs = set.intersection(*[ctx[o] for o in combo]) if combo else universe
            out.add((frozenset(o for o in objs if attrs <= ctx[o]), frozenset(attrs)))
    return out
```

It is exponential in the object count, so cap the objects and keep the attributes fine.

## Validate any ranking against a null from the same codebase

Score size-matched random groups with the identical statistic, a few hundred draws. This controls for vintage, house style and domain at once. It is what separates a metric that works from one that merely tracks size — and in one case it showed a proposed metric was *anti*-correlated with the ground truth, with every true positive scoring below its own corpus median.

A control that does not come out near 1.0 means the harness is wrong, not that you found something.

## Where to go next

- Structural questions that stay inside the graph — dead code, clones, blast radius — are in `codebase-recon`, `patterns/structure.md`.
- Questions the graph cannot decide — is this threshold redundant, do these configurations behave the same — are in `code-symbolic`.
