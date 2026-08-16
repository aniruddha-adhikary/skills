#!/usr/bin/env python3
"""
tldstub.py — synthesise compilable stub tag-handler classes from .tld files.

Jasper refuses to translate a JSP whose custom tag handler class is not on the
classpath: `Unable to load tag handler class [...]`. On dspace6 that single cause
blocks 183 of 215 pages. Building dspace-jspui to get the real classes needs the
full maven dependency tree.

But Jasper does not need the tag's *behaviour* to translate the page — it needs
the class to exist and to expose a setter per declared attribute, because that is
what the generated servlet calls. The TLD declares exactly that, so the stubs can
be generated from the TLD itself. The page body — the HTML, the scriptlets, the
getParameter calls — is translated identically either way.

Proper XML parse (xml.etree), namespace-aware. No regex over markup.
"""
import os, subprocess, sys, xml.etree.ElementTree as ET


def local(t):
    return t.rsplit("}", 1)[-1]


def child_text(el, name, default=None):
    for c in el:
        if local(c.tag) == name:
            return (c.text or "").strip()
    return default


def scan(tld_paths):
    tags = {}
    for p in tld_paths:
        try:
            root = ET.parse(p).getroot()
        except Exception as e:
            print("TLD parse failed %s: %s" % (p, e))
            continue
        for el in root.iter():
            if local(el.tag) not in ("tag", "tag-file"):
                continue
            cls = child_text(el, "tag-class") or child_text(el, "tagclass")
            if not cls:
                continue
            body = (child_text(el, "body-content") or "JSP").upper()
            attrs = {}
            for a in el:
                if local(a.tag) != "attribute":
                    continue
                nm = child_text(a, "name")
                ty = child_text(a, "type") or "java.lang.String"
                if nm:
                    attrs[nm] = ty
            prev = tags.get(cls)
            if prev:
                prev[1].update(attrs)
            else:
                tags[cls] = (body, attrs)
        for el in root.iter():
            if local(el.tag) == "validator":
                cls = child_text(el, "validator-class")
                if cls:
                    tags.setdefault("#TLV#" + cls, ("TLV", {}))
    return tags


JAVA_KEYWORDS = {"class", "for", "if", "int", "new", "package", "public", "return"}


def emit(tags, outdir):
    n = 0
    for cls, (body, attrs) in sorted(tags.items()):
        tlv = cls.startswith("#TLV#")
        if tlv:
            cls = cls[5:]
        pkg, simple = cls.rsplit(".", 1) if "." in cls else ("", cls)
        d = os.path.join(outdir, *pkg.split(".")) if pkg else outdir
        os.makedirs(d, exist_ok=True)
        base = ("javax.servlet.jsp.tagext.TagLibraryValidator" if tlv else
                ("javax.servlet.jsp.tagext.BodyTagSupport" if body in ("JSP", "TAGDEPENDENT")
                 else "javax.servlet.jsp.tagext.TagSupport"))
        lines = []
        if pkg:
            lines.append("package %s;" % pkg)
        lines.append("public class %s extends %s {" % (simple, base))
        if not tlv:
            lines.append("  private static final long serialVersionUID = 1L;")
            for a, ty in sorted(attrs.items()):
                if a in JAVA_KEYWORDS or not a.isidentifier():
                    continue
                setter = "set" + a[0].upper() + a[1:]
                lines.append("  public void %s(%s v) { }" % (setter, ty))
            lines.append("  public int doStartTag() { return EVAL_BODY_INCLUDE; }")
            lines.append("  public int doEndTag() { return EVAL_PAGE; }")
        lines.append("}")
        with open(os.path.join(d, simple + ".java"), "w") as f:
            f.write("\n".join(lines) + "\n")
        n += 1
    return n


def main():
    webapp, outdir, cp = sys.argv[1], sys.argv[2], sys.argv[3]
    tlds = []
    for dp, dn, fn in os.walk(webapp):
        for x in fn:
            if x.endswith(".tld"):
                tlds.append(os.path.join(dp, x))
    tags = scan(tlds)
    src = os.path.join(outdir, "src")
    cls = os.path.join(outdir, "classes")
    os.makedirs(cls, exist_ok=True)
    n = emit(tags, src)
    files = []
    for dp, dn, fn in os.walk(src):
        files += [os.path.join(dp, x) for x in fn if x.endswith(".java")]
    print("tlds=%d stub classes=%d" % (len(tlds), n))
    if files:
        r = subprocess.run(["javac", "-nowarn", "-cp", cp, "-d", cls] + files,
                           capture_output=True, text=True)
        print("javac rc=%d" % r.returncode)
        if r.returncode:
            print(r.stderr[:3000])
    print("classes dir:", cls)


if __name__ == "__main__":
    main()
