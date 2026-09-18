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
| 1 | Session basics | ❌ | Model = `claude-opus-5`; tools present (Bash, Read, Write, Edit, Glob, Grep, Agent, Skill, Workflow, GitHub MCP, Claude Code Remote MCP); `python3 --version`, `uv --version`, `df -h .` all failed with `apply-seccomp: write /proc/self/uid_map: Operation not permitted` | Bash sandbox setting — sandboxed Bash is enabled and `dangerouslyDisableSandbox` is disabled in this session's configuration |
| 2 | File tools | ❓ | Not run — aborted at check 1 | — |
| 3 | Package install | ❓ | Not run — requires a shell | Bash sandbox setting |
| 4 | Compute and write a chart | ❓ | Not run — requires a shell | Bash sandbox setting |
| 5 | Output channel (chart to chat) | ❓ | Not run — depends on check 4 | — |
| 6 | Inbound data (file upload) | ❓ | Not run — aborted at check 1 | — |
| 7 | Network policy | ❓ | Not run — requires `curl` | Bash sandbox setting (then: cloud environment network policy) |
| 8 | Local embeddings | ❓ | Not run — requires checks 3 and a shell | Bash sandbox setting |
| 9 | Headless Claude, plain call | ❓ | Not run — requires a shell | Bash sandbox setting |
| 10 | Headless Claude, restricted tools | ❓ | Not run — requires a shell | Bash sandbox setting |
| 11 | Structured output | ❓ | Not run — requires a shell | Bash sandbox setting |
| 12 | Agent SDK with in-process tool | ❓ | Not run — requires checks 3 and a shell | Bash sandbox setting |
| 13 | Local commit — no push | ❓ | Not run — requires a shell | Bash sandbox setting |

## Human confirmations
- Chart visible in chat: not tested (no chart could be produced)
- Uploaded file arrived on disk and could be opened: not tested

## Notes for the administrator
- The blocker is the Bash sandbox, not the network, not the model allow-list, and not
  permissions in the allow/deny sense. The sandbox wrapper itself fails to start, so no
  command reaches a shell at all.
- The session configuration also disables the `dangerouslyDisableSandbox` override, so there
  is no in-session way to bypass it and continue the run.
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
