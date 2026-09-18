# Claude Code on the Web — environment notes

Why `setup.sh` contains what it does, and the measurements behind it. Recorded
so the script itself can stay short.

Environment: Claude Code on the Web, running as **root**, Ubuntu-based image,
system Python 3.11, `/usr/local/bin/python3`.

## Settled facts

- **Claude Code runs as root**, and its bundled seccomp helper cannot build a
  nested user namespace as root. Without `sandbox.enableWeakerNestedSandbox`
  the Bash tool does not work *at all*. This is the one non-negotiable setting.
  Uninstalling `@anthropic-ai/sandbox-runtime` does not help — the helper is
  inside the CLI binary.
- **Sandboxed commands have no network egress at runtime.** Both agent-proxy
  ports are unreachable from inside the namespace and direct connections are
  refused. `NO_PROXY` lists the allowlisted hosts, so they bypass the proxy and
  fail too.
- **Build-time network works.** The setup script reaches PyPI fine; the agent
  proxy does not exist yet when it runs.
- **There is no `/etc/claude-code/managed-settings.json`.** Org policy arrives
  as a signed artifact (`~/.claude/policy-limits.json`). User-scope settings are
  not overwritten, so writing `~/.claude/settings.json` from the setup script is
  safe.
- **The AppArmor userns workaround is a no-op here.** An earlier script wrote an
  `/etc/apparmor.d/bwrap` profile when
  `kernel.apparmor_restrict_unprivileged_userns` was `1`. That sysctl does not
  exist on this kernel and `apparmor_parser` is not installed, so the block
  never ran. Dropping it changes nothing.

Dead ends, already tried: `sandbox.network.httpProxyPort` (no effect),
uninstalling `@anthropic-ai/sandbox-runtime` (no-op), unsetting `HTTPS_PROXY`
(declined on policy grounds).

## Why each setting is in `setup.sh`

### `sandbox.enableWeakerNestedSandbox: true`
Mandatory. See above — without it there is no Bash tool.

### `sandbox.excludedCommands` — glob form
Must be `"pip3 *"`, not `"pip3"`. A bare name does not match a command with
arguments, which is why an earlier attempt looked like a negative result when
it was never active. The docs' own example is `"docker *"`.

When active, an excluded command leaves the sandbox entirely — filesystem *and*
network. Verified: an excluded `pip3 download --dest /dl cowsay` wrote to `/dl`
at filesystem root and fetched from PyPI.

**Caveat — this is not dependable.** Measured within a single session:
`pip3 install chromadb` and `pip3 download cowsay` both succeeded, then later
the identical commands failed:

```
ProxyError('Cannot connect to proxy.', NewConnectionError(
  '...: Failed to establish a new connection: [Errno 111] Connection refused'))
```

and the filesystem bypass was gone too (`pip3 download --no-index --dest
/probe_fs_dir` → `[Errno 30] Read-only file system`). `settings.json` was
unchanged and there was no project-level override. Cause not determined from
inside the sandbox. Other capabilities (`curl`, `rm -rf`, `git add`) were also
denied later in the same session, so the environment's permission posture may
narrow as a session runs.

**Consequence:** do not let a live demo depend on a runtime install. Run the
smoke test below at the start of a session, before an audience is watching.

### Never set `sandbox.filesystem` — it breaks session startup

**This was a real regression; do not reintroduce it.** Setting

```json
"sandbox": { "filesystem": { "allowWrite": ["/root", "/opt", "/tmp"] } }
```

stopped new sessions from starting at all. The setting exists and is settable at
user scope (`sandbox.filesystem.allowRead`/`allowWrite` are among the few
`sandbox.filesystem.*` keys enterprise policy does not restrict), which is what
made it look safe. But the sandbox builds its own rules as:

```js
filesystem: { allowWrite: [e.privateTmp],
              denyWrite: [...e.projectRoots, e.home, ...],
              denyRead:  [e.home, ...e.tempRoots, ...] }
```

