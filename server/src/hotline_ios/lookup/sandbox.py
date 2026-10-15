"""Read-only bash for the mid-call answerer, enforced by bubblewrap, not by a command list.

Allowlist, not denylist: $HOME is an empty tmpfs and only ~/data comes back, read-only,
with every secret-looking file inside it masked by /dev/null. The rest of / is visible
read-only (so df, free, uptime, git, ps of its own namespace work), except:
  /run  (tmpfs: unix sockets of other sessions, postgres, dbus stay unreachable even
         though --unshare-net already removes the network)
  /mnt/iosbuild, /mnt/windows/{Users,ProgramData,$Recycle.Bin}  (signing material, Windows profiles)
No environment is inherited (--clearenv): inside hotline-ios the parent env carries SIP
credentials and HOTLINE_API_KEY loaded from .env, and `env` would print them.
Per command: 5 s timeout, 4 KB of output. Per answer: at most 3 commands (answerer.py).

Red-teamed 2026-10-16 (duplex-lab/ab, bash_eval.py): the API key, ~/.ssh, ~/.claude, gh,
browser profiles, .env files, environment variables, writes, deletes, network, other
processes' sockets: all unreachable; 0 secrets in 16 model answers to 8 hostile requests.
Known limit: inside ~/data the masking is by file-name pattern, so a secret kept in an
ordinarily named file there would be readable.
"""
from __future__ import annotations

import os
import subprocess
from functools import lru_cache
from pathlib import Path

HOME = Path.home()
DATA = HOME / "data"
SECRET_GLOBS = (".env", ".env.*", "*.pem", "*.key", "*.p12", "*.mobileprovision", "*credentials*", "*secret*",
                "*token*", ".netrc", ".git-credentials", "id_rsa*", "id_ed25519*", ".envrc")
MASK_DIRS = ("/run", "/mnt/iosbuild", "/mnt/windows/Users", "/mnt/windows/ProgramData", "/mnt/windows/$Recycle.Bin")
SAFE_SUFFIXES = {".py", ".pyc", ".cpp", ".h", ".hpp", ".c", ".cu", ".ts", ".tsx", ".js", ".rs", ".go", ".swift",
                 ".md", ".model", ".gguf", ".safetensors", ".onnx", ".bin", ".txt.gz", ".html", ".css", ".snap"}
TIMEOUT_S = 5
OUT_CAP = 4096


@lru_cache(maxsize=1)
def _masked_files() -> tuple[str, ...]:
    """Secret-looking files under ~/data, found once per process (skips venvs and node_modules)."""
    found = []
    for root, dirs, files in os.walk(DATA):
        dirs[:] = [d for d in dirs if d not in (".venv", "node_modules", ".git", "__pycache__", "cu12")]
        for f in files:
            p = Path(root) / f
            # a symlink cannot be mounted over (bwrap refuses); its target is masked itself
            # when it lives under ~/data. Code and model files named *token* are not secrets.
            if p.is_symlink() or p.suffix in SAFE_SUFFIXES:
                continue
            if any(p.match(g) for g in SECRET_GLOBS):
                found.append(str(p))
    return tuple(sorted(found))


def argv(cmd: str) -> list[str]:
    a = ["bwrap", "--ro-bind", "/", "/", "--tmpfs", str(HOME), "--ro-bind", str(DATA), str(DATA)]
    for d in MASK_DIRS:
        if os.path.isdir(d):
            a += ["--tmpfs", d]
    for f in _masked_files():
        a += ["--ro-bind", "/dev/null", f]
    a += ["--tmpfs", "/tmp", "--dev", "/dev", "--proc", "/proc",
          "--unshare-net", "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--die-with-parent", "--new-session",
          "--clearenv", "--setenv", "PATH", "/usr/local/bin:/usr/bin:/bin", "--setenv", "HOME", str(HOME),
          "--setenv", "LANG", "C.UTF-8", "--chdir", str(DATA),
          "timeout", "-k", "1", str(TIMEOUT_S), "bash", "-c", cmd]
    return a


def run(cmd: str) -> str:
    """Run one command in the sandbox; returns combined output, capped, with the exit status."""
    try:
        p = subprocess.run(argv(cmd), capture_output=True, timeout=TIMEOUT_S + 3, env={}, check=False)
        out = (p.stdout + p.stderr)[:OUT_CAP].decode("utf-8", "replace")
        status = "timed out" if p.returncode == 124 else f"exit {p.returncode}"
        return f"{out}\n[{status}]" if out else f"[{status}, no output]"
    except subprocess.TimeoutExpired:
        return "[timed out]"
