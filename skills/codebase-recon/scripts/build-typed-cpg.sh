#!/usr/bin/env bash
# build-typed-cpg.sh — build a Java CPG that is worth trusting.
#
# WHY THIS EXISTS
#   Two setup steps decide whether your answers are real, and both are easy to skip
#   because skipping them produces no error:
#
#   1. DEPENDENCY JARS. Without them the call graph is degenerate, not fuzzy — every
#      unresolved call resolves to one body-less stub, so reachability shrinks and
#      every precision metric IMPROVES. The graph looks better than it is.
#   2. THE TEST TREE. javasrc2cpg silently drops nine directory names, `test` among
#      them — which is standard Maven layout. Staging it raised the method count
#      by ~1.45x on two projects. Exit 0, empty stderr. A test-only method looks dead.
#
#   This script does both, then measures whether step 1 actually worked.
#
# USAGE
#   build-typed-cpg.sh <source-dir> <output.cpg.bin> [options]
#
#     --jars <dir|csv>   directory to search for .jar, or a comma-separated list.
#                        Default: resolve with maven into <source-dir>/target/dependency
#     --with-tests       stage the test tree so it survives the frontend (see below).
#                        Renames test dirs, builds, then restores them. Off by default
#                        because it touches your working tree.
#     --xmx <size>       heap for the frontend (default 8g)
#     --no-verify        skip the post-build unresolved-signature measurement
#
# WHAT --with-tests DOES TO YOUR TREE
#   Renames every directory named exactly `test` to `test__staged`, builds, then
#   renames them back — restored on exit even if the build fails. Each rename is
#   printed. If the tree is a dirty git checkout the script refuses, because an
#   interrupted run would leave renamed directories in your diff.
set -euo pipefail

SRC=""; OUT=""; JARS=""; WITH_TESTS=0; XMX="8g"; VERIFY=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jars) JARS="$2"; shift 2 ;;
    --with-tests) WITH_TESTS=1; shift ;;
    --xmx) XMX="$2"; shift 2 ;;
    --no-verify) VERIFY=0; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) if [[ -z "$SRC" ]]; then SRC="$1"; elif [[ -z "$OUT" ]]; then OUT="$1"; fi; shift ;;
  esac
done
[[ -z "$SRC" || -z "$OUT" ]] && { sed -n '2,40p' "$0"; exit 1; }
[[ -d "$SRC" ]] || { echo "no such source directory: $SRC" >&2; exit 1; }
SRC="$(cd "$SRC" && pwd)"

# ------------------------------------------------------------------ preflight
# Distributions commonly symlink `joern` alone, so the frontend is present but not
# on PATH. Find it next to joern rather than failing.
if command -v javasrc2cpg >/dev/null 2>&1; then
  FRONTEND="$(command -v javasrc2cpg)"
elif command -v joern >/dev/null 2>&1; then
  FRONTEND="$(dirname "$(readlink -f "$(command -v joern)")")/javasrc2cpg"
else
  FRONTEND="$HOME/joern/joern-cli/javasrc2cpg"
fi
[[ -x "$FRONTEND" ]] || {
  echo "javasrc2cpg not found (looked next to joern too) — set FRONTEND=/path/to/it" >&2
  exit 1; }
command -v java >/dev/null 2>&1 || { echo "no java on PATH" >&2; exit 1; }
echo "== frontend $FRONTEND"

