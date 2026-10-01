"""Weekly dictionary review: find likely mishearings in recent dictations and
turn the ones you approve into dictionary entries and word replacements.

Everything stays on this machine. Two finders run over the last week of
history (~/.local/share/omavoice/history.jsonl):

  near   words that are a near miss of a dictionary term ("Omachi" for
         Omarchy): plain string similarity, no model
  model  the local cleanup model reads the week in batches and names words
         that look like a misheard name, product or term; every claim must
         quote text that really is in the history, or it is dropped

Suggestions you skip come back next week only if heard again; "never"
remembers them in review-ignored.json. Approving adds the term to
dictionary.txt with a `misheard as "X"` hint (which the cleanup also turns
into a worked example), and optionally an exact [text.replacements] entry in
config.toml. config.toml is validated before it is saved.
"""
import difflib
import json
import os
import re
import time
import tomllib
import urllib.request

import omavoice_store as store

DICT_PATH = os.path.join(store.CONFIG_DIR, "dictionary.txt")
VOXTYPE_CONFIG = os.path.join(store.CONFIG_DIR, "config.toml")
SUGGESTIONS = os.path.join(store.DATA_DIR, "review-suggestions.json")
IGNORED = os.path.join(store.DATA_DIR, "review-ignored.json")
WORDLIST = "/usr/share/dict/cracklib-small"
HOST = os.environ.get("OLLAMA_HOST_URL", "http://127.0.0.1:11434")
MODEL = os.environ.get("DICTATION_MODEL", "gemma4:e4b")
ADDED_SECTION = "## Added by the weekly review"
NEAR_RATIO = 0.8

WORD = re.compile(r"[A-Za-z][A-Za-z0-9'\-]*")


def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def load_dictionary(path=None):
    """[(term, hint, line_index)] from dictionary.txt, skipping comments."""
    out = []
    try:
        lines = open(path or DICT_PATH, encoding="utf-8").read().splitlines()
    except OSError:
        return out
    for i, line in enumerate(lines):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        term, _, hint = s.partition("|")
        out.append((term.strip(), hint.strip(), i))
    return out


def english_words():
    try:
        return {w.strip().lower() for w in open(WORDLIST, encoding="utf-8", errors="replace")}
    except OSError:
        return set()


def recent_texts(days=7, now=None):
    now = now or time.time()
    return [e["text"] for e in store.entries() if now - float(e.get("t", 0)) <= days * 86400 and e.get("text")]


def _context(texts, heard, width=60):
    pat = re.compile(r"(?<!\w)" + re.escape(heard) + r"(?!\w)", re.I)
    for t in texts:
        m = pat.search(t)
        if m:
            a, b = max(0, m.start() - width), min(len(t), m.end() + width)
            return ("..." if a else "") + t[a:b].strip() + ("..." if b < len(t) else "")
    return ""


def _known_misheard(dictionary):
    """Forms already handled: hints that say misheard as "X"."""
    known = set()
    for _, hint, _ in dictionary:
        for m in re.finditer(r'misheard as "([^"]+)"', hint, re.I):
            known.add(norm(m.group(1)))
    return known


def _replacements(path=None):
    try:
        return {norm(k) for k in tomllib.load(open(path or VOXTYPE_CONFIG, "rb")).get("text", {}).get("replacements", {})}
    except (OSError, tomllib.TOMLDecodeError):
        return set()


