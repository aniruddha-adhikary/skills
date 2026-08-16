#!/usr/bin/env bash
# Guards for the Joern traps that are detectable at a tool boundary.
#
# WHAT BELONGS HERE
#   Only a wrong action that is visible in the tool call itself. Anything needing
#   judgement — is this a join or a ranking, is this denominator behavioural —
#   stays in the skill, because a hook cannot read intent.
#
# WHAT MUST NOT BE HERE
#   Version-pinned bugs. They get fixed upstream, and then the guard blocks a
#   command that now works, long after anyone remembers this file exists. A guard
#   is only safe if the thing it catches is ARCHITECTURAL — true because of how
#   the tool is built, not because of a defect in one release. Version-pinned
#   facts belong in traps.md, where they carry the version number.
#
# BLOCK vs ADVISE
#   exit 2 blocks and sends stderr back to Claude. Reserve it for an action that
#   silently produces a WRONG ANSWER. Everything else exits 0 and prints a note,
#   which Claude reads as context — because a guard that fires on something
#   defensible teaches everyone to ignore it.
set -uo pipefail
IN=$(cat)
EV=$(printf '%s' "$IN" | jq -r '.hook_event_name // empty')
CMD=$(printf '%s' "$IN" | jq -r '.tool_input.command // empty')
FILE=$(printf '%s' "$IN" | jq -r '.tool_input.file_path // empty')
TEXT=$(printf '%s' "$IN" | jq -r '.tool_input.content // .tool_input.new_string // empty')

block() { echo "$1" >&2; exit 2; }

if [[ "$EV" == "PreToolUse" && -n "$CMD" ]]; then
  # The server is shared mutable state: load-then-query is two round trips and a
  # concurrent importCpg silently redirects the second one.
  if grep -qE 'curl.*query-sync' <<<"$CMD"; then
    block "Do not reach the Joern server with curl. A concurrent importCpg between your load and your query silently answers about a different codebase — this has produced published wrong numbers.
Use: scripts/gq.py <cpg-path> -e '<query>'  (binds the CPG by name, so the race cannot occur)"
  fi
  # Arg-parser detail rather than a design property, so advise only.
  if grep -qE '\-\-param[= ][A-Za-z]=' <<<"$CMD"; then
    echo "Note: a one-character --param name has been observed arriving as '--p x', which the parser rejects. If it fails, lengthen the name (cpgPath)."
  fi
  # Without jars the call graph is degenerate, not fuzzy — and nothing looks wrong.
  if grep -q 'javasrc2cpg' <<<"$CMD" && ! grep -q 'inference-jar-paths' <<<"$CMD"; then
    echo "Note: javasrc2cpg without --inference-jar-paths produces a DEGENERATE call graph, not a fuzzy one — unresolved calls collapse to a single stub, so reachability shrinks and every precision metric improves while nothing looks wrong. scripts/build-typed-cpg.sh resolves jars, stages the test tree, and checks its own work."
    exit 0   # advisory: a jar-less build is sometimes deliberate
  fi
fi

if [[ "$EV" == "PostToolUse" && "$FILE" =~ \.(sc|scala)$ && -n "$TEXT" ]]; then
  W=""
  grep -q 'whereNot(_\.isExternal' <<<"$TEXT" && W+="
- whereNot(_.isExternal) silently empties the traversal: the no-arg accessor yields a non-empty iterator, which reads as 'matched'. Use .internal or .isExternal(false)."
  grep -qE '_\.isAbstract' <<<"$TEXT" && W+="
- _.isAbstract is not a Method step in the version this was written against; if it does not compile, use m.modifier.modifierType.exists(_ == \"ABSTRACT\")."
  grep -qE 'cpg\.identifier\.name\("[A-Z0-9_]{3,}"' <<<"$TEXT" && W+="
- A field read is an <operator>.fieldAccess call, not an identifier, so cpg.identifier.name(\"CONST\") returns nothing for a static final — indistinguishable from 'never read'. Use cpg.fieldAccess.fieldIdentifier.canonicalName."
  grep -qE '\.code\b.*(groupBy|hashCode|distinct|dedup)|(groupBy|hashCode).*\.code\b' <<<"$TEXT" && W+="
- Keying on .code conflates calls: the receiver is dropped in three syntactic positions, so distinct calls render identically. Read call.receiver / call.argument instead."
  grep -q 'newTagNodePair' <<<"$TEXT" && ! grep -qE 'fullName -> |toMap' <<<"$TEXT" && W+="
- Index nodes into a Map before tagging; a per-row fullNameExact scan is quadratic. And query tags from the node side: cpg.method.where(_.tag.name(\"X\"))."
  # stdout + exit 0: Claude reads this as context. Blocking here would end the
  # turn over a query that may well be deliberate.
  [[ -n "$W" ]] && echo "Joern traps to check in this query:$W"
fi
exit 0
