#!/usr/bin/env bash
# GPU Setup Script with NVIDIA Driver and GPU Operator Installation
# This script automates a reproducible installation on Kubernetes nodes.
# Supported distributions:
#   - Ubuntu 22.04
#   - SUSE Linux Enterprise 15 SP6
#   - SUSE Linux Enterprise Micro 6.0
#
# Original implementation by Victor Ribeiro <victor.ribeiro@suse.com>




#
# Logging
#
readonly RED=$'\e[31m'
readonly GREEN=$'\e[32m'
readonly ORANGE=$'\e[0;33m'
readonly NORMAL=$'\e[0m'


log_info() {
  printf "%b\n" "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')][INFO] ${1}${NORMAL}" >&2
}

log_error() {
  printf "%b\n" "${RED}[$(date '+%Y-%m-%d %H:%M:%S')][ERROR] ${1}${NORMAL}" >&2
}

log_warning() {
  printf "${ORANGE}[$(date '+%Y-%m-%d %H:%M:%S')][WARN] %s${NORMAL}\n" "$@" >&2
}


# 
# Assertions
# These asserts are used to design the functions in a defensive way.
#
E_ASSERT_FAILED=99
assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3-}"

  if [[ "$expected" == "$actual" ]]
  then
    return 0
  else
    if [ "${#msg}" -gt 0 ] 
    then
      log_error "assert_eq: $expected == $actual :: $msg"
    fi
    exit $E_ASSERT_FAILED
  fi
}

assert_file_exists() {
  local file="$1"
  local msg="${2-}"

  if [ -e "$file" ]
  then
    return 0
  else
    if [ "${#msg}" -gt 0 ] 
    then
      log_error "File does not exist: $file :: $msg"
    fi
    exit $E_ASSERT_FAILED
  fi

}

command_exists() {
  command -v "$1" > /dev/null 2>&1
}

assert_command_exists() {
  local cmd="$1"
  local msg="${2-}"

  if command_exists "$cmd"
  then
    return 0
  else
    if [ "${#msg}" -gt 0 ] 
    then
      log_error "Command does not exist: $cmd :: $msg"
    fi
    exit $E_ASSERT_FAILED
  fi

}

# 
# Utils
#
get_os_id() {
  assert_file_exists "/etc/os-release" "file /etc/os-release is missing"

  local id_line
  id_line=$(grep -E '^ID=' /etc/os-release)

  printf "%s\n" "${id_line#ID=}"
}

get_os_version_id() {
  assert_file_exists "/etc/os-release" "file /etc/os-release is missing"

  local version_id_line
  version_id_line=$(grep -E '^VERSION_ID=' /etc/os-release)


  printf "%s\n" "${version_id_line#VERSION_ID=}"
}

# 
# Flags and flag parsing
#
INSTALL_DRIVER=true
INSTALL_OPERATOR=true
ENABLE_REBOOT=false
DEPLOY_SAMPLE_WORKLOAD=false
TIME_SLICING_CONFIG=""
DRY_RUN=false

usage() {
    cat <<EOF
GPU Setup Script - Version 1.1.0
----------------------------------
Usage: $0 [options]
Options:
  -d, --skip-driver             Skip NVIDIA driver installation
  -o, --skip-operator           Skip NVIDIA GPU Operator installation
  -r, --enable-reboot           Automatically reboot after driver install
  -t, --enable-time-slicing     Enable GPU time-slicing config
  -w, --deploy-sample-workload  Deploy a CUDA sample workload (vectoradd)
  -h, --help                    Show this help message
EOF
}

parse_args() {

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -d|--skip-driver)       INSTALL_DRIVER=false;       shift ;;
      -o|--skip-operator)     INSTALL_OPERATOR=false;     shift ;;
      -r|--enable-reboot)     ENABLE_REBOOT=true;        shift ;;
      -t|--enable-time-slicing)
        [[ -z "${2:-}" ]] && { log_error "Option '$1' requires a file path"; exit 1; }
        [[ ! -f $2       ]] && { log_error "File not found: $2";           exit 1; }
        TIME_SLICING_CONFIG=$2
        shift 2 ;;
      -w|--deploy-sample-workload) DEPLOY_SAMPLE_WORKLOAD=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help)              usage; exit 0 ;;  
      *) log_error "Unknown option: $1" ; exit 1 ;;  
    esac
  done
}

