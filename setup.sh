#!/bin/bash
# Prepare the container to behave like a local on-device Claude Code session.
# Installs no project packages — see docs/environment-notes.md for why each
# setting is here.
set -uo pipefail

apt-get update -qq
apt-get install -y bubblewrap >/dev/null

python3 - <<'PY'
import json, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
p.parent.mkdir(parents=True, exist_ok=True)
raw = p.read_text().strip() if p.exists() else ""
cfg = json.loads(raw) if raw else {}

sb = cfg.setdefault("sandbox", {})
sb["enableWeakerNestedSandbox"] = True
sb["excludedCommands"] = ["pip *", "pip3 *", "python3 -m pip *",
                          "uv *", "uvx *", "docker *"]
fs = sb.setdefault("filesystem", {})
fs["allowWrite"] = sorted({*fs.get("allowWrite", []), "/root", "/opt", "/tmp"})

cfg.setdefault("env", {}).update({
    "PIP_BREAK_SYSTEM_PACKAGES": "1",
    "PIP_IGNORE_INSTALLED": "1",
})

p.write_text(json.dumps(cfg, indent=2) + "\n")
print("settings written")
PY

printf '%s\n' .bashrc .bash_profile .gitconfig .zshrc .zprofile .profile \
  .idea .vscode .claude .mcp.json .ripgreprc .gitmodules ':memory:*' \
  > /opt/gitignore-global
git config --global core.excludesFile /opt/gitignore-global

bwrap --dev-bind / / --proc /proc --unshare-all true 2>/dev/null \
  && echo "bwrap: OK" || echo "bwrap: FAIL"
