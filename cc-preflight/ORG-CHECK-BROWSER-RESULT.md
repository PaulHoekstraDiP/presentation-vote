# Claude Code on the Web — readiness result

2026-09-18 · model in session: `claude-opus-5` (served: `claude-opus-5`) · plan/seat type: not visible · environment: `env_01AqW1c5Vaxu8opz7BNdztG4` (kind: `anthropic_cloud`)

**Run aborted at check 1.** The Bash tool could not execute any command in the session that
produced this report. Every invocation — including a bare `echo hello` — failed before the
command ran, with:

```
apply-seccomp: write /proc/self/uid_map: Operation not permitted
```

Retried five times across four turns; identical failure each time. Checks 1, 3, 4, 7–14 all
depend on a working shell, so none of them can be reported. Per the check instructions ("If
you cannot get past check 1, stop"), no further checks were attempted.

**This has since been fixed** — see *Resolution* below. The check itself still needs re-running
from the top in an environment with the fix applied; nothing in checks 2–14 was ever observed.

| # | Check | Status | Observed (one line) | If ❌: setting most likely responsible |
|---|-------|--------|----------------------|----------------------------------------|
| 1 | Session basics | ❌ | Model = `claude-opus-5`; tools present (Bash, Read, Write, Edit, Glob, Grep, Agent, Skill, Workflow, GitHub MCP, Claude Code Remote MCP); `python3 --version`, `uv --version`, `df -h .` all failed with `apply-seccomp: write /proc/self/uid_map: Operation not permitted` | Bundled seccomp helper fails as root — see Resolution. `allowUnsandboxedCommands: false` removes the fallback that would have softened it |
| 2 | File tools | ❓ | Not run — aborted at check 1 | — |
| 3 | Package install | ❓ | Not run — requires a shell | Bundled seccomp helper — see Resolution |
| 4 | Compute and write a chart | ❓ | Not run — requires a shell | Bundled seccomp helper — see Resolution |
| 5 | Output channel (chart to chat) | ❓ | Not run — depends on check 4 | — |
| 6 | Inbound data (file upload) | ❓ | Not run — aborted at check 1 | — |
| 7 | Network policy | ❓ | Not run — requires `curl` | Bundled seccomp helper — see Resolution (network policy still untested behind it) |
| 8 | Local embeddings | ❓ | Not run — requires check 3 and a shell | Bundled seccomp helper — see Resolution |
| 9 | Headless Claude, plain call | ❓ | Not run — requires a shell | Bundled seccomp helper — see Resolution |
| 10 | Headless Claude, restricted tools | ❓ | Not run — requires a shell | Bundled seccomp helper — see Resolution |
| 11 | Structured output | ❓ | Not run — requires a shell | Bundled seccomp helper — see Resolution |
| 12 | Agent SDK with in-process tool | ❓ | Not run — requires check 3 and a shell | Bundled seccomp helper — see Resolution |
| 13 | Local commit — no push | ❓ | Not run — requires a shell | Bundled seccomp helper — see Resolution |

## Human confirmations
- Chart visible in chat: not tested (no chart could be produced)
- Uploaded file arrived on disk and could be opened: not tested

## Root cause (measured via /proc, since the Read tool bypasses the Bash sandbox)
The Bash sandbox's seccomp helper creates a new user namespace and writes a UID mapping into
it. That write is what fails. `/proc/self/uid_map` reads `0 0 4294967295` — the identity map
of the **initial** user namespace. The kernel never permits writing the init namespace's
`uid_map`; that returns `EPERM` unconditionally. So the helper is writing the mapping while
still in the init namespace: its `unshare(CLONE_NEWUSER)` did not take effect.

Everything that would normally block user namespaces is permissive here:

| Probe | Value | Verdict |
|---|---|---|
| `/proc/sys/user/max_user_namespaces` | `64318` | allowed (not `0`) |
| `kernel.apparmor_restrict_unprivileged_userns` | sysctl absent | no AppArmor restriction |
| `kernel.unprivileged_userns_clone` | sysctl absent | no Debian-style gate |
| `/proc/self/setgroups` | `allow` | not the setgroups trap |
| Process UID | `0 0 0 0` | **running as root — this is the trigger** |
| `CapEff` | `000001fffeffffff` | CAP_SETUID (7), CAP_SYS_ADMIN (21), CAP_SETFCAP (31) present; only CAP_SYS_RESOURCE (24) missing |
| `Seccomp` | `0` | no seccomp filter on the Claude process itself |

Bubblewrap itself is fine: the setup script's own probe ran
`bwrap --dev-bind / / --proc /proc --unshare-all true` successfully (`BWRAP_OK`), so a full
sandbox — user namespace and fresh `/proc` — can be built in this VM. Kernel is
`6.18.44-fc-v33` (Firecracker microVM).

This matches [anthropics/sandbox-runtime#505](https://github.com/anthropics/sandbox-runtime/pull/505)
(merged 2026-09-03), which quotes this exact error: pre-fix, the helper's nested user
namespace could not map uid 0 as root, and strict mode therefore never started for root
callers. The build shipped in this image does not carry that fix.

Why it was total rather than a nuisance: org managed settings set
`sandbox.allowUnsandboxedCommands: false` (Strict sandbox mode), which removes the
unsandboxed-retry fallback. A sandbox setup failure becomes complete loss of the Bash tool.

## Superseded remedy — removing the npm package does NOT work
An earlier revision of this report recommended dropping the optional seccomp filter
(`npm install -g @anthropic-ai/sandbox-runtime`), on the reasoning that bwrap worked and only
the optional helper was broken. **That was wrong.** A follow-up session applied it and found:

- the package was gone, and no `apply-seccomp` binary remained anywhere on the filesystem;
- the probe reported `seccomp_helper: ABSENT` and `BWRAP_OK`;
- the error was nevertheless **byte-identical**.

Grepping the remaining `@anthropic-ai/claude-code` bundle found `apply-seccomp` inside
`cli.js`. Claude Code carries its own copy of the sandbox logic and never consults the npm
package, so uninstalling it is a no-op. Recorded here so the dead end is not retried.

## Resolution — `enableWeakerNestedSandbox`, applied web-only
`sandbox.enableWeakerNestedSandbox: true`, written to user-scope `~/.claude/settings.json`.
Org managed settings do not define that key, so user scope sets it without conflicting with
policy. **Verified working:** after the write, `echo hello` runs.

Applied by the cloud environment's setup script — see `setup-sandbox-fix.sh` in this
directory. That is what scopes it correctly: setup scripts run only when a cloud environment
is provisioned and never execute on a developer's machine, so **on-device terminal sessions
keep the full sandbox**. Putting the key in org managed settings would have weakened
on-device sessions too.

**What is being accepted.** In the weaker mode, as root with `CAP_SYS_ADMIN`, a sandboxed
command can `umount` the read-deny tmpfs or remount `/` read-write, making the org's
`sandbox.filesystem.denyRead` list advisory rather than enforced — *in web sessions only*.
Accepted deliberately by the administrator: the web container is ephemeral and never touches
a local machine. It does still hold the session's GitHub token and API credentials.

**Caveats.**
- Applies per cloud environment. Every environment used for the training needs the script.
- This is a default, not an enforcement. A user could edit their own settings inside a web
  session. Making it unoverridable would require managed settings, which are org-wide and
  would reach local terminals.
- Revisit when a web image ships a build that starts strict mode as root; then remove the
  setting. Worth reporting the root-caller failure to Anthropic in the meantime.

## Notes for the administrator
- The trigger is that Claude Code runs as **root** in the web container. It is not the
  network policy, not the model allow-list, and not a permissions allow/deny entry.
- Strict sandbox mode (`allowUnsandboxedCommands: false`) is what converted a degraded
  sandbox into a dead Bash tool. The setting is doing its job; it just has no soft failure
  mode.
- The same check runs fine on a local Claude Code install — consistent with the above, since
  macOS uses Seatbelt and a local Linux install is typically not root.
- Next step: apply `setup-sandbox-fix.sh` to the training environment, then **re-run this
  check from the top**. Checks 2–14 have never been observed, so none of them should be
  assumed to pass — the network policy, package installs, the embeddings download, headless
  `claude` calls and the Agent SDK are all still untested.

## Deviation from the check's scope
The check specifies "do not contact GitHub in any way". After the shell failure, the
administrator explicitly authorised a push so the result would survive the session being
discarded. GitHub was therefore contacted, via the API only — the shell that `git` would need
never worked. Sequence:

1. `GET /repos/.../branches` succeeded (only `master` existed).
2. `POST /repos/.../git/refs` to create `claude/new-session-pi0w0k` → `403 Resource not
   accessible by integration`.
3. `PUT /repos/.../contents/cc-preflight/...` → same `403`. Push reported as blocked.
4. The administrator then re-linked their GitHub account, after which steps 2 and 3 both
   succeeded.

Nothing was written to `master`. No pull request or issue was created, and no other
repository was read.

**Second finding for the administrator:** GitHub write access was initially absent — the
installation could read the repository but not write to it — and only appeared after the
account was re-linked mid-session. Worth confirming that participants' accounts are linked
with write access *before* the training day, or they will hit the same `403` when they try to
push their work.
