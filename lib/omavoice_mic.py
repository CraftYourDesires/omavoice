"""Is the microphone actually reaching Voxtype?

Voxtype records the default PipeWire source. When that is EasyEffects'
filtered mic (easyeffects_source), EasyEffects must have a hardware capture
port linked into its input chain (ee_sie_* nodes); if that link drops (for
example after a temporary default source comes and goes) the source is
pure silence and Cohere turns it into replacement characters. EasyEffects
only links that chain while something records, so the static check is its
saved input device; listen() then records a second to catch silence.
"""
import array
import math
import os
import shutil
import subprocess
import tempfile
import time
import wave

EE_CONF = os.path.expanduser("~/.config/easyeffects/db/easyeffectsrc")


def _run(cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def default_source():
    return _run(["pactl", "get-default-source"]).strip()


def easyeffects_input_linked():
    """True when some hardware capture port feeds EasyEffects' input chain
    (only while something is recording)."""
    current = None
    for line in _run(["pw-link", "-l"]).splitlines():
        if not line.startswith((" ", "\t")):
            current = line.strip()
        elif current and current.startswith("alsa_input.") and "|->" in line and "ee_sie_" in line:
            return True
    return False


def sources():
    return [l.split("\t")[1] for l in _run(["pactl", "list", "short", "sources"]).splitlines() if "\t" in l]


def easyeffects_input_device():
    try:
        for line in open(EE_CONF, encoding="utf-8"):
            if line.startswith("inputDevice="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def listen(seconds=1.0):
    """Peak level in dBFS of the default source over `seconds`, or None."""
    fd, path = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    try:
        subprocess.run(["timeout", str(seconds), "pw-record", "--rate", "16000", "--channels", "1",
                        "--format", "s16", path], capture_output=True, timeout=seconds + 5)
        with wave.open(path) as w:
            data = w.readframes(w.getnframes())
        if not data:
            return None
        peak = max(abs(x) for x in array.array("h", data)) or 1
        return 20 * math.log10(peak / 32768)
    except (OSError, wave.Error, subprocess.TimeoutExpired, EOFError):
        return None
    finally:
        os.remove(path)


def chain_ok(probe=True):
    """(ok, detail) for the path from the microphone to Voxtype."""
    src = default_source()
    if not src:
        return False, "no default microphone (pactl get-default-source is empty)"
    if src == "easyeffects_source":
        dev = easyeffects_input_device()
        if dev and dev not in sources():
            return False, (f"EasyEffects listens to {dev}, which no longer exists, so Voxtype hears silence; "
                           "fix it with: omavoice-doctor --fix-mic")
    if probe:
        peak = listen()
        if peak is not None and peak < -88:
            return False, (f"the microphone is silent ({peak:.0f} dB peak over 1s); "
                           "if EasyEffects is in the chain try: omavoice-doctor --fix-mic")
        return True, f"{src}, {peak:.0f} dB peak over 1s" if peak is not None else src
    return True, src


def hardware_mic():
    """The highest priority hardware capture source (what WirePlumber picks)."""
    best, best_pr = "", -1
    for line in _run(["pw-cli", "ls", "Node"]).split("\tid ")[1:]:
        if 'media.class = "Audio/Source"' not in line:
            continue
        name = line.split('node.name = "', 1)[-1].split('"', 1)[0]
        pr = line.split('priority.session = "', 1)[-1].split('"', 1)[0]
        if name.startswith("alsa_input.") and pr.isdigit() and int(pr) > best_pr:
            best, best_pr = name, int(pr)
    return best


def restart_easyeffects(wait=15):
    """Point EasyEffects back at a real microphone when its saved input device
    is gone, restart it the way Omarchy's autostart runs it, and return True
    once a recording links the microphone into its chain."""
    subprocess.run(["pkill", "-x", "easyeffects"], check=False)
    for _ in range(10):
        if subprocess.run(["pgrep", "-x", "easyeffects"], capture_output=True).returncode != 0:
            break
        time.sleep(0.5)
    dev = easyeffects_input_device()
    if dev and dev not in sources():
        mic = hardware_mic()
        if mic:
            text = open(EE_CONF, encoding="utf-8").read().replace(f"inputDevice={dev}", f"inputDevice={mic}")
            with open(EE_CONF, "w", encoding="utf-8") as f:
                f.write(text)
    launcher = ["uwsm-app", "--"] if shutil.which("uwsm-app") else []
    subprocess.Popen(launcher + ["easyeffects", "--service-mode", "--hide-window"], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    time.sleep(3)
    for _ in range(wait):
        peak = listen(1.0)
        if peak is not None and peak >= -88:
            return True
    return False
