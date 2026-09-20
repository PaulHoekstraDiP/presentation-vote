# Claude Code on the Web — readiness result

2026-09-20 · model in session: `claude-opus-5` · environment: `env_01AqW1c5Vaxu8opz7BNdztG4`
(kind: `anthropic_cloud`) · CLI 2.1.276

> **STATUS: THE CHECK HAS NEVER BEEN COMPLETED.** Every session that attempted it was
> provisioned before the setup-script fixes, so the shell was dead and checks 3–14 could not
> run. This file records what *is* known. Re-run the check from the top in a freshly
> provisioned environment. Technical detail and evidence: `FINDINGS.md` in this directory.

## Results

| # | Check | Status | Observed (one line) | If ❌: setting most likely responsible |
|---|-------|--------|----------------------|----------------------------------------|
| 1 | Session basics | ❌ | `python3 --version`, `uv --version`, `df -h .` all failed with `apply-seccomp: write /proc/self/uid_map: Operation not permitted`; model `claude-opus-5`, tools present | Sandbox cannot initialise as root — fixed by `sandbox.enableWeakerNestedSandbox: true` in the setup script |
| 2 | File tools | ✅ | Write, Edit, Read, Grep, Glob on `cc-preflight/notes.md` all succeeded — these bypass the shell | — |
| 3 | Package install | ❌ | No runtime network egress; also `uv pip install --system` targets a read-only path under `$HOME` | Sandbox network relay never starts — not fixable from configuration |
| 4 | Compute and write a chart | ❓ | Never run — requires a shell | — |
| 5 | Output channel (chart to chat) | ❓ | Never run — depends on check 4 | — |
| 6 | Inbound data (file upload) | ⚠️ | Not run as specified, but uploads demonstrably work: the check document itself arrived by upload and was read from disk | — |
| 7 | Network policy | ❌ | All six hosts unreachable, allowlisted ones included — `ECONNREFUSED` before any policy evaluation | Sandbox network relay — *not* the org network policy |
| 8 | Local embeddings | ❌ | chromadb unavailable; `huggingface.co` is also absent from the org allowlist | Relay, plus cloud environment network policy for the model host |
| 9 | Headless Claude, plain call | ❌ | Needs live API access from inside the sandbox | Sandbox network relay |
| 10 | Headless Claude, restricted tools | ❓ | Never run | — |
| 11 | Structured output | ❓ | Never run | — |
| 12 | Agent SDK with in-process tool | ❌ | Needs live API access from inside the sandbox | Sandbox network relay |
| 13 | Local commit — no push | ❓ | Never run here; a parallel session found `git commit` refused by the permissions deny list | Permissions allow/deny list |

## Human confirmations
- Chart visible in chat: not tested (no chart could be produced)
- Uploaded file arrived on disk and could be opened: **yes** — the check document was
  uploaded with the `+` button and read successfully (markdown)

## Browser situation — summary for the administrator

- **The web environment cannot run the training as-is.** Two defects, most likely one root
  cause: Claude Code runs as root, its sandbox can't initialise properly, and so neither the
  seccomp helper nor the in-namespace network relay starts.
- **One is fixed, one is not.** `sandbox.enableWeakerNestedSandbox: true` plus installing
  `socat` gets sessions starting with a working Bash tool. Nothing restores network access
  from inside the sandbox — five approaches were tried and measured as dead.
- **Everything must be pre-baked.** Build-time network works fine, so packages and the 80 MB
  chromadb embedding model must be installed by the setup script. Participants cannot
  `pip install` anything on the day.
- **Ship the training datasets in the repo.** `pd.read_csv("https://...")` fails for the same
  reason. This is easy to overlook and would surface live, mid-exercise.
- **Agent-building should stay on local Claude Code.** The headless `claude` calls and the
  Agent SDK need live API access from inside the sandbox, which is exactly what is broken.
  Data analysis works in the browser once pre-baked; agent work does not.

## Notes
- The trigger is that Claude Code runs as **root** in the web container. It is not the org
  network policy, not the model allow-list, and not a permissions allow/deny entry — those
  were each ruled out by measurement.
- `sandbox.allowUnsandboxedCommands: false` (managed) is what turned a degraded sandbox into
  a completely unusable Bash tool, by removing the unsandboxed-retry fallback. The setting is
  working as designed; it just has no soft failure mode.
- A bug report ready to file with Anthropic is at the end of `FINDINGS.md`.
- Two setup-script traps cost a provisioning cycle each and are documented in `FINDINGS.md`:
  omitting `socat` stops Claude Code launching entirely, and setting `sandbox.filesystem`
  stops sessions starting.

## Deviation from the check's scope
The check specifies "do not contact GitHub in any way". The administrator explicitly
authorised pushing `cc-preflight/` after the shell failure, so the results would survive the
session being discarded. GitHub was contacted via the API only — the shell `git` would need
never worked. No pull request or issue was created; nothing was written to `master`.

Separately: GitHub write access was initially absent (`403`) and only appeared after the
administrator re-linked their account mid-session. Worth confirming participants' accounts
are linked with write access before the training day.
