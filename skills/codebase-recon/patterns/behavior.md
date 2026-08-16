# Behavior — what the code computes, what escapes, and how to know you are right

Static structure tells you what *can* happen. Use this page when you need what *does*, and when there is no specification to check against.

## Ask what the code can observe, not what it computes

**What you learn:** which computed values can never reach anything a user, an auditor or another system sees. **Why it matters:** code that computes the right answer into a place nothing reads passes every test that asserts on return values — and that is a shape real billing and compliance defects take.

The output is what escapes: a row written, a message sent, a line logged.

Declare the observable set explicitly and **prove each borderline member** rather than assuming it — a state-setter counts only if something reads it back. Then close backwards from each sink over control and data dependence, and iterate to a fixpoint so a callee's return becomes observable once the call lands in a caller's closure.

Three closures that look right and are not:

- control dependence alone misses everything mediated by data;
- a closure that never ascends the AST loses **every value produced by a call on an assignment's right-hand side**;
- a closure following only return values cannot see an instance-field channel.

The payoff is a question worth more than coverage: *which computed values can never reach a boundary?* One system computed a negotiated rate into a context nothing read, while billing used a different source — under a suite that asserted the discarded value and passed.

The cheapest instance needs no closure at all — methods whose return value every caller throws away (a call used as a bare statement has a `Block` parent):

```scala
cpg.method.internal
  .filterNot(m => m.methodReturn.typeFullName == "void" || m.name.startsWith("<"))
  .filter(m => m.callIn.nonEmpty && m.callIn.forall(c => c.astParent.isBlock))
  .fullName.l
// surfaces boolean success codes that no caller ever checks
```

**Compare effect traces, not verdicts.** A compliance defect showed up as the audit trail emptying while the accept/reject decision stayed identical.

## Widen the observation before inventing a new experiment

**What you learn:** defects that were already inside an experiment you ran, outside what it looked at. **Why it matters:** it is the cheapest move available. You re-run the same inputs and compare more of the output.

Take a relation or diff that holds, add the next persisted artefact to what you compare — the reason string, the audit table, the ledger row — and re-run the *identical* pairs.

A relation that held on every permuted run of the verdict failed on a large share of the same runs once the reason string was observed, and on nearly all of them once the audit table was. The defect was already inside an earlier experiment, outside its projection.

A narrow result that holds is not wrong; it is the *character* of the defect. A verdict that never changes is exactly why nobody notices the audit trail being voided.

## Flatten the abstraction

**What you learn:** what the program actually decides, with the class structure removed. **Why it matters:** the class hierarchy is somebody's opinion about organisation; it can hide that two of its members can never fire, and no amount of reading the classes shows you that.

Inline through interfaces, dispatch loops and context objects until you have one predicate per outcome over primitive terms. Then cluster by **predicate shape** rather than by domain noun — that is what makes the result disagree with the class structure instead of restating it.

It is how you find that some members of a rule hierarchy can never reject anything. They implement the same interface as the rules that can, so they look interchangeable — but their predicate has no path to a rejection, and all they do is attach data for a later rule to read. The class structure cannot show you that; the flattened predicate can.

Opaque leaves cannot be expanded — database columns, the clock, SQL held only as literals. Every downstream claim is conditional on them, so say so. And note what the boolean abstraction discards: the reason strings, which are often the thing that actually varies.

## Deciding, rather than describing — see `code-symbolic`

Once you have one predicate per outcome, the questions stop being traversals and become proofs: is this threshold redundant, do these two configurations behave identically and on exactly which inputs do they differ, do these two formulas agree, is this computed value even the right kind of thing.

That needs a solver, and it has its own skill. What matters from here is that **the extraction is the bridge** — `JL.pathCondition` for the predicates, `JL.initConstants` for the thresholds they compare against, and an atom table recording, for each leaf, what you *cannot* expand: a database column, the clock, a config key. Carry the source location on every fact, or a proof cannot be turned back into a file you can open.

One rule that belongs here because it is about the code and not the solver: **run the solver's answer through the compiled program before writing it down.** A solver works in exact arithmetic and your code does not, so a witness can be valid in the model and rejected by the gate it was supposed to pass. See `code-symbolic` for the worked case.

## Get an oracle without a specification

**What you learn:** that something is wrong, without anyone knowing what right looks like. **Why it matters:** on legacy systems there is no spec, the tests pass, and the usual answer is "we cannot check that". These three sources say otherwise.

Three sources.

