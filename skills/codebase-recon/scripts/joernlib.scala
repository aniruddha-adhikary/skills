package joernlib

import io.shiftleft.codepropertygraph.generated.{Cpg, DiffGraphBuilder}
import io.shiftleft.codepropertygraph.generated.nodes.*
import io.shiftleft.semanticcpg.language.*

/** Reusable Joern traversals, so a pattern page can name a function instead of
  * printing forty lines of Scala into your context.
  *
  *   scripts/gq.py <cpg> -e 'JL.health(cpg)'          // auto-loaded into the session
  *   joern --import joernlib.scala --script yours.sc   // for a standalone script
  *
  * Every function here was extracted from a probe that ran it on real code. The
  * comments record the failure each one exists to prevent.
  */
object JL:

  /** The REPL supplies this; a compiled build does not, and every call-graph step
    * fails without it. */
  given ICallResolver = NoResolve

  // ---------------------------------------------------------------- fidelity

  /** Answer this before trusting anything else. Empty overlays mean no call graph,
    * no CFG and no dataflow, and every such query then returns 0 in silence. */
  def health(cpg: Cpg): String =
    val ov = cpg.metaData.overlays.l
    val javaFiles = cpg.file.name.l.count(n => n.contains('.'))
    s"root=${cpg.metaData.root.l.mkString} files=$javaFiles " +
      s"methods=${cpg.method.internal.size} overlays=${ov.mkString(",")}" +
      (if ov.isEmpty then "  !! NO OVERLAYS — graph queries return 0" else "")

  /** Abort an extraction rather than emit zeros that look like findings. */
  def requireOverlays(cpg: Cpg): Unit =
    if cpg.metaData.overlays.l.isEmpty then
      System.err.println("FATAL: no overlays — every reachability answer would be 0")
      System.exit(2)

  def isAbstract(m: Method): Boolean =
    m.modifier.modifierType.exists(_ == "ABSTRACT")

  // ------------------------------------------------------- module attribution

  /** First path segment of the file. */
  def modOfFile(f: String): String =
    val s = if f == null then "" else f.replace('\\', '/')
    val i = s.indexOf('/')
    if i > 0 then s.substring(0, i) else "<unknown>"

  /** `<init>` and `<clinit>` report `filename == "<empty>"` — the literal string,
    * not "". Without this fallback whole modules come up short in every
    * module-level count, with nothing empty-looking to notice. */
  def fileOfMethod(m: Method): String =
    val f = m.filename
    if f == null || f.isEmpty || f == "<empty>" then
      m.typeDecl.filename.l.headOption.getOrElse("<none>")
    else f

  def typeToModule(cpg: Cpg): Map[String, String] =
    cpg.typeDecl.internal.l
      .map(t => (t.fullName, modOfFile(t.filename)))
      .filter(_._2 != "<unknown>").toMap

  // ------------------------------------------------------------- call graph

  /** Resolved call edges. Use this, never `methodFullName`, which names the
    * DECLARED target: one interface call site collapses to one edge instead of
    * fanning out to its implementations. Abstract declarations are dropped
    * because counting them inflates reachability straight back. */
  def callEdges(cpg: Cpg): List[(String, String)] =
    cpg.method.internal.flatMap(m =>
      m.callee.internal.filterNot(isAbstract).dedup.map(c => (m.fullName, c.fullName))
    ).l

  /** Cross-check the two derivations before running any graph algorithm on them.
    * A large `onlyResolved` is the interface-dispatch fan-out you would have lost. */
  def callEdgeDelta(cpg: Cpg): String =
    val internal = cpg.method.internal.fullName.toSet
    val resolved = callEdges(cpg).toSet
    val declared = cpg.call.l.flatMap { c =>
      val caller = c.method.fullName
      if internal.contains(c.methodFullName) && internal.contains(caller)
      then Some((caller, c.methodFullName)) else None
    }.toSet
    s"resolved=${resolved.size} declared=${declared.size} " +
      s"onlyResolved=${(resolved -- declared).size} onlyDeclared=${(declared -- resolved).size}"

  // ----------------------------------------------------------------- absence

  /** Methods nothing calls. Excluding `<...>` is not cosmetic: every constructor
    * and static initialiser has zero callers by construction. Read the dead-code
    * preconditions before believing the result. */
  def uncalled(cpg: Cpg): List[String] =
    cpg.method.internal.filterNot(_.name.startsWith("<"))
      .filter(_.callIn.isEmpty).fullName.l

  /** Prove an empty result is real. An empty traversal and "this does not occur"
    * are indistinguishable without a known positive. */
  def sanity(known: => Boolean, absent: => Boolean): String =
    s"knownPositive=${known} knownNegativeEmpty=${absent}" +
      (if known && absent then "" else "   !! a control failed; distrust every empty result")

  // ----------------------------------------------- constants and read sites

  /** Field initialisers are moved into a synthesised `<clinit>`, so no
    * intra-procedural closure reaches them. Thresholds and resource names are
    * almost never literals at the site that uses them. */
  def constOf(cpg: Cpg, typeFull: String, field: String): List[String] =
    cpg.method.fullName(s"${java.util.regex.Pattern.quote(typeFull)}[.]<clinit>.*")
      .ast.isCall.nameExact("<operator>.assignment")
      .code(s".*[.]$field = .*").code.l

  /** Every `NAME = literal` in a static or instance initialiser. */
  def initConstants(cpg: Cpg): List[(String, String)] =
    cpg.method.internal.name("<clinit>|<init>").l.flatMap { m =>
      m.ast.isCall.nameExact("<operator>.assignment").l.flatMap { a =>
        val args = a.argument.l
        val lhs = args.headOption.flatMap {
          case c: Call if c.name == "<operator>.fieldAccess" =>
            c.ast.isFieldIdentifier.l.lastOption.map(_.canonicalName)
          case i: Identifier => Some(i.name)
          case _             => None
        }
        lhs.map(n => (n, a.code))
      }
    }

  /** Config read sites, keyed by the RESOLVED receiver type. Disambiguating by
    * receiver is the step that justifies a CPG over grep: one method name commonly
    * serves several unrelated contracts, and merging them yields a wrong contract. */
  def readSites(cpg: Cpg, names: String*): List[(String, String, String)] =
    cpg.call.nameExact(names*).l.map { c =>
      (c.receiver.evalType.headOption.getOrElse("<unknown>"),
       c.argument.isLiteral.code.headOption.getOrElse("<dynamic>"),
       s"${c.method.fullName}:${c.lineNumber.getOrElse(-1)}")
    }

  /** Which external artifacts this program actually opens. */
  def resourcesRead(cpg: Cpg): List[String] =
    cpg.call.nameExact("getResourceAsStream", "getBundle", "getResource")
      .argument.isLiteral.code.dedup.l

  // --------------------------------------------------------------------- SQL

  private def sqlish(s: String): Boolean =
    val u = s.toUpperCase
    u.contains("SELECT ") || u.contains("INSERT INTO") ||
      u.contains("UPDATE ") || u.contains("DELETE FROM")

  /** SQL-shaped literals, lifted to the outermost enclosing concatenation. A single
    * literal is usually one fragment of a `+`-joined statement, and joining every
    * literal in a method instead welds unrelated statements together and invents
    * table names. Parse the result with a real SQL parser, never a regex. */
  def sqlStatements(cpg: Cpg): List[(String, String)] =
    cpg.literal.filter(l => l.typeFullName == "java.lang.String" && sqlish(l.code)).l
      .map { l =>
        val outer = l.inAst.collectAll[Call].l.map(_.code)
          .filter(sqlish).sortBy(-_.length).headOption.getOrElse(l.code)
        val m = l.method   // a single Method, and null when overlays are absent
        (if m == null then "<no-overlays>" else m.fullName,
         outer.replaceAll("\"", " ").replaceAll("\\s+", " ").trim)
      }.distinct

  // ---------------------------------------------------------------- tagging

  /** Attach external facts (config, schema, ownership) to graph nodes. Index into a
    * Map first — a per-row `fullNameExact` scan is O(rows x nodes). Query tags from
    * the NODE side: `cpg.method.where(_.tag.name("X"))`, not `cpg.tag.name("X").method`. */
  def tagMethods(cpg: Cpg, rows: List[(String, String, String)]): Int =
    val byName = cpg.method.internal.l.map(m => m.fullName -> m).toMap
    given diffGraph: DiffGraphBuilder = Cpg.newDiffGraphBuilder
    var applied = 0
    rows.foreach { case (target, key, value) =>
      byName.get(target).foreach { n => n.start.newTagNodePair(key, value).store(); applied += 1 }
    }
    flatgraph.DiffGraphApplier.applyDiff(cpg.graph, diffGraph)
    applied

  // ------------------------------------------------------------ fingerprints

  /** One token per node. level 1 keeps literals and names (exact clones), level 2
    * erases them but keeps call names (renamed clones), level 3 keeps shape only. */
  private def tok(n: AstNode, level: Int): String = n match
    case c: Call =>
      val nm = c.methodFullName
      if nm.startsWith("<operator>") then "O:" + nm.stripPrefix("<operator>.")
      else if level >= 3 then "C" else "C:" + c.name
    case _: Identifier        => "I"
    case l: Literal           => if level == 1 then "L:" + l.code else "L"
    case f: FieldIdentifier   => if level == 1 then "F:" + f.canonicalName else "F"
    case cs: ControlStructure => "S:" + cs.controlStructureType
    case _: Local             => "V"
    case _: Return            => "R"
    case _: Block             => "B"
    case _: TypeRef           => "T"
    case _: MethodParameterIn => "P"
    case _: JumpTarget        => "J"
    case other                => other.label

  /** Parenthesised pre-order walk. The closing marker matters: without it
    * `a + (b*c)` and `(a+b)*c` collide. */
  private def walk(n: AstNode, level: Int, sb: StringBuilder): Unit =
    sb.append(tok(n, level)).append('(')
    n.astChildren.l.sortBy(_.order).foreach(c => walk(c, level, sb))
    sb.append(')')

  def fingerprint(m: Method, level: Int = 2): String =
    val sb = new StringBuilder
    m.body.astChildren.l.sortBy(_.order).foreach(c => walk(c, level, sb))
    sb.toString

  /** Clone classes. Equality at level 2 is a machine-checkable certificate that
    * nothing but literals and names differ — which is what makes a collapse safe
    * to propose. It fires rarely; do not build a workflow that assumes it. */
  def cloneClasses(cpg: Cpg, level: Int = 2, minAst: Int = 22): List[(String, List[String])] =
    cpg.method.internal.filter(_.ast.size >= minAst).l
      .groupBy(m => fingerprint(m, level))
      .filter(_._2.size > 1).toList
      .map { case (fp, ms) => (fp.hashCode.toString, ms.map(_.fullName)) }
      .sortBy(-_._2.size)

  // ------------------------------------------------------------ path conditions

  /** The conjunction of conditions guarding a node, outermost first, with else
    * arms negated. This is what a business rule actually says, and it is the one
    * thing grep structurally cannot produce. */
  def pathCondition(n: AstNode): List[String] =
    val buf = scala.collection.mutable.ListBuffer[String]()
    var child: AstNode = n
    var parent = child.astParent
    var guard = 0
    while parent != null && guard < 200 do
      guard += 1
      parent match
        case cs: ControlStructure if cs.controlStructureType == "IF" =>
          val kids = cs.astChildren.l.sortBy(_.order)
          val idx = kids.indexWhere(_.id == child.id)
          val cond = cs.condition.code.headOption.getOrElse("?")
          if idx == 1 then buf.prepend(s"($cond)")
          else if idx >= 2 then buf.prepend(s"!($cond)")
        case cs: ControlStructure if cs.controlStructureType == "SWITCH" =>
          buf.prepend("[switch " + cs.condition.code.headOption.getOrElse("?") + "]")
        case _ => ()
      child = parent
      parent = try child.astParent catch case _: Throwable => null
    buf.toList
