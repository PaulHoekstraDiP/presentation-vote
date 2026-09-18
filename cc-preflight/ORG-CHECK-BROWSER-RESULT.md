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
| 1 | Session basics | ❌ | Model = `claude-opus-5`; tools present (Bash, Read, Write, Edit, Glob, Grep, Agent, Skill, Workflow, GitHub MCP, Claude Code Remote MCP); `python3 --version`, `uv --version`, `df -h .` all failed with `apply-seccomp: write /proc/self/uid_map: Operation not permitted` | Bash sandbox wrapper fails to initialise — see Root cause. Not a misconfigured setting; `dangerouslyDisableSandbox` being disabled is what removes the usual fallback |
| 2 | File tools | ❓ | Not run — aborted at check 1 | — |
| 3 | Package install | ❓ | Not run — requires a shell | Bash sandbox wrapper fails to initialise — see Root cause |
| 4 | Compute and write a chart | ❓ | Not run — requires a shell | Bash sandbox wrapper fails to initialise — see Root cause |
| 5 | Output channel (chart to chat) | ❓ | Not run — depends on check 4 | — |
| 6 | Inbound data (file upload) | ❓ | Not run — aborted at check 1 | — |
| 7 | Network policy | ❓ | Not run — requires `curl` | Bash sandbox wrapper fails to initialise — see Root cause (network policy still untested behind it) |
| 8 | Local embeddings | ❓ | Not run — requires checks 3 and a shell | Bash sandbox wrapper fails to initialise — see Root cause |
| 9 | Headless Claude, plain call | ❓ | Not run — requires a shell | Bash sandbox wrapper fails to initialise — see Root cause |
| 10 | Headless Claude, restricted tools | ❓ | Not run — requires a shell | Bash sandbox wrapper fails to initialise — see Root cause |
| 11 | Structured output | ❓ | Not run — requires a shell | Bash sandbox wrapper fails to initialise — see Root cause |
| 12 | Agent SDK with in-process tool | ❓ | Not run — requires checks 3 and a shell | Bash sandbox wrapper fails to initialise — see Root cause |
| 13 | Local commit — no push | ❓ | Not run — requires a shell | Bash sandbox wrapper fails to initialise — see Root cause |

## Human confirmations
- Chart visible in chat: not tested (no chart could be produced)
- Uploaded file arrived on disk and could be opened: not tested

## Root cause (measured via /proc, since the Read tool bypasses the Bash sandbox)
The Bash tool builds a sandbox by creating a new user namespace and writing a UID mapping
into it. That write is what fails. `/proc/self/uid_map` reads `0 0 4294967295` — the identity
map of the **initial** user namespace. The kernel never permits writing the init namespace's
`uid_map`; that returns `EPERM` unconditionally. So the wrapper is writing the mapping while
still in the init namespace: its `unshare(CLONE_NEWUSER)` did not take effect.

Everything that would normally block user namespaces is permissive here:

| Probe | Value | Verdict |
|---|---|---|
| `/proc/sys/user/max_user_namespaces` | `64318` | allowed (not `0`) |
| `kernel.apparmor_restrict_unprivileged_userns` | sysctl absent | no AppArmor restriction |
| `kernel.unprivileged_userns_clone` | sysctl absent | no Debian-style gate |
| `/proc/self/setgroups` | `allow` | not the setgroups trap |
| Process UID | `0 0 0 0` | running as root |
| `CapEff` | `000001fffeffffff` | includes CAP_SETUID (bit 7) |
| `Seccomp` | `0` | no seccomp filter on the process |

Kernel is `6.18.44-fc-v33` (Firecracker microVM). Caveat: /proc is readable but nothing is
executable, so the wrapper's actual syscall sequence was not observed — the `unshare`
conclusion is the reading most consistent with the evidence, not a watched event.

## Notes for the administrator
- **This is not a setting that was configured wrongly.** The environment permits user
  namespaces; the sandbox wrapper fails to enter one. It reads as a defect in the wrapper's
  initialisation inside this container image, and is worth reporting to Anthropic. The
  "setting most likely responsible" column in the table above should be read with that
  correction in mind.
- It is also not the network policy, not the model allow-list, and not a permissions
  allow/deny entry. No command reaches a shell at all.
- The session configuration also disables the `dangerouslyDisableSandbox` override, so there
  is no in-session way to bypass it and continue the run. This is what turns a sandbox
  setup failure into a total one: normally the fallback is to run unsandboxed with user
  approval, and that escape hatch is closed here. Allowing that override, or disabling the
  Bash sandbox for this environment, would unblock the run — at the cost of a real isolation
  boundary, so it is an administrator's decision, not a default to reach for.
- The same check run on a local Claude Code install works. That is consistent with the
  above: macOS uses Seatbelt (`sandbox-exec`), an unrelated mechanism, and a local Linux
  install is not already nested inside a container runtime.
- Without a shell, a hands-on training in which participants install packages, run pandas and
  matplotlib, and build Python agents with the Agent SDK is not possible in this environment
  as currently configured. This is the one thing worth fixing before anything else is tested.
- The model, file tools and MCP servers (GitHub, Claude Code Remote) all appear present and
  connected, so the rest of the stack is likely fine once the shell works — but that is an
  expectation, not a measured result.
- Suggested next step: re-provision or reconfigure the cloud environment with sandboxed Bash
  working (or disabled), then re-run this same check from the top. Nothing in checks 2–14 was
  observed, so none of it should be assumed to pass.

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
