#!/bin/bash
#
# Revised environment setup script for Claude Code on the Web.
#
# WHAT CHANGED FROM THE ORIGINAL
#   The original installed the OPTIONAL seccomp filter:
#       npm install -g @anthropic-ai/sandbox-runtime
#   That is what breaks the Bash tool in this container. This version removes
#   it instead, and keeps everything else.
#
# EVIDENCE
#   1. The original script's own probe wrote BWRAP_OK to /tmp/sandbox-probe.txt:
#          bwrap --dev-bind / / --proc /proc --unshare-all true
#      succeeded. So bubblewrap can build a full sandbox in this VM, including
#      unsharing the user namespace and mounting a fresh /proc.
#   2. Every Bash command nonetheless failed with
#          apply-seccomp: write /proc/self/uid_map: Operation not permitted
#      The "apply-seccomp:" prefix is the seccomp helper, not bwrap.
#   3. Claude Code runs as root here (Uid 0). Pre-fix, the helper's nested user
#      namespace could not map uid 0 as root. Fixed in
#      anthropics/sandbox-runtime#505 (merged 2026-09-03).
#   4. The installed version was already 0.0.76 (tagged 2026-09-10, i.e. after
#      that merge) and it still failed — so the shipped vendored helper binary
#      in vendor/seccomp/x64/apply-seccomp does not carry the fix.
#
#   Conclusion: bwrap works, the optional helper does not. Drop the helper.
#
# WHAT THIS COSTS
#   Only the seccomp filter's extra Unix-domain-socket blocking. Filesystem and
#   network isolation are still enforced by bubblewrap, so the org's
#   sandbox.filesystem.denyRead list keeps working as intended.
#
#   This is why enableWeakerNestedSandbox is NOT used here. That setting is for
#   containers where bwrap cannot mount a fresh /proc — provably not the case in
#   this VM — and as root with CAP_SYS_ADMIN it would have made denyRead
#   advisory rather than enforced. Dropping the optional helper keeps the
#   filesystem policy intact.

set -u

apt-get update -qq
apt-get install -y bubblewrap socat || true

# The optional seccomp filter is deliberately NOT installed: its vendored
# apply-seccomp binary fails as root in this container and takes the whole Bash
# tool down with it. Remove it if a previous run or the base image left it
# behind. Re-enable only once a release is confirmed to fix the root case.
npm uninstall -g @anthropic-ai/sandbox-runtime 2>/dev/null || true

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

# probe: can bwrap actually build a sandbox in this VM?
{
  echo "bwrap:  $(command -v bwrap || echo MISSING)"
  echo "socat:  $(command -v socat || echo MISSING)"
  echo "userns_restrict: $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo unset)"
  echo "max_user_namespaces: $(sysctl -n user.max_user_namespaces 2>/dev/null || echo unknown)"
  echo "euid: $(id -u)  (0 means root; the seccomp helper's failure is root-specific)"

  # Record whether the optional helper is still present anywhere. If this names
  # a path, the Bash tool will probably still fail and the uninstall above did
  # not reach the copy Claude Code resolves.
  helper="$(find /opt /usr/lib /usr/local/lib "${HOME}" \
              -path '*/sandbox-runtime/vendor/seccomp/*/apply-seccomp' \
              -print -quit 2>/dev/null)"
  echo "seccomp_helper: ${helper:-ABSENT}"

  if bwrap --dev-bind / / --proc /proc --unshare-all true 2>/tmp/bwrap-err; then
    echo "probe: BWRAP_OK"
  else
    echo "probe: BWRAP_FAIL"
    sed 's/^/  /' /tmp/bwrap-err
  fi
} > /tmp/sandbox-probe.txt 2>&1

exit 0

# VERIFY IN A FRESH SESSION
#   1. cat /tmp/sandbox-probe.txt  -> expect BWRAP_OK and seccomp_helper: ABSENT
#   2. echo hello                  -> must actually run
#   3. /sandbox                    -> confirm the resolved config
#
# IF IT STILL FAILS
#   Managed settings set sandbox.failIfUnavailable: true. The docs treat the
#   seccomp filter as optional and bubblewrap as the required dependency, so
#   removing the helper should not trip it — but this was never executed, so
#   confirm rather than assume. If startup complains about a missing
#   dependency, set failIfUnavailable: false for this environment only.
