# Claude Code on the Web — readiness result

2026-09-18 · model in session: `claude-opus-5` (served: `claude-opus-5`) · plan/seat type: not visible · environment: `env_01AqW1c5Vaxu8opz7BNdztG4` (kind: `anthropic_cloud`)

**Run aborted at check 1.** The Bash tool cannot execute any command in this session. Every
invocation — including a bare `echo hello` — fails before the command runs, with:

```
apply-seccomp: write /proc/self/uid_map: Operation not permitted
```

This is the Bash sandbox wrapper failing to initialise, not a failure of the command itself.
Retried five times across four turns, including a bare `echo hello`; identical failure each time.
Checks 1, 3, 4, 7, 8, 9, 10, 11, 12, 13 and 14 all depend on a working shell, so none of them
can be run or meaningfully reported. Per the check instructions ("If you cannot get past
check 1, stop"), no further checks were attempted.

| # | Check | Status | Observed (one line) | If ❌: setting most likely responsible |
|---|-------|--------|----------------------|----------------------------------------|
| 1 | Session basics | ❌ | Model = `claude-opus-5`; tools present (Bash, Read, Write, Edit, Glob, Grep, Agent, Skill, Workflow, GitHub MCP, Claude Code Remote MCP); `python3 --version`, `uv --version`, `df -h .` all failed with `apply-seccomp: write /proc/self/uid_map: Operation not permitted` | Optional seccomp filter fails to initialise as root — see Fix. Not a misconfigured setting; `allowUnsandboxedCommands: false` is what removes the usual fallback |
| 2 | File tools | ❓ | Not run — aborted at check 1 | — |
| 3 | Package install | ❓ | Not run — requires a shell | Optional seccomp filter — see Fix |
| 4 | Compute and write a chart | ❓ | Not run — requires a shell | Optional seccomp filter — see Fix |
| 5 | Output channel (chart to chat) | ❓ | Not run — depends on check 4 | — |
| 6 | Inbound data (file upload) | ❓ | Not run — aborted at check 1 | — |
| 7 | Network policy | ❓ | Not run — requires `curl` | Optional seccomp filter — see Fix (network policy still untested behind it) |
| 8 | Local embeddings | ❓ | Not run — requires checks 3 and a shell | Optional seccomp filter — see Fix |
| 9 | Headless Claude, plain call | ❓ | Not run — requires a shell | Optional seccomp filter — see Fix |
| 10 | Headless Claude, restricted tools | ❓ | Not run — requires a shell | Optional seccomp filter — see Fix |
| 11 | Structured output | ❓ | Not run — requires a shell | Optional seccomp filter — see Fix |
| 12 | Agent SDK with in-process tool | ❓ | Not run — requires checks 3 and a shell | Optional seccomp filter — see Fix |
| 13 | Local commit — no push | ❓ | Not run — requires a shell | Optional seccomp filter — see Fix |

## Human confirmations
- Chart visible in chat: not tested (no chart could be produced)
- Uploaded file arrived on disk and could be opened: not tested

## Root cause (measured via /proc, since the Read tool bypasses the Bash sandbox)
The Bash tool builds a sandbox by creating a new user namespace and writing a UID mapping
into it. That write is what fails. `/proc/self/uid_map` reads `0 0 4294967295` — the identity
map of the **initial** user namespace. The kernel never permits writing the init namespace's
`uid_map`; that returns `EPERM` unconditionally. So the helper is writing the mapping while
still in the init namespace: its `unshare(CLONE_NEWUSER)` did not take effect.

Everything that would normally block user namespaces is permissive here:

| Probe | Value | Verdict |
|---|---|---|
| `/proc/sys/user/max_user_namespaces` | `64318` | allowed (not `0`) |
| `kernel.apparmor_restrict_unprivileged_userns` | sysctl absent | no AppArmor restriction |
| `kernel.unprivileged_userns_clone` | sysctl absent | no Debian-style gate |
| `/proc/self/setgroups` | `allow` | not the setgroups trap |
| Process UID | `0 0 0 0` | running as root |
| `CapEff` | `000001fffeffffff` | CAP_SETUID (7), CAP_SYS_ADMIN (21) and CAP_SETFCAP (31) all present; only CAP_SYS_RESOURCE (24) missing |
| `Seccomp` | `0` | no seccomp filter on the Claude process itself |

Kernel is `6.18.44-fc-v33` (Firecracker microVM). Caveat: /proc is readable but nothing is
executable, so the helper's actual syscall sequence was not observed — the `unshare`
conclusion is the reading most consistent with the evidence, not a watched event.

## Fix — drop the optional seccomp filter (`setup-sandbox-fix.sh`)
This is a known bug, fixed upstream in
[anthropics/sandbox-runtime#505](https://github.com/anthropics/sandbox-runtime/pull/505)
(merged 2026-09-03). Pre-fix builds cannot start strict mode as root: the seccomp helper's
nested user namespace must map uid 0, which the kernel (5.12+) allows only if the namespace
creator held `CAP_SETFCAP`. The PR quotes this exact error and reports that, after the fix,
"Strict mode: now starts for root callers (previously failed at uid_map)."

Why it is total rather than a nuisance: org managed settings set
`sandbox.allowUnsandboxedCommands: false` (Strict sandbox mode), which removes the usual
fallback of retrying a failed command unsandboxed. A sandbox setup failure therefore becomes
complete loss of the Bash tool.

**It is the optional seccomp filter, not bubblewrap.** Two pieces of evidence narrow it down:

- The environment's own setup script runs a bwrap probe, and it wrote `BWRAP_OK` to
  `/tmp/sandbox-probe.txt`: `bwrap --dev-bind / / --proc /proc --unshare-all true` succeeded.
  Bubblewrap can therefore build a full sandbox in this VM, user namespace and fresh `/proc`
  included.
- The runtime error is prefixed `apply-seccomp:` — the seccomp helper, which the setup script
  installs separately via `npm install -g @anthropic-ai/sandbox-runtime` and which the docs
  describe as optional.

The installed version was already **0.0.76** (tagged 2026-09-10, after the #505 merge) and it
still failed. The helper ships as a prebuilt vendored binary at
`vendor/seccomp/x64/apply-seccomp`, so the fix has evidently not reached that blob. Upgrading
the package is not a route forward today.

**Chosen remedy:** `setup-sandbox-fix.sh` in this directory is a revised setup script that
stops installing the optional seccomp filter and uninstalls it if the base image ships one.
Bubblewrap then handles the sandbox on its own.

**What that costs:** only the seccomp filter's extra Unix-domain-socket blocking. Filesystem
and network isolation remain enforced by bubblewrap, so the org's
`sandbox.filesystem.denyRead` list keeps working.

**`enableWeakerNestedSandbox` was considered and rejected.** It was the initial
recommendation here, before the probe output was found, and the administrator had already
agreed to the weakening it implies. That setting exists for containers where bwrap cannot
mount a fresh `/proc`, which the probe proves is not the case — and as root with
`CAP_SYS_ADMIN` it would have made `denyRead` advisory rather than enforced. Dropping the
optional helper unblocks the shell without weakening the filesystem policy, so the agreed
weakening turned out to be unnecessary.

**Preferred long-term fix:** a sandbox-runtime release whose vendored helper carries #505, at
which point the optional filter can be restored. Worth raising with Anthropic.

**To verify:** `failIfUnavailable: true` is set in managed settings. The docs treat the
seccomp filter as optional and bubblewrap as the required dependency, so removing the helper
should not trip it — but confirm rather than assume, and set `failIfUnavailable: false` for
this environment only if startup complains.

**Untested.** Bash never worked in this session, so the remedy could not be verified here.
Confirm in a fresh session — `/tmp/sandbox-probe.txt` should show `BWRAP_OK` and
`seccomp_helper: ABSENT`, and `echo hello` should run — before relying on it for the
training day.

## Notes for the administrator
- **This is not a setting that was configured wrongly.** The environment permits user
  namespaces and bubblewrap works; the optional seccomp helper fails as root.
- It is not the network policy, not the model allow-list, and not a permissions allow/deny
  entry. No command reaches a shell at all.
- Strict sandbox mode (`allowUnsandboxedCommands: false`) is what converts this from a
  degraded sandbox into a dead Bash tool, by removing the unsandboxed-retry fallback. That
  setting is doing its job; it just has no soft failure mode.
- The same check run on a local Claude Code install works. Consistent with the above: macOS
  uses Seatbelt (`sandbox-exec`), an unrelated mechanism, and a local Linux install is
  typically not running as root.
- Without a shell, a hands-on training in which participants install packages, run pandas and
  matplotlib, and build Python agents with the Agent SDK is not possible. Fix this before
  anything else is tested.
- The model, file tools and MCP servers (GitHub, Claude Code Remote) all appear present and
  connected, so the rest of the stack is likely fine once the shell works — but that is an
  expectation, not a measured result.
- Next step: apply `setup-sandbox-fix.sh`, then re-run this check from the top. Nothing in
  checks 2–14 was observed, so none of it should be assumed to pass.

## Deviation from the check's scope
The check specifies "do not contact GitHub in any way". After the shell failure, the
administrator running the check explicitly authorised a push so the result would survive the
session being discarded. GitHub was therefore contacted, via the API only — the shell that
`git` would need never worked. Sequence:

1. `GET /repos/.../branches` succeeded (only `master` existed).
2. `POST /repos/.../git/refs` to create `claude/new-session-pi0w0k` → `403 Resource not
   accessible by integration`.
3. `PUT /repos/.../contents/cc-preflight/...` → same `403`. Push reported as blocked.
4. The administrator then re-linked their GitHub account, after which steps 2 and 3 both
   succeeded and this file was committed to `claude/new-session-pi0w0k`.

Nothing was written to `master`. No pull request or issue was created, and no other
repository was read.

**Second finding for the administrator:** GitHub write access was initially absent — the
installation could read the repository but not write to it — and only appeared after the
account was re-linked mid-session. Worth confirming that participants' accounts are linked
with write access *before* the training day, or they will hit the same `403` when they try to
push their work. This is independent of the shell failure above, which remains unresolved.
