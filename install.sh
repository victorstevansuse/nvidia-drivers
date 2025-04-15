#!/bin/bash

# NVIDIA Easy Installation Script.
# Implemented by Victor Ribeiro <victor.ribeiro@suse.com>


set -euo pipefail

########################################
# Ensure root access 
########################################
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31mERROR: This script must be run as root. Exiting.\033[0m" >&2
    exit 1
fi

########################################
# Color Definitions
########################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

########################################
# Variables and Defaults
########################################
NVIDIA_REPO_SLE="https://download.nvidia.com/suse/sle15sp6/"
NVIDIA_REPO_NAME="nvidia-sle15sp6-main"
UBUNTU_DRIVER_PKG="nvidia-driver-535"

# Flags default values
INSTALL_DRIVER=true
INSTALL_OPERATOR=true
ENABLE_REBOOT=false

########################################
# Logging Function with Color
########################################
log() {
    local message="$1"
    local color="${GREEN}"  # default for info messages

    if [[ "$message" == ERROR:* ]]; then
        color="${RED}"
    elif [[ "$message" == WARNING:* ]]; then
        color="${YELLOW}"
    fi

    echo -e "[GPU-Setup] $(date '+%Y-%m-%d %H:%M:%S') ${color}${message}${NC}"
}

########################################
# Usage Information
########################################
usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --skip-driver       Skip NVIDIA driver installation.
  --skip-operator     Skip NVIDIA GPU Operator installation.
  --enable-reboot     Enable automatic reboot after installation (disabled by default).
  --help              Show this help message and exit.

Description:
  This script provides an automated, reproducible way to install
  NVIDIA drivers and the NVIDIA GPU Operator on a node.
  It supports Ubuntu, SUSE Linux Enterprise (SLE), and SUSE Linux Enterprise Micro.
EOF
}

########################################
# Parse Command-Line Flags
########################################
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --skip-driver)
            INSTALL_DRIVER=false
            ;;
        --skip-operator)
            INSTALL_OPERATOR=false
            ;;
        --enable-reboot)
            ENABLE_REBOOT=true
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            log "ERROR: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

# Immediately warn if automatic reboot is enabled
if $ENABLE_REBOOT; then
    log "WARNING: Automatic system reboot is ENABLED. The system will reboot automatically after installation."
fi

########################################
# Pre-flight Checks for Required Commands
########################################
preflight_checks() {
    # Check for basic commands
    for cmd in date command; do
        command -v "$cmd" &>/dev/null || { log "ERROR: Required command '$cmd' not found. Exiting."; exit 1; }
    done

    if [ "$INSTALL_DRIVER" = true ]; then
        command -v modprobe &>/dev/null || { log "ERROR: modprobe command not found. Exiting."; exit 1; }
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            case "$ID" in
                ubuntu)
                    command -v apt-get &>/dev/null || { log "ERROR: apt-get command not found. Exiting."; exit 1; }
                    ;;
                sles|suse|suse-linux-enterprise)
                    command -v zypper &>/dev/null || { log "ERROR: zypper command not found. Exiting."; exit 1; }
                    ;;
                sle-micro|slemicro|suse-micro|sl-micro)
                    command -v transactional-update &>/dev/null || { log "ERROR: transactional-update command not found. Exiting."; exit 1; }
                    ;;
                *)
                    log "ERROR: Unsupported OS or OS not recognized! Currently the script only supports SLE 15 SP6, SLE Micro 6.0, and Ubuntu 22.04.\nExiting."
                    exit 1
                    ;;
            esac
        else
            log "ERROR: /etc/os-release not found. Unable to detect OS. Exiting."
            exit 1
        fi
    fi

    if [ "$INSTALL_OPERATOR" = true ]; then
        command -v helm &>/dev/null || { log "ERROR: helm command not found. Exiting."; exit 1; }
        command -v kubectl &>/dev/null || { log "ERROR: kubectl command not found. Exiting."; exit 1; }
    fi
}
preflight_checks

########################################
# Cleanup Function (Triggered on Error)
########################################
cleanup() {
    log "WARNING: Performing cleanup due to an error..."
    if [ "$INSTALL_OPERATOR" = true ]; then
        if kubectl get namespace gpu-operator &>/dev/null; then
            log "WARNING: Removing gpu-operator namespace..."
            kubectl delete namespace gpu-operator || log "WARNING: Failed to delete gpu-operator namespace."
        fi
    fi
    # Additional cleanup can be added here if needed.
}
trap cleanup ERR

########################################
# Detect Operating System
########################################
OS=""
OS_VERSION=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="$ID"
    OS_VERSION="${VERSION_ID:-}"
fi
log "Detected OS: $OS $OS_VERSION"

