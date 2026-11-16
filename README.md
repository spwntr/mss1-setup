# MSS1 Setup — Strix Halo (Minisforum MS-S1 Max) — Quick Start

Setup steps for the local LLM stack on MSS1.

This will get you to llama.cpp hosting a chat in webui and/or a pi.dev agent. Both can help you get 
everything else you'd want setup. chat can help you do it, pi.dev can potentially do it for you.

> For the **base minimal explanations of why** things are done this way, see
> **`llm-setup.md`**. Deep troubleshooting and experiments: **`TROUBLESHOOTING.md`**.

## Windows → Ubuntu migration — see `llm-setup.md` §5

Note: it's a **fresh install of Windows that we will never use** — so no migration, just change a
few settings and then wipe for the Ubuntu install.

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

## Setup sequence (ordered)

### Step -1 — git or just pull up the mss1-setup

https://github.com/spwntr/mss1-setup

or

```bash
sudo apt install git
git clone https://github.com/spwntr/mss1-setup.git
cd mss1-setup
cat README.md
```

or navigate there and open the file as a text document 

### Step 0 — SSH key setup
Ed25519 SSH keys + `authorized_keys` + host alias.

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C "<username>@<host>" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
chmod 600 ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
```

### Step 1 — Encryption: dropbear + clevis

Ubuntu 26.04 installer refuses hardware-backed (TPM) full-disk encryption (PCR_UNUSABLE error;
Secure Boot policy PCR7 measurements, dbt not supported by secboot). With plain passphrase LUKS, the
machine drops to early boot and waits for the passphrase at the console — a headless server hangs
after every reboot / power cut.

Workarounds:
1. **Remote unlock over SSH** — `dropbear-initramfs`.
   Small SSH server that runs in initramfs before the disk is unlocked; after reboot you SSH in
   from anywhere and type the passphrase. Simple and secure; person still has to unlock after each
   reboot, just not physically.

   ```bash
   sudo apt install dropbear-initramfs net-tools ssh cryptsetup lvm2 shim-signed
   # add your public key to /etc/dropbear/initramfs/authorized_keys
   cat ~/.ssh/id_ed25519.pub >> /etc/dropbear/initramfs/authorized_keys
   sudo chmod 600 /etc/dropbear/initramfs/authorized_keys
   sudo update-initramfs -u
   sudo systemctl enable ssh.service
   sudo systemctl start ssh.service
   ```

   After reboot, connect with `ssh root@<host-ip>` and run `cryptroot-unlock` to enter the disk
   passphrase.

2. **Bind disk to TPM yourself** — `clevis` + `clevis-tpm2`.
   Install with normal LUKS, add TPM as an extra unlock method after install. These tools seal the
   key to the machine's current measurements rather than predicting future ones, so the dbt problem
   that blocked the installer doesn't apply. You get unattended boot, and your passphrase remains as
   a backup.

   ```bash
   # output is the <luks-partition> something like nvmexxxxxx
   lsbkl -f | grep -i crypto
   sudo apt install clevis clevis-luks clevis-tpm2 clevis-initramfs
   sudo clevis luks bind -d /dev/<luks-partition> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'
   sudo update-initramfs -u
   ```

   Caveat: a firmware or Secure Boot database update can change PCR7; the TPM unlock then fails and
   falls back to asking for the passphrase. When that happens, unlock manually once using (1.) and re-bind.
   
   ```bash
   sudo clevis luks bind -d /dev/<luks-partition> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'
   sudo update-initramfs -u
   ```

- After success: `sudo clevis luks list -d /dev/<luks-partition>` and `sudo update-initramfs -u`.
- If you wait ~30–60 s it eventually decrypts itself → TPM released the key, Clevis unlocked
  unattended; the passphrase prompt is cosmetic.

### Step 2 — Add AMD ROCm apt repo (repo adds)
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
sudo usermod -aG video, render $USER
```

Amd tools aren't in path for some reason. Add them to path:
`echo 'export PATH=/opt/rocm/core-10.1/bin:$PATH' >> ~/.bashrc`
Reload bashrc to use the new path.
`source ~/.bashrc`

### Step 3 — Install all the stuff with apt
Docker official:
```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg util-linux-extra
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=amd signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  resolute stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Add the user to the docker group (then re-login):
```bash
sudo usermod -aG docker $USER
newgrp docker
```

### Step 4 — Build llama.cpp — `llm-setup.md` §1.7


or just get the app:
```bash
curl -LsSf https://llama.app/install.sh | sh
```

or do it the hard way so you can merge model download shards and quantize big model files:

```bash
sudo apt install amdrocm-core-sdk llama.cpp-tools libllama0 libggml0 libggml0-backend-vulkan \
  cmake ccache build-essential libssl-dev ninja-build 

