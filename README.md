# GPU Setup Script

This repository provides an automated, and reproducible installation script for NVIDIA drivers and the NVIDIA GPU Operator on a Kubernetes nodes.

---

## Supported Platforms

- **Ubuntu 22.04**
- **SUSE Linux Enterprise (SLE) 15 SP6**
- **SUSE Linux Enterprise Micro 6.0**

---

## Features

- **Automated Installation:**  
  Installs both the NVIDIA driver and the NVIDIA GPU Operator with a single command.

- **Idempotence:**  
  Checks for existing installations and skips or reattempts installation steps accordingly.

---

## Prerequisites

Before running the script, ensure that:

- **Root Privileges:**  
  The script must be executed as the root user or with `sudo`.

- **Required Tools and Commands:**  
  - Basic shell utilities: `bash`, `date`, etc.
  - Kernel module tool: `modprobe`
  - Kubernetes tools: `kubectl` and `helm` (required for the GPU Operator installation)
  
- **Internet Connectivity:**  
  The system must be connected to the internet to download packages and access external repositories.

---

## Usage

You can download and run the script manually. This is the preferred option in case you want to use flags.

```bash
curl -fsSL -o nvidia_easy_install.sh https://raw.githubusercontent.com/victorstevansuse/nvidia-drivers/latest/install.sh
chmod 700 nvidia_easy_install.sh
sudo ./nvidia_easy_install.sh
```

Optionally, you use the following `curl` or `get` command:


```bash
curl -o- https://raw.githubusercontent.com/victorstevansuse/nvidia-drivers/latest/install.sh | sudo bash
```

```bash
wget -qO- https://raw.githubusercontent.com/victorstevansuse/nvidia-drivers/latest/install.sh | sudo bash
```


### Options

- **`-d, --skip-driver`**  
  Skip the installation of the NVIDIA driver.

- **`-o, --skip-operator`**  
  Skip the installation of the NVIDIA GPU Operator.

- **`-r, --enable-reboot`**  
  Automatically reboot the system after completing the installation.

- **`-h, --help`**  
  Display the help message and usage instructions.

### Examples

- **Install both NVIDIA drivers and the GPU Operator:**

  ```bash
  sudo ./gpu-setup.sh
  ```

- **Install only the GPU Operator (skip driver installation):**

  ```bash
  sudo ./gpu-setup.sh --skip-driver
  ```

- **Install only the driver and enable automatic reboot:**

  ```bash
  sudo ./gpu-setup.sh -o -r
  ```

---

## How It Works

1. **Pre-flight Checks:**  
   The script validates the availability of necessary commands, tools, and the operating system details before proceeding.

2. **Operating System Detection:**  
   It sources the `/etc/os-release` file to determine the correct installation steps based on the host distribution.

3. **NVIDIA Driver Installation:**  
   - Checks whether `nvidia-smi` is already available and properly communicating with the GPU.
   - Installs the appropriate NVIDIA driver package if needed.

4. **NVIDIA GPU Operator Installation:**  
   Deploys the NVIDIA GPU Operator via Helm into a dedicated Kubernetes namespace to manage GPU resources.

5. **CUDA Sample Workload Deployment:**  
   Executes a sample CUDA job to verify that the GPU functionality is correctly set up and that the installed drivers and operator are working as expected.

6. **Cleanup (WIP):**  
   A cleanup function is automatically invoked if any error occurs during the installation process, ensuring that partially applied changes are reverted.
