# LLM Setup — Local LLM Stack on Strix Halo (Miniforum MS-S1 Max)

Base document. Holds the **minimal explanations of why** the local LLM stack is
configured the way it is, plus the **setup steps with copy-paste commands**.

Deep troubleshooting, experiments, and extra stuff tried live: see
`TROUBLESHOOTING.md`.

---

## 0. Machine & stack (why)

- **Machine:** Miniforum MS-S1 Max, AMD Ryzen AI Max+ "P495" (Strix Halo, gfx1151),
  Radeon 8060S iGPU.
- **RAM:** 192 GB unified (this box) / 128 GB (fresh MS-S1 395) — see `TROUBLESHOOTING.md` §A5.
- **OS:** Ubuntu 26.04 "Resolute" (Wayland).
- **Stack:** ROCm 10.1 (system) + Ollama (Docker, `ollama/ollama:rocm`, root) + Open WebUI.

## 1. Setup steps (copy-paste)

Ordered sequence: SSH key setup → encryption → repo adds → apt install → docker → ollama → ...

### 1.0 Prerequisites
- Ubuntu 26.04 host with `sudo` access.

### 1.1 Step 1 — SSH key setup
Ed25519 SSH keys + `authorized_keys` + host alias.

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C "<username>@<host>" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
chmod 600 ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
```

Host alias (`<host>` → `<ip_address>`) lives in `~/.ssh/config`:

Example `~/.ssh` file structure:

```
~/.ssh/
├── authorized_keys
├── config
├── id_ed25519
└── id_ed25519.pub
```

### 1.2 Step 2 — Encryption: dropbear + clevis
Install dropbear + clevis.

### 1.3 Step 3 — Add AMD ROCm apt repo (repo adds)
```bash
sudo mkdir --parents --mode=0755 /etc/apt/keyrings
wget -qO - https://stable.repo.amd.com/rocm/gpg/packages.gpg | \
  gpg --dearmor | sudo tee /etc/apt/keyrings/amdrocm.gpg > /dev/null
sudo tee /etc/apt/sources.list.d/amdrocm-stable.sources << 'EOF'
X-Repo-Id: amdrocm-stable
Types: deb
URIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu2604/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/amdrocm.gpg
Enabled: yes
EOF
sudo apt update
sudo apt install -y amdrocm-base amdrocm-amdsmi
```

Add the user to the GPU groups (video + render) for AMD ROCm:
```bash
sudo usermod -aG video, render "<username>"
```
Amd tools aren't in path for some reason. Add them to path:
`echo 'export PATH=/opt/rocm/core-10.1/bin:$PATH' >> ~/.bashrc`
Reload bashrc to use the new path.
`source ~/.bashrc`

> Note: the old `ppa:amdgpu/install` add failed with `ERROR: ppa 'amdgpu/install' not found`. The
> current official repo for Ubuntu 26.04 ("resolute") is
> `https://stable.repo.amd.com/rocm/core/packages/ubuntu2604/` (suite `stable`), which ships ROCm
> 10.x packages (`amdrocm-*`). The older `https://repo.radeon.com/rocm/apt/<ver>/` layout only ships
> `jammy`/`noble` suites — do not use it for 26.04.

### 1.4 Step 4 — Install all the stuff with apt
Docker official:
```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=am64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  resolute stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Plus the rest of the apt packages.
```bash
sudo apt update
sudo apt install -y \
  git pigz util-linux-extra \
  openssh-server openssh-client ssh-askpass molly-guard ncurses-term \
  cryptsetup efibootmgr grub-efi-amd64 grub-efi-amd64-signed lvm2 shim-signed wbritish \
  linux-generic-hwe-24.04 \
  llama.cpp-tools libllama0 libggml0 libggml0-backend-vulkan \
  cmake build-essential libssl-dev ninja-build \
  python3.14-venv python3-pip python3-setuptools \
  wl-clipboard
```

### 1.5 Step 5 — Add user to Docker group
```bash
sudo usermod -aG docker "<username>"
newgrp docker
```

### 1.6 Step 6 — Ollama compose file
Path: `~/docker/ollama/compose.yml` — full file:

```yaml
services:
  ollama:
    image: ollama/ollama:rocm
    container_name: ollama
    pull_policy: always
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - ollama_models:/root/.ollama/models
      - /home/<username>/models:/host-files
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
    ipc: host
    environment:
      - OLLAMA_NUM_PARALLEL=3
      - OLLAMA_MAX_LOADED_MODELS=4
      - OLLAMA_KEEP_ALIVE=3600
      - OLLAMA_DEBUG=1
    healthcheck:
      test: ["CMD-SHELL", "timeout 2 bash -c ': > /dev/tcp/127.0.0.1/11434' || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    pull_policy: always
    restart: unless-stopped
    depends_on:
      ollama:
        condition: service_healthy
    user: "1000:1000"
    ports:
      - "0.0.0.0:3000:8080"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - WEBUI_AUTH=true
      - WEBUI_SECRET_KEY_FILE=/app/backend/data/.webui_secret_key
      # - DEFAULT_MODEL=qwen3.8-27b-bf16
    volumes:
      - open_webui_data:/app/backend/data

volumes:
  ollama_models:
  open_webui_data:
```

### 1.7 Step 7 — Start Ollama
```bash
cd ~/docker/ollama
docker compose up -d
docker compose ps
docker compose logs -f ollama
```

### 1.8 Step 8 — Open WebUI
- Open `http://<ip_address>:3000` — create the first account on first visit (admin).

### 1.9 Step 9 — Build llama.cpp `llama-gguf-split`
```bash
cd ~/llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release <flags>
cmake --build build --target llama-gguf-split
# binary → ~/llama.cpp/build/bin/llama-gguf-split
```

### 2.0 Step 10 — Hugging Face + merge + import
```bash
uvx --from huggingface-cli huggingface-cli login
uvx --from huggingface-cli huggingface-cli download RecursiveSI/flint \
    --include "flint-BF16-*.gguf" --local-dir ~/models
~/models/import_gguf_model_file.sh <file-or-shard.gguf> [model-name]
```

### 2.1 Step 11 — Verify
```bash
curl -s localhost:11434/api/version
curl -s localhost:11434/api/tags
curl -d '{"model":"qwen3:0.6b","prompt":"Say hello","stream":false}' localhost:11434/api/generate
```

## 3. Disk encryption: Ubuntu 26.04 + Secure Boot / TPM (PCR7, dbt)

- Ubuntu 26.04 installer refuses hardware-backed (TPM) full-disk encryption (PCR_UNUSABLE error;
  Secure Boot policy PCR7 measurements, dbt not supported by secboot).
- With plain passphrase LUKS, the machine drops to early boot and waits for the passphrase at the
  console — a headless server hangs after every reboot / power cut.

## Workarounds

1. **Remote unlock over SSH** — `dropbear-initramfs`.
   Small SSH server that runs in initramfs before the disk is unlocked; after reboot you SSH in
   from anywhere and type the passphrase. Simple and secure; person still has to unlock after each
   reboot, just not physically.

   ```bash
   sudo apt install dropbear-initramfs
   # add your public key to /etc/dropbear/initramfs/authorized_keys
   cat ~/.ssh/id_ed25519.pub >> /etc/dropbear/initramfs/authorized_keys
   sudo chmod 600 /etc/dropbear/initramfs/authorized_keys
   sudo update-initramfs -u
   ```

   After reboot, connect with `ssh root@<host-ip>` and run `cryptroot-unlock` to enter the disk
   passphrase.

2. **Bind disk to TPM yourself** — `clevis` + `clevis-tpm2`.
   Install with normal LUKS, add TPM as an extra unlock method after install. These tools seal the
   key to the machine's current measurements rather than predicting future ones, so the dbt problem
   that blocked the installer doesn't apply. You get unattended boot, and your passphrase remains as
   a backup.

   ```bash
   sudo apt install clevis clevis-luks clevis-tpm2 clevis-initramfs
   sudo clevis luks bind -d /dev/<luks-partition> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'
   sudo update-initramfs -u
   ```

   Caveat: a firmware or Secure Boot database update can change PCR7; the TPM unlock then fails and
   falls back to asking for the passphrase. When that happens, unlock manually once and re-bind.

3. **Network-bound unlocking** — Clevis + Tang.

4. **Encrypt only data, not OS**.

## TPM bind steps (after installing with normal LUKS)

- Find the LUKS partition: `lsblk -f` / `sudo blkid -t TYPE=crypto_LUKS`.
- Clevis defaults to the older SHA-1 PCR bank; the TPM here only uses SHA-256, so bind with
  `{"pcr_bank":"sha256","pcr_ids":"7"}`:
  ```bash
  sudo clevis luks bind -d /dev/<luks-partition> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'
  ```
  (Replace with your LUKS partition; it will ask for the existing LUKS passphrase.)
- After success:
  ```bash
  sudo clevis luks list -d /dev/<luks-partition>
  sudo update-initramfs -u
  ```
- If it still asks for the passphrase after reboot: check initramfs tooling — with `dracut`, use
  `clevis-dracut` + `sudo dracut -f` (`dropbear-initramfs` is initramfs-tools-only).
- If you wait ~30–60 s it eventually decrypts itself → TPM released the key, Clevis unlocked
  unattended; the passphrase prompt is cosmetic.

## Why the different tools exist

- **dropbear-initramfs**: small SSH server running in initramfs before the disk is unlocked; lets
  you unlock remotely over SSH (`ssh root@<host-ip>` → `cryptroot-unlock`).
- **clevis / clevis-luks / clevis-tpm2 / clevis-initramfs**: Clevis framework for declarative
  unlock; `clevis-luks` hooks into LUKS, `clevis-tpm2` binds to TPM PCRs, `clevis-initramfs` puts
  Clevis into the boot image so boot can auto-unlock.
- **clevis luks bind / regen**: bind (seal) a LUKS key to TPM PCRs, or re-bind after firmware /
  Secure Boot changes PCR7.

## Operational notes

- Keep the passphrase safe; it's the fallback if the TPM ever refuses to unlock.
- Expect to re-bind after firmware or Secure Boot updates: `sudo clevis luks regen -d /dev/<luks-partition> -s 1`.
- Test the remote unlock once; if the delay bothers you, it's usually the boot environment waiting
  for the network for dropbear — harmless, but can be shortened.

## 4. Model inventory / how to add a model

| Model | File | Size | Notes |
|---|---|---|---|
| `qwen3.8-27b-bf16` | `~/models/Qwen3.8-27B-BF16.gguf` | 53.8 GB | BF16; deep think; **no parallel requests** |
| `flint-bf16` | `~/models/flint-bf16-merged.gguf` | 79.5 GB | Flint 40B MoE BF16 (Recursive); **no parallel requests** |
| `qwen3.6-35b-a3b-bf16-262k` | `~/models/Qwen3.6-35B-A3B-BF16.gguf` | 69.4 GB | MoE BF16 |
| `qwen3.6-35b-a3b-q4_262k` | `~/models/Qwen3.6-35B-A3B-Q4_K_M.gguf` | 21.2 GB | Q4_K_M |
| `qwen3.8-27b-q4_k_m_262k` | `~/models/Qwen3.8-27B-Q4_K_M.gguf` | 16.5 GB | Q4_K_M |
| `qwen2.5-coder-14b-instruct-q4_k_m` | — | 9.0 GB | test/secondary |
| `qwen3:0.6b` | — | 0.5 GB | smoke test |

Adding a new model: see §2.0. Merged file is **kept** at end of merge (user preference).

## 5. Windows → Ubuntu migration (MS-S1 Max)

Note: it's a **fresh install of Windows that we will never use** — so no migration needed, just
change a few settings and then wipe for the Ubuntu install.

Steps to get the box from Windows to Ubuntu:

1. Fly through the Windows setup **without** connecting to wifi or plugging in ethernet.
2. Go to Windows settings for disk encryption and turn **off** disk encryption. This may take a
   while. Reboot.
3. Make an Ubuntu 26.04 bootable USB drive.
4. While booting, when you see the **MINIS FORUM**, hit **DELETE** on your keyboard to enter BIOS.
   Choose boot from USB that you have put in with Ubuntu on it. Select Try/install.
5. 1st attempt install, choose hardware backed encryption. It will tell you you need to clear TPM,
   which you should do and it will immediately reboot. Intercept it again and with DELETE and send it
   into BIOS and boot from USB again. Try/install Ubuntu.
6. Hardware encryption is broken, so with TPM cleared, go through normal LUKS encryption and put in
   a passphrase that you keep track of in your password manager (you will need it later in the
   installation as well).
7. Finish installation as instructed. Remove USB when instructed and reboot. Put in your passphrase
   when instructed.
8. Connect to wifi or ethernet. Open App Center and update the apps in there.
9. Open terminal, `sudo apt update` then `sudo apt upgrade`. Let that finish and reboot.
10. Optional: make a free Ubuntu Pro account and bind your installation with the instructions online;
    redo update and upgrade, and reboot.
11. Open Firmware Updater and update all of those with reboots. **DO NOT POWER OFF** while the
    firmware updates are happening. They might take a while.

## References

- AMD official ROCm install docs (authoritative, has Ubuntu 26.04 section):
  https://rocm.docs.amd.com/en/latest/install/rocm.html
- AMD ROCm apt repo (new, correct one for 26.04):
  https://stable.repo.amd.com/rocm/core/packages/ubuntu2604/
- Docker official docs (Ubuntu install):
  https://docs.docker.com/engine/install/ubuntu/
- Community writeups used during initial setup (predate the new AMD repo, but useful for Strix Halo specifics — GTT sizing, iGPU quirks):
  - https://note.com/a_244/n/n0470d851f36c?hl=en
  - https://www.reddit.com/r/MiniPCs/comments/1sb93jd/minisforum_mss1_max_and_others_setting_up_and/

## Why / decisions

- Two big BF16 models resident (27B + Flint 40B) → ~70 GB each; no parallel requests.
- Ollama in Docker w/ `ipc: host`, `--device /dev/kfd --dev/dri`, ROCm image, `OLLAMA_NUM_PARALLEL=3`.
- GTT window 180 GB (kernel cap); fresh 128 GB boxes don't raise it.

## Related

- Troubleshooting: `TROUBLESHOOTING.md`
- This doc: base minimal explanations of why.
