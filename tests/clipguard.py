"""Shared helpers for the tests that touch the live Wayland clipboard.

ClipboardGuard snapshots your real clipboard (every type) before a test and
puts it back afterwards, then checks it byte for byte. The snapshot is held in
memory and, in case the test dies, in a 0600 file under $XDG_RUNTIME_DIR (RAM),
removed at the end. Nothing here prints clipboard content, only hashes and
counts.

Synthetic test clipboards always include x-kde-passwordManagerHint, so the
clipboard history watchers (Omarchy's clipboard plugin, clipq) skip them.
"""
import hashlib
import os
import struct
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.environ.get("OMAVOICE_CLIPBOARD_BIN") or os.path.join(REPO, "build", "omavoice-clipboard")
HINT = "x-kde-passwordManagerHint"
RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "/tmp")


def build_helper():
    if not os.access(HELPER, os.X_OK) or os.path.getmtime(HELPER) < os.path.getmtime(os.path.join(REPO, "clipboard", "omavoice-clipboard.c")):
        subprocess.run([os.path.join(REPO, "clipboard", "build.sh")], check=True, stdout=subprocess.DEVNULL)


def refuse_while_dictating():
    try:
        state = open(os.path.join(RUNTIME, "voxtype", "state")).read().strip()
    except OSError:
        state = ""
    if state in ("recording", "transcribing"):
        sys.exit("refusing to run while you are dictating")


def pack(items):
    out = b"OMVCLIP1\n" + struct.pack("<I", len(items))
    for mime, data in items:
        out += mime.encode() + b"\0" + struct.pack("<Q", len(data)) + data
    return out


def unpack(blob):
    assert blob[:9] == b"OMVCLIP1\n", "bad snapshot"
    (n,) = struct.unpack("<I", blob[9:13])
    pos, items = 13, []
    for _ in range(n):
        end = blob.index(b"\0", pos)
        mime = blob[pos:end].decode()
        (length,) = struct.unpack("<Q", blob[end + 1:end + 9])
        items.append((mime, blob[end + 9:end + 9 + length]))
        pos = end + 9 + length
    return items


def dump():
    return subprocess.run([HELPER, "dump"], capture_output=True, check=True, timeout=10).stdout


def load(blob):
    r = subprocess.run([HELPER, "load"], input=blob, capture_output=True, timeout=10)
    assert r.returncode == 0, "load failed"


def types():
    return subprocess.run([HELPER, "types"], capture_output=True, text=True, timeout=10).stdout.split()


def digest(items):
    h = hashlib.sha256()
    for mime, data in sorted(items):
        h.update(mime.encode() + b"\0" + hashlib.sha256(data).digest())
    return h.hexdigest()[:16]


class ClipboardGuard:
    def __enter__(self):
        build_helper()
        refuse_while_dictating()
        self.blob = dump()
        self.items = unpack(self.blob)
        d = os.path.join(RUNTIME, "omavoice-test")
        os.makedirs(d, mode=0o700, exist_ok=True)
        self.path = os.path.join(d, "clipboard-backup")
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(self.blob)
        return self

    def __exit__(self, *exc):
        load(self.blob)
        after = unpack(dump())
        same = digest(after) == digest(self.items)
        print(("PASS" if same else "FAIL") + f"  your own clipboard is back ({len(self.items)} types, digest {digest(self.items)})")
        if same:
            os.remove(self.path)
        else:
            print(f"      a copy of it is in {self.path} (0600); restore with: omavoice-clipboard load < {self.path}")
            self.failed = True
        return False
