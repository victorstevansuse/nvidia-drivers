#!/bin/bash
set -euo pipefail

NVIDIA_REPO_SLE="https://download.nvidia.com/suse/sle15sp6/"
NVIDIA_REPO_NAME="nvidia-sle15sp6-main"
UBUNTU_DRIVER_PKG="nvidia-driver-535"

log() { echo -e "[GPU-Setup] $1"; }

OS=""
OS_VERSION=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="$ID"
    OS_VERSION="${VERSION_ID:-}"
fi

log "Detected OS: $OS $OS_VERSION"

NVIDIA_SMI=$(command -v nvidia-smi || true)
if [ -n "$NVIDIA_SMI" ]; then
    if nvidia-smi &>/dev/null; then
        log "NVIDIA driver already installed and working (nvidia-smi detected GPU)."
        DRIVER_PRESENT=true
    else
        DRIVER_PRESENT=false
        log "nvidia-smi found but not functioning. Will attempt reinstallation of drivers."
    fi
else
    DRIVER_PRESENT=false
    log "NVIDIA driver not found (nvidia-smi not available). Installation will proceed."
fi

if [ "$DRIVER_PRESENT" = false ]; then
    case "$OS" in
      ubuntu)
        log "Installing NVIDIA driver on Ubuntu..."
        apt-get update -y
        apt-get install -y "${UBUNTU_DRIVER_PKG}"
        modprobe nvidia || true
        ;;
      sles|suse|suse-linux-enterprise)
        log "Installing NVIDIA open driver on SUSE Linux Enterprise 15 SP6..."
        if ! zypper lr | grep -q "$NVIDIA_REPO_NAME"; then
            log "Adding NVIDIA repository for SLE 15 SP6..."
            zypper --non-interactive addrepo --refresh "$NVIDIA_REPO_SLE" "$NVIDIA_REPO_NAME"
        fi
        zypper --non-interactive --gpg-auto-import-keys refresh
        zypper --non-interactive --auto-agree-with-licenses install -y nvidia-open-driver-G06-signed-kmp-default nvidia-compute-utils-G06
        modprobe nvidia || true
        ;;
      "sle-micro"|"slemicro"|"suse-micro"|"sl-micro")
        log "Installing NVIDIA open driver on SUSE Linux Enterprise Micro... (using transactional-update)"
        # Use transactional-update for SLE Micro
        # Open a transactional shell to add repo and install packages
        # We will create a here-document to feed commands into transactional-update shell
        transactional-update shell <<EOF
zypper --non-interactive addrepo --refresh $NVIDIA_REPO_SLE $NVIDIA_REPO_NAME
zypper --non-interactive --gpg-auto-import-keys refresh
# Find latest G06 driver version available (optional step omitted for simplicity; assuming default latest)
zypper --non-interactive install -y nvidia-open-driver-G06-signed-kmp-default nvidia-compute-utils-G06
exit
EOF
        log "Transactional update applied. Rebooting to activate the new snapshot with NVIDIA driver..."
        reboot
        exit 0
        ;;
      *)
        log "Unsupported OS or OS not recognized! Exiting."
        exit 1
        ;;
    esac

    if ! command -v nvidia-smi &>/dev/null; then
        log "ERROR: nvidia-smi not found after installation. NVIDIA driver install may have failed."
        exit 1
    fi
    if ! nvidia-smi &>/dev/null; then
        log "ERROR: NVIDIA driver installed but nvidia-smi cannot communicate with GPU. Please check driver compatibility."
        exit 1
    fi
    log "NVIDIA driver installation complete. `nvidia-smi --query-gpu=name --format=csv,noheader` detected."
fi

log "Deploying NVIDIA GPU Operator to Kubernetes via Helm..."
if ! helm repo list | grep -q "https://helm.ngc.nvidia.com/nvidia"; then
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia > /dev/null 2>&1 && helm repo update > /dev/null 2>&1
fi

kubectl create namespace gpu-operator --dry-run=client -o yaml | kubectl apply -f -

helm install gpu-operator nvidia/gpu-operator -n gpu-operator --wait

log "Checking GPU Operator components status..."
kubectl get pods -n gpu-operator

log "Deploying CUDA sample workload (vectorAdd) to verify GPU functionality..."
cat <<'EOJ' | kubectl apply -f -
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
kubectl wait --for=condition=Complete --timeout=120s job/vectoradd-sample

VECTORADD_POD=$(kubectl get pods -n default -l job-name=vectoradd-sample -o jsonpath='{.items[0].metadata.name}')
log "VectorAdd job completed. Logs from the GPU workload:"
kubectl logs "$VECTORADD_POD" -n default

log "GPU setup and verification complete! The NVIDIA GPU operator is running and sample workload executed successfully."