`$HOME` is on **both** `denyWrite` and `denyRead`, and `allowWrite` is the
private tmp *only*. Putting `/root` (= `$HOME`) on `allowWrite` contradicts
that directly, and `/tmp` collides with the private-tmp mapping. `setup.sh`
now calls `sb.pop("filesystem", None)` so it also repairs a container whose
settings already carry the bad key.

### Cache env vars, and what is actually read-only

The sandbox write allowlist covers `/dev/*`, `/tmp/claude`, `.`, `$TMPDIR` and
the repo directory — nothing else. So:

- `/root` and `/root/.cache` are read-only → `matplotlib` warns on every import,
  and `chromadb` dies with
  `OSError: [Errno 30] Read-only file system: '/root/.cache/chroma'`.
- `/opt/cache` is read-only *despite being mode 0777 on disk*. The `chmod -R
  0777 /opt/cache` in `setup.sh` is **not** what makes it writable — it is kept
  only so the build-time `mkdir` is group/other-readable.
- `/tmp` is read-only; only `/tmp/claude*` is writable. Use `$TMPDIR`.

Since `sandbox.filesystem` is off limits, the workable approach is the original
one: point the tools at `/opt/cache` via `MPLCONFIGDIR`, `HF_HOME`,
`XDG_CACHE_HOME` and `UV_CACHE_DIR`. Known limitation: matplotlib still prints
its "not a writable directory" warning on import, because `/opt/cache` is not on
the sandbox allowlist and cannot be added. It is cosmetic — the font cache is
pre-built and readable, so import stays at ~0.8s cold and warm, with no rebuild.
Leaving it noisy is the accepted trade for sessions that start.

### `PIP_IGNORE_INSTALLED=1` and `PIP_BREAK_SYSTEM_PACKAGES=1`
This is the fix for the long-standing `chromadb` install failure, which was
**not** a missing build dependency — `build-essential` and `python3-dev` were
added on a wrong hunch and are not needed. Every wheel downloaded fine,
including `onnxruntime`. The real error, verbatim:

```
Installing collected packages: pypika, flatbuffers, ... chromadb
  Attempting uninstall: pyyaml
    Found existing installation: PyYAML 6.0.1
ERROR: Cannot uninstall PyYAML 6.0.1, RECORD file not found.
       Hint: The package was installed by debian.
```

`claude-agent-sdk` hit the same wall on a different victim:

```
ERROR: Cannot uninstall PyJWT 2.7.0, RECORD file not found.
       Hint: The package was installed by debian.
```

Packages `dpkg` installed into `/usr/lib/python3/dist-packages` have no `RECORD`
file, so pip cannot uninstall them when a dependency resolution needs a newer
version. `--break-system-packages` does **not** help; only `--ignore-installed`
does. Verified: `pip3 install --ignore-installed PyYAML chromadb` →
`Successfully installed chromadb-1.5.9 ...`, and `rank-bm25` then imported fine.

`PIP_IGNORE_INSTALLED=1` makes that the default for every install, so a live
`pip3 install <x>` needs no special flags. Trade-off: pip reinstalls
already-satisfied dependencies rather than skipping them, so installs are
slower but do not fail. The alternative — pre-seeding RECORD-bearing copies of
the ~23 no-RECORD distro packages at build time — was rejected as pre-baking.

For reference, the distro packages with no `RECORD`:
`PyGObject, PyJWT, PyYAML, argcomplete, blinker, cryptography, dbus-python,
distro, launchpadlib, lazr.restfulclient, lazr.uri, oauthlib, packaging, pip,
pyparsing, python-apt, setuptools, six, toml, wadllib, wheel, xmltodict, yq`

This also means the common `pip install --upgrade pip setuptools wheel` line
fails silently on this image — `pip`, `setuptools` and `wheel` are all on that
list.

### Global gitignore, without trailing slashes
The sandbox bind-mounts `/dev/null` over the paths on its write denylist, so
`.idea`, `.vscode`, `.gitmodules`, `.bash_profile`, `.zprofile` and `.ripgreprc`
show up as **character devices**, not directories:

```
crw-rw-rw- 1 root root 1, 3 .gitmodules
```