**Metamorphic relations** — properties that must hold whatever the answer is: permutation invariance, config-flag neutrality, monotonicity under a stricter rule set, scaling homogeneity, idempotence, clock invariance.

Derive them rather than guessing. Every invariant a static pass already *proved* becomes a relation. The set difference of two shipped configs becomes a monotonicity relation. Where two expressions compute the same quantity from different sources, the relation is that they must agree — and a violation names the disagreement. One system's credit check read the price the client requested while the fill logic read the live quote, so "an order that fills at price q must be accepted when priced at q" was a relation the code could fail.

State both halves of a monotonicity claim. "A discount must not increase the bill" is satisfied by equality — and equality *was* the defect.

**Sibling agreement** — clone-class members must agree, so the clone relationship supplies the **oracle**, not the input. Prove no coverage-driven generator would have found your vector by diffing coverage bitsets — the set of instrumentation probes each input hits; the bug-revealing input typically adds no coverage at all.

**The future** — score a detector against what maintainers did next, aimed at **bug fixes**, not deletions. Dead code has no forcing function, so deletion labels nothing. Identity is the expensive part: use the simple class name on both sides and print the ambiguity rate.

## Prove a relation is not vacuous with a counter

**What you learn:** whether your check actually ran. **Why it matters:** a check evaluated over zero inputs prints as "passed", which is indistinguishable from a real result and much more comforting.

Expect your relations to hold vacuously on the first run — a counter catches this and reading the harness does not.

Write a control per relation counting how many inputs actually reach the state the relation is about, print it beside the verdict, and mark zero as vacuous. Print skipped pairs separately — **short-circuit evaluation makes every relation about a later pipeline stage vacuous on an input an earlier stage rejects**.

Causes that generalise: an empty table means a database-backed branch never runs; a fresh bootstrap means nothing reaches the read-modify-write; a test entity that is not a row in the parent table means an earlier gate rejects everything.

Sometimes *holding* is the finding. State the relation as "this gate can reject somewhere in its domain", sweep the domain exhaustively, and a single violation — it never can — is the result.

## Calibrate before you believe a lift

**What you learn:** whether your detector beats chance. **Why it matters:** on a single codebase a random detector routinely scores what looks like a strong result, so an uncalibrated lift is not evidence.

Draw control groups **matched on location** and sized like your detector's arms, scored by the identical statistic.

Expect this to kill headlines: an apparent lift can disappear entirely once the null is measured with the same statistic, because the detector's arms live in systematically different packages and location alone accounts for the difference. **A control that does not come out near 1.0 means the harness is wrong**, not that you found something.

Report the median per-run figure, never a rate pooled across runs whose base rates differ by an order of magnitude.

## Test generation

**What you learn:** the input that separates two things that are supposed to be identical. **Why it matters:** coverage-driven generation will not produce it — the bug-revealing vector often adds no coverage at all, so no coverage goal has any reason to reach for it.

Generate **distinguishing** inputs, not coverage-adequate ones. For divergent clones, four rules over extracted facts do it: a guard atom present in one member and absent in another; the same arm path doing a different observable thing; a write key held by some members and missing from one; two members updating the same table with different column lists.

Key those rules on the **first literal inside the sink**, not on the effect kind. Every rule calls the same setter and both data-access objects call the same executor, so kind alone yields zero candidates — for the wrong reason.

Cover **configurations and evaluation order** instead of decision structure. Kill dead dimensions before enumerating; the naive cross product is astronomically larger than the set of distinct programs, and CI usually exercises one of them. For ordering, derive the obligation rather than sampling: with first-failure semantics the number of distinct verdicts equals the number of rules that fail on that input, so witnesses are constructive and permutation search finds nothing the bound did not predict.

Report outcomes at three granularities and always say which: verdict; verdict plus state; state plus ordered messages. Most order-sensitivity is message order — true and useless.

## Slicing is a context auditor

**What you learn:** what is missing from context you already assembled. **Why it matters:** a slice presented as an explanation of the code is confidently wrong, because business rules turn on constants and constants sit outside a dependence closure.

The slice comes back with the logic and without the thresholds, and reads as coherent.

Use it the other way. Give it context you already assembled and take the **gap list**: the constants and callees the context names but does not contain. Nothing else produces that list. Then repair the enclosing method instead — method plus member closure plus callee inlining plus comments is branch-complete by construction.

Audit branch completeness too: for each `if` whose condition is in your selection, check that every arm contributes something. Subtract the `if`'s own line, or a fully dropped arm scores as present because the arm block inherits it.
