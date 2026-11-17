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
   a passphrase that you keep track of **in your password manager** (you will need it later in the
   installation as well).
7. Finish installation as instructed. Remove USB when instructed and reboot. Put in your passphrase
   when instructed.
8. Connect to wifi or ethernet. Open App Center and update the apps in there.
9. Open terminal, `sudo apt update` then `sudo apt upgrade`. Let that finish and reboot.
10. Optional: make a free Ubuntu Pro account and bind your installation with the instructions online;
    redo update and upgrade, and reboot.
11. Open Firmware Updater and update all of those with reboots. **DO NOT POWER OFF** while the
    firmware updates are happening. They might take a while.

## Setup sequence (ordered starting with fresh Ubuntu 26.04 install)
Visit https://github.com/spwntr/mss1-setup

### Step 0 — SSH key and setup
Ed25519 SSH keys + `authorized_keys` + host alias. ssh.service 

open the terminal app.
Install some programs we'll need.
```bash
sudo apt install net-tools ssh cryptsetup lvm2 shim-signed
```
Setup ssh keys
```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
```
Use your username and the name of your computer as `<username>` and `<host>`. This information is in your terminal command line prompt `<username>@<host>:~$`
```bash
ssh-keygen -t ed25519 -C "<username>@<host>" -f ~/.ssh/id_ed25519
```
put in a passcode that you won't forget as the key. you can leave it blank, but you would have to remember you left it blank if you do.
```bash
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
```
```bash
chmod 600 ~/.ssh/authorized_keys
```
```bash
chmod 600 ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
```
Start the ssh.service
```bash
sudo systemctl enable ssh.service
```
```bash
sudo systemctl start ssh.service
```
Check that it is running. should be green dots with "active (running)"
```bash
sudo systemctl status ssh.service
```
do (ctl + c) to get back to the terminal prompt.


### Step 1 — Bind disk to TPM — `clevis` + `clevis-tpm2` so that it will automatically unencrypt the disk.
Ubuntu 26.04 installer refuses hardware-backed (TPM) full-disk encryption (PCR_UNUSABLE error;
Secure Boot policy PCR7 measurements, dbt not supported by secboot). With plain passphrase LUKS, the
machine drops to early boot and waits for the passphrase at the console — a headless server hangs
after every reboot / power cut.


   Install with normal LUKS, add TPM as an extra unlock method after install. These tools seal the
   key to the machine's current measurements rather than predicting future ones, so the dbt problem
   that blocked the installer doesn't apply. You get unattended boot, and your passphrase remains as
   a backup.

   Find the encrypted partition. Output is the `<luks-partition>` something like nvmexxxxxx that. Replace the place holder in the following commands.
   ```bash
   lsbkl -f | grep -i crypto
   ```
   ```bash
   sudo apt install clevis clevis-luks clevis-tpm2 clevis-initramfs
   ```
   Bind the encrypted partition to the TPM. This will ask you for the encryption passphrase that should be in your password manager from installing Ubuntu.
   ```bash
   sudo clevis luks bind -d /dev/<luks-partition> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'
   ```
   ```bash
   sudo update-initramfs -u
   ```

   Caveat: a firmware or Secure Boot database update can change PCR7; the TPM unlock then fails and
   falls back to asking for the passphrase. When that happens, unlock manually once using (1.) and re-bind.
   
   ```bash
   sudo clevis luks bind -d /dev/<luks-partition> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'
   ```
   ```bash
   sudo update-initramfs -u
   ```

- After success: this should list `{1: ` with the details from the bind command above.
  ```bash
  sudo clevis luks list -d /dev/<luks-partition>
  ```
- After reboot, the passphrase box will show up, but if you wait ~30–60 seconds it eventually decrypts itself → TPM released the key, Clevis unlocked
  unattended; the passphrase prompt is cosmetic.
- I'm working on instructions to have the fallback dropbear to remotely login and put in the passphrase.

### Step 2 — Add AMD ROCm apt repo (repo adds)
Make a keyrings directory to store authentication keys for the repositories that we will download from.
```bash
sudo mkdir --parents --mode=0755 /etc/apt/keyrings
```
Get the key for AMD RocM packages.
```bash
wget -qO - https://stable.repo.amd.com/rocm/gpg/packages.gpg | \
  gpg --dearmor | sudo tee /etc/apt/keyrings/amdrocm.gpg > /dev/null
```
Add the repository to the ones `apt` looks for when you do `sudo apt update`
```bash
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
```
Update the repositories. You should see the newly added amd.com/rocm/core repo in the list.
```bash
sudo apt update
```
Install the AMD packages.
```bash
sudo apt install -y amdrocm-core-sdk amdrocm-amdsmi
```

Add the user to the GPU groups (video + render) for AMD ROCm:
```bash
sudo usermod -aG video,render $USER
```

Amd tools aren't in path for some reason. Add them to path:
```bash
echo 'export PATH=/opt/rocm/core-10.1/bin:$PATH' >> ~/.bashrc'
```
Reload bashrc to use the new path.
```bash
source ~/.bashrc
```