A `.idea/` pattern only matches a directory, so the old list never hid them and
the repo's stop-hook kept reporting untracked files. Bare names match both.
Verified: with the corrected list, `git status --short` drops from seven entries
to one.

## Other packages that failed, and why

Neither was a dependency problem:

```
### rank-bm25
pip._vendor.urllib3.exceptions.ReadTimeoutError:
  HTTPSConnectionPool(host='files.pythonhosted.org', port=443): Read timed out.

### pyarrow
pip._vendor.urllib3.exceptions.ReadTimeoutError:
  HTTPSConnectionPool(host='files.pythonhosted.org', port=443): Read timed out.
```

Plain PyPI read timeouts. If they recur, `PIP_RETRIES=5` and `PIP_TIMEOUT=60`
in `env` are the fix; left out of the minimal script.

## `uv`

`uv *` and `uvx *` are in `excludedCommands`, so uv is permitted. But **uv is
not installed by the minimal script** — it only existed previously because an
older script `pip install`ed it (`uv 0.12.16`, at `/root/.local/bin/uv`). To
have it, add one line:

```bash
pip3 install --break-system-packages --ignore-installed uv
```

Two things to know if you use it instead of pip:

- `uv pip install <x>` refuses to touch a non-virtualenv Python. Use
  `uv pip install --system <x>`, or set `UV_SYSTEM_PYTHON=1` in `env`.
- Whether uv sidesteps the `RECORD` problem was **not** verified. With
  `PIP_IGNORE_INSTALLED=1` the problem is moot either way.

## Known-good version snapshot

Installed and verified working together during testing (runtime `pip install`,
numpy upgraded in place by chromadb without breaking the compiled stack):

```
chromadb 1.5.9   numpy 2.4.6    pandas 3.0.6   scipy 1.17.1
sklearn 1.9.1    matplotlib 3.11.2   plotly 7.1.0   polars 1.44.2
duckdb 1.5.5     seaborn 0.13.2
```

Installing `chromadb` upgrades `numpy`. With nothing pre-installed, install
order matters: install `chromadb` **before** pandas/scipy/sklearn, or verify the
ABI afterwards with

```python
import pandas, numpy as np, scipy.linalg, sklearn.decomposition
pandas.DataFrame({'a': np.arange(4.0)}).sum()
scipy.linalg.norm(np.eye(3))
sklearn.decomposition.PCA(n_components=1).fit(np.random.rand(8, 3))
```

## chromadb specifics

- Collection names must be **3–512 characters** from `[a-zA-Z0-9._-]`.
  `create_collection('t')` raises `InvalidArgumentError`. An earlier probe used
  `'v'` and `'warm'`, which made healthy state look broken.
- The default embedding function downloads ONNX MiniLM-L6-v2 on first use to
  `Path.home()/".cache"/"chroma"/"onnx_models"/"all-MiniLM-L6-v2"`. It is
  derived from `Path.home()`, so pointing `HF_HOME` or `XDG_CACHE_HOME`
  elsewhere has no effect on it. `$HOME` is read-only under the sandbox and
  cannot be opened up (see the `sandbox.filesystem` warning above), so run
  embedding work with `HOME` set to a writable path, e.g.
  `HOME=$TMPDIR python3 your_script.py`.
- `_download_model_if_not_exists()` checks for six files (`config.json`,
  `model.onnx`, `special_tokens_map.json`, `tokenizer_config.json`,
  `tokenizer.json`, `vocab.txt`) under `.../onnx/` *before* calling `makedirs`
  or downloading. If all six are present it returns immediately — so a
  read-only cache is fine, but only if the model is already there. With runtime
  installs, the first `collection.add()` must reach
  `chroma-onnx-models.s3.amazonaws.com`.

## Smoke test

Run at the start of a session, before demoing:

```bash
pip3 install cowsay && python3 -c "import cowsay; cowsay.cow('runtime installs work')"
```

If that fails with `ProxyError: Cannot connect to proxy`, runtime installs are
unavailable for this session and nothing will recover it from inside.
