---
name: "scale-engineering"
description: "Plan, scope, and build software work by class instead of instance. Use whenever work has many similar items: pages, forms, rules, endpoints, reports, migrations, refactors, codemods, or when sizing AI-assisted work, tickets, epics, or token cost."
---

# Scale Engineering

**Think once per class. Execute cheaply per instance. Fix at the class level.**

Teams often scope AI-assisted work one item at a time: one page, one form, one rule per ticket. Each engineer then pays a strong model to think the same thoughts again, and AI cost tracks headcount. This skill moves the unit of work to the class.

## When this applies

Look for the same shape repeated N times: pages, forms, rules, API endpoints, reports, integrations, config files, migration targets. If N is large, plan for the class.

## The method

1. **Find the classes.** Use static analysis, search, dependency graphs, and clustering to group instances into families. Group by how they vary (the variation axes). A human expert confirms each family. Instances that fit no family are the long tail. Do those by hand.
2. **Split each family into a slot and slottable entities.** The slot is the shared part. Build it once, in the foundation. A slottable entity holds only what varies, ideally as plain configuration or parameters.
3. **Build verification first (shift testing left).** For a migration, use differential tests: give the old and new system the same input and compare. For new work, write tests or specs per family. Reuse existing fuzzers, test generators, and the platform's own tools.
4. **Write the generator.** AI writes the transformer (codemod). Deterministic tools run it. If the source is a platform product (a rules engine, CMS, or policy engine), first build a generic transformer against the platform's public samples, without project code. It stays reusable and keeps project code private.
5. **Iterate at the class level.** Run on every instance, verify, fix the generator, run again. Let agents build their own tools to see failures, such as failure clusterers and diff normalizers. Keep those tools deterministic and in the repo.

## Rules

1. **Fix the generator.** The generator is the foundation, the transformer, and the family definitions together. A hand patch on one output is lost on the next run. Keep all outputs regenerable. Only the long tail gets hand edits.
2. **Blame the right layer.** A failure belongs to one of: the transformer, the family definition, the foundation, the verification, an agent-built tool, or a truly unique instance. Fix it there, so the fix reaches every instance.
3. **Shift review left.** Give privileged code (foundation, generator, gate, review tooling) a deep engineering review. Generated entities pass a machine gate, automated verification, and sampled human review.
4. **Engineers make guarantees. Business owners judge the specifics.** Engineers guarantee safety, integrity, fidelity, equivalence, and traceability for every entity. Business owners review the real entities in a view built for them. A need outside the guarantees becomes a platform change.
5. **One owner per layer.** Agents propose. Humans accept.

## Right-size the work

- Scope an epic to one class or family, with a named class owner who has authority over its foundation.
- Let foundation and generator work span sprints.
- Measure instances verified and cost per instance.
- Spend strong-model reasoning in bursts on the slots. Use small models, local models, or scripts per entity. This cuts duplicate spend.
- Estimate: total = foundation + generator + (cost per instance × N) + long tail. Find the break-even N.

## Lifecycle

Discover → build slots and harness → generate or migrate → prove parity → cut over → transform. New needs feed back into the loop. For modernization, change the technology first, prove parity, then change the business in small moves.

## When to skip it

- Small N: hand work costs less below the break-even point.
- The business will discard most old behavior: parity work is waste.
- Weak verification: build the harness before the generator.
- Unconfirmed families: a wrong family gives a wrong generator.

## How to respond

When the user brings a plan, ticket, backlog, or task:

1. Name the entity class and estimate N.
2. Propose the slot and slottable-entity split.
3. Say how to verify it, and what comes first.
4. Re-scope the work by family, with an owner and a cost estimate.
5. Say plainly when the approach does not fit.

Keep it short. Use the user's own numbers in the estimate when they give them, and mark any assumed numbers as placeholders.