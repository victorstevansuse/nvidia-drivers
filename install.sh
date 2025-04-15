#!/bin/bash
# GPU Setup Script with NVIDIA Driver and GPU Operator Installation
# This script automates a reproducible installation on Kubernetes nodes.
# Supported distributions:
#   - Ubuntu 22.04
#   - SUSE Linux Enterprise 15 SP6
#   - SUSE Linux Enterprise Micro 6.0
#
# Original implementation by Victor Ribeiro <victor.ribeiro@suse.com>

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'  # No Color

# General log function printing a timestamp and message.
log() {
    local level="$1"
    local msg="$2"
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${level} ${msg}"
}
info() {
    log "${GREEN}[INFO]${NC}" "$1"
}
warn() {
    log "${YELLOW}[WARNING]${NC}" "$1"
}
error() {
    log "${RED}[ERROR]${NC}" "$1"
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "'$1' command not found. Please install it and retry."
}
ensure() {
    "$@" || error "Command failed: $*"
}
ignore() {
    "$@"
}

usage() {
    cat <<EOF
GPU Setup Script - Version 1.0.0
----------------------------------
This script automates the installation of NVIDIA drivers and the NVIDIA GPU Operator
on a Kubernetes node.
It supports:
  - Ubuntu 22.04
  - SUSE Linux Enterprise (SLE) 15 SP6
  - SUSE Linux Enterprise Micro 6.0

Usage: $0 [options]

Options:
  -d, --skip-driver       Skip NVIDIA driver installation.
  -o, --skip-operator     Skip NVIDIA GPU Operator installation.
  -r, --enable-reboot     Automatically reboot the system after installation.
  -h, --help              Show this help message and exit.

Examples:
  $0                # Install both driver and GPU Operator.
  $0 -d             # Install only GPU Operator.
  $0 -o -r          # Install only the driver and enable auto-reboot.
EOF
}

########################################
# Ensure Root Access
########################################
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root. Exiting."
fi

########################################
# Variables and Defaults
########################################
NVIDIA_REPO_SLE="https://download.nvidia.com/suse/sle15sp6/"
NVIDIA_REPO_NAME="nvidia-sle15sp6-main"
UBUNTU_DRIVER_PKG="nvidia-driver-535"

# Default flag values
INSTALL_DRIVER=true
INSTALL_OPERATOR=true
ENABLE_REBOOT=false

ARGS=("$@")
for arg in "${ARGS[@]}"; do
    case "$arg" in
        --skip-driver)
            INSTALL_DRIVER=false
            shift
            ;;
        --skip-operator)
            INSTALL_OPERATOR=false
            shift
            ;;
        --enable-reboot)
            ENABLE_REBOOT=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
    esac
done

while getopts "dorh" opt; do
    case "$opt" in
        d) INSTALL_DRIVER=false ;;
        o) INSTALL_OPERATOR=false ;;
        r) ENABLE_REBOOT=true ;;
        h)
            usage
            exit 0
            ;;
        ?)
            usage
            exit 1
            ;;
    esac
done

if $ENABLE_REBOOT; then
    warn "Automatic system reboot is ENABLED. The system will reboot after installation."
fi

# Used to shortcut the required dependencies, fail fast and avoid executing steps that'll later fail because of missing stuff.
preflight_checks() {
    need_cmd date
    need_cmd command
    if [ "$INSTALL_DRIVER" = true ]; then
        need_cmd modprobe
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            case "$ID" in
                ubuntu)
                    need_cmd apt-get
                    ;;
                sles|suse|suse-linux-enterprise)
                    need_cmd zypper
                    ;;
                sle-micro|slemicro|suse-micro|sl-micro)
                    need_cmd transactional-update
                    ;;
                *)
                    error "Unsupported OS! Currently supports SLE 15 SP6, SLE Micro 6.0, and Ubuntu 22.04."
                    ;;
            esac
        else
            error "/etc/os-release not found. Unable to detect OS."
        fi
    fi

    if [ "$INSTALL_OPERATOR" = true ]; then
        need_cmd helm
        need_cmd kubectl
    fi
}
preflight_checks

