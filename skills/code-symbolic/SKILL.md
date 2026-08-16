---
name: code-symbolic
description: Decide questions about a codebase's logic that reading and traversal cannot. Use for business rules, rule engines, thresholds, configuration profiles, feature flags, pricing or billing formulas, and duplicated or contradictory calculations — whether a threshold is redundant, whether two configurations are the same program and on exactly which inputs they differ, whether two formulas agree and what the difference costs, whether a computed value is even the right kind of thing, and to generate the test case that separates two things that should behave identically. Reaches for z3, an SMT solver, a binary decision diagram, an MDD, or sympy against real code. Not behaviour-driven development, Cucumber or Gherkin — "BDD" here means a binary decision diagram. Extracts its facts from a code property graph; build one with the codebase-recon skill first.
---

# Solvers and computer algebra over code

No amount of reading establishes that something holds for *every* input. Solvers and computer algebra have done that for decades. The graph finds where the logic is; z3, a decision diagram or sympy decides what it means.

**Depends on `codebase-recon`.** The graph finds *where* the logic is. These tools decide *what it means*.

## Which of the three skills you want

They divide by **the shape of the answer you need**, not by tool:

| you need | skill | the answer looks like |
|---|---|---|
| to **locate or enumerate** — where is this, what calls it, what is missing | `codebase-recon` | a list of methods, files and lines |
| to **cut or group** — where to split, how big the facade is, what overlaps | `code-graph` | a boundary, or groups that may overlap |
| to **decide** — is this redundant, are these the same, do they agree | `code-symbolic` | yes, no, or the exact inputs on which they differ |

Going straight to the third without the first usually means proving something about code that is not the code that runs.

## What this actually finds

Concrete shapes, so you recognise one when you have it:

- **A rule that cannot reject anything.** It implements the same interface as the rules that can, so it looks interchangeable — but its predicate has no path to a rejection and all it does is attach data. Found by flattening the hierarchy into one predicate per outcome; invisible from the class structure.
- **Two configuration profiles that are the same program.** One is then deletable, and you can say so with a proof rather than a shrug. The inverse is as common: profiles that look near-identical and differ on a set of inputs you can enumerate.
- **A threshold implied by another one, so it never fires.** Two guards on the same variable where one is strictly weaker. At scale these are usually the same guard written two ways in two files by two people.
- **One constant meaning two unrelated business quantities.** The same rate appears as a commission and as a spread; the same factor is a credit buffer and an exchange rate. The finding is a warning *against* deduplicating them, which is what a human reading a constants file would do.
- **A calculation that disagrees with itself across the codebase.** Subtract the two formulas and the residue is what the disagreement costs, per unit, symbolically — then join it to real rows for a figure. Keep the sign: under-charging and over-charging need opposite remediation.
- **A quantity multiplied as if it were money when it is a count.** Dimensional composition catches it; no test will, because the number looks plausible.
- **A tolerance check decided by floating-point representation rather than by the tolerance.** At exactly the boundary, whether it passes depends on the binary expansion of the inputs — so the same "10% rule" accepts some and rejects others.
- **A defensive check that is dead in production and live in one profile.** Reachability is configuration-dependent, so "dead code" is not a property of the code alone.

Before believing any of these, **check the site is reachable at all.** Several apparent live discrepancies turn out to be in code nothing calls — a shape, not a loss.

## Pick the right tool: z3 decides, sympy rewrites, a decision diagram canonicalises

This is the distinction people collapse, and it is the whole of choosing correctly.

