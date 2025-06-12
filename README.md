# GPU Setup Script

> Automated, reproducible installation of **either** NVIDIA drivers **or** the NVIDIA GPU Operator on Kubernetes worker nodes.

---

## Supported Linux distributions

* **Ubuntu 22.04 LTS**
* **SUSE Linux Enterprise Server (SLES) 15 SP6**
* **SUSE Linux Enterprise Micro 6.0 or newer**

---

## Key capabilities

* **One‑command GPU enablement**
* **Mutually exclusive driver / operator paths** – avoid partial or conflicting configurations.
* **Dry‑run mode** – print every command without touching the host.
* **CUDA sample workload validation** – optional VectorAdd pod to prove everything works.
---

## Quick start

Install the latest driver *and* keep the node running (no reboot):

```bash
curl -fsSL https://raw.githubusercontent.com/victorstevansuse/nvidia-drivers/latest/install.sh | sudo bash
```

Download + tweak flags locally:

```bash
curl -fsSL -o gpu-setup.sh https://raw.githubusercontent.com/victorstevansuse/nvidia-drivers/latest/install.sh
chmod +x gpu-setup.sh
sudo ./gpu-setup.sh [flags]
```

---

## CLI flags

| Short | Long option                | Default | Purpose                                                                                                                            |
| ----- | -------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `-d`  | `--skip-driver`            | `false` | Skip NVIDIA driver installation.                                                                                                   |
| `-o`  | `--install-gpu-operator`   | `false` | Deploy the NVIDIA GPU Operator via Helm. **Cannot be used together with driver installation – make sure to pass `--skip-driver`.** |
| `-r`  | `--enable-reboot`          | `false` | Reboot immediately after successfully installing the driver.                                                                       |
| `-w`  | `--deploy-sample-workload` | `false` | Run the CUDA `vectoradd` sample pod after setup to validate GPU functionality.                                                     |
|       | `--dry-run`                | `false` | Echo every shell command instead of executing it.                                                                                  |
| `-h`  | `--help`                   | –       | Show usage information.                                                                                                            |

---

## Examples

| Scenario                                           | Command                                                    |
| -------------------------------------------------- | ---------------------------------------------------------- |
| **Driver only** (default path)                     | `sudo ./gpu-setup.sh`                                      |
| **GPU Operator only** (driver already present)     | `./gpu-setup.sh --skip-driver --install-gpu-operator` |
| **Dry‑run – explore without changes**              | `sudo ./gpu-setup.sh --dry-run`                            |

---

## Workflow overview

1. **Pre‑flight checks**
   • Ensures required utilities (`bash`, `kubectl`, `helm`, etc.).
   • Verifies root privileges when the driver will be installed.
   • Detects OS and GPU presence.
   • Confirms cluster health when the GPU Operator path is chosen.

2. **Driver installation path (default)**
   • Adds the correct NVIDIA repository and installs the newest production branch:
   ‑ `nvidia-driver-535` on Ubuntu.
   ‑ `nvidia-open-driver-G06` on SLES / SLE Micro.
   • Optionally reboots the host if `-r` is set.

3. **GPU Operator installation path (`--install-gpu-operator`)**
   • Creates the **gpu-operator** namespace with the required security label.
   • Adds the NVIDIA Helm repo and deploys the operator.
   • Honours existing Node Feature Discovery (NFD) deployment if found.

4. **Optional sample workload (`-w`)**
   • Launches a CUDA VectorAdd pod.
   • Waits for completion and prints the container logs.
   • Cleans up the pod when it succeeds.

---

## Prerequisites

| Requirement         | Needed for                            | Notes                                                                                                                     |
| ------------------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Root privileges     | Driver installation                   | Operator installation can run as an unprivileged user, provided that `kubectl` and `helm` are on the user’s *login* PATH. |
| `kubectl` & `helm`  | GPU Operator                          | `helm` 3.0+ required. Control‑plane must be Ready.                                                                        |
| Physical NVIDIA GPU | Driver installation & sample workload | The script aborts early if no GPU (`nvidia` PCI device) is detected.                                                      |

---

## Troubleshooting

* **“NVIDIA driver already present”** – rerun with `--skip-driver` if you intentionally keep the existing driver.
* **“GPUs not found”** – validate hardware passthrough (for VMs) or physical GPU presence.
* **Operator deploy hangs** – check cluster state (`kubectl get pods -A`) and verify Node Feature Discovery labels.
* **"Control-plane not healthy" when cluster is available** - make sure to run the script without `sudo` when installing GPU Operator or deploying the sample workload.

