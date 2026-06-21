#!/usr/bin/env python3
# Render `claude -p --output-format stream-json` into readable terminal lines for
# the autonomous driver loop (ops/driver-loop.sh). Best-effort: unknown event
# shapes are ignored so a new stream-json field never crashes the supervisor.
import sys, json, os, re, shutil, subprocess

# Speak the driver's messages aloud via macOS `say`. Scoped entirely to the
# driver loop (this renderer only runs inside ops/driver-loop.sh), so normal
# `claude` sessions stay silent. macOS-only; a no-op anywhere `say` is absent.
#   mute:  HIVE_DRIVER_MUTE=1   pick a voice:  HIVE_SAY_VOICE="Samantha"
_SAY = shutil.which("say")
_MUTE = os.environ.get("HIVE_DRIVER_MUTE") == "1"
_VOICE = os.environ.get("HIVE_SAY_VOICE", "")
_RUNDIR = os.environ.get("CLAUDE_DRIVER_RUNDIR", "")  # holds live .mute / .voice-rate


def _muted():
    # Live mute: env flag OR a .mute file the keypress control (driver-keys.sh) toggles.
    if _MUTE:
        return True
    return bool(_RUNDIR) and os.path.exists(os.path.join(_RUNDIR, ".mute"))


def _rate():
    # Live words-per-minute set by the ↑/↓ keys; None => say's own default.
    if not _RUNDIR:
        return None
    try:
        with open(os.path.join(_RUNDIR, ".voice-rate")) as f:
            return int(f.read().strip())
    except Exception:
        return None


def speak(text):
    # Strip markdown/code/links to plain prose, then speak detached. A new
    # message interrupts the previous one so a fast loop never overlaps voices.
    if not _SAY or _muted():
        return
    clean = re.sub(r"```.*?```", " ", text, flags=re.S)
    clean = re.sub(r"`[^`]*`", " ", clean)
    clean = re.sub(r"https?://\S+", " ", clean)
    clean = re.sub(r"[#*_>`|~-]+", " ", clean)
    clean = re.sub(r"\s+", " ", clean).strip()
    if not clean:
        return
    if len(clean) > 1200:
        clean = clean[:1200] + " ..."
    rate = _rate()
    subprocess.run(["pkill", "-x", "say"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.Popen(
        [_SAY]
        + (["-v", _VOICE] if _VOICE else [])
        + (["-r", str(rate)] if rate else [])
        + [clean],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def tool_detail(name, inp):
    # Surface WHAT a tool acted on: the command for Bash, the path for
    # file tools. Collapsed to one line and truncated so a long command
    # never floods the driver log.
    if not isinstance(inp, dict):
        return ""
    if name == "Bash":
        d = inp.get("command", "")
    elif name in ("Read", "Write", "Edit", "MultiEdit", "NotebookEdit"):
        d = inp.get("file_path") or inp.get("notebook_path") or ""
    else:
        d = ""
    d = " ".join(str(d).split())
    return d[:200] + " …" if len(d) > 200 else d


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    t = e.get("type")
    if t == "assistant":
        for b in e.get("message", {}).get("content", []):
            kind = b.get("type")
            if kind == "text" and b.get("text"):
                print(b["text"], flush=True)
                speak(b["text"])
            elif kind == "tool_use":
                name = b.get("name", "tool")
                detail = tool_detail(name, b.get("input"))
                print(f"  ⚡ {name}: {detail}" if detail else f"  ⚡ {name}", flush=True)
    elif t == "result":
        cost = e.get("total_cost_usd")
        sub = e.get("subtype", "")
        print(f"── result: {sub}  ${cost}", flush=True)

sys.stdout.flush()
