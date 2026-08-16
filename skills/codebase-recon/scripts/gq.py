#!/usr/bin/env python3
"""
gq.py — guarded client for a resident Joern server.

WHY THIS EXISTS, AND WHY NOT curl
    The server is SHARED MUTABLE STATE. Loading a CPG and then querying it is two
    HTTP round trips, and anyone else's `importCpg` in between silently reassigns
    the active `cpg`. Your query succeeds, returns a plausible number, and answers
    about the wrong codebase.

    So every query this script sends carries an identity probe in the SAME payload,
    and the answer is rejected — and the graph reloaded — if it came from elsewhere.

HOW IT AVOIDS THE RACE RATHER THAN JUST CATCHING IT
    The REPL's bare `cpg` is the server's single ACTIVE project, which is what makes
    it racy. But projects are addressable by name, so a query can bind its own graph
    and never read the global at all:

        def _q(cpg: Cpg) = { <your query> }
        _q(workspace.project("mine.cpg.bin").flatMap(_.cpg).get)

    Verified: with another project active, a name-scoped query still returns the
    right graph's numbers. Two agents on one server can now work on different CPGs
    concurrently with no coordination, no reload, and nothing to thrash over. The
    identity probe stays as a cheap assertion, not as the mechanism.

    Wrapping in a `def` has a second payoff: the server renders every intermediate
    `val` of a multi-statement query, and one counting query returned 42.8 MB of
    pretty-printed case classes. Inside a function body only the result comes back.

    Caveat: projects are named after the CPG file's BASENAME, so two different
    graphs both called `out.cpg.bin` would collide. This script checks the bound
    graph's root against the path you asked for and refuses on a mismatch.

USE
    gq.py <cpg-path> -e 'cpg.method.internal.size'
    gq.py <cpg-path> query.sc
    gq.py <cpg-path> --status
    gq.py <cpg-path> --unload         # free the heap when you are done

    Any query mentioning JL. loads scripts/joernlib.scala into the session first,
    so the reusable traversals are available on the fast path and not only under
    `joern --import`:
        gq.py <cpg> -e 'JL.health(cpg)'
        gq.py <cpg> -e 'JL.callEdgeDelta(cpg)'
    export GQ_CPG=/path/to/x.cpg.bin     # then the path may be omitted

    --url    server URL (default http://127.0.0.1:8080/query-sync, or $JOERN_URL)
    --raw '<query>'   run the query unguarded, no CPG needed (for `1+1`-style checks)

START THE SERVER (once, leave it running)
    nohup joern --server --server-host 127.0.0.1 --server-port 8080 \
      > /tmp/joern-server.log 2>&1 &
    # ~40 s to come up

WHAT THE GUARD CHECKS, AND WHY EACH ONE IS THERE
    root      the CPG's own source path. Catches the hijack above.
    overlays  an empty list means no call graph, no CFG, no dataflow — and every
              graph query then returns 0 with no error. A bare frontend CPG does
              this. The REPL applies overlays on import, which is why interactive
              use hides the problem and scripted use does not.
    files     a sanity magnitude. Compare it against `find <src> -name '*.java' |
              wc -l`; a large shortfall means the frontend dropped directories
              (it drops `test`, among others, silently and with exit code 0).
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

DEFAULT_URL = os.environ.get("JOERN_URL", "http://127.0.0.1:8080/query-sync")
# Immutable facts only: which root a given CPG file reports. Never "what am I
# currently doing" — that is the state that made concurrent agents collide.
CACHE = os.path.expanduser("~/.cache/joern-gq-roots.json")

# The endpoint returns the REPL's *rendering of values*, not anything printed —
# a `println` here vanishes. So the identity probe has to be a val whose value
# carries it, which the REPL then echoes back to us.
def guard_stmt(project):
    return (f'val _guard = {{ val _c = workspace.project("{project}")'
            '.flatMap(_.cpg).get; s"@@GUARD root=${_c.metaData.root.l.mkString("|")}'
            ' overlays=${_c.metaData.overlays.l.mkString(",")}'
            ' files=${_c.file.size}" }')


def scoped(project, query):
    """Bind `cpg` to a named project so the global active one is never read."""
    return (guard_stmt(project) + "\n"
            "def _q(cpg: io.shiftleft.codepropertygraph.generated.Cpg) = {\n"
            f"{query}\n}}\n"
            f'_q(workspace.project("{project}").flatMap(_.cpg).get)')


ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")


def post(url, query, timeout):
    body = json.dumps({"query": query}).encode()
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"})
    t = time.time()
    try:
        out = json.load(urllib.request.urlopen(req, timeout=timeout))
    except urllib.error.URLError as e:
        sys.exit(
            f"cannot reach the Joern server at {url} ({e})\n"
            "start it:  nohup joern --server --server-host 127.0.0.1 "
            "--server-port 8080 > /tmp/joern-server.log 2>&1 &")
    return time.time() - t, (out.get("stdout") or "") + (out.get("stderr") or "")


def split_guard(text):
    """Pull the guard line out of the output; return (guard_dict, rest)."""
    guard, keep = {}, []
    for line in ANSI.sub("", text).splitlines():
        m = re.search(r"@@GUARD root=(.*?) overlays=(.*?) files=(\d+)", line)
        if m:
            guard = {"root": m.group(1),
                     "overlays": [o for o in m.group(2).split(",") if o],
                     "files": int(m.group(3))}
        else:
            keep.append(line)
    return guard, "\n".join(keep).strip()


def known_root(path):
    try:
        with open(CACHE) as fh:
            return json.load(fh).get(path)
    except (OSError, ValueError):
        return None


def remember_root(path, root):
    try:
        with open(CACHE) as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        d = {}
    d[path] = root
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    with open(CACHE, "w") as fh:
        json.dump(d, fh)


def resolve_cpg(arg):
    p = arg or os.environ.get("GQ_CPG")
    if not p:
        sys.exit("name the CPG: gq.py <cpg-path> -e '<query>'  (or set GQ_CPG, "
                 "or pass --raw for a query that needs no graph)")
    p = os.path.abspath(os.path.expanduser(p))
    if not os.path.exists(p):
        sys.exit(f"no such CPG: {p}")
    return p


LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "joernlib.scala")


def lib_source():
    """joernlib.scala without its `package` clause.

    The REPL has no notion of the package, so the clause has to go; everything
    else — the imports, the given, the object — evaluates as written."""
    with open(LIB) as fh:
        src = "".join(l for l in fh if not l.startswith("package "))
    # The file ends inside an indented block, and the REPL wants that block
    # closed before EOF: "unindent expected, but eof found". A comment at
    # column 0 is enough.
    return src + "\n// end joernlib\n"


def ensure_lib(url, timeout):
    """Define JL on the server once. Objects persist in the REPL session, so this
    costs one extra round trip after a server start and nothing afterwards — and
    it is idempotent, so another agent having loaded it already is fine."""
    _, out = post(url, "JL.getClass.getSimpleName", timeout)
    if "JL" in ANSI.sub("", out) and "not found" not in ANSI.sub("", out).lower():
        return
    _, out = post(url, lib_source(), timeout)
    clean = ANSI.sub("", out)
    if "-- [E" in clean or "error" in clean.lower():
        sys.stderr.write("!! joernlib failed to load on the server:\n"
                         + "\n".join(clean.splitlines()[:12]) + "\n")


def project_of(path):
    return os.path.basename(path)


def ensure_loaded(url, path, timeout):
    """Make sure the named project is resident AND has its overlays.

    Two ways to be not-ready, and the second one is a trap: a project can be listed
    and even reopenable while carrying no overlays, in which case method and call
    counts look completely normal and every call-graph or dataflow query returns 0.
    An unload/reopen cycle produces exactly that. `importCpg` re-applies the default
    overlays; `openProject` does not. So test for overlays, not for presence.
    """
    project = project_of(path)
    probe = (f'workspace.project("{project}").flatMap(_.cpg)'
             '.map(_.metaData.overlays.l.size).getOrElse(-1)')
    _, out = post(url, probe, timeout)
    m = re.search(r"Int = (-?\d+)", ANSI.sub("", out))
    if not m or int(m.group(1)) < 1:
        post(url, f'importCpg("{path}")', timeout)
    return project


def run(url, path, query, timeout):
    project = ensure_loaded(url, path, timeout)
    if "JL." in query:
        ensure_lib(url, timeout)
    d, out = post(url, scoped(project, query), timeout)
    g, rest = split_guard(out)
    if not g:
        print(ANSI.sub("", out).rstrip())
        return
    # Binding by name makes a hijack impossible, so this is an assertion rather
    # than a retry loop. The one thing it can still catch is a basename collision.
    expected = known_root(path)
    if expected is None:
        remember_root(path, g["root"])
    elif g["root"] != expected:
        sys.exit(f"project name {project!r} resolves to {g['root']}, but {path} "
                 f"was previously {expected} — two CPGs share a basename. "
                 "Rename one; the server keys projects by filename.")
    if not g["overlays"]:
        sys.stderr.write(
            "!! overlays=[] — this graph has no call graph, CFG or dataflow, so "
            "any such query returned 0 for that reason, not because there is "
            "nothing there.\n")
    # drop the `def _q(...)` echo the REPL prints before the result
    rest = "\n".join(l for l in rest.splitlines() if not l.startswith("def _q("))
    print(f"[{d:6.3f}s] {rest.strip()}")


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("cpg", nargs="?")
    ap.add_argument("script", nargs="?")
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("-e", "--eval", dest="expr")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--load", action="store_true")
    ap.add_argument("--unload", action="store_true")
    ap.add_argument("--raw")
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("-h", "--help", action="store_true")
    a = ap.parse_args()

    if a.help or len(sys.argv) == 1:
        print(__doc__)
        return
    if a.raw:
        _, out = post(a.url, a.raw, a.timeout)
        print(ANSI.sub("", out).rstrip())
        return
    if a.status:
        _, out = post(a.url, "workspace.projects.map(_.name).l", a.timeout)
        print(f"server   : {a.url}")
        print("projects :", ", ".join(re.findall(r'"([^"]+\.bin)"', ANSI.sub("", out))) or "none")
        _, act = post(a.url, "workspace.getActiveProject.map(_.name)", a.timeout)
        m = re.search(r'"([^"]+)"', ANSI.sub("", act))
        print(f"active   : {m.group(1) if m else 'none'}  "
              "(irrelevant — queries here bind by name, not by active)")
        return

    path = resolve_cpg(a.cpg)
    if a.unload:
        # Name-scoped queries never evict anything, so graphs accumulate until the
        # JVM dies. Free yours when you are done with it.
        pr = project_of(path)
        post(a.url, f'workspace.unloadCpgByProjectName("{pr}")', a.timeout)
        print(f"   unloaded {pr}")
        return
    if a.load:
        print(f"   project {ensure_loaded(a.url, path, a.timeout)}")
    q = a.expr
    if a.script:
        with open(a.script) as fh:
            q = fh.read()
    if q:
        run(a.url, path, q, a.timeout)


if __name__ == "__main__":
    main()