########################################
# NVIDIA Driver Installation
########################################
if [ "$INSTALL_DRIVER" = true ]; then
    NVIDIA_SMI=$(command -v nvidia-smi || true)
    if [ -n "$NVIDIA_SMI" ]; then
        if nvidia-smi &>/dev/null; then
            log "NVIDIA driver already installed and working (nvidia-smi detected GPU)."
            DRIVER_PRESENT=true
        else
            DRIVER_PRESENT=false
            log "WARNING: nvidia-smi found but not functioning. Will attempt reinstallation of drivers."
        fi
    else
        DRIVER_PRESENT=false
        log "WARNING: NVIDIA driver not found (nvidia-smi not available). Installation will proceed."
    fi

    install_nvidia_driver() {
        case "$OS" in
            ubuntu)
                log "Installing NVIDIA driver on Ubuntu..."
                apt-get update -y || { log "ERROR: apt-get update failed."; exit 1; }
                apt-get install -y "${UBUNTU_DRIVER_PKG}" || { log "ERROR: Failed to install ${UBUNTU_DRIVER_PKG}."; exit 1; }
                modprobe nvidia || { log "ERROR: modprobe nvidia failed."; exit 1; }
                log "Successfully installed NVIDIA driver on Ubuntu."
                ;;
            sles|suse|suse-linux-enterprise)
                log "Installing NVIDIA open driver on SUSE Linux Enterprise 15 SP6..."
                if ! zypper lr | grep -q "$NVIDIA_REPO_NAME"; then
                    log "Adding NVIDIA repository for SLE 15 SP6..."
                    zypper --non-interactive addrepo --refresh "$NVIDIA_REPO_SLE" "$NVIDIA_REPO_NAME" || { log "ERROR: Failed to add NVIDIA repository."; exit 1; }
                fi
                zypper --non-interactive --gpg-auto-import-keys refresh || { log "ERROR: zypper refresh failed."; exit 1; }
                zypper --non-interactive --auto-agree-with-licenses install -y nvidia-open-driver-G06-signed-kmp-default nvidia-compute-utils-G06 || { log "ERROR: Installation of NVIDIA driver packages failed."; exit 1; }
                modprobe nvidia || { log "ERROR: modprobe nvidia failed."; exit 1; }
                log "Successfully installed NVIDIA driver on SUSE Linux Enterprise 15 SP6."
                ;;
            sle-micro|slemicro|suse-micro|sl-micro)
                log "Installing NVIDIA open driver on SUSE Linux Enterprise Micro... (using transactional-update)"
                transactional-update shell <<EOF || { log "ERROR: Transactional-update installation failed."; exit 1; }
zypper --non-interactive addrepo --refresh $NVIDIA_REPO_SLE $NVIDIA_REPO_NAME
zypper --non-interactive --gpg-auto-import-keys refresh
zypper --non-interactive install -y nvidia-open-driver-G06-signed-kmp-default nvidia-compute-utils-G06
exit
EOF
                log "Transactional update applied."
                if $ENABLE_REBOOT; then
                    log "WARNING: Reboot is enabled. System will reboot shortly to apply the new snapshot with NVIDIA driver."
                    sleep 5
                    reboot
                    exit 0
                else
                    log "INFO: Reboot is disabled by flag. Please reboot manually to apply the NVIDIA driver."
                fi
                ;;
            *)
                log "ERROR: Unsupported OS or OS not recognized! Currently the script only supports SLE 15 SP6, SLE Micro 6.0, and Ubuntu 22.04.\nExiting."
                exit 1
                ;;
        esac
    }
    
    if [ "$DRIVER_PRESENT" = false ]; then
        install_nvidia_driver
        # Verify installation success
        if ! command -v nvidia-smi &>/dev/null; then
            log "ERROR: nvidia-smi not found after driver installation. Installation may have failed."
            exit 1
        fi
        if ! nvidia-smi &>/dev/null; then
            log "ERROR: NVIDIA driver installed but nvidia-smi cannot communicate with GPU. Please check driver compatibility."
            exit 1
        fi
        log "NVIDIA driver installation complete. Detected GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader)"
    else
        log "INFO: Skipping NVIDIA driver installation as driver is already present."
    fi
else
    log "INFO: NVIDIA driver installation skipped as per flag."
fi

########################################
# NVIDIA GPU Operator Installation
########################################
if [ "$INSTALL_OPERATOR" = true ]; then
    log "Deploying NVIDIA GPU Operator to Kubernetes via Helm..."
    if ! helm repo list | grep -q "https://helm.ngc.nvidia.com/nvidia"; then
        helm repo add nvidia https://helm.ngc.nvidia.com/nvidia > /dev/null 2>&1 || { log "ERROR: Failed to add Helm repo for NVIDIA GPU Operator."; exit 1; }
        helm repo update > /dev/null 2>&1 || { log "ERROR: Helm repo update failed."; exit 1; }
    fi

    kubectl create namespace gpu-operator --dry-run=client -o yaml | kubectl apply -f - || { log "ERROR: Failed to create/update namespace gpu-operator."; exit 1; }

    helm install gpu-operator nvidia/gpu-operator -n gpu-operator --wait || { log "ERROR: Failed to install GPU Operator via Helm."; exit 1; }

    log "Checking GPU Operator components status..."
    kubectl get pods -n gpu-operator || { log "ERROR: Failed to retrieve GPU Operator pods status."; exit 1; }
else
    log "INFO: NVIDIA GPU Operator installation skipped as per flag."
fi

########################################
# Deploy CUDA Sample Workload (if GPU Operator is installed)
########################################
if [ "$INSTALL_OPERATOR" = true ]; then
    log "Deploying CUDA sample workload (vectorAdd) to verify GPU functionality..."
    cat <<'EOJ' | kubectl apply -f - || { log "ERROR: Failed to deploy CUDA sample workload."; exit 1; }
apiVersion: batch/v1
kind: Job
metadata:
  name: vectoradd-sample
  namespace: default
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: vectoradd
        image: "nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubi8"
        resources:
          limits:
            nvidia.com/gpu: 1
EOJ

    log "Waiting for the sample job to complete..."
    kubectl wait --for=condition=Complete --timeout=120s job/vectoradd-sample || { log "ERROR: CUDA sample workload did not complete successfully."; exit 1; }

    VECTORADD_POD=$(kubectl get pods -n default -l job-name=vectoradd-sample -o jsonpath='{.items[0].metadata.name}') || { log "ERROR: Failed to retrieve VectorAdd pod name."; exit 1; }
    log "VectorAdd job completed. GPU workload logs:"
    kubectl logs "$VECTORADD_POD" -n default || { log "ERROR: Failed to retrieve logs from the GPU workload."; exit 1; }

    log "GPU Operator sample workload executed successfully."
fi

log "GPU setup and verification complete!"