########################################
# Cleanup Function (Triggered on Error)
########################################
cleanup() {
    warn "Performing cleanup due to an error..."
    if [ "$INSTALL_OPERATOR" = true ]; then
        if kubectl get namespace gpu-operator &>/dev/null; then
            warn "Removing gpu-operator namespace..."
            kubectl delete namespace gpu-operator || warn "Failed to delete gpu-operator namespace."
        fi
    fi
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
info "Detected OS: $OS $OS_VERSION"

########################################
# NVIDIA Driver Installation
########################################
if [ "$INSTALL_DRIVER" = true ]; then
    NVIDIA_SMI=$(command -v nvidia-smi || true)
    if [ -n "$NVIDIA_SMI" ]; then
        if nvidia-smi &>/dev/null; then
            info "NVIDIA driver already installed and working (nvidia-smi detected GPU)."
            DRIVER_PRESENT=true
        else
            DRIVER_PRESENT=false
            warn "nvidia-smi found but not functioning. Will attempt reinstallation of drivers."
        fi
    else
        DRIVER_PRESENT=false
        warn "NVIDIA driver not found (nvidia-smi not available). Installation will proceed."
    fi

    install_nvidia_driver() {
        case "$OS" in
            ubuntu)
                info "Installing NVIDIA driver on Ubuntu..."
                ensure apt-get update -y
                ensure apt-get install -y "${UBUNTU_DRIVER_PKG}"
                ensure modprobe nvidia
                info "Successfully installed NVIDIA driver on Ubuntu."
                ;;
            sles|suse|suse-linux-enterprise)
                info "Installing NVIDIA open driver on SUSE Linux Enterprise 15 SP6..."
                if ! zypper lr | grep -q "$NVIDIA_REPO_NAME"; then
                    info "Adding NVIDIA repository for SLE 15 SP6..."
                    ensure zypper --non-interactive addrepo --refresh "$NVIDIA_REPO_SLE" "$NVIDIA_REPO_NAME"
                fi
                ensure zypper --non-interactive --gpg-auto-import-keys refresh
                ensure zypper --non-interactive --auto-agree-with-licenses install -y nvidia-open-driver-G06-signed-kmp-default nvidia-compute-utils-G06
                ensure modprobe nvidia
                info "Successfully installed NVIDIA driver on SUSE Linux Enterprise 15 SP6."
                ;;
            sle-micro|slemicro|suse-micro|sl-micro)
                info "Installing NVIDIA open driver on SLE Micro using transactional-update..."
                transactional-update shell <<EOF || error "Transactional-update installation failed."
zypper --non-interactive addrepo --refresh $NVIDIA_REPO_SLE $NVIDIA_REPO_NAME
zypper --non-interactive --gpg-auto-import-keys refresh
zypper --non-interactive install -y -l nvidia-open-driver-G06-signed-kmp-default nvidia-compute-utils-G06
exit
EOF
                info "Transactional update applied."
                if $ENABLE_REBOOT; then
                    warn "Reboot is enabled. System will reboot shortly to apply the new snapshot with NVIDIA driver."
                    sleep 5
                    reboot
                    exit 0
                else
                    info "Reboot is disabled by flag. Please reboot manually to apply the NVIDIA driver."
                fi
                ;;
            *)
                error "Unsupported OS or OS not recognized! Only supports SLE 15 SP6, SLE Micro 6.0, and Ubuntu 22.04."
                ;;
        esac
    }
    
    if [ "$DRIVER_PRESENT" = false ]; then
        install_nvidia_driver
        # Verify installation success
        if ! command -v nvidia-smi &>/dev/null; then
            error "nvidia-smi not found after driver installation. Installation may have failed."
        fi
        if ! nvidia-smi &>/dev/null; then
            error "NVIDIA driver installed but nvidia-smi cannot communicate with GPU. Please check driver compatibility."
        fi
        info "NVIDIA driver installation complete. Detected GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader)"
    else
        info "Skipping NVIDIA driver installation as driver is already present."
    fi
else
    info "NVIDIA driver installation skipped as per flag."
fi

########################################
# NVIDIA GPU Operator Installation
########################################
if [ "$INSTALL_OPERATOR" = true ]; then
    info "Deploying NVIDIA GPU Operator to Kubernetes via Helm..."
    if ! helm repo list | grep -q "https://helm.ngc.nvidia.com/nvidia"; then
        ensure helm repo add nvidia https://helm.ngc.nvidia.com/nvidia > /dev/null 2>&1
        ensure helm repo update > /dev/null 2>&1
    fi

    ensure kubectl create namespace gpu-operator --dry-run=client -o yaml | kubectl apply -f - || error "Failed to create/update namespace gpu-operator."
    ensure helm install gpu-operator nvidia/gpu-operator -n gpu-operator --wait || error "Failed to install GPU Operator via Helm."
    info "Checking GPU Operator components status..."
    ensure kubectl get pods -n gpu-operator || error "Failed to retrieve GPU Operator pods status."
else
    info "NVIDIA GPU Operator installation skipped as per flag."
fi

########################################
# Deploy CUDA Sample Workload (if GPU Operator is installed)
########################################
if [ "$INSTALL_OPERATOR" = true ]; then
    info "Deploying CUDA sample workload (vectorAdd) to verify GPU functionality..."
    cat <<'EOJ' | kubectl apply -f - || error "Failed to deploy CUDA sample workload."
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

    info "Waiting for the sample job to complete..."
    ensure kubectl wait --for=condition=Complete --timeout=120s job/vectoradd-sample || error "CUDA sample workload did not complete successfully."
    VECTORADD_POD=$(kubectl get pods -n default -l job-name=vectoradd-sample -o jsonpath='{.items[0].metadata.name}') || error "Failed to retrieve VectorAdd pod name."
    info "VectorAdd job completed. GPU workload logs:"
    ensure kubectl logs "$VECTORADD_POD" -n default || error "Failed to retrieve logs from the GPU workload."
    info "GPU Operator sample workload executed successfully."
fi

info "GPU setup and verification complete!"
