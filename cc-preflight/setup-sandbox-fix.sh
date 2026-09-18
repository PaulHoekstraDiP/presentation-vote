#!/usr/bin/env bash
#
# Claude Code on the Web — work around the root-caller sandbox failure.
#
# Symptom this fixes:
#   Every Bash command fails before it runs with
#     apply-seccomp: write /proc/self/uid_map: Operation not permitted
#
# Cause:
#   Claude Code runs as root in the web container. Pre-fix builds of
#   sandbox-runtime cannot start strict mode as root: the seccomp helper's
#   nested user namespace must map uid 0, which the kernel (5.12+) allows only
#   if the namespace creator held CAP_SETFCAP. Fixed upstream in
#   anthropics/sandbox-runtime#505 (merged 2026-09-03), but that fix needs the
#   vendored sandbox binaries rebuilt into the container image.
#
# Workaround:
#   Set sandbox.enableWeakerNestedSandbox = true, so the inner sandbox
#   bind-mounts the container's existing /proc instead of mounting a fresh one.
#
# Trade-off (accepted deliberately for the web environment):
#   On a pre-#505 build, the weaker mode as root with CAP_SYS_ADMIN lets a
#   sandboxed command umount the read-deny tmpfs or remount / read-write,
#   which makes sandbox.filesystem.denyRead advisory rather than enforced.
#   This is acceptable here because the web container is ephemeral and never
#   touches a local machine. Do NOT set this in on-device / terminal
#   environments, where the filesystem policy is doing real work.
#
# This writes the key at two scopes:
#   ~/.claude/settings.json            user scope, applies to every project
#   ./.claude/settings.local.json      project scope, higher precedence
# Org managed settings do not set this key, so neither write conflicts with
# them. Managed settings still win on every key they do define.

set -euo pipefail

apply() {
  local target="$1"
  mkdir -p "$(dirname "$target")"

  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    let cfg = {};
    if (fs.existsSync(p)) {
      const raw = fs.readFileSync(p, "utf8").trim();
      if (raw) {
        try {
          cfg = JSON.parse(raw);
        } catch (e) {
          console.error(`refusing to overwrite malformed JSON at ${p}: ${e.message}`);
          process.exit(1);
        }
      }
    }
    cfg.sandbox = cfg.sandbox || {};
    cfg.sandbox.enableWeakerNestedSandbox = true;
    fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
    console.log(`sandbox.enableWeakerNestedSandbox = true -> ${p}`);
  ' "$target"
}

apply "${HOME}/.claude/settings.json"
apply "$(pwd)/.claude/settings.local.json"

# Known gotcha: CLAUDE_CODE_SUBPROCESS_ENV_SCRUB has been reported to silently
# force enableWeakerNestedSandbox back to false (anthropics/claude-code#73786).
# If the sandbox still fails, check this first.
if [ -n "${CLAUDE_CODE_SUBPROCESS_ENV_SCRUB:-}" ]; then
  echo "WARNING: CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is set; it may silently" >&2
  echo "         disable enableWeakerNestedSandbox. See claude-code#73786." >&2
fi

echo "Done. Verify in a fresh session: run /sandbox to see the resolved"
echo "config, then confirm a plain command such as 'echo hello' executes."