# ---------------------------------------------------------------- step 1: jars
# You need JARS, not a successful build. `dependency:copy-dependencies` skips
# compilation, plugins, codegen and tests — a far lower bar than `mvn package`,
# and it is usually the difference between "we cannot analyse this" and a typed graph.
if [[ -z "$JARS" ]]; then
  if [[ -f "$SRC/pom.xml" ]]; then
    echo "== resolving dependencies with maven (no compile)"
    MVNLOG=$(mktemp /tmp/mvndep-XXXX.log)
    (cd "$SRC" && mvn dependency:copy-dependencies \
        -DoutputDirectory=target/dependency -DincludeScope=runtime) > "$MVNLOG" 2>&1 \
      || echo "   maven returned non-zero — classifying below, then using what it fetched"
    # Detection only. These conditions each have a known fix, and each one otherwise
    # reads as "the dependencies are gone" when the artifacts are in fact reachable.
    if grep -qi 'blocked mirror\|maven-default-http-blocker\|http://.*repo' "$MVNLOG"; then
      cat >&2 <<'HTTP'
   !! an http:// repository was blocked. Maven 3.8+ blocks plain HTTP, and old POMs
      hardcode it. The artifacts are usually on Central anyway. Add to ~/.m2/settings.xml:
        <mirror><id>central-https</id><mirrorOf>external:http:*</mirrorOf>
                <url>https://repo.maven.apache.org/maven2</url></mirror>
HTTP
    fi
    if [[ -f "$SRC/pom.xml" ]]; then
      OWNG=$(sed -n 's:.*<groupId>\(.*\)</groupId>.*:\1:p' "$SRC/pom.xml" | head -1)
      if [[ -n "$OWNG" ]] && grep -q "Could not resolve.*$OWNG" "$MVNLOG" 2>/dev/null; then
        echo "   !! unresolved artifacts share this project's groupId ($OWNG)." >&2
        echo "      Those are reactor-internal modules, not missing dependencies." >&2
        echo "      Build the reactor once (mvn -N install, or mvn install -DskipTests)." >&2
      fi
    fi
    grep -oi 'Could not resolve dependencies[^\n]*' "$MVNLOG" | head -3 >&2 || true
    rm -f "$MVNLOG"
    JARS="$SRC/target/dependency"
  else
    echo "== no pom.xml and no --jars given; looking for jars under the source tree"
    JARS="$SRC"
  fi
fi

if [[ "$JARS" == *,* ]]; then
  JARLIST="$JARS"
else
  [[ -d "$JARS" ]] || { echo "no such jar directory: $JARS" >&2; exit 1; }
  JARLIST="$(find "$JARS" -name '*.jar' -type f 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')"
fi
NJARS=$(printf '%s' "$JARLIST" | tr ',' '\n' | grep -c . || true)
echo "== $NJARS jars"
if [[ "$NJARS" -eq 0 ]]; then
  cat >&2 <<'EOF'
   !! zero jars. Before concluding they are unobtainable, note that across nine
      2000s-era codebases 9 of 9 reached >=90% of their external artifacts:
        - Maven Central is append-only and still serves 2006-era jars; a dead
          corporate repo was often only a proxy of Central.
        - Old POMs hardcode http://, which returns 501 and is additionally blocked
          by maven-default-http-blocker. One `mirrorOf: external:http:*` fixes both.
        - "Reactor-internal snapshots missing" usually means the reactor was not built,
          not that anything is missing.
      Partial resolution still helps. Continuing, but treat the call graph as degenerate.
EOF
fi

# ---------------------------------------------------- step 2: stage the test tree
RENAMED=()
restore() {
  for d in "${RENAMED[@]:-}"; do
    if [[ -n "$d" && -d "${d}__staged" ]]; then mv "${d}__staged" "$d"; fi
  done
  return 0   # a false test here would abort the script under `set -e`
}
if [[ "$WITH_TESTS" -eq 1 ]]; then
  if git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 && \
     [[ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]]; then
    echo "refusing --with-tests: $SRC is a dirty git checkout, and an interrupted" >&2
    echo "run would leave renamed directories in your diff. Commit or stash first." >&2
    exit 1
  fi
  trap restore EXIT INT TERM
  while IFS= read -r d; do
    mv "$d" "${d}__staged" && RENAMED+=("$d") && echo "   staged $d"
  done < <(find "$SRC" -type d -name test -not -path '*/.git/*' | sort -r)
  echo "== staged ${#RENAMED[@]} test directories (restored on exit)"