def find_near(texts, dictionary, english=None):
    """Near misses of dictionary terms, as [{heard, term, kind, count}]."""
    english = english if english is not None else english_words()
    terms = [(t, norm(t), len(t.split())) for t, _, _ in dictionary if len(norm(t)) >= 4]
    # Spelled exactly like a term (spaces kept, case and punctuation ignored).
    surface = lambda w: " ".join(norm(x) for x in w)
    exact = {surface(t.split()) for t, _, _ in dictionary}
    found = {}
    for text in texts:
        words = WORD.findall(text)
        for n in (1, 2, 3):
            for i in range(len(words) - n + 1):
                span = words[i:i + n]
                heard = " ".join(span)
                h = norm(heard)
                if len(h) < 4:
                    continue
                # "Omarchy" or "on Omarchy" already has the right spelling;
                # "North wind" for Northwind does not, so it still counts.
                if any(surface(span[a:b]) in exact for a in range(n) for b in range(a + 1, n + 1)):
                    continue
                if n == 1 and h in english:
                    continue
                if n > 1 and all(norm(w) in english for w in words[i:i + n]) and not any(w[0].isupper() for w in words[i:i + n]):
                    continue
                for term, t, tn in terms:
                    if abs(len(h) - len(t)) > max(2, len(t) // 3) or abs(tn - n) > 1:
                        continue
                    r = difflib.SequenceMatcher(a=h, b=t).ratio()
                    if r >= NEAR_RATIO:
                        key = (h, term)
                        f = found.setdefault(key, {"heard": heard, "term": term, "kind": "near", "count": 0, "score": r})
                        f["count"] += 1
    return list(found.values())


SCHEMA = {
    "type": "object",
    "properties": {"items": {"type": "array", "items": {
        "type": "object",
        "properties": {"heard": {"type": "string"}, "term": {"type": "string"}, "why": {"type": "string"}},
        "required": ["heard", "term", "why"]}}},
    "required": ["items"],
}


def _ask_model(batch, dictionary_text):
    prompt = (
        "These are speech-to-text dictations by one person. Find words or short phrases that were most likely MISHEARD: "
        "a name, product, company, place or technical term that came out as a different, wrong spelling or as ordinary words. "
        "Use the person's dictionary below as strong evidence. For each, give `heard` copied exactly from the text and `term`, "
        "the correct spelling. Only include clear cases. Ignore normal words that are spelled correctly, grammar, style and "
        "punctuation. Return an empty list when nothing is misheard.\n\n"
        f"<dictionary>\n{dictionary_text}\n</dictionary>\n\n<dictations>\n{batch}\n</dictations>")
    body = json.dumps({
        "model": MODEL, "stream": False, "think": False, "keep_alive": "10m", "format": SCHEMA,
        "messages": [{"role": "user", "content": prompt}],
        # num_ctx matches dictation-cleanup, so this never forces a reload.
        "options": {"temperature": 0, "num_ctx": 8192, "num_predict": 600},
    }).encode()
    req = urllib.request.Request(f"{HOST}/api/chat", data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(json.load(r)["message"]["content"]).get("items", [])


def find_with_model(texts, dictionary, batch_words=900):
    dictionary_text = "\n".join(t + (f" | {h}" if h else "") for t, h, _ in dictionary)
    batches, cur, n = [], [], 0
    for t in texts:
        cur.append(t)
        n += len(t.split())
        if n >= batch_words:
            batches.append(cur)
            cur, n = [], 0
    if cur:
        batches.append(cur)
    found = {}
    for b in batches:
        joined = "\n".join(b)
        try:
            items = _ask_model(joined, dictionary_text)
        except (OSError, ValueError, KeyError):
            continue
        for it in items:
            heard, term = str(it.get("heard", "")).strip(), str(it.get("term", "")).strip()
            # The model must quote real text and propose a real change.
            if not heard or not term or norm(heard) == norm(term) or len(heard) > 40 or len(term) > 40:
                continue
            if not re.search(r"(?<!\w)" + re.escape(heard) + r"(?!\w)", joined, re.I):
                continue
            key = (norm(heard), term)
            f = found.setdefault(key, {"heard": heard, "term": term, "kind": "model", "count": 0, "why": str(it.get("why", ""))[:120]})
            f["count"] += 1
    return list(found.values())


def _load_json(path, default):
    try:
        return json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        return default


def ignored():
    return set(_load_json(IGNORED, []))


def ignore(s):
    items = ignored() | {f"{norm(s['heard'])}>{s['term']}"}
    store._private_dir()
    store._write_private(IGNORED, json.dumps(sorted(items)))


def scan(days=7, use_model=True, now=None):
    """Find suggestions for the last `days` days and save them for review."""
    texts = recent_texts(days, now)
    dictionary = load_dictionary()
    skip = _known_misheard(dictionary) | _replacements()
    never = ignored()
    found = find_near(texts, dictionary)
    if use_model and texts:
        found += find_with_model(texts, dictionary)
    out, seen = [], set()
    for s in sorted(found, key=lambda s: (s["kind"] != "near", -s["count"])):
        h = norm(s["heard"])
        if h in skip or f"{h}>{s['term']}" in never or h in seen:
            continue
        seen.add(h)
        s["context"] = _context(texts, s["heard"])
        s["in_dictionary"] = any(norm(t) == norm(s["term"]) for t, _, _ in dictionary)
        out.append(s)
    store._private_dir()
    store._write_private(SUGGESTIONS, json.dumps({"time": time.time(), "dictations": len(texts), "items": out},
                                                  ensure_ascii=False, indent=1))
    return out


def pending():
    return _load_json(SUGGESTIONS, {}).get("items", [])


def clear_pending():
    try:
        os.remove(SUGGESTIONS)
    except OSError:
        pass


def add_to_dictionary(term, heard, path=None):
    """Add `term` (or extend its line) with a misheard-as hint. Returns the line."""
    path = path or DICT_PATH
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        lines = []
    note = f'misheard as "{heard}"'
    for i, line in enumerate(lines):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        t, sep, hint = s.partition("|")
        if norm(t) == norm(term):
            hint = hint.strip()
            if note.lower() in hint.lower():
                return lines[i]
            lines[i] = f"{t.strip()} | {hint + ', ' if hint else ''}{note}"
            break
    else:
        if ADDED_SECTION not in lines:
            lines += ["", ADDED_SECTION]
        lines.append(f"{term} | {note}")
        i = len(lines) - 1
    with open(path + ".review.tmp", "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(path + ".review.tmp", path)
    return lines[i]


def add_replacement(heard, term, path=None):
    """Add "heard" = "term" to [text.replacements]; the file is only replaced
    when the result still parses. Returns True when it changed."""
    path = path or VOXTYPE_CONFIG
    text = open(path, encoding="utf-8").read()
    data = tomllib.loads(text)
    reps = data.get("text", {}).get("replacements", {})
    if any(norm(k) == norm(heard) for k in reps):
        return False
    line = f"{json.dumps(heard.lower())} = {json.dumps(term)}"
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if l.strip() == "[text.replacements]"), None)
    if start is None:
        lines += ["", "[text.replacements]", line]
    else:
        end = next((i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith("[")), len(lines))
        while end > start + 1 and not lines[end - 1].strip():
            end -= 1
        lines.insert(end, line)
    new = "\n".join(lines)
    tomllib.loads(new)  # raises before anything is written
    with open(path + ".review.tmp", "w", encoding="utf-8") as f:
        f.write(new)
    os.chmod(path + ".review.tmp", os.stat(path).st_mode & 0o777)
    os.replace(path + ".review.tmp", path)
    return True