preflight_checks() {
  log_info "Running preflight checks."

  if [[ "$EUID" -ne 0 ]]
  then
    log_error "Driver installation requires root. Please re-run as root or use --skip-driver."
    exit 1
  fi

  local id
  id="$(get_os_id)"

  local version_id
  version_id="$(get_os_version_id)"

  if $INSTALL_DRIVER
  then
    log_info "Checking OS support"
    case "$id" in
      ubuntu)
          if [[ "$version_id" == "24.04" ]]
          then
            log_info "Ubuntu 24.04 detected."
          else
            log_error "Ubuntu version $version_id currently not supported. Exiting..."
            exit 1;
          fi
        ;; 
      sles|suse*) 
          if [[ "$version_id" == "15.6" ]]
          then
            log_info "SUSE Linux Enterprise 15-SP6 detected."
          else
            log_error "SUSE Linux Enterprise version $version_id currently not supported. Exiting..."
            exit 1
          fi
        ;; 
      sle-micro*)
          if [[ "$version_id" == "6.0" ]]
          then
            log_info "SUSE Linux Micro 6.0 detected."
          else
            log_error "SUSE Linux Micro version $version_id currently not supported. Exiting..."
            exit 1;
          fi
        ;; 
      *) log_error "Unsupported OS: $id"; exit 1;
    esac
  fi

  user="$(id -un 2>/dev/null || true)"

  if $INSTALL_OPERATOR
  then
    log_info "Checking dependencies for NVIDIA GPU Operator installation"
    if [[ "$user" != "root" ]]
    then
      if ! sudo -u "$user" -i command -v helm > /dev/null 2>&1; then
        log_error "helm not in user PATH for user $user"
        exit 1
      fi

      if ! sudo -u "$user" -i command -v kubectl > /dev/null 2>&1; then
        log_error "kubectl not in user PATH for user $user"
        exit 1
      fi
    else
      assert_command_exists "helm"
      assert_command_exists "kubectl"
    fi
  fi
}

readonly NVIDIA_DRIVER_REPO="https://download.nvidia.com/suse/sle15sp6/"
readonly NVIDIA_REPO_NAME="nvidia-sle15sp6-main"
readonly NVIDIA_DRIVER_VERSION="550.100"


install_driver(){
  local id
  id=$(get_os_id)

  local sh_c="sh -c"
  if $DRY_RUN
  then
    sh_c="echo"
  fi

  if command_exists "nvidia-smi" && nvidia-smi &>/dev/null
  then
    log_info "NVIDIA driver (nvidia-smi) already present"

  else
    log_warning "Installing NVIDIA driver..."
    if "$DRY_RUN"
    then
      set -x
    fi

    case "$id" in
      ubuntu)
        $sh_c apt-get update -y
        $sh_c apt-get install -y "nvidia-driver-535" 
        ;;
      sles*)
        $sh_c zypper ar --refresh "$NVIDIA_DRIVER_REPO" "$NVIDIA_REPO_NAME"
        $sh_c zypper ref
        $sh_c zypper in -y -l nvidia-open-driver-G07-signed-kmp="$NVIDIA_DRIVER_VERSION" nvidia-compute-utils-G06="$NVIDIA_DRIVER_VERSION"
        ;;
      sl-micro*)
        $sh_c transactional-update shell <<EOF || error "transactional-update failed"
          zypper ar --refresh $NVIDIA_REPO_SLE $NVIDIA_REPO_NAME
          zypper ref
          zypper in -y -l nvidia-open-driver-G06-signed-kmp-default nvidia-compute-utils-G06
          exit
EOF
        ;;
      *)
        log_error "Unsupported OS for driver installation"
        exit 1
        ;;
    esac

    log_info "Driver installed: $(nvidia-smi --query-gpu=name --format=csv,noheader)"
  fi

  set +x
}