fi

# ------------------------------------------------------------------- step 3: build
mkdir -p "$(dirname "$OUT")"
echo "== building $OUT"
START=$(date +%s)
if [[ -n "$JARLIST" ]]; then
  "$FRONTEND" "$SRC" --inference-jar-paths "$JARLIST" -o "$OUT" -J-Xmx"$XMX"
else
  "$FRONTEND" "$SRC" -o "$OUT" -J-Xmx"$XMX"
fi
echo "== built in $(( $(date +%s) - START ))s"

restore; trap - EXIT INT TERM

# ------------------------------------------------- step 4: did the jars actually land
# The number that tells you: what fraction of calls still resolve to a stub.
# Measured elsewhere: 17.32% -> 0.02% once jars were supplied. If yours is still
# high, the jar list did not cover what this code actually calls.
if [[ "$VERIFY" -eq 1 ]] && command -v joern >/dev/null 2>&1; then
  echo "== verifying"
  TMP=$(mktemp /tmp/verify-XXXX.sc)
  # NB: the param name must be more than one character. `--param p=x` is passed
  # through as `--p x`, and the arg parser wants `-p x`, so a one-letter name fails.
  cat > "$TMP" <<'SC'
@main def exec(cpgPath: String) = {
  importCpg(cpgPath)
  val total = cpg.call.size
  val unres = cpg.call.methodFullName(".*<unresolved.*").size
  val pct   = if (total == 0) 0.0 else unres * 100.0 / total
  val javaFiles = cpg.file.name.l.count(_.endsWith(".java"))
  println(f"@@ files=$javaFiles methods=${cpg.method.internal.size} (node total ${cpg.file.size}, the rest are synthetic)")
  println(f"@@ overlays=${cpg.metaData.overlays.l.mkString(",")}")
  println(f"@@ unresolved signatures: $unres / $total = $pct%.2f%%")
  if (pct > 5.0)
    println("@@ !! still high — the jar list is missing what this code actually calls")
}
SC
  VOUT=$(joern --script "$TMP" --param cpgPath="$OUT" 2>/dev/null | sed -n 's/^@@ //p')
  rm -f "$TMP"
  echo "$VOUT" | sed 's/^/   /'

  # Reconcile the graph against the source tree. A shortfall that matches the number
  # of files under a dropped directory tells you exactly what went missing; a
  # shortfall that matches nothing is its own finding.
  SRCJ=$(find "$SRC" -name '*.java' -not -path '*/.git/*' | wc -l)
  CPGF=$(echo "$VOUT" | sed -n 's/.*files=\([0-9]*\).*/\1/p' | head -1)
  TESTJ=$(find "$SRC" -name '*.java' -path '*/test/*' -not -path '*/.git/*' | wc -l)
  if [[ -n "$CPGF" ]]; then
    echo "   source .java=$SRCJ  in CPG=$CPGF  under a test dir=$TESTJ"
    GAP=$(( SRCJ - CPGF ))
    TOL=$(( TESTJ / 50 + 2 ))
    if [[ "$GAP" -eq 0 ]]; then
      echo "   reconciles exactly: every source file is in the graph"
    elif [[ "$TESTJ" -gt 0 && "$GAP" -ge $((TESTJ - TOL)) && "$GAP" -le $((TESTJ + TOL)) ]]; then
      echo "   !! $GAP missing files match the $TESTJ under a test/ directory."
      echo "      The frontend dropped your tests. Rebuild with --with-tests, or every"
      echo "      test-only method will look dead."
    else
      echo "   !! $GAP files are missing and the test tree ($TESTJ) does not explain it."
      echo "      The frontend also drops: .git .mvn .gradle build target out node_modules .idea"
  fi
fi
fi
echo "== done: $OUT"
