#!/usr/bin/env node
// Dictionary editor tests (app/Dictionary.js): round trips byte for byte,
// edits touch only their own line, sections and comments survive, and the
// result reads the same way dictation-cleanup reads it. Your own dictionary
// is only round-tripped in memory; nothing from it is printed.
import { readFileSync, existsSync, writeFileSync, mkdtempSync, rmSync } from "node:fs"
import { execFileSync } from "node:child_process"
import vm from "node:vm"
import os from "node:os"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const here = dirname(fileURLToPath(import.meta.url))
const D = {}
vm.runInNewContext(readFileSync(join(here, "../app/Dictionary.js"), "utf8").replace(/^\.pragma library.*$/m, ""), D)

let failed = 0, passed = 0
function check(name, ok, detail = "") {
  ok ? passed++ : failed++
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  (" + detail + ")" : ""}`)
}
const lines = t => t.split("\n")
const diffCount = (a, b) => {
  const x = lines(a), y = lines(b)
  let n = Math.abs(x.length - y.length)
  for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) n++
  return n
}

const example = readFileSync(join(here, "../config/dictionary.example.txt"), "utf8")
const tricky = "# header comment\n\nLoose Term\n##  People  \nSam|teammate\n  Priya Venkataraman   |  client  \n### not a section\n\n\n## Empty\n## Jargon\nWayland\n  # indented comment\nsystemd | init, \"misheard as system d\""

// ---- round trips
for (const [name, text] of [["example", example], ["tricky spacing, no final newline", tricky], ["CRLF", example.replace(/\n/g, "\r\n")], ["empty", ""]]) {
  check(`round trip is byte for byte: ${name}`, D.serialize(D.parse(text)) === text)
}
const real = join(os.homedir(), ".config/voxtype/dictionary.txt")
if (existsSync(real)) {
  const text = readFileSync(real, "utf8")
  check("round trip is byte for byte: your dictionary (not printed)", D.serialize(D.parse(text)) === text,
    `${D.entryCount(D.parse(text))} entries`)
}

// ---- structure
{
  const doc = D.parse(tricky)
  const secs = D.sections(doc)
  check("lines before the first ## form an untitled section", secs[0].name === "" && secs[0].entries.map(e => e.term).join() === "Loose Term")
  check("section names are trimmed", secs[1].name === "People")
  check("term | hint splits and trims", secs[1].entries[1].term === "Priya Venkataraman" && secs[1].entries[1].hint === "client")
  check("### is a comment, not a section", !secs.some(s => s.name.startsWith("#")) && doc.lines[6].kind === "comment")
  check("empty sections are kept", secs.some(s => s.name === "Empty" && s.entries.length === 0))
  check("indented comments are comments", doc.lines.filter(l => l.kind === "comment").length === 3)
  check("hints keep quotes and commas", secs.at(-1).entries[1].hint === "init, \"misheard as system d\"")
}

// ---- edits
{
  const doc = D.parse(example)
  const secs = D.sections(doc)
  const sam = secs.find(s => s.name === "People").entries[0]
  const edited = D.serialize(D.setEntry(doc, sam.line, "Sam", "teammate, misheard as \"Psalm\" or \"some\""))
  check("editing a hint changes exactly one line", diffCount(example, edited) === 1)
  check("edited entry reads back", D.sections(D.parse(edited)).find(s => s.name === "People").entries[0].hint.includes("\"some\""))
  const same = D.serialize(D.setEntry(doc, sam.line, " Sam ", "teammate, sometimes misheard as \"Psalm\""))
  check("saving an unchanged entry keeps its original text", same === example)
  const cleared = D.serialize(D.setEntry(doc, sam.line, "Sam", ""))
  check("clearing a hint leaves just the term", lines(cleared)[sam.line] === "Sam")

  const tools = secs.find(s => s.name === "Products and tools")
  const added = D.addEntry(doc, tools.header, "Quickshell", "Qt shell toolkit")
  const addedText = D.serialize(added)
  const toolsAfter = D.sections(added).find(s => s.name === "Products and tools")
  check("adding goes to the end of its section", toolsAfter.entries.at(-1).term === "Quickshell" && toolsAfter.entries.length === tools.entries.length + 1)
  check("adding keeps the blank line before the next section", lines(addedText)[toolsAfter.entries.at(-1).line + 1] === "")
  check("adding inserts exactly one line", lines(addedText).length === lines(example).length + 1 && diffCount(example, addedText) >= 1)
  const jargon = D.sections(doc).find(s => s.name === "Jargon")
  const last = D.sections(D.addEntry(doc, jargon.header, "Hyprland plugins")).find(s => s.name === "Jargon")
  check("adding to the last section works", last.entries.at(-1).term === "Hyprland plugins")

  const removed = D.serialize(D.removeEntry(doc, sam.line))
  check("deleting removes exactly that line", lines(removed).length === lines(example).length - 1 && !removed.includes("Psalm") && removed.includes("Priya"))
  const withSection = D.addSection(doc, "Places")
  const s2 = D.sections(withSection).at(-1)
  check("new section is appended after a blank line", s2.name === "Places" && lines(D.serialize(withSection)).at(-3) === "" && lines(D.serialize(withSection)).at(-2) === "## Places")
  const withEntry = D.addEntry(withSection, s2.header, "Secaucus")
  check("entries go into a new section", D.sections(withEntry).at(-1).entries[0].term === "Secaucus")
  const renamed = D.renameSection(doc, tools.header, "Tools")
  check("renaming a section changes one line", diffCount(example, D.serialize(renamed)) === 1 && D.sections(renamed).some(s => s.name === "Tools"))
  check("editing never mutates the original", D.serialize(doc) === example)
}

// ---- validation
check("empty term rejected", D.problem("  ", "x") !== "")
check("term starting with # rejected", D.problem("#hash", "") !== "")
check("| inside a term rejected", D.problem("a|b", "") !== "")
check("newlines rejected", D.problem("a\nb", "") !== "" && D.problem("a", "b\nc") !== "")
check("normal term accepted", D.problem("Priya Venkataraman", "client, misheard as \"Pria\"") === "")
check("duplicates found case-insensitively", D.duplicates(D.parse(example), "hubspot", -1).length === 1)

// ---- reads the way dictation-cleanup reads it
{
  const doc = D.parse(example)
  const s = D.sections(doc)
  let d = D.addEntry(doc, s.find(x => x.name === "People").header, "Aoife", "coworker, misheard as \"eefa\"")
  d = D.removeEntry(d, D.sections(d).find(x => x.name === "Jargon").entries[0].line)
  const text = D.serialize(d)
  const dir = mkdtempSync(join(os.tmpdir(), "omavoice-dict."))
  writeFileSync(join(dir, "dictionary.txt"), text)
  const py = `import importlib.machinery, importlib.util, os, sys
os.environ["OMAVOICE_CONFIG_DIR"] = sys.argv[2]
loader = importlib.machinery.SourceFileLoader("dc", sys.argv[1])
spec = importlib.util.spec_from_loader("dc", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
print(m.load_dictionary())`
  const got = execFileSync("python3", ["-c", py, join(here, "../bin/dictation-cleanup"), dir], { encoding: "utf8" }).trimEnd()
  const want = D.sections(d).flatMap(x => x.entries).map(e => (e.hint ? `${e.term} | ${e.hint}` : e.term)).join("\n")
  check("dictation-cleanup reads exactly the entries the editor shows", got === want, `${got.split("\n").length} entries`)
  rmSync(dir, { recursive: true })
}

console.log(`\n${passed} passed, ${failed} failed`)
process.exit(failed ? 1 : 0)