# Install GPU Operator using Helm using the NGC NVIDIA repository.
# More about configuration options for containerd (toolkit.env config below): https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html#specifying-configuration-options-for-containerd
# Configuration for containerd are the same as in the SUSE AI Stack: https://github.com/SUSE/suse-ai-stack/blob/ebf1a105d573dd69b167c78dfdc76644f42c3b05/roles/nvidia-gpu-operator/tasks/main.yml#L57-L60
# More about configuring time-slicing with GPU Operator here: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html#configuring-time-slicing-before-installing-the-nvidia-gpu-operator
# Required kubectl and hel,
IS_NFD_ENABLED=false
install_gpu_operator(){

 
  if kubectl wait --for=condition=Ready node --all --timeout=60s 2>/dev/null
  then
    log_info "Control-plane is healthy — continuing"
  else
    log_info "Control-plane not healthy — aborting"
    exit 1
  fi 


  log_info "Checking if the node advertises the resource nvidia.com/gpu"
  # Note: Installing the NVIDIA GPU Operator only makes sense when at least one node already exposes GPU capacity
  local -r gpu_values
  gpu_values="$(kubectl get nodes \
    -o jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' 2>/dev/null)"

  if grep -Eq '^[1-9][0-9]*$' <<<"$(tr ' ' '\n' <<<"${gpu_values}")"
  then
      log_info 'GPUs detected — values: %s\n' "${gpu_values:-<none>}"
  else
      log_error 'No NVIDIA GPU capacity found.'
      exit 1
  fi


  log_info "Checking for Node Feature Discovery labels..."
  # Using jsonpath instaed of JQ. 
  # Reference: https://github.com/SUSE/suse-ai-stack/blob/ebf1a105d573dd69b167c78dfdc76644f42c3b05/roles/nvidia-gpu-operator/tasks/main.yml#L17 (which is also in NVIDIA GPU Operator docs installation)
  if kubectl get nodes \
       -o jsonpath='{range .items[*].metadata.labels}{.}{"\n"}{end}' \
     | grep -q '^feature.node.kubernetes.io'
  then
    IS_NFD_ENABLED=true
    log_info "NFD detected."
  else
    IS_NFD_ENABLED=false
    log_info "NFD not detected."
  fi


  log_info "Creating and labeling gpu-operator namespace..."

  kubectl create ns gpu-operator --dry-run=client -o yaml | kubectl apply -f -
  kubectl label --overwrite ns gpu-operator pod-security.kubernetes.io/enforce=privileged

  log_info "Adding/updating NVIDIA Helm repository..."
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
  helm repo update

  HELM_VALUES=(
    driver.enabled=false
    nfd.enabled="$IS_NFD_ENABLED"
    toolkit.env[0].name=CONTAINERD_SOCKET
    toolkit.env[0].value=/run/k3s/containerd/containerd.sock
  )

  if [[ -n $TIME_SLICING_CONFIG ]]; then
    log_info "Enabling GPU time-slicing from file: $TIME_SLICING_CONFIG"

    # let Helm know which ConfigMap/CR this file creates
    # Derive a stable name from the file base-name (strip extension)
    cfg_name="$(basename "$TIME_SLICING_CONFIG")"
    cfg_name="${cfg_name%.*}"

    HELM_VALUES+=(
      "devicePlugin.config.name=${cfg_name}"
      "devicePlugin.config.default=any"
    )

    kubectl apply -f "$TIME_SLICING_CONFIG"
  fi

  log_info "Installing/upgrading NVIDIA GPU Operator..."
  helm upgrade --install gpu-operator nvidia/gpu-operator \
    -n gpu-operator --wait \
    "$(printf "--set %s " "${HELM_VALUES[@]}")"

  log_info "Waiting for GPU Operator deployment to roll out…"
  kubectl -n gpu-operator rollout status deploy/gpu-operator --timeout=300s

  if "$IS_NFD_ENABLED" 
  then
    log_info "Waiting for NFD deployments…"
    for svc in node-feature-discovery-master node-feature-discovery-worker; do
      kubectl -n gpu-operator rollout status deploy/gpu-operator-$svc --timeout=300s
    done
  fi

  info "Pausing for cluster stabilization…"
  sleep 120
  info "Waiting for container toolkit health (port 9345)…"
  until nc -z localhost 9345; do sleep 5; done
  info "Container toolkit is healthy"
}

deploy_sample_workload() {
  log_info "Deploying CUDA sample vectoradd..."

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
spec:
  restartPolicy: OnFailure
  containers:
  - name: cuda-vectoradd
    image: "nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04"
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

  # wait 60s for the pod to leave pending or running phases
  kubectl wait "pod/cuda-vectoradd" -n "default" --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s
  
  local phase
  local exit_code
  phase="$(kubectl get pod "cuda-vectoradd" -n "default" -o jsonpath='{.status.phase}')"
  exit_code="$(kubectl get pod "cuda-vectoradd" -n "default" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"

  if [[ "$phase" == "Succeeded" && "$exit_code" == "0" ]]
  then
    log_info "Sample workload finished successfully"
    log_info "Sample logs:"
    kubectl logs "cuda-vectoradd" -n default

    log_info "Deleting cuda-vectoradd sample pod"
    kubectl delete -f cuda-vectoradd.yaml
  else
    log_error "Sample workload failed (phase: $phase, exit: $exit_code)"
    log_warning "Sample logs:"

    kubectl logs "cuda-vectoradd" -n default
  fi
}



do_install() {
  parse_args "$@"
  preflight_checks

  if $INSTALL_DRIVER
  then
    log_info "Starting nvidia-smi installation."
    install_driver
    if "$ENABLE_REBOOT"
    then
      log_warning "Rebooting..."
      reboot
    else
      log_warning "Reboot disabled. Please reboot manually"
    fi
  else
    log_info "Driver installation skipped."
  fi


  if "$INSTALL_OPERATOR"
  then
    log_info "Starting NVIDIA GPU Operator installation."
    install_gpu_operator

    if "$DEPLOY_SAMPLE_WORKLOAD"
    then
      deploy_sample_workload
    fi
  else
    log_info "NVIDIA GPU Operator installation skipped."
  fi

}

do_install "$@" 

