#!/bin/bash
# Claude Code on the Web — environment setup.
#
# This is the minimum that gets a session starting with a working Bash tool.
# It does NOT fix runtime egress; nothing in a setup script can. See
# FINDINGS.md in this directory for the full evidence and the options.
#
# WHAT MATTERS HERE, AND WHY
#
#   socat is REQUIRED, not optional. Managed settings set
#   sandbox.failIfUnavailable=true, so a missing sandbox dependency stops
#   Claude Code starting at all. A revision that installed only bubblewrap
#   meant no session would launch.
#
#   sandbox.enableWeakerNestedSandbox=true is what makes Bash work. Claude Code
#   runs as root here and its bundled seccomp helper cannot map uid 0 in a
#   nested user namespace, so without this every command dies with
#     apply-seccomp: write /proc/self/uid_map: Operation not permitted
#   Upstream fix is anthropics/sandbox-runtime#505 (merged 2026-09-03) but is
#   not in the shipped vendored binary as of 0.0.76.
#
#   Never set sandbox.filesystem. The sandbox puts $HOME on its own
#   denyWrite/denyRead; adding /root to allowWrite stops sessions starting.
#
#   Never set PIP_IGNORE_INSTALLED. It forces a full reinstall of every
#   dependency on each invocation.
#
# DO NOT RETRY (all measured, all dead):
#   sandbox.network.httpProxyPort            - no effect
#   sandbox.excludedCommands, bare form      - inert
#   sandbox.excludedCommands, glob form      - inert
#   external socat relay on 127.0.0.1:3128   - binds in the outer namespace,
#                                              unreachable from the sandbox
#
# IF YOU NEED PACKAGES AT RUNTIME
#   You can't have them. Build-time network works, so pre-install them here
#   (one package per pip invocation — a batched install resolves
#   all-or-nothing and one bad package silently takes out the rest), and ship
#   training datasets in the repo since URL fetching is also dead.

set -uo pipefail

apt-get update -qq
apt-get install -y bubblewrap socat python3-pip python3-venv git \
                   ca-certificates iproute2 || true

# Runtime-writable cache locations. $HOME, /usr and /tmp are all read-only to
# sandboxed commands; only $TMPDIR, the working directory, and what we create
# here are writable. 0777 because these must be written at runtime, not just
# read.
mkdir -p /opt/cache/{matplotlib,huggingface,xdg,uv}
chmod -R 0777 /opt/cache

# No `hooks` block on purpose: a malformed one stops sessions starting.
python3 - <<'PY' || echo "FATAL: settings not written; Bash will NOT work" >&2
import json, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
p.parent.mkdir(parents=True, exist_ok=True)
raw = p.read_text().strip() if p.exists() else ""
cfg = json.loads(raw) if raw else {}

sb = cfg.setdefault("sandbox", {})
sb["enableWeakerNestedSandbox"] = True
sb.pop("filesystem", None)       # stops sessions starting
sb.pop("excludedCommands", None) # inert here; dropped to avoid implying otherwise

env = cfg.setdefault("env", {})
env.update({
    "MPLCONFIGDIR": "/opt/cache/matplotlib",
    "HF_HOME": "/opt/cache/huggingface",
    "XDG_CACHE_HOME": "/opt/cache/xdg",
    "UV_CACHE_DIR": "/opt/cache/uv",
    "MPLBACKEND": "Agg",
    "PIP_BREAK_SYSTEM_PACKAGES": "1",
})
env.pop("PIP_IGNORE_INSTALLED", None)

p.write_text(json.dumps(cfg, indent=2) + "\n")
assert json.loads(p.read_text())["sandbox"]["enableWeakerNestedSandbox"] is True
print("settings OK")
PY

# Session scaffolding shows as untracked and trips the git stop-hook on every
# turn. Global excludes file, so the repo itself is not modified.
printf '%s\n' .bashrc .bash_profile .gitconfig .zshrc .zprofile .profile \
  .idea .vscode .claude .mcp.json .ripgreprc .gitmodules ':memory:*' \
  > /opt/gitignore-global
git config --global core.excludesFile /opt/gitignore-global || true

{
  command -v bwrap >/dev/null && echo "bwrap: OK" || echo "bwrap: MISSING"
  command -v socat >/dev/null && echo "socat: OK" \
    || echo "socat: MISSING — Claude Code will NOT start"
  bwrap --dev-bind / / --proc /proc --unshare-all true 2>/dev/null \
    && echo "bwrap probe: OK" || echo "bwrap probe: FAIL"
  echo "euid: $(id -u)"
} > /tmp/sandbox-probe.txt 2>&1

cat /tmp/sandbox-probe.txt
exit 0
