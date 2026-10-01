.pragma library
// Parser and editor for ~/.config/voxtype/dictionary.txt, the file
// dictation-cleanup reads. Pure functions with no Qt dependencies, so the
// app and the Node tests use the same code.
//
// The file is kept line for line: "## Name" starts a section, other "#"
// lines are comments, blank lines stay, and every other line is an entry,
// "term" or "term | hint". Editing changes only the lines you touch; every
// other line (comments, spacing, odd formatting) is written back byte for
// byte.

function parseLine(raw) {
  var s = raw.trim()
  if (s === "") return { kind: "blank", raw: raw }
  if (/^##(?!#)/.test(s)) return { kind: "section", raw: raw, name: s.replace(/^##\s*/, "") }
  if (s.charAt(0) === "#") return { kind: "comment", raw: raw }
  var bar = s.indexOf("|")
  var term = bar === -1 ? s : s.slice(0, bar).trim()
  var hint = bar === -1 ? "" : s.slice(bar + 1).trim()
  return { kind: "entry", raw: raw, term: term, hint: hint }
}

// text -> { lines: [...], eol: "\n" or "\r\n", finalNewline: bool }
function parse(text) {
  var t = String(text === undefined || text === null ? "" : text)
  var eol = t.indexOf("\r\n") !== -1 ? "\r\n" : "\n"
  var finalNewline = t.length > 0 && t.slice(-eol.length) === eol
  var body = finalNewline ? t.slice(0, -eol.length) : t
  var parts = t.length === 0 ? [] : body.split(eol)
  var lines = []
  for (var i = 0; i < parts.length; i++) lines.push(parseLine(parts[i]))
  return { lines: lines, eol: eol, finalNewline: finalNewline || t.length === 0 }
}

function serialize(doc) {
  var out = doc.lines.map(function(l) { return l.raw }).join(doc.eol)
  return doc.lines.length && doc.finalNewline ? out + doc.eol : out
}

function copyDoc(doc) {
  return { lines: doc.lines.map(function(l) { var c = {}; for (var k in l) c[k] = l[k]; return c }), eol: doc.eol, finalNewline: doc.finalNewline }
}

function formatEntry(term, hint) {
  var t = String(term).trim(), h = String(hint || "").trim()
  return h ? t + " | " + h : t
}

// Why a term or hint cannot be saved, or "" when it can.
function problem(term, hint) {
  var t = String(term === undefined ? "" : term).trim()
  var h = String(hint === undefined ? "" : hint)
  if (!t) return "The term is empty."
  if (t.charAt(0) === "#") return "A term cannot start with #, that would make it a comment."
  if (t.indexOf("|") !== -1) return "Put a | only between the term and its hint."
  if (/[\r\n]/.test(t) || /[\r\n]/.test(h)) return "Keep it on one line."
  return ""
}

// Sections for display: the lines before the first "##" form an untitled
// section (index -1 header). Each entry carries its line index.
function sections(doc) {
  var out = [{ name: "", header: -1, entries: [] }]
  for (var i = 0; i < doc.lines.length; i++) {
    var l = doc.lines[i]
    if (l.kind === "section") out.push({ name: l.name, header: i, entries: [] })
    else if (l.kind === "entry") out[out.length - 1].entries.push({ line: i, term: l.term, hint: l.hint })
  }
  if (out[0].entries.length === 0 && out.length > 1) out.shift()
  return out
}

function entryCount(doc) {
  var n = 0
  for (var i = 0; i < doc.lines.length; i++) if (doc.lines[i].kind === "entry") n++
  return n
}

// Other entries with the same term (case-insensitive), as line indexes.
function duplicates(doc, term, exceptLine) {
  var t = String(term).trim().toLowerCase()
  var out = []
  for (var i = 0; i < doc.lines.length; i++) {
    var l = doc.lines[i]
    if (l.kind === "entry" && i !== exceptLine && l.term.toLowerCase() === t) out.push(i)
  }
  return out
}

function setEntry(doc, line, term, hint) {
  var d = copyDoc(doc)
  var l = d.lines[line]
  if (!l || l.kind !== "entry") return d
  if (l.term === String(term).trim() && l.hint === String(hint || "").trim()) return d
  d.lines[line] = parseLine(formatEntry(term, hint))
  return d
}

function removeEntry(doc, line) {
  var d = copyDoc(doc)
  if (d.lines[line] && d.lines[line].kind === "entry") d.lines.splice(line, 1)
  return d
}

// Add an entry at the end of a section (after its last entry, before the
// blank lines that separate it from the next one). header is the section's
// "##" line index, or -1 for the lines before the first section.
function addEntry(doc, header, term, hint) {
  var d = copyDoc(doc)
  var start = header + 1
  var end = d.lines.length
  for (var i = start; i < d.lines.length; i++) {
    if (d.lines[i].kind === "section") { end = i; break }
  }
  var at = end
  while (at > start && d.lines[at - 1].kind === "blank") at--
  d.lines.splice(at, 0, parseLine(formatEntry(term, hint)))
  return d
}

// A new "## Name" section at the end, separated by one blank line.
function addSection(doc, name) {
  var d = copyDoc(doc)
  var n = String(name).trim()
  if (!n) return d
  if (d.lines.length && d.lines[d.lines.length - 1].kind !== "blank") d.lines.push(parseLine(""))
  d.lines.push(parseLine("## " + n))
  return d
}

function renameSection(doc, header, name) {
  var d = copyDoc(doc)
  var n = String(name).trim()
  if (n && d.lines[header] && d.lines[header].kind === "section") d.lines[header] = parseLine("## " + n)
  return d
}

// Line indexes that differ from another version, for "unsaved" markers.
function changedLines(a, b) {
  return serialize(a) !== serialize(b)
}
