# Claude Code on the Web — sandbox findings

Investigation record for the data-analysis training environment. Everything below was
measured, not assumed. Written because the session container is discarded and this was the
only copy.

## Summary

Two defects, most likely one root cause: **the sandbox cannot initialise correctly as root
in this image**, so neither the seccomp helper nor the in-namespace network relay comes up.

1. **Bash tool dead.** Every command failed before running with
   `apply-seccomp: write /proc/self/uid_map: Operation not permitted`.
   *Workaround found:* `sandbox.enableWeakerNestedSandbox: true`.
2. **No runtime egress.** With (1) worked around, commands run but every network
   destination fails with `ECONNREFUSED`, allowlisted hosts included.
   *No workaround exists.* Needs an Anthropic-side fix.

## Detail

### 1. The Bash tool failure
Claude Code runs as **root** here (`/proc/self/status` → `Uid: 0 0 0 0`). The seccomp
helper's nested user namespace must map uid 0, which the kernel (5.12+) allows only if the
namespace creator held `CAP_SETFCAP`. Pre-fix, strict mode never started for root callers.

Matches [anthropics/sandbox-runtime#505](https://github.com/anthropics/sandbox-runtime/pull/505),
merged 2026-09-03. The installed package was already **0.0.76** (tagged 2026-09-10, after
that merge) and still failed, so the prebuilt `vendor/seccomp/*/apply-seccomp` binary appears
not to carry the fix.

Nothing environmental was blocking user namespaces: `max_user_namespaces=64318`, no AppArmor
`userns` restriction, `setgroups=allow`, root with `CAP_SETUID`/`CAP_SYS_ADMIN`/`CAP_SETFCAP`,
no seccomp filter on the Claude process. `bwrap --dev-bind / / --proc /proc --unshare-all true`
succeeds.

Managed `sandbox.allowUnsandboxedCommands: false` removes the unsandboxed-retry fallback,
which is what turned a degraded sandbox into a completely unusable Bash tool.

### 2. The egress failure
Sandboxed commands receive `http(s)_proxy=127.0.0.1:3128`. Nothing listens there, so every
connection fails instantly with `ECONNREFUSED` — including hosts in managed
`sandbox.network.allowedDomains`. `NO_PROXY` also lists the allowlisted hosts, so those
bypass the proxy and fail on a direct connection instead.

Note 3128 is the *sandbox's own* proxy, not the environment's agent proxy — the latter is on
a per-session random high port documented in `/root/.ccr/README.md`.

**Proof of a separate network namespace.** A `socat` listener was confirmed UP on
`127.0.0.1:9999` in the container (`ss -ltn` showed it bound). From inside a sandboxed
command, connecting to it returned `ECONNREFUSED`. Two separate loopbacks. Consequently an
external relay bound on 3128 → agent proxy also came up correctly in the outer namespace and
was still unreachable from the sandbox.

Build-time (unsandboxed, during environment provisioning) network works normally.

## Ruled out — do not retry

| Approach | Outcome |
|---|---|
| Uninstalling `@anthropic-ai/sandbox-runtime` | No-op. The helper is compiled into claude-code's own `cli.js`; the error was byte-identical with no `apply-seccomp` binary anywhere on disk. |
| `sandbox.network.httpProxyPort` | Applied, no effect. |
| `sandbox.excludedCommands`, bare form (`"pip3"`) | Inert. Does not match a command with arguments. |
| `sandbox.excludedCommands`, glob form (`"pip3 *"`) | Also inert. |
| External `socat` relay on 127.0.0.1:3128 | Binds in the outer namespace; unreachable from inside the sandbox. |
| Unsetting `HTTPS_PROXY` | Not attempted — the environment's own guidance forbids it, and it would route around org egress policy. |

## Setup-script requirements

- **`socat` is REQUIRED, not optional.** With managed `sandbox.failIfUnavailable: true`, a
  missing sandbox dependency stops Claude Code starting at all. A revision that installed
  only `bubblewrap` meant no session would launch.
- **Never set `sandbox.filesystem`.** The sandbox puts `$HOME` on its own denyWrite/denyRead;
  adding `/root` to `allowWrite` stops sessions starting.
- **Never set `PIP_IGNORE_INSTALLED`.** It forces a full reinstall of every dependency on
  each invocation, defeating pre-baking and failing outright without runtime egress.
- The settings `env` block **does** reach sandboxed Bash (verified: `UV_CACHE_DIR` and
  `MPLCONFIGDIR` both arrive).
- At runtime, `/tmp`, `$HOME` and `/usr` are read-only to sandboxed commands. Writable:
  `$TMPDIR`, the repo working directory, and anything created 0777 under `/opt`.
- Install python packages **one at a time**. A single `pip install a b c` resolves
  all-or-nothing, so one bad package silently takes out the others.

## Consequences for the training

Without runtime egress, participants cannot `pip install` anything and cannot fetch data
from a URL (`pd.read_csv("https://...")` included). Options:

1. **Run the training on local Claude Code**, where all of this works.
2. **Pre-bake** every package and the chromadb embedding model at build time, where the
   network does work, and **ship the training datasets in the repo**. Note `huggingface.co`
   is not in the org allowlist, so the 80 MB model must be cached at build time regardless.
3. File the bug and wait — timing not under our control.

## Bug report (ready to file)

> **Claude Code on the Web, CLI 2.1.276, container running as root.**
>
> **1.** The bundled seccomp helper cannot map uid 0 in its nested user namespace as root.
> Every Bash command fails before execution with
> `apply-seccomp: write /proc/self/uid_map: Operation not permitted`. Matches
> anthropics/sandbox-runtime#505 (merged 2026-09-03); the installed package was already
> 0.0.76 (tagged 09-10) and still failed, so the vendored
> `vendor/seccomp/*/apply-seccomp` binary appears not to carry the fix. With managed
> `sandbox.allowUnsandboxedCommands: false` there is no fallback, so the Bash tool is lost
> entirely.
>
> **2.** With `sandbox.enableWeakerNestedSandbox: true` as a workaround, commands run but
> all egress fails. Sandboxed commands receive `http(s)_proxy=127.0.0.1:3128`; nothing
> listens there, so every host — including ones in managed `sandbox.network.allowedDomains`
> — fails with `ECONNREFUSED`. `NO_PROXY` also lists the allowlisted hosts, so those bypass
> the proxy and fail direct.
>
> **Proven separate network namespace:** a `socat` listener confirmed UP on
> `127.0.0.1:9999` in the container is `ECONNREFUSED` from inside a sandboxed command. An
> external relay bound on 3128 → the agent proxy is therefore unreachable from the sandbox.
>
> Ineffective: `sandbox.network.httpProxyPort`; `sandbox.excludedCommands` in bare and glob
> form. Build-time (unsandboxed) network works normally. `bubblewrap` and `socat` both
> installed; `bwrap --dev-bind / / --proc /proc --unshare-all true` succeeds.
>
> Both symptoms look like one defect: the sandbox cannot initialise correctly as root in
> this image, so neither the seccomp helper nor the in-namespace network relay comes up.