| your question | tool | because |
|---|---|---|
| Can this ever happen? Does this guard imply that one? Give me an input that breaks it. | **z3** | it searches for a satisfying assignment over *all* inputs, and hands back a counterexample |
| Do these two expressions compute the same thing? What is the difference worth? | **sympy** | it rewrites algebra — subtract and simplify; the residue *is* the discrepancy |
| Is this expression shaped like *something × a rate*? | **sympy** matching | it pattern-matches the expression tree, so you find the shape without knowing the names |
| Are these two boolean rules the same function? On exactly which inputs do they differ? | **binary decision diagram** | equal functions are the *identical object*, so equality is free and the difference is a set operation |
| Is this computed value even the right kind of thing? | **sympy units** | it composes dimensions, so a product that is not money is a defect |

Rough rule: **if the answer is a yes/no about every input, that is z3. If the answer is another expression, that is sympy.** A decision diagram is what you use when you will ask the same boolean question many times and want equality to be a pointer comparison.

## The wire from a `.sc` to a solver

There is no library binding between Joern and any of these, and you do not want one. **The `.sc` says where and what; the tool says what it means; JSON Lines is the wire.** One fact per line, so the halves stay independently debuggable.

```scala
@main def exec(cpgPath: String) = {
  importCpg(cpgPath)
  val ops = Map("<operator>.greaterThan" -> ">", "<operator>.lessThan" -> "<",
                "<operator>.greaterEqualsThan" -> ">=", "<operator>.lessEqualsThan" -> "<=")
  cpg.controlStructure.controlStructureType("IF").condition.isCall
     .filter(c => ops.contains(c.name)).l.foreach { c =>
    val a = c.argument.l
    if (a.size == 2 && a(1).isInstanceOf[io.shiftleft.codepropertygraph.generated.nodes.Literal]
        && a(1).code.matches("-?[0-9]+"))
      println(s"""{"var":"${a(0).code.replace("\"", "'")}","op":"${ops(c.name)}",""" +
              s""""k":${a(1).code},"at":"${c.method.fullName}:${c.lineNumber.getOrElse(-1)}"}""")
  }
}
```

```
{"var":"AD_Org_ID","op":">","k":0,"at":"CalloutBankTransfer.fromBankAccount:209"}
```

**Keep `at` on every line.** It is what turns a proof back into a file you can open.

## z3 — proof by refutation, and the counterexample

You almost never assert what you want to be true. You assert its **negation** and hope for `unsat`, because "no input satisfies A and not B" *is* "A implies B".

```python
import z3
x = z3.Int("x")                       # Int, not Real: <=0 and <1 are the same set
s = z3.Solver(); s.add(x > 100, z3.Not(x > 50))
s.check()                             # unsat  =>  x>100 implies x>50, so the second guard is redundant
```

When it comes back `sat`, the model is the reason — and it is the thing to put in a report or a test:

```python
s = z3.Solver(); s.add(x > 50, z3.Not(x > 100))
s.check(); s.model()                  # [x = 51] — the input that separates the two guards
```

Run over every variable compared against a literal, this finds thresholds that are the same guard written two ways. On one real codebase: 7,203 comparisons over 2,567 variables, 248 proved implications, including pairs implying each other in both directions.

**`Int` versus `Real` changes the answer.** `x <= 0` and `x < 1` are the same set over integers and different over reals. Choose the sort that matches the declared type, or you will prove something about a program you do not have.

## sympy — same thing, written differently?

**Subtract and simplify. A zero residue is proof; a non-zero residue is the discrepancy, and it is the more useful outcome.**

```python
from sympy import symbols, simplify, Rational
qty, price, rate = symbols("qty price rate")

simplify(qty*price*rate - (qty*price)*rate) == 0      # True — same formula, different parenthesisation
simplify(qty*price*rate - qty*price*Rational(1,200))  # price*qty*(200*rate - 1)/200
```

That residue is the artefact to carry forward: it says *what the disagreement costs*, per unit, symbolically. Join it against real rows and it becomes a figure. **Keep the sign** — one side being under-charged rather than over-charged changes the remediation entirely.

Use `Rational(5,1000)`, never `0.005`. Float literals reintroduce the representation error you are trying to reason about.

For boolean rules, simplification is the canonicalisation:

```python
from sympy.logic.boolalg import simplify_logic
big, vip = symbols("big vip")
simplify_logic((big & vip) | (big & ~vip))            # big — the vip test never mattered
```

That is a whole class of finding: a condition that reads as two rules and reduces to one.

## sympy — matching a shape without knowing the names

When you want *every* place that computes "something times a rate", you cannot grep for it — the names differ everywhere. Match the expression tree instead:

```python
from sympy import Wild
w = Wild("w"); k = Wild("k", exclude=[qty, price])    # k must be a constant, not a variable
(qty*price*Rational(5,1000)).match(w*k)               # {w_: price*qty, k_: 1/200}
```

`exclude` is what makes it precise: without it the pattern matches almost anything. This is how you build the inventory — every commission, every fee, every discount — and then group by the matched constant to find the same rate written five ways, or five different rates that should be one.

## Binary decision diagrams — canonical booleans, so equality is free

**A binary decision diagram is a canonical form for a boolean function.** Not behaviour-driven development; nothing to do with Gherkin or `given/when/then`. Think of it as a compiled, deduplicated decision tree: fix an order over the variables, branch on each in turn, then share every identical subtree and drop every node whose two branches agree.

The payoff is that the form is **canonical** — two boolean functions that accept the same inputs compile to the *same graph*, whatever expression you started from. So equality of two rule sets is a pointer comparison rather than a proof obligation, and combining them is a graph operation:

- `A == B` — do these two configurations accept exactly the same inputs?
- `A & ~B` — the set of inputs A accepts and B rejects. Not a summary of the difference; the difference.
- counting or enumerating solutions is a walk over the graph, so "how many cases does this profile admit" is cheap.

That is why it beats calling a solver in a loop here: you pay once to build the diagram, then ask unlimited equality and difference questions for free. Use z3 when you need arithmetic or a single counterexample; use a diagram when the question is boolean and you will ask it many times.

```python
from dd.autoref import BDD
bdd = BDD(); bdd.declare("t_vol", "t_credit", "t_kyc")
A = bdd.add_expr("t_vol | t_credit")                  # rules registered in profile A
B = bdd.add_expr("t_vol | t_credit | t_kyc")          # profile B adds one
A == B                                                # False — they are different programs
list(bdd.pick_iter(B & ~A))                           # exactly the inputs B rejects and A does not
```

`B & ~A` is the difference *set*, not a summary of it — which is what makes this answerable rather than arguable.

## Generating test cases

The same machinery that decides also *generates*, and this is the highest-value thing you get for free. **A satisfying model is a test case. A proved implication is a test you do not have to write.**

**From a difference set — one test per input class that separates two configurations.** This is the strongest form, because each case is guaranteed to distinguish, and there is one per genuinely distinct behaviour rather than one per line:

```python
for m in bdd.pick_iter(B & ~A, care_vars=["vol", "credit", "kyc"]):
    print(m)          # {'vol': False, 'credit': False, 'kyc': True}
```

That single row is the whole obligation: the only input class on which those two profiles disagree. Ship one test for it and you have covered the difference exactly.

**From a solver model — a concrete input at a boundary you care about:**

```python
x, q = z3.Ints("price qty")
s = z3.Solver(); s.add(q > 50000, x > 100, z3.Not(q > 100000))
s.check(); s.model()                  # [price = 101, qty = 50145]
```

Constrain the region deliberately — just inside one threshold and outside the next — and the model lands where the behaviour changes.

**Then execute it.** A generated case is a hypothesis until it runs; see the section below on witnesses rejected by the real code.

**What not to generate for.** Coverage criteria are the wrong target on business logic. MC/DC needs decisions combining several conditions and business rules are mostly single-condition, so it generates a large suite that misses the real defects. Coverage preservation is also the wrong *safety* criterion when collapsing duplicated code: the vector that reveals the fault typically adds no coverage at all, so no coverage goal has any reason to produce it.

