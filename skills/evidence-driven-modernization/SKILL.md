---
name: evidence-driven-modernization
description: >
  Evidence-driven analysis and modernization of legacy software.
  Use when analyzing, migrating, converting, refactoring, or replacing an
  existing system where behavioral equivalence, provenance, runtime behavior,
  or correctness matters.
---

# Objective

Reduce uncertainty about legacy behavior with the minimum necessary work.

Optimize for resolved claims and reduced blockers, not number of files read,
tests executed, artifacts produced, or narrative generated.

# Non-negotiable rules

1. Establish authoritative inputs before analysis.
2. Inventory before deeply investigating individual elements.
3. Represent unknown behavior explicitly.
4. Build an acyclic evidence dependency graph.
5. Every substantial task must resolve a named claim or blocker.
6. Prefer the cheapest experiment capable of changing the claim disposition.
7. Never perform expensive downstream verification while upstream evidence is mutable.
8. Parallel workers must own disjoint writable state.
9. Freeze producers before shared integration.
10. Stop investigating when additional evidence cannot change the decision.
11. Never equate coverage with behavioral equivalence.
12. Never promote synthetic or fixture-only evidence to production applicability.

# Initial phase

Before implementation-specific analysis, produce:

- source manifest;
- structural inventory;
- claim/gap ledger;
- evidence DAG;
- current blockers;
- initial work ranking.

Do not begin one-off harness construction before these exist.

# Work selection

For unresolved claims, rank:

- decision value;
- reusable closure;
- expected information gain;
- cost;
- invalidation risk;
- shared-state contention.

Prefer high-value, reusable, cheap, isolated work.

# Work-item contract

Each nontrivial task records:

- claim ID;
- question;
- dependencies;
- current disposition;
- proposed evidence;
- expected decision impact;
- stop condition;
- outputs owned;
- applicability assumptions.

# Claim outcomes

Use explicit dispositions:

- EXACT
- CONDITIONALLY_EXACT
- PARTIAL
- FALLBACK_REQUIRED
- EXTERNAL_BOUNDARY
- MALFORMED_SOURCE
- UNKNOWN
- INVALID

Never collapse these into a generic pass flag.

# Verification levels

During active development:
use focused static/unit/mutation checks.

At lane freeze:
run the full local proof.

After all upstream lanes freeze:
integrate once and run global differential verification.

# Completion

Report separately:

- evidence integrity;
- behavioral completeness;
- production applicability;
- promotability;
- remaining exact blockers.

A negative or bounded result is valid progress when it replaces an unknown
with reproducible evidence.