# from home, or where ever you want llama.cpp directory (if not home, modify ~/llama.cpp references below accordingly)
cd ~

git clone https://github.com/ggml-org/llama.cpp
cd ~/llama.cpp

# build llama.cpp
HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -S . -B build -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151 -DCMAKE_BUILD_TYPE=Release
    
cmake --build build --config Release -j"$(nproc)"

# binary → ~/llama.cpp/build/bin/llama
# spilt/merge tool → ~/llama.cpp/build/bin/llama-gguf-split
# build quantize tool → ~/llama.cpp/build/bin/llama-quantize
# if you built the tools, you probably want to add them to your path
echo 'export PATH=~/llama.cpp/build/bin:$PATH' >> ~/.bashrc
# Reload bashrc to use the new path.
source ~/.bashrc
```

Once you have a model in ~/models directory after Step 5 (below) you can:

1. run it as a chat bot in an open-webui interface with:
```bash
llama-server -m ~/models/<your_gguf_file>
```

or 

```bash
llama-server -m ~/models/<your_model_folder>/<your_gguf_model_file>
```

and it should be reachable at `localhost:9931` from a browser

2. run llama.cpp as a model router that you can connect to an agent like pi.dev as below
```bash
llama-server --models-dir ~/models
```

### Step 5 — Hugging Face + download, merge + import to ollama to come — `llm-setup.md` §1.8

```bash
mkdir ~/models
sudo apt install python3-huggingface-hub python3.14-venv 
hf download Qwen/Qwen3.6-35B-A3B --local-dir ~/models/Qwen3.6-35B-A3B
```

Merge sharded Huggingface download into single gguf file that can be hosted on llama.cpp
```bash
cd ~/llama.cpp
python3 -m venv .venv
# once the above step has been completed the first time and created the .venv environment
# "source .venv/bin/activate" gets you back into the .venv environment
(.venv) pip install -r requirements.txt
(.venv) python3 convert_hf_to_gguf.py ../models/Qwen3.6-35B-A3B --outfile ../models/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B.gguf --outtype f16
(.venv) deactivate
```

### Step 5.5 — Pi.dev

```bash
sudo apt install npm
curl -fsSL https://pi.dev/install.sh | sh
```

Don't start pi now when it asked you to at the end of installation. It added pi to the path in .bashrc, which we need to reload.

```bash
source ~/.bashrc
```

and setup the model control for pi

```bash
nano ~/.pi/agent/models.json
```

this will open a nano editor in the terminal. Don't just press buttons here, it doesn't act normal.

copy this (beow json) like normal (ctl + c). Then paste it into the nano terminal window with (ctl + shift + v)

```bash
{
  "$schema": "https://pi.dev/schemas/models.schema.json",
  "providers": {
    "llama.cpp": {
      "baseUrl": "http://localhost:9931/v1",
      "api": "openai-completions",
      "apiKey": "none",
      "models": [
        {
          "id": "Qwen3.6-35B-A3B",
          "name": "Qwen3.6-35B-A3B",
          "reasoning": true,
          "stop": ["gasdf"],
          "input": ["text"],
          "contextWindow": 262144,
          "maxTokens": 262144,
          "cost": {
            "input": 0,
            "output": 0,
            "cacheRead": 0,
            "cacheWrite": 0
          }
        }
      ]
    }
  }
}
```

do (ctl + o), press enter to save the file. then (ctl + x) to close nano.

Start pi
```bash
pi
```

in pi, login to llama.cpp
```pi
/login llama.cpp
```

follow directions to input llama router `http://localhost:9931`
then leave api key blank (unless you've set one in llama.cpp)
```pi
/llama
```
move the arrow to Qwen3.6-35B-A3B, hit enter. It will say something in red about the key, don't worry about it.

```pi
/model
```

select Qwen3.6-35-A3B, hit enter. Start asking it questions. It should be able to help troubleshoot from here.

To exit pi:
```pi
/quit
```

### Step 6 — Docker — `llm-setup.md` §1.3

### Step 7 — Ollama compose — `llm-setup.md` §1.4

Full compose file: `~/docker/ollama/compose.yml`.

### Step 8 — Start Ollama — `llm-setup.md` §1.5

```bash
cd ~/docker/ollama
docker compose up -d
docker compose ps
docker compose logs -f ollama
```

### Step 9 — Open WebUI — `llm-setup.md` §1.6

### Step 10 — Verify — `llm-setup.md` §1.9

## Model inventory / how to add a model — `llm-setup.md` §4

## Deep troubleshooting / experiments — `TROUBLESHOOTING.md`

## References — `llm-setup.md`

## Open questions / future work