Cover **configurations and evaluation order** instead. Kill the dead dimensions first — the naive cross product is astronomically larger than the set of distinct programs, and CI usually exercises one of them. For ordering, derive the obligation rather than sampling: under first-failure semantics the number of distinct verdicts equals the number of rules that fail on that input, so the witnesses are constructive and permutation search finds nothing the bound did not already predict.

For oracles that need no correct answer — metamorphic relations, clone siblings — see `codebase-recon`, `patterns/behavior.md`.

## When your variables are not boolean

Everything above encodes each atom as true or false. That is right for a guard, and wrong for a configuration dimension with five settings, a status enum, or a priority level — encoding those as several booleans admits combinations the program cannot reach, and you then spend effort excluding them.

A **multi-valued decision diagram** is the same idea with a branch per value instead of two, and `dd.mdd` provides one alongside `bdd_to_mdd`. Reach for it when your atoms are genuinely n-ary and the boolean encoding is producing impossible states.

**Untested here.** Every result in this skill came from a boolean encoding; the multi-valued route is a reasoned recommendation, not a measured one. Treat it as a lead.

## Build the atom table once

Beyond single comparisons you need three extractions, and the third is the one people skip.

1. **One predicate per outcome.** `JL.pathCondition(node)` from every return and every effect site gives the guarding conjunction, outermost first, with else arms negated.
2. **The constants those predicates compare against.** `JL.initConstants(cpg)` recovers them from the synthesised `<clinit>`; thresholds are almost never literals at the comparison.
3. **An atom table** mapping each leaf to `(concrete condition, file:line, kind)` — where **kind** records what you cannot reason about: a database column, the clock, a config key, a call into another system.

Declare those leaves. Every claim downstream is conditional on them, and a report that does not name them is overclaiming.

## Layer them, in this order

**Prove the arithmetic in z3 first, then inject those facts as axioms into the boolean model.**

Boolean abstraction destroys `qty > 50000 ⟹ qty > 1000` — to a decision diagram those are two unrelated variables. Without the layering every threshold looks independent and no redundancy is findable at all.

```python
axioms = bdd.true
for ax in ["t_q100k => t_vol", "t_vol => t_q1k"]:     # each proved unsat-of-negation in z3
    axioms &= bdd.add_expr(ax)
diff = axioms & A & ~B                                 # now the difference respects the ordering
```

Scope each axiom to the layer it came from, or a fact about one pipeline stage turns up inside the witnesses for another.

Reachability is configuration-dependent: the same defensive check is unreachable under one profile and live under another. Do not call it dead code without naming the configuration.

## Then run the answer through the real code

A solver works in exact arithmetic and your program does not, so its answer is a hypothesis about the shipped code.

```java
if (Math.abs(fill / requested - 1.0) > 0.10) reject();
```

The solver produced `fill = 30.25, requested = 27.50` — exactly 10%, so the gate should allow it. Run it and the gate **rejects**: in IEEE-754, `30.25 / 27.50 - 1.0` is `0.10000000000000009`, which is greater than `0.10`.

1. **Execute every witness against the compiled code** before writing it down. Print CONFIRMED or REFUTED per claim.
2. **When it is refuted, do not discard it.** Sweep the neighbouring inputs; most are rejected at the boundary and some are not, and those are the reachable cases.
3. **Report a disagreement as a disagreement.** Where an exact-rational model of a rounding rule differs from the executed code, print both.

Run only the solver and you publish a case the code rejects. Run only the code and you never find the boundary worth sweeping.

## Two measured nulls

**SMT pruning of test vectors inside a single decision returns nothing** — a theorem, not a null. Unique-cause pairs on a flat condition are already the least-constrained vectors, so the criterion is self-pruning. Across rules it prunes heavily.

**Numeric optimisation on a linear path** agrees with the analytic answer. A cross-check on your model; not a finding.