### Step 3 — Install all the stuff with apt
Docker official:
```bash
sudo apt update
```
Install some tools that we will use.
```bash
sudo apt install -y ca-certificates curl gnupg util-linux-extra
```
Get the authentication key for docker repo.
```bash
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
```
```bash
sudo chmod a+r /etc/apt/keyrings/docker.asc
```
Add docker repo to the repositories.
```bash
echo \
  "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  resolute stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```
Update
```bash
sudo apt update
```
Get docker tools.
```bash
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Add the user to the docker group so that you can use docker commands without sudo.
```bash
sudo usermod -aG docker $USER
```
Reload the docker group or close the terminal and open a new one.
```bash
newgrp docker
```

### Step 4 — Build llama.cpp — `llm-setup.md` §1.7

Do it the hard way so you can get tools to merge model download shards and quantize big model files:

```bash
sudo apt install git llama.cpp-tools libllama0 libggml0 libggml0-backend-vulkan \
  cmake ccache build-essential libssl-dev ninja-build
```

change directory to home.
```bash
cd ~
```
Clone llama.cpp into ~/llama.cpp directory
```bash
git clone https://github.com/ggml-org/llama.cpp && cd ~/llama.cpp
```
Move into the llama.cpp directory
```bash
cd llama.cpp
```
build llama.cpp. copy and paste all of this section.
```bash
HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -S . -B build -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151 -DCMAKE_BUILD_TYPE=Release
    
cmake --build build --config Release -j"$(nproc)"
```
Once it's done:
   llama and llama-server tools → ~/llama.cpp/build/bin/llama
   spilt/merge tool → ~/llama.cpp/build/bin/llama-gguf-split
   build quantize tool → ~/llama.cpp/build/bin/llama-quantize

Add the llama.cpp tools to your path
```bash
echo 'export PATH=~/llama.cpp/build/bin:$PATH' >> ~/.bashrc
```
Reload bashrc to use the new path.
```bash
source ~/.bashrc
```

### Step 5 — Hugging Face + download, merge + import to ollama to come — `llm-setup.md` §1.8

Make the directory to store the models
```bash
mkdir ~/models
```
Install hugging face tools and python3 .venv environments
```bash
sudo apt install python3-huggingface-hub python3.14-venv
```
next step is going to take a while. it builds the hf tool and then will download a very large model (~60 GB)
```bash
hf download Qwen/Qwen3.6-35B-A3B --local-dir ~/models/Qwen3.6-35B-A3B
```

Merge sharded Huggingface download into single gguf file that can be hosted on llama.cpp. This uses a different tool that was not made when we cmake built the llama.cpp tools above. It uses python3 .venv environments in the ~/llama.cpp directory.
```bash
cd ~/llama.cpp
```
Create the .venv python3 environment.
```bash
python3 -m venv .venv
```

once the above `python3 -m venv .venv` step creates the .venv project environment, `source .venv/bin/activate` gets you back into the .venv environment when you are in the ~/llama.cpp directory. only copy the commands below from after the `$`, they assume you are in the .venv environment denoted by the (.venv) in the command prompt.

Download the python3 dependencies for the package.
```bash
(.venv)$ pip install -r requirements.txt
```
convert the shards into a .gguf file with full quantization.
```bash
(.venv)$ python3 convert_hf_to_gguf.py ../models/Qwen3.6-35B-A3B --outfile ../models/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B.gguf --outtype f16
```
Close the python3 package environment.
```bash
(.venv)$ deactivate
```


### Step 6 — Run the model with llama.cpp

Once you have a model in ~/models directory you can:

1. run it as a chat bot in an open-webui interface with:
```bash
llama-server -m ~/models/<your_gguf_file>
```

or 

```bash
llama-server -m ~/models/<your_model_folder>/<your_gguf_file>
```

and it should be reachable at `localhost:9931` from a browser


2. run llama.cpp as a model router that you can connect to an agent like pi.dev as below
```bash
llama-server --models-dir ~/models
```

### Step 7 — Pi.dev. Get an agent.

```bash
sudo apt install npm
```
```bash
curl -fsSL https://pi.dev/install.sh | sh
```

Don't start pi now when it asks you to at the end of installation. It added pi to the path in .bashrc, which we need to reload.

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

- there's a bug in llama.cpp right now that causes models end early on spaces. so we've added the "stop": ["gasdf"] until the bug is fixed. then we can remove it.

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

### Step 8 — Docker — `llm-setup.md` §1.3

### Step 9 — Ollama compose — `llm-setup.md` §1.4

Full compose file: `~/docker/ollama/compose.yml`.

### Step 10 — Start Ollama — `llm-setup.md` §1.5

```bash
cd ~/docker/ollama
docker compose up -d
docker compose ps
docker compose logs -f ollama
```

### Step 11 — Open WebUI — `llm-setup.md` §1.6

### Step 12 — Verify — `llm-setup.md` §1.9

## Model inventory / how to add a model — `llm-setup.md` §4

## Deep troubleshooting / experiments — `TROUBLESHOOTING.md`

## References — `llm-setup.md`

## Open questions / future work
