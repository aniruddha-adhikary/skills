#!/usr/bin/env bash
# merge-jsp.sh — put your JSP pages INTO the code property graph.
#
# WHY
#   javasrc2cpg parses .java and ignores everything else, so a web application's
#   entire presentation layer is invisible. Form fields, the parameters they post,
#   and which servlet receives them are simply absent from the graph, and every
#   "who reads this input" or "is this method dead" answer is wrong by that much.
#
#   You do not have to model JSP. It is a programming language with a compiler,
#   and that compiler emits ordinary Java servlets. Compile the pages, then build
#   ONE graph over the generated servlets and your own source together. The JSP
#   layer stops being a separate channel you join by hand and becomes real call
#   edges you can traverse.
#
#   The blocker is that Jasper refuses a page whose custom tag handler class is
#   not on the classpath, which on a real application is most pages. But it does
#   not need the tag to *work* — it needs the class to exist and expose a setter
#   per declared attribute, and the .tld declares exactly that. So synthesise the
#   handlers from the TLDs. That is the difference between translating a handful
#   of pages and translating all of them.
#
# USAGE
#   merge-jsp.sh <webapp-dir> <out.cpg.bin> [--src <app-src>] [--project <repo-root>] [--jasper-lib <dir>]
#
#     <webapp-dir>   the directory holding your .jsp pages (and WEB-INF, if any)
#     --src          also compile your application's own sources into the graph
#     --project      repo root to search for .tld files (default: guessed above the webapp)
#     --jasper-lib   directory of Tomcat/Jasper jars; fetched with coursier if omitted
set -euo pipefail

WEBAPP=""; OUT=""; APPSRC=""; JLIB=""; PROJ=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) APPSRC="$2"; shift 2 ;;
    --project) PROJ="$2"; shift 2 ;;
    --jasper-lib) JLIB="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) if [[ -z "$WEBAPP" ]]; then WEBAPP="$1"; elif [[ -z "$OUT" ]]; then OUT="$1"; fi; shift ;;
  esac
done
[[ -z "$WEBAPP" || -z "$OUT" ]] && { sed -n '2,30p' "$0"; exit 1; }
WEBAPP="$(cd "$WEBAPP" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /tmp/mergejsp-XXXX)"

# ------------------------------------------------------------------ jasper jars
if [[ -z "$JLIB" ]]; then
  JLIB="$WORK/lib"; mkdir -p "$JLIB"
  command -v cs >/dev/null || { echo "need coursier (cs) or --jasper-lib" >&2; exit 1; }
  echo "== fetching Jasper"
  cs fetch org.apache.tomcat:tomcat-jasper:9.0.85 javax.servlet:jstl:1.2 2>/dev/null \
    | while read -r j; do ln -sf "$j" "$JLIB/"; done
fi
CP="$JLIB/*"

# ------------------------------------------------------------- collect the TLDs
# In a multi-module project the tag library is a SIBLING module, not under the
# webapp, and Jasper resolves a taglib uri off the classpath. One unfound .tld
# fails every page that declares it — on one project, 224 errors from one file.
: "${PROJ:=$(cd "$WEBAPP/../../../.." 2>/dev/null && pwd || echo "$WEBAPP")}"
TLDCP="$WORK/tldcp/META-INF"; mkdir -p "$TLDCP"
while IFS= read -r tld; do cp -n "$tld" "$TLDCP/" 2>/dev/null || true; done \
  < <(find "$PROJ" -name '*.tld' -not -path '*/target/*' 2>/dev/null)
NTLD=$(find "$TLDCP" -name '*.tld' | wc -l)
echo "== $NTLD tag library descriptors found under $PROJ"
[[ "$NTLD" -gt 0 ]] && CP="$CP:$WORK/tldcp"

NJSP=$(find "$WEBAPP" -name '*.jsp' | wc -l)
echo "== $NJSP pages under $WEBAPP"

