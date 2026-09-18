#!/bin/bash
# Prepare the container to behave like a local on-device Claude Code session.
# Installs no project packages — see docs/environment-notes.md.
set -uo pipefail

apt-get update -qq
apt-get install -y bubblewrap python3-pip git ca-certificates || true

mkdir -p /opt/cache/{matplotlib,huggingface,xdg,uv}
chmod -R 0777 /opt/cache

python3 - <<'PY' || echo "FATAL: settings not written; Bash will NOT work" >&2
import json, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
p.parent.mkdir(parents=True, exist_ok=True)
raw = p.read_text().strip() if p.exists() else ""
cfg = json.loads(raw) if raw else {}

sb = cfg.setdefault("sandbox", {})
sb["enableWeakerNestedSandbox"] = True
sb["excludedCommands"] = ["docker *", "pip *", "pip3 *", "uv *", "uvx *"]
# Never set sandbox.filesystem here: the sandbox puts $HOME on its own
# denyWrite/denyRead, so adding /root to allowWrite stops sessions starting.
sb.pop("filesystem", None)

cfg.setdefault("env", {}).update({
    "MPLCONFIGDIR": "/opt/cache/matplotlib",
    "HF_HOME": "/opt/cache/huggingface",
    "XDG_CACHE_HOME": "/opt/cache/xdg",
    "UV_CACHE_DIR": "/opt/cache/uv",
    "MPLBACKEND": "Agg",
    "PIP_BREAK_SYSTEM_PACKAGES": "1",
    "PIP_IGNORE_INSTALLED": "1",
})

p.write_text(json.dumps(cfg, indent=2) + "\n")
assert json.loads(p.read_text())["sandbox"]["enableWeakerNestedSandbox"] is True
print("settings OK")
PY

printf '%s\n' .bashrc .bash_profile .gitconfig .zshrc .zprofile .profile \
  .idea .vscode .claude .mcp.json .ripgreprc .gitmodules ':memory:*' \
  > /opt/gitignore-global
git config --global core.excludesFile /opt/gitignore-global || true

bwrap --dev-bind / / --proc /proc --unshare-all true 2>/dev/null \
  && echo "bwrap: OK" || echo "bwrap: FAIL"
