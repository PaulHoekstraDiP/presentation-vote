#!/bin/bash
#
# Environment setup script for Claude Code on the Web.
#
# WHY THIS EXISTS
#   Claude Code runs as root in the web container. Its seccomp helper cannot
#   build the nested user namespace it needs as root, so every Bash command
#   dies before it runs with:
#       apply-seccomp: write /proc/self/uid_map: Operation not permitted
#   Org managed settings set allowUnsandboxedCommands: false, which removes the
#   unsandboxed-retry fallback, so this is total loss of the Bash tool.
#
#   Fixed upstream in anthropics/sandbox-runtime#505 (merged 2026-09-03), but
#   not yet in the build shipped here.
#
# WHY NOT JUST REMOVE THE npm PACKAGE
#   Tried, did not work. @anthropic-ai/sandbox-runtime was uninstalled and no
#   apply-seccomp binary remained anywhere on the filesystem, yet the identical
#   error persisted. The string "apply-seccomp" is present in claude-code's own
#   bundled cli.js: Claude Code carries its own copy of the sandbox logic and
#   never consults the npm package. Removing that package is a no-op here.
#
# THE FIX
#   sandbox.enableWeakerNestedSandbox = true, written at user scope. Org managed
#   settings do not define this key, so user scope sets it without conflicting
#   with policy. Verified working: after this, `echo hello` runs.
#
# WHY THIS IS WEB-ONLY
#   Setup scripts run only when a cloud environment is provisioned. They never
#   execute on a developer's local machine, so terminal users keep the full
#   sandbox. Putting the key in org managed settings instead would weaken
#   on-device sessions too, which is exactly what we want to avoid.
#
# WHAT IS BEING ACCEPTED
#   In the weaker mode, as root with CAP_SYS_ADMIN, a sandboxed command can
#   umount the read-deny tmpfs or remount / read-write. That makes the org's
#   sandbox.filesystem.denyRead list advisory rather than enforced *in web
#   sessions only*. Accepted deliberately: the web container is ephemeral and
#   never touches a local machine. Note it does still hold the session's GitHub
#   token and API credentials.
#
# REVIEW THIS
#   Once a web image ships a build that starts strict mode as root, delete the
#   settings block below and re-test. The weakening is a workaround, not a
#   destination.

set -u

apt-get update -qq
apt-get install -y bubblewrap socat || true

# Not installed: @anthropic-ai/sandbox-runtime. Claude Code bundles its own
# sandbox logic, so the npm package has no effect on the Bash tool either way.

# Ubuntu 24.04 blocks bwrap from creating user namespaces by default
if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null)" = "1" ]; then
  cat > /etc/apparmor.d/bwrap <<'EOF'
abi <abi/4.0>,
include <tunables/global>
profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
EOF
  apparmor_parser -r /etc/apparmor.d/bwrap || true
fi

# The actual fix. Merges into any existing user settings rather than clobbering,
# and refuses to touch the file if it is not valid JSON.
mkdir -p "${HOME}/.claude"
node -e '
  const fs = require("fs");
  const p = `${process.env.HOME}/.claude/settings.json`;
  let cfg = {};
  if (fs.existsSync(p)) {
    const raw = fs.readFileSync(p, "utf8").trim();
    if (raw) {
      try {
        cfg = JSON.parse(raw);
      } catch (e) {
        console.error(`malformed JSON at ${p}, leaving it alone: ${e.message}`);
        process.exit(1);
      }
    }
  }
  cfg.sandbox = cfg.sandbox || {};
  cfg.sandbox.enableWeakerNestedSandbox = true;
  fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
  console.log(`sandbox.enableWeakerNestedSandbox = true -> ${p}`);
' || echo "WARNING: could not write user settings; the Bash tool will not work" >&2

# probe: record what the sandbox layer actually looks like this boot
{
  echo "bwrap:  $(command -v bwrap || echo MISSING)"
  echo "socat:  $(command -v socat || echo MISSING)"
  echo "userns_restrict: $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo unset)"
  echo "max_user_namespaces: $(sysctl -n user.max_user_namespaces 2>/dev/null || echo unknown)"
  echo "euid: $(id -u)  (0 means root; the seccomp helper's failure is root-specific)"

  if [ -f "${HOME}/.claude/settings.json" ]; then
    echo "weaker_nested_sandbox: $(node -e '
      try {
        const c = require(`${process.env.HOME}/.claude/settings.json`);
        console.log(c.sandbox?.enableWeakerNestedSandbox === true ? "SET" : "NOT SET");
      } catch (e) { console.log("UNREADABLE"); }
    ' 2>/dev/null || echo UNKNOWN)"
  else
    echo "weaker_nested_sandbox: NO SETTINGS FILE"
  fi

  if bwrap --dev-bind / / --proc /proc --unshare-all true 2>/tmp/bwrap-err; then
    echo "probe: BWRAP_OK"
  else
    echo "probe: BWRAP_FAIL"
    sed 's/^/  /' /tmp/bwrap-err
  fi
} > /tmp/sandbox-probe.txt 2>&1

exit 0

# VERIFY IN A FRESH SESSION
#   1. cat /tmp/sandbox-probe.txt -> expect BWRAP_OK and
#                                    weaker_nested_sandbox: SET
#   2. echo hello                 -> must actually run
#   3. /sandbox                   -> confirm the resolved config
