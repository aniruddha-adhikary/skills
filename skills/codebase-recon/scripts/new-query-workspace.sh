#!/usr/bin/env bash
# new-query-workspace.sh — scaffold a type-checked Joern query workspace.
#
# WHY THIS IS A SCRIPT AND NOT A PAGE OF INSTRUCTIONS
#   The setup is four files and two commands, and every version number in them
#   must match the Joern that will run the script. Written as prose, the template
#   carries example versions, a reader copies them, and the mismatch does not fail
#   at compile time — it fails later with a runtime linkage error. This script
#   reads the versions off the installed jars, so the skew cannot happen.
#
# USAGE
#   new-query-workspace.sh <dir> [--joern <joern-install>] [--no-compile]
#
#   --no-compile   skip `scala-cli compile`, which is slow on a cold cache
set -euo pipefail

DIR=""; JOERN_HOME=""; COMPILE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --joern) JOERN_HOME="$2"; shift 2 ;;
    --no-compile) COMPILE=0; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) DIR="${DIR:-$1}"; shift ;;
  esac
done
[[ -z "$DIR" ]] && { sed -n '2,15p' "$0"; exit 1; }

# ---------------------------------------------------------------- find joern
if [[ -z "$JOERN_HOME" ]]; then
  if command -v joern >/dev/null 2>&1; then
    JOERN_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v joern)")")")"
  else
    JOERN_HOME="$HOME/joern"
  fi
fi
LIB="$JOERN_HOME/joern-cli/lib"
[[ -d "$LIB" ]] || LIB="$JOERN_HOME/lib"
[[ -d "$LIB" ]] || { echo "cannot find joern-cli/lib under $JOERN_HOME — pass --joern" >&2; exit 1; }

ver() { ls "$LIB" | sed -n "s/^$1-\(.*\)\.jar$/\1/p" | head -1; }
JOERN_V="$(ver 'io\.joern\.semanticcpg')"
SCALA_V="$(ls "$LIB" | sed -n 's/^org\.scala-lang\.scala3-library_3-\(.*\)\.jar$/\1/p' | head -1)"
[[ -n "$JOERN_V" && -n "$SCALA_V" ]] || {
  echo "could not read versions from $LIB" >&2; exit 1; }
echo "== joern $JOERN_V / scala $SCALA_V  (read from $LIB)"

# ---------------------------------------------------------------- scaffold
mkdir -p "$DIR/scripts"
cd "$DIR"

cat > project.scala <<EOF
//> using scala $SCALA_V
//> using dep io.joern::semanticcpg:$JOERN_V
//> using dep io.joern::dataflowengineoss:$JOERN_V
//> using option -Wconf:any:silent
// Joern compiles .sc scripts in its own REPL, which injects \`cpg\`, \`importCpg\`
// and an implicit EngineContext. scala-cli knows none of those, so a shim would
// show errors that are not real. Keep shims out of this build.
//> using exclude "scripts/*.sc"
EOF

cat > QueryLib.scala <<'EOF'
package joernscripts

import io.shiftleft.codepropertygraph.generated.Cpg
import io.shiftleft.semanticcpg.language.*
import io.joern.dataflowengineoss.language.*
import io.joern.dataflowengineoss.queryengine.EngineContext

/** The Joern REPL injects this implicitly; a plain scala-cli build does not, so
  * `callIn`, `callee` and every other call-graph step fail to compile without it.
  * NoResolve uses the call graph as built. */
given ICallResolver = NoResolve

/** Put every real traversal here, taking `cpg` as a parameter.
  *
  * This is the half the language server can check. A wrong step is a red squiggle
  * now rather than a failed run after a JVM start and a graph load. It is also why
  * the shim in scripts/ stays three lines long.
  */
object QueryLib:

  /** Always answer this before trusting any other result. An empty overlay list
    * means no call graph, no CFG and no dataflow — every such query returns 0,
    * silently. */
  def health(cpg: Cpg): String =
    val overlays = cpg.metaData.overlays.l
    s"root=${cpg.metaData.root.l.mkString} files=${cpg.file.size} " +
      s"methods=${cpg.method.internal.size} overlays=${overlays.mkString(",")}" +
      (if overlays.isEmpty then "  !! NO OVERLAYS — graph queries will return 0" else "")

  def internalMethodNames(cpg: Cpg): List[String] =
    cpg.method.internal.fullName.l

  /** Methods nothing calls. The filterNot is not cosmetic: every <init> and
    * <clinit> has zero callIn by construction. Read the dead-code preconditions
    * in when-not-to.md before believing the result. */
  def uncalled(cpg: Cpg): List[String] =
    cpg.method.internal
      .filterNot(_.name.startsWith("<"))
      .filter(_.callIn.isEmpty)
      .fullName.l

  /** Concrete call edges. Abstract declarations are a large share of raw `callee`
    * rows, and counting them inflates reachability. `_.isAbstract` does not exist. */
  def callEdges(cpg: Cpg): List[(String, String)] =
    val isAbstract = (m: io.shiftleft.codepropertygraph.generated.nodes.Method) =>
      m.modifier.modifierType.exists(_ == "ABSTRACT")
    cpg.method.internal.flatMap(m =>
      m.callee.internal.filterNot(isAbstract).dedup.map(c => (m.fullName, c.fullName))
    ).l

  def paramToSink(cpg: Cpg, sinkPattern: String)(using EngineContext): List[String] =
    val sinks   = cpg.call.name(sinkPattern).argument
    val sources = cpg.method.internal.parameter.indexGt(0)
    sinks.reachableByFlows(sources).map(_.elements.map(_.code).mkString(" -> ")).l
EOF

cat > scripts/shim.sc <<'EOF'
import joernscripts.QueryLib

// Keep this file tiny. Metals analyses .sc files on its own and reports errors
// here that are not real (`Not found: cpg`, unsupported @main). Three lines caps
// the noise. The parameter name must be longer than one character — `--param p=x`
// arrives at the arg parser as `--p x` and is rejected.
@main def exec(cpgPath: String) = {
  importCpg(cpgPath)
  println(QueryLib.health(cpg))
}
EOF

cat > run.sh <<EOF
#!/usr/bin/env bash
# Type-check first, then pay for the JVM. Compiling is seconds; a failed run is
# a JVM start plus a graph load.
set -euo pipefail
cd "\$(dirname "\$0")"
scala-cli compile .
joern --import "\$PWD/QueryLib.scala" --script scripts/shim.sc --param cpgPath="\$1"
EOF
chmod +x run.sh

echo "== wrote project.scala QueryLib.scala scripts/shim.sc run.sh"

# ---------------------------------------------------------------- bootstrap
if [[ "$COMPILE" -eq 1 ]] && command -v scala-cli >/dev/null 2>&1; then
  echo "== scala-cli compile (slow the first time: it fetches deps and source jars)"
  scala-cli compile . 2>&1 | tail -5
  scala-cli setup-ide . && echo "== setup-ide done — Metals can connect"
else
  echo "== skipped compile. Run: scala-cli compile . && scala-cli setup-ide ."
fi

cat <<EOF

Next:
  ./run.sh <path-to.cpg.bin>        type-checks, then runs

If hover does not resolve the Joern DSL in QueryLib.scala, the language server is
not attached yet. Claude Code registers language servers at session start, so a
mid-session install needs a reload before it takes effect.
EOF