# ------------------------------------------------------- translate, then repair
GEN="$WORK/gen"; mkdir -p "$GEN"
run_jspc() { java -cp "$CP" org.apache.jasper.JspC -webapp "$WEBAPP" -d "$GEN" 2>&1; }
report() {   # human output to stderr; only the count goes to stdout
  local n; n=$(find "$GEN" -name '*.java' | wc -l)
  echo "   translated $n of $NJSP" >&2
  [[ "$n" -lt "$NJSP" ]] && {
    echo "   blocking causes, most frequent first:" >&2
    grep -ohP '(?<=: )[A-Za-z\[].{0,78}' "$WORK/log" 2>/dev/null \
      | sed 's/[0-9][0-9]*/N/g' | sort | uniq -c | sort -rn | head -5 | sed 's/^/     /' >&2
  }
  echo "$n"
}
echo "== translating"
run_jspc > "$WORK/log" || true
N=$(report | tail -1)

if [[ "$N" -lt "$NJSP" ]]; then
  echo "== attempting the two generic repairs"
  # 1. taglib uri unresolved -> the .tld is not on the classpath. Common in a
  #    multi-module build, where the tag library is a sibling module or a jar.
  # 2. tag handler class missing -> Jasper needs the class to exist and expose a
  #    setter per declared attribute, not to work. Synthesise it from the .tld.
  STUBS="$WORK/stubs"; mkdir -p "$STUBS"
  python3 "$HERE/tldstub.py" "$WORK/tldcp" "$STUBS" "$CP" >/dev/null 2>&1 || true
  python3 "$HERE/tldstub.py" "$WEBAPP" "$STUBS" "$CP" >/dev/null 2>&1 || true
  CP="$CP:$STUBS:$STUBS/classes:$STUBS/*"
  rm -rf "$GEN"; mkdir -p "$GEN"
  run_jspc > "$WORK/log" || true
  N=$(report | tail -1)
fi

if [[ "$N" -lt "$NJSP" ]]; then
  cat <<'ADVICE'

   Not all pages translated. Read the causes above and fix the largest bucket;
   each one has a standard remedy, and one unresolved cause commonly blocks
   hundreds of pages:

     "absolute uri [...] cannot be resolved"
         The .tld is not on the classpath. Find it anywhere in the project
         (it is often a sibling module or inside a jar) and put it under a
         META-INF/ directory that is on the classpath. Re-run with --project.

     "Failed to load or instantiate TagExtraInfo class"
         A .tld can declare a <teiclass> as well as a <tagclass>, and Jasper needs
         both to exist. Stub the TEI class too — it extends javax.servlet.jsp.tagext.TagExtraInfo
         and needs no body. One missing TEI blocked every page on a real project.

     "Unable to load tag handler class"
         The handler class does not exist. tldstub.py generates one per declared
         tag; if it did not fire, the .tld it needs was not among those found.

     JSTL / TLV classes absent
         Add the jstl jar to --jasper-lib.

     "Compilation error" in a scriptlet
         The page calls into your application. Compile your sources first and
         add them to the classpath, or accept that these pages stay out.

   Partial translation is still worth building — the pages that did translate
   are real methods in the graph. Report the ratio with any finding.
ADVICE
fi
[[ "$N" -eq 0 ]] && { echo "no pages translated" >&2; exit 1; }

# --------------------------------------------------- one graph, both languages
SRCROOT="$WORK/src"; mkdir -p "$SRCROOT"
cp -r "$GEN" "$SRCROOT/jsp"
if [[ -n "$APPSRC" ]]; then
  echo "== adding application sources"
  cp -r "$APPSRC" "$SRCROOT/app"
fi

FRONTEND="$(command -v javasrc2cpg || echo "$(dirname "$(readlink -f "$(command -v joern)")")/javasrc2cpg")"
JARS=$(find "$JLIB" -name '*.jar' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
echo "== building $OUT"
"$FRONTEND" "$SRCROOT" ${JARS:+--inference-jar-paths "$JARS"} -o "$OUT" -J-Xmx8g >/dev/null

cat <<EOF

Done. The pages are now methods in the graph. Jasper's class name encodes the
page path, so provenance survives:  org.apache.jsp.tools.edit_002ditem_jsp
                                 -> tools/edit-item.jsp

Try:
  scripts/gq.py $OUT -e 'cpg.method.internal.filter(_.fullName.contains("org.apache.jsp")).size'
  scripts/gq.py $OUT -e 'cpg.call.name("getParameter").argument.isLiteral.code.dedup.l'
EOF
rm -rf "$WORK/src"
