# TROUBLESHOOTING — Local LLM stack on Strix Halo (MS-S1 Max)

> Agent note: this file is shared context. Read `llm-setup.md` first for
> architecture and daily ops; `llm-setup.md` §0 holds the apt package
> inventory. Each entry below: **Symptom → Cause → Fix → Prevent**. If you hit
> something new, append an entry in the same format.

Machine: Miniforum MS-S1 Max, Ryzen AI Max+ P495 (Strix Halo, gfx1151),
Radeon 8060S iGPU, 192 GB unified memory, Ubuntu 26.04 "Resolute", Wayland.
Stack: ROCm 10.1 (system) + Ollama (Docker, root image, ROCm) + Open WebUI.

---

## A. GPU / ROCm

### A1. GPU invisible to ROCm tools (0 devices)
- **Symptom:** `/dev/kfd` and `/dev/dri/renderD128` exist, `lspci` shows the
  GPU (device 0x1586), but `rocm-smi`/`amd-smi` enumerate 0 GPUs or fail to
  load their own libraries.
- **Cause:** broken/mixed userland. On this box it was Ubuntu's DFSG ROCm
  packages (`+dfsg`/`-0ubuntu` builds): no `/opt/rocm` layout, version-mixed
  libs (7.1 hip + 7.2 amd-smi), `libamd_smi.so` loaded but `get_processor_handles`
  returned rc=1/count=0.
- **Fix:**
  1. Dry-run the purge and verify the list:
     `sudo apt-get remove --dry-run 'hip*' 'rocm*' 'libamd*' 'libhip*' amd-dbgapi-dev`
     (was 69 packages; only weak reverse-dep: `libcholmod5` Recommends `libamd3`
     — safe to orphan, keep libcholmod5)
  2. Purge, then `sudo apt autoremove --purge`
  3. Add AMD's official repo (see A2) and `sudo apt install amdrocm-base amdrocm-amdsmi`
  4. Verify: `amd-smi list` (must show GPU 0)
- **Prevent:** never mix Ubuntu-DFSG ROCm with AMD's repo; check
  `dpkg -l | grep -E 'rocm|hip'` for `+dfsg`/`-0ubuntu` suffixes.

### A2. Wrong ROCm apt repo URL (404 No Release file)
- **Symptom:** `apt update` → "repository ... does not have a Release file".
- **Cause:** the old layout `https://repo.radeon.com/rocm/apt/<ver>/dists/`
  only ships `jammy` and `noble` suites for ALL of ROCm 7.x. No bookworm, no
  trixie, no resolute. (Easy to get wrong — older tutorials point here.)
- **Fix:** follow AMD's current install instructions (they own the repo
  layout, so don't duplicate it here — it changes):
  https://rocm.docs.amd.com/en/latest/install/rocm.html  (filter: Ubuntu 26.04)
  As of this writing that means the `stable.repo.amd.com` repo with an
  `ubuntu2604` suite; packages are `amdrocm-*` (ROCm 10.x), installed under
  `/opt/rocm/core-<ver>/`.
- **Prevent:** always check the current docs page with the OS filter:
  https://rocm.docs.amd.com/en/latest/install/rocm.html

### A3. `rocm-smi` missing / `amd-smi` not on PATH
- **Symptom:** `rocm-smi: command not found`; `amdrocm-amdsmi` installed but
  no `amd-smi` command.
- **Cause:** `rocm-smi` is deprecated in ROCm 10.x; its replacement `amd-smi`
  ships in `amdrocm-amdsmi` at `/opt/rocm/core-10.1/bin/amd-smi` (reached via
  the `/opt/rocm/bin` alternatives symlink), which is not on the default PATH.
- **Fix:** `echo 'export PATH=/opt/rocm/core-10.1/bin:$PATH' >> ~/.bashrc`
- **Prevent:** know the tool rename: ROCm ≤7 → `rocm-smi`, ROCm 10 → `amd-smi`.

### A4. Ollama can't see the iGPU
- **Symptom:** Ollama logs show CPU-only inference.
- **Fix (in order):**
  1. Container must have `--device /dev/kfd --device /dev/dri`,
     `group_add: [video, render]` (or run as root), `ipc: host`
  2. Use the `ollama/ollama:rocm` image (bundles ROCm runtime)
  3. If a future build drops gfx1151: set `HSA_OVERRIDE_GFX_VERSION=11.0.0`
     (v0.40.4 detects gfx1151 natively — no override needed)
- **Verify:** log line `inference compute ... library=ROCm compute=gfx1151`
  and `runner.inference="[{ID:0 Library:ROCm}]"` after a request.

### A5. Only part of 192 GB visible to the GPU (GTT window)
- **Symptom:** Ollama/ROCm report total < 192 GB; `amd-smi monitor` shows
  `GTT_USAGE x/180.0 GB` (was `x/128.0 GB` before 2026-10-24).
- **Cause:** NOT a bug. `amdgpu.gttsize` on the kernel cmdline caps the
  GPU's window into unified memory; the rest stays CPU-only. Current value:
  **180 GB** (`amdgpu.gttsize=184320`, raised 2026-10-24 from 128 GB because
  multi-model + parallel-worker residency outgrew it — see A6).
- **Fix (only if a future model needs it):** raise the GRUB cmdline
  (absolute max 192 GB = `196608`; keep a margin) → `sudo update-grub` →
  reboot. Lowered value: n/a.
- **Prevent:** understand it's a fixed kernel mapping, not a dynamic pool;
  raising it lets the GPU starve the desktop compositor on an iGPU. Only
  takes effect at boot.

### A6. Ollama: "not enough memory, waiting for pending requests" with plenty of free RAM
- **Symptom:** a second model (or a second pi on the same big model) hangs or
  errors with "llama-server model predicted to exceed available memory,
  evicting" / "waiting for pending requests to complete" in the Ollama logs,
  even though `free`/`amd-smi` show tens of GB free.
- **Cause:** two facts combine: (1) the scheduler **reserves worst-case per
  runner**: `model weights + (OLLAMA_NUM_PARALLEL slots × full-num_ctx KV)
  per model`. A 27B pinned at num_ctx 262144 with PARALLEL=8 predicts
  ~110 GiB even while actually using ~56 GB. (2) There is **no preemption**:
  a long single request (e.g. a 2-hour planner turn) is atomic to the
  scheduler, so eviction can only happen after it finishes.
- **2026-10-24 incident log (the tell):**
  `predicted="110.1 GiB" predicted_num_ctx=1048576 ... available="38.6 GiB"`
  → the 1M figure was the scheduler's KV prediction under the old 262k-pin +
  PARALLEL=8 registration; the other model only loaded after the 27B request
  ended and the runner evicted.
- **Fix:** right-size `num_ctx` (per-model Modelfile, `ollama create` — see
  llm-setup.md §3.6) and `OLLAMA_NUM_PARALLEL` to real usage; raise `gttsize`
  (A5). Current setting: 27B at `num_ctx 65536`, PARALLEL=3, GTT 180 GB.
- **Prevent:** size runner reservations, not just weights:
  `weights + slots × num_ctx × KV-per-token + other models ≪ GTT`. KV per
  token for the 27B ≈ 4 GiB at 65k ctx, ≈ 15 GiB at 262k ctx.
- **Note:** a frozen-looking container after a long model swap is usually
  mid-reload (`load_tensors: loading model tensors` in logs); if the client
  has no retry patience, the request times out client-side even though the
  server recovers — check logs before `docker restart`.

---

## B. Docker / containers

### B1. Non-root Ollama: `permission denied` on model blobs
- **Symptom:** `Error: open /home/ubuntu/.ollama/models/blobs/sha256-...:
  permission denied` after switching from the root image to a non-root one.
- **Cause:** the named volume was created/initialized by the old root
  container; existing paths are root-owned.
- **Fix (one-time):**
  ```
  docker run --rm -v ollama_ollama_models:/data alpine chown -R 1000:1000 /data
  ```
- **Prevent:** when changing a container's user, chown its volumes.

### B2. Non-root Open WebUI crash-loop on `.webui_secret_key`
- **Symptom:** restart loop; log: `start.sh: line 45: .webui_secret_key:
  Permission denied`.
- **Cause:** start.sh writes the generated secret next to itself in
  `/app/backend`, which is read-only for non-root users in the image.
- **Fix:** env `WEBUI_SECRET_KEY_FILE=/app/backend/data/.webui_secret_key`
  (inside the mounted volume) + one-time chown of the `open_webui_data` volume.
- **Prevent:** any non-root app that writes config "next to itself" needs the
  file redirected to a writable mount.

### B3. Healthcheck always failing (no wget/curl in image)
- **Symptom:** container `unhealthy` though the service is fine; the classic
  `wget -qO- http://127.0.0.1:PORT/...` test errors.
- **Cause:** `ollama/ollama:rocm` ships neither wget nor curl.
- **Fix:** `test: ["CMD-SHELL", "ollama list >/dev/null 2>&1 || exit 1"]`
- **Prevent:** check what's in the image before writing a healthcheck
  (`docker run --rm --entrypoint sh <image> -c 'which wget curl'`).

### B4. Dockerfile useradd/groupadd failures on the ollama base image
- **Symptom:** build fails: `UID 1000 is not unique` / `group 'video' already
  exists`.
- **Cause:** the base image already contains user `ubuntu` (uid 1000, member
  of `video` gid 44).
- **Fix:** reuse it — `usermod -aG render ubuntu`, `ENV
  OLLAMA_HOME=/home/ubuntu/.ollama`, `USER ubuntu`. Create only the missing
  `render` group (gid 990 to match host).
- **Prevent:** inspect the base image's `/etc/passwd` + `/etc/group` before
  adding users.

### B5. Container name conflict when merging compose files
- **Symptom:** `Conflict. The container name "/X" is already in use by
  container ...` after moving a service to another compose file.
- **Fix:** `docker rm -f X` first; also `docker volume rm` orphaned
  project-prefixed volumes (e.g. `open-webui_open_webui_data` vs
  `ollama_open_webui_data` — two projects = two volumes!).
- **Prevent:** one compose project per logical unit; check
  `docker volume ls` for duplicates after merges.

### B6. `depends_on` "doesn't work" between compose files
- **Cause:** `depends_on` only resolves services in the SAME compose project.
- **Fix:** put dependent services in one file (what we did), or use an
  external network + application-level retry.

### B7. Non-root Ollama wrapper (abandoned)
- **Symptom:** none active — the wrapper was tried, then abandoned.
- **Cause:** the custom non-root `~/docker/ollama/Dockerfile` wrapper made base
  image updates opaque (pull_policy applied to the local wrapper tag, not the
  `FROM` base), so the stack was reverted to the official root image.
- **Fix:** none needed now; current compose uses `ollama/ollama:rocm` as root.
- **Prevent:** don't reintroduce the wrapper without re-testing image updates.

---

## C. Ollama / model import

### C1. Sharded GGUF import fails
- **Symptom:** `ollama create FROM model-00001-of-00004.gguf` →
  `Error: invalid split GGUF: ... has 1 shards, expected 4`.
- **Cause:** Ollama cannot import split GGUFs; it needs one merged file.
- **Fix:** merge first with llama.cpp's tool (built from `~/llama.cpp`):
  ```
  ~/llama.cpp/build/bin/llama-gguf-split --merge \
      model-00001-of-00004.gguf ... model-00004-of-00004.gguf model-merged.gguf
  ```
  Note: cmake target is `llama-gguf-split` (the source file is `gguf-split.cpp`
  but the CMake target has the `llama-` prefix). Recent llama.cpp GitHub
  releases do NOT ship a standalone `gguf` binary — build it.
- **Prevent:** the import script (`~/models/import_gguf_model_file.sh`)
  detects `-NNNNN-of-NNNNM` patterns and merges automatically.

### C2. Import "succeeded" but model missing
- **Symptom:** `ollama create` prints `success`, then `ollama ls | grep X`
  finds nothing.
- **Cause:** race — manifest write completes before the model is queryable.
- **Fix:** retry the verification (script does 10×2 s).
- **Related gotcha:** if no explicit name is given, `ollama create` derives
  the model name from the **Modelfile's basename** — a temp Modelfile named
  `.Modelfile.import` once created a model literally called
  `.modelfile.import`. Always pass the model name explicitly.

### C3. `model '' not found` from the API
- **Cause:** field-name asymmetry — `/api/pull` uses `{"name": ...}` but
  `/api/generate` and `/api/chat` use `{"model": ...}`.
- **Fix:** use the right field per endpoint.

### C4. Empty response from a working model
- **Symptom:** HTTP 200, `done: true`, but `response: ""`.
- **Cause (seen with qwen3:0.6b + tiny `num_predict`):** the model emits
  only tokens that get trimmed (e.g. thinking/whitespace) within the tiny
  budget, or the prompt didn't trigger output. Not an error.
- **Fix:** increase `num_predict`, use a real prompt; check
  `eval_count`/`eval_duration` in the response to confirm tokens were generated.

### C5. `reasoning_effort` rejected by chat template (Jinja 500)
- **Symptom:** HTTP 500: `Unexpected reasoning effort high. Supported types
  are xhigh (default), medium, and low.` — from `qwen3.8-27b-bf16`'s chat
  template, which only accepts `xhigh`/`medium`/`low` (its default is
  xhigh = max thinking).
- **Cause (seen via pi 2026-10-23):** pi's openai-completions adapter
  normalizes `xhigh` → `high` (an OpenAI-standard value the template
  doesn't know), so any explicit high-ish level 500s. Direct curl with
  `xhigh` also gets mangled to `max` by some clients.
- **Fix:** omit `reasoning_effort` entirely → template default (xhigh).
  In pi: `--thinking off` (contrary to its name, this just means "don't
  send the field", which here means MAX thinking). Do not "upgrade" it to
  `--thinking high`/`xhigh` — that breaks the call. See agent.md decision
  log (PACS repo).
- **Prevent:** model-specific template constraints are invisible in
  `ollama show`; test `curl /v1/chat/completions` with and without the
  field when a reasoning model starts failing.

### C6. 27B runner sizing saga (resolved 2026-10-24; historical)
- **Symptom:** second model couldn't load / hangs; logs showed
  `predicted="110.1 GiB" predicted_num_ctx=1048576 ... available="38.6 GiB"`.
- **Cause:** scheduler reserves `weights + slots × full-num_ctx KV` per runner;
  a 27B pinned at num_ctx 262144 with PARALLEL=8 predicted ~110 GiB.
- **Fix:** re-create model with `num_ctx 65536`, `OLLAMA_NUM_PARALLEL=3`,
  `OLLAMA_MAX_LOADED_MODELS=4`, + §3.2 GTT raise. (27B no longer primary;
  current primary is flint — see llm-setup.md §3.6.)
- **Prevent:** size runner reservations, not just weights.

---

## D. Host environment (Ubuntu 26.04 / Wayland)

### D1. No pip, no venv
- **Symptom:** `python3 -m pip` → No module named pip; `python3 -m venv` →
  "ensurepip is not available".
- **Cause:** Ubuntu splits ensurepip into `python3.14-venv` (not installed by
  default on this box; sudo needs a TTY so it wasn't installed interactively).
- **Fix (proper):** `sudo apt install python3.14-venv`
- **Fix (no-sudo workaround used):**
  `curl -sSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py &&
  python3 /tmp/get-pip.py --target /tmp/pylibs &&
  PYTHONPATH=/tmp/pylibs python3 -m pip install --target /tmp/pylibs <pkg>`

### D2. Wayland clipboard unavailable in pi TUI
- **Symptom:** selecting text → "clipboard unavailable: install 'wl-clipboard'
  or check wayland access".
- **Fix:** `sudo apt install wl-clipboard`
- **Workaround:** Shift+drag for terminal-native selection.

### D3. sudo requires a terminal
- **Symptom:** `sudo: A terminal is required to authenticate` when run from
  the pi agent.
- **Cause:** no passwordless sudo; agent has no TTY.
- **Fix:** run sudo commands in the user's own terminal; the agent can
  prepare exact command lists (dry-runs included) for the user to execute.

---

## References

- AMD official ROCm install docs: https://rocm.docs.amd.com/en/latest/install/rocm.html
- AMD ROCm apt repo: https://stable.repo.amd.com/rocm/core/packages/ubuntu2604/
- Docker official docs: https://docs.docker.com/engine/install/ubuntu/
- Old AMD ROCm apt repo layout: https://repo.radeon.com/rocm/apt/<ver>/
- Community writeups (Strix Halo):
  - https://note.com/a_244/n/n0470d851f36c?hl=en
  - https://www.reddit.com/r/MiniPCs/comments/1sb93jd/minisforum_mss1_max_and_others_setting_up_and/

## E. Quick diagnosis cheatsheet

| Check | Command | Good output |
|---|---|---|
| Kernel sees GPU | `lspci \| grep -i 'display\|vga'` | `Display controller: ... Strix Halo` (iGPU has no VGA class on this platform — grep for `display`, not `vga`) |
| KFD device | `ls /dev/kfd /dev/dri/renderD128` | both exist |
| System ROCm | `amd-smi list` | `GPU: 0, UUID 00001586-...` |
| GTT window | `amd-smi monitor` | `GTT_USAGE x/180.0 GB` |
| Ollama up | `curl -s localhost:11434/api/version` | `{"version":"0.40.x"}` |
| Ollama sees GPU | `docker compose logs ollama \| grep 'inference compute'` | `library=ROCm compute=gfx1151` |
| Model on GPU | logs after a request | `runner.inference="[{ID:0 Library:ROCm}]"` |
| Container users | `docker exec ollama id` | `uid=1000(ubuntu) ... 990(render)` |
| Open WebUI | `curl -s -o /dev/null -w '%{http_code}' localhost:3000` | `200` |
| Models | `curl -s localhost:11434/api/tags` | JSON list |
