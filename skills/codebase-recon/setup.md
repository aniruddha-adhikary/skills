# Setup — a graph worth trusting, and a fast way to ask it things

Two things decide whether your answers are real, and both fail silently: **the dependency jars** and **the test tree**. The script below does both and then checks its own work.

## Build

```bash
scripts/build-typed-cpg.sh <source-dir> <out.cpg.bin> --with-tests
```

It resolves dependencies with Maven, stages the test tree, builds, and then reports three things you must read:

| it reports | act when |
|---|---|
| jar count | zero. See the next section before you accept it. |
| unresolved-signature rate | above 1%. The jar list misses what this code calls. |
| source files against graph files | it says the numbers do not reconcile. |

The last check is the one that catches most silent damage. The frontend drops nine directory names — `.git .mvn .gradle build target out node_modules .idea test` — with exit code 0 and an empty stderr. The script counts `.java` files on disk and counts them in the graph. It then tells you whether the shortfall matches your test tree, or something you have not considered.

`--with-tests` renames test directories, builds, and restores them on exit. It refuses to run on a dirty git checkout, because an interrupted run would leave renamed directories in your diff.

## Before you accept "it does not build"

Two cheap moves, in this order, before concluding a codebase cannot be compiled. Both change what is available to you more than any query does.

**Try an older JDK.** The most common blocker, and not a property of the code. Codebases that fail on 21 and on 11 build on 8 — one twelve-module system long written off compiles in twenty seconds.

> Set `JAVA_HOME` for the one command rather than switching the toolchain default. That default is global mutable state; changing it will break a resident Joern server and anything else mid-flight.

**Then try a tolerant compiler.** `ecj -proceedOnError` compiles what it can and stubs the rest, so source `javac` refuses still yields class files:

```bash
find <src> -name '*.java' > srcs.txt
java -jar ecj.jar -8 -nowarn -proceedOnError -cp "<jars>" -d out/ @srcs.txt
```

On one 1,102-file codebase that does not build: 1,310 class files, two files with any error. A poisoned method keeps its signature, annotations and place in the hierarchy — only the body becomes a stub.

**Why bother when the frontend reads source anyway.** Bytecode buys what source cannot: a bytecode graph resolves calls the source frontend leaves unresolved, `jimple2cpg` gives you framework *behaviour* rather than just signatures, and a template or codegen compiler usually needs the application's own compiled classes before it will translate anything. If a build looks impossible, that is worth ten minutes of testing before you plan around it.

## When dependency resolution looks impossible

It usually is not. Across nine 2000s-era codebases, all nine reached at least 90% of their external artifacts. **You need jars, not a build**, so use `mvn dependency:copy-dependencies`, which skips compilation, plugins, codegen and tests.

Four failure modes look like missing artifacts and are not. The script detects the middle two and prints the fix.

- **A dead corporate repository.** Maven Central is append-only and still serves 2006-era jars. The old repository was often only a proxy of Central, so retry the coordinate against Central.
- **A blocked `http://` repository.** Old POMs hardcode plain HTTP. Maven 3.8 and later block it. One `mirrorOf: external:http:*` entry in `settings.xml` fixes every such repository at once.
- **Reactor-internal modules.** If the unresolved artifacts share the project's own groupId, they are its own modules. Build the reactor once instead of hunting for them.
- **A version that was never published.** Check the adjacent versions before you conclude the artifact is gone.

Partial resolution still helps. Treat coverage as a percentage, never as a yes or no.

**Scope note.** `--inference-jar-paths` fixes call *signatures*, not library *structure*. A framework class still has no methods and no members. Framework **behavior** needs `jimple2cpg` over the jar itself.

## Ask questions

Start one server, then query it by naming the graph:

```bash
nohup joern --server --server-host 127.0.0.1 --server-port 8080 > /tmp/joern-server.log 2>&1 &
scripts/gq.py <out.cpg.bin> -e 'cpg.method.internal.size'
```

`joern --script` costs 5–10 seconds per question. A warm server answers in well under a second, which is what makes twenty narrowing questions practical.

`gq.py` binds `cpg` to the graph you name, so a concurrent `importCpg` cannot redirect your query to another codebase. It also warns when the graph has no overlays. Do not reach the endpoint with `curl`, which has neither guard.

Nothing evicts a graph, so memory only grows. Run `scripts/gq.py <cpg> --unload` when you finish with one, and give an unrelated codebase its own server and port.

Send a whole-graph pass to an isolated `joern --script -J-Xmx5g` instead, so one heavy traversal cannot evict everyone else's work.

## Three things about the endpoint

- **It returns the REPL's rendering of values, not printed output.** A `println` in your query vanishes. Make the last expression the thing you want back.
- **It renders every intermediate `val`.** A one-number query can come back as megabytes of pretty-printed case classes. `gq.py` wraps your query in a function, so only the result comes back. Wrapping in `{ ... }` does not work.
- **`importCpg` copies the graph into `./workspace`**, relative to the directory the server started in. That is why a `workspace/` folder appears there.

## Install

```bash
which joern javasrc2cpg java && java -version
```

- **Joern** — <https://docs.joern.io/installation>. Many distributions symlink only `joern`, so `javasrc2cpg` is present but not on `PATH`. The build script looks next to `joern` and finds it.
- **JDK 21** works. Joern ships its own Scala.
- **Maven** only if you resolve dependencies from a POM.

The type-checked query workspace is separate and optional. See [lsp-workspace.md](./lsp-workspace.md).
