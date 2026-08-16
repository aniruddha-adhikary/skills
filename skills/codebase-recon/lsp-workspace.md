# A workspace where a wrong traversal is a red squiggle

## Decide whether you need this

You do not need it to ask questions. `scripts/gq.py` answers in about 50 ms against a resident server, so a wrong step already fails fast.

Set this up when you write a query longer than a few lines, or when you do not know which step comes next. It gives you two things the server cannot:

- **Errors before the run.** A long script fails at the first bad step, after a JVM start and a graph load. The compiler reports every bad step at once, in seconds.
- **Completion and hover on the DSL.** `cpg.call.internal` and `_.isAbstract` both look correct and neither exists.

## Create it

```bash
scripts/new-query-workspace.sh <dir>
```

The script reads the Joern and Scala versions off the installed jars, writes the four files, then compiles. Do not copy versions out of a template. They must match the Joern that runs the script, and a mismatch compiles cleanly and fails later with a runtime linkage error.

Pass `--joern <path>` if `joern` is not on your `PATH`, and `--no-compile` to skip the first dependency fetch.

You get:

| file | role |
|---|---|
| `project.scala` | scala-cli directives, with versions already correct |
| `QueryLib.scala` | every real traversal, each taking `cpg` as a parameter |
| `scripts/shim.sc` | a three-line Joern entry point |
| `run.sh` | compile, then run |

**Put the logic in `QueryLib.scala` and keep the shim tiny.** That split is what makes the language server useful, and it is also what keeps the false errors quiet (see below).

## Attach the language server

Claude Code registers language servers **when the session starts**. Installing one mid-session does nothing until the session reloads.

Install a Scala LSP plugin with `/plugin`, or write `.lsp.json` at the project root:

```json
{
  "scala": {
    "command": "metals",
    "args": [],
    "extensionToLanguage": { ".scala": "scala", ".sc": "scala", ".sbt": "sbt" },
    "transport": "stdio",
    "maxRestarts": 3
  }
}
```

Then **stop and tell the user**:

> The Scala language server is installed but will not load until you reload. Restart the session, then tell me to continue.

Do not try to verify hover in the same session. If the `LSP` tool is still missing after a reload, the harness may need `ENABLE_LSP_TOOL=1`. Treat that as a fallback, because the tool also works without it.

## Verify before you trust it

Hover a DSL step in `QueryLib.scala`. A working setup returns the signature and the scaladoc:

```
def isExternal(value: Boolean): Iterator[Method]
Traverse to nodes where the isExternal equals the given `value`
```

`goToDefinition` should land in a `-sources.jar` under `.metals/readonly/dependencies/`. If hover returns nothing, the build server is not connected. Run `scala-cli setup-ide .` again and confirm the session reloaded.

## Gotchas

- **Call-graph steps need a resolver that the REPL supplies and a build does not.** `callIn`, `callee` and their relatives fail to compile with `No given instance of type ICallResolver`. The generated `QueryLib.scala` declares `given ICallResolver = NoResolve`. Keep it.
- **`--param` needs a name longer than one character.** `--param p=x` reaches the arg parser as `--p x`, which it rejects while reporting that it wanted `-p <str>`. Use `cpgPath`, not `p`.
- **`--classpathEntry` does not reach the script compiler.** A classes directory and a packaged jar both fail with `Not found: <package>`. Use `--import <source.scala>`, which compiles the source onto the script classpath. `run.sh` already does this.
- **Metals reports errors in `.sc` files that are not real.** It analyses them outside the build, so it reports `Not found: cpg`, `Not found: importCpg`, and an unsupported `@main`. All three are false. A three-line shim caps the noise, which is the second reason for the split.
- **Version skew is silent until it is not.** Dependencies that differ from the running Joern compile fine and fail at runtime. This is the failure the script exists to prevent.
