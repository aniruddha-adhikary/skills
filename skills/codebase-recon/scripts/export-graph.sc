// export-graph.sc — one extraction, everything downstream in Python.
//
// The graph work that succeeded was always small hand-rolled code over a flat
// export, never a famous algorithm applied to the CPG in place. Export once,
// then iterate in Python without paying a JVM start per question.
//
//   joern --script export-graph.sc --param cpgPath=x.cpg.bin --param outDir=out/
//
// Writes TSVs:  calls  modules  tables  columns
//
// Code fields are Base64-encoded on purpose: a raw `code` column contains
// double quotes, and Python's csv module treats those as quotes even in a TSV
// and silently merges rows.

import java.io.PrintWriter
import java.util.Base64

@main def exec(cpgPath: String, outDir: String) = {
  importCpg(cpgPath)

  if (cpg.metaData.overlays.l.isEmpty) {
    println("FATAL: no overlays — every call-graph answer would be 0")
    System.exit(2)
  }
  new java.io.File(outDir).mkdirs()
  def w(name: String) = new PrintWriter(s"$outDir/$name")
  def b64(s: String) = Base64.getEncoder.encodeToString(
    Option(s).getOrElse("").getBytes("UTF-8"))

  // module = first path segment. <init>/<clinit> report filename "<empty>",
  // the literal string, so fall back to the owning type's file.
  def fileOf(m: io.shiftleft.codepropertygraph.generated.nodes.Method) = {
    val f = m.filename
    if (f == null || f.isEmpty || f == "<empty>") m.typeDecl.filename.l.headOption.getOrElse("?")
    else f
  }
  def modOf(f: String) = { val i = f.indexOf('/'); if (i > 0) f.substring(0, i) else "<root>" }

  val isAbstract = (m: io.shiftleft.codepropertygraph.generated.nodes.Method) =>
    m.modifier.modifierType.exists(_ == "ABSTRACT")

  // --- calls: resolved edges only, abstract declarations dropped -------------
  val c = w("calls.tsv"); c.println("caller\tcallee")
  cpg.method.internal.foreach { m =>
    m.callee.internal.filterNot(isAbstract).dedup.foreach(t => c.println(s"${m.fullName}\t${t.fullName}"))
  }
  c.close()

  // --- modules ---------------------------------------------------------------
  val mo = w("modules.tsv"); mo.println("method\tmodule\tfile")
  cpg.method.internal.foreach { m =>
    val f = fileOf(m); mo.println(s"${m.fullName}\t${modOf(f)}\t$f")
  }
  mo.close()

  // --- SQL literals, lifted to the outermost concatenation -------------------
  // A single literal is one fragment of a +-joined statement; joining every
  // literal in a method instead welds unrelated statements together.
  def sqlish(s: String) = { val u = s.toUpperCase
    u.contains("SELECT ") || u.contains("INSERT INTO") || u.contains("UPDATE ") || u.contains("DELETE FROM") }
  val t = w("sql.tsv"); t.println("method\tmodule\tline\tsql_b64")
  cpg.literal.filter(l => l.typeFullName == "java.lang.String" && sqlish(l.code)).foreach { l =>
    val outer = l.inAst.collectAll[io.shiftleft.codepropertygraph.generated.nodes.Call]
      .l.map(_.code).filter(sqlish).sortBy(-_.length).headOption.getOrElse(l.code)
    val m = l.method
    if (m != null) t.println(s"${m.fullName}\t${modOf(fileOf(m))}\t${l.lineNumber.getOrElse(-1)}\t${b64(outer)}")
  }
  t.close()

  // --- field access, for a method x field projection -------------------------
  val fa = w("fields.tsv"); fa.println("method\towner\tfield")
  cpg.fieldAccess.foreach { a =>
    val m = a.method
    if (m != null) a.fieldIdentifier.canonicalName.headOption.foreach { fn =>
      fa.println(s"${m.fullName}\t${m.typeDecl.fullName.l.headOption.getOrElse("?")}\t$fn")
    }
  }
  fa.close()

  println(s"wrote calls.tsv modules.tsv sql.tsv fields.tsv to $outDir")
}
