#!/bin/sh
# This script installs Ollama on Linux.
# It detects the current operating system architecture and installs the appropriate version of Ollama.

set -eu

status() { echo ">>> $*" >&2; }
error() { echo "ERROR $*"; exit 1; }
warning() { echo "WARNING: $*"; }

available() { command -v "$1" >/dev/null; }
require() {
    MISSING=''
    for TOOL in "$@"; do
        if ! available "$TOOL"; then
            MISSING="$MISSING $TOOL"
        fi
    done

    echo "$MISSING"
}

[ "$(uname -s)" = "Linux" ] || error 'This script is intended to run on Linux only.'

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) error "Unsupported architecture: $ARCH" ;;
esac

SUDO=
if [ "$(id -u)" -ne 0 ]; then
    # Running as root, no need for sudo
    if ! available sudo; then
        error "This script requires superuser permissions. Please re-run as root."
    fi

    SUDO="sudo"
fi

NEEDS=$(require curl awk grep sed tee xargs)
if [ -n "$NEEDS" ]; then
    status "ERROR: The following tools are required but missing:"
    for NEED in $NEEDS; do
        echo "  - $NEED"
    done
    exit 1
fi

TEMP_DIR=$(mktemp -d)
cleanup() {
    EXIT_CODE=$?
    rm -rf "$TEMP_DIR"

    if available nvidia-smi && lsmod | grep -qv nvidia; then
        status 'Reboot to complete NVIDIA CUDA driver install.'
    fi

    if available systemctl >/dev/null; then
        $SUDO systemctl restart ollama

        timeout 10 sh -c 'while :; do [ "$(curl -s http://127.0.0.1:11434)" = "Ollama is running" ] && break; sleep 0.2; done' \
            && status 'Ollama service is available at 127.0.0.1:11434' \
            || true
    fi

    if available ollama; then
        status 'Install completed. Run "ollama --help" to get started.'
    fi

    exit $EXIT_CODE
}
trap cleanup EXIT

status "Downloading ollama..."
curl --fail --show-error --location --progress-bar -o "$TEMP_DIR/ollama" "https://ollama.ai/download/ollama-linux-$ARCH"

for BIN_DIR in /usr/local/bin /usr/bin /bin; do
    if echo "$PATH" | grep -q $BIN_DIR; then
        break
    fi
done

status "Installing ollama to $BIN_DIR..."
$SUDO install -o0 -g0 -m755 -d "$BIN_DIR"
$SUDO install -o0 -g0 -m755 "$TEMP_DIR/ollama" "$BIN_DIR/ollama"

# Everything from this point onwards is optional.

configure_systemd() {
    if ! id ollama >/dev/null 2>&1; then
        status "Creating ollama user..."
        $SUDO useradd -r -s /bin/false -m -d /usr/share/ollama ollama
    fi

    status "Creating ollama systemd service..."
    cat <<EOF | $SUDO tee /etc/systemd/system/ollama.service >/dev/null
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=$BIN_DIR/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=$PATH"

[Install]
WantedBy=default.target
EOF
    SYSTEMCTL_RUNNING="$(systemctl is-system-running || true)"
    case $SYSTEMCTL_RUNNING in
        running|degraded)
            status "Enabling and starting ollama service..."
            $SUDO systemctl daemon-reload
            $SUDO systemctl enable ollama
            ;;
    esac
}

if available systemctl; then
    configure_systemd
fi

if ! available lspci && ! available lshw; then
    warning "Unable to detect NVIDIA GPU. Install lspci or lshw to automatically detect and install NVIDIA CUDA drivers."
    exit
fi

check_gpu() {
    case $1 in
        lspci) available lspci && lspci -d '10de:' | grep -q 'NVIDIA' || return 1 ;;
        lshw) available lshw && $SUDO lshw -c display -numeric | grep -q 'vendor: .* \[10DE\]' || return 1 ;;
        nvidia-smi) available nvidia-smi || return 1 ;;
    esac
}

if check_gpu nvidia-smi; then
    status "NVIDIA GPU installed."
    exit
fi

if ! check_gpu lspci && ! check_gpu lshw; then
    install_success
    warning "No NVIDIA GPU detected. Ollama will run with CPU."
    exit
fi

# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#rhel-7-centos-7
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#rhel-8-rocky-8
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#rhel-9-rocky-9
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#fedora
install_cuda_driver_yum() {
    status 'Installing NVIDIA repository...'
    case $PACKAGE_MANAGER in
        yum)
            $SUDO $PACKAGE_MANAGER -y install yum-utils
            $SUDO $PACKAGE_MANAGER-config-manager --add-repo "https://developer.download.nvidia.com/compute/cuda/repos/$1$2/$(uname -m)/cuda-$1$2.repo"
            ;;
        dnf)
            $SUDO $PACKAGE_MANAGER config-manager --add-repo "https://developer.download.nvidia.com/compute/cuda/repos/$1$2/$(uname -m)/cuda-$1$2.repo"
            ;;
    esac

    case $1 in
        rhel)
            status 'Installing EPEL repository...'
            # EPEL is required for third-party dependencies such as dkms and libvdpau
            $SUDO $PACKAGE_MANAGER -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$2.noarch.rpm" || true
            ;;
    esac

    status 'Installing CUDA driver...'

    if [ "$1" = 'centos' ] || [ "$1$2" = 'rhel7' ]; then
        $SUDO $PACKAGE_MANAGER -y install nvidia-driver-latest-dkms
    fi

    $SUDO $PACKAGE_MANAGER -y install cuda-drivers
}

# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#ubuntu
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#debian
install_cuda_driver_apt() {
    status 'Installing NVIDIA repository...'
    curl -fsSL -o "$TEMP_DIR/cuda-keyring.deb" "https://developer.download.nvidia.com/compute/cuda/repos/$1$2/$(uname -m)/cuda-keyring_1.1-1_all.deb"

    case $1 in
        debian)
            status 'Enabling contrib sources...'
            $SUDO sed 's/main/contrib/' < /etc/apt/sources.list | $SUDO tee /etc/apt/sources.list.d/contrib.list > /dev/null
            if [ -f "/etc/apt/sources.list.d/debian.sources" ]; then
                $SUDO sed 's/main/contrib/' < /etc/apt/sources.list.d/debian.sources | $SUDO tee /etc/apt/sources.list.d/contrib.sources > /dev/null
            fi
            ;;
    esac

    status 'Installing CUDA driver...'
    $SUDO dpkg -i "$TEMP_DIR/cuda-keyring.deb"
    $SUDO apt-get update

    [ -n "$SUDO" ] && SUDO_E="$SUDO -E" || SUDO_E=
    DEBIAN_FRONTEND=noninteractive $SUDO_E apt-get -y install cuda-drivers -q
}

if [ ! -f "/etc/os-release" ]; then
    error "Unknown distribution. Skipping CUDA installation."
fi

. /etc/os-release

OS_NAME=$ID
OS_VERSION=$VERSION_ID

PACKAGE_MANAGER=
for PACKAGE_MANAGER in dnf yum apt-get; do
    if available $PACKAGE_MANAGER; then
        break
    fi
done

if [ -z "$PACKAGE_MANAGER" ]; then
    error "Unknown package manager. Skipping CUDA installation."
fi

if ! check_gpu nvidia-smi || nvidia-smi | grep -qo "CUDA Version: [0-9]*\.[0-9]*"; then
    case $OS_NAME in
        centos|rhel) install_cuda_driver_yum 'rhel' "$OS_VERSION" ;;
        rocky) install_cuda_driver_yum 'rhel' "$(echo "$OS_VERSION" | cut -c1)" ;;
        fedora) install_cuda_driver_yum "$OS_NAME" "$OS_VERSION" ;;
        amzn) install_cuda_driver_yum 'fedora' '35' ;;
        debian) install_cuda_driver_apt "$OS_NAME" "$OS_VERSION" ;;
        ubuntu) install_cuda_driver_apt "$OS_NAME" "$(echo "$OS_VERSION" | sed 's/\.//')" ;;
        *) exit ;;
    esac
fi

if ! lsmod | grep -q nvidia; then
    KERNEL_RELEASE="$(uname -r)"
    case $OS_NAME in
        centos|rhel|rocky|amzn) $SUDO $PACKAGE_MANAGER -y install "kernel-devel-$KERNEL_RELEASE" "kernel-headers-$KERNEL_RELEASE" ;;
        fedora) $SUDO $PACKAGE_MANAGER -y install "kernel-devel-$KERNEL_RELEASE" ;;
        debian|ubuntu) $SUDO apt-get -y install "linux-headers-$KERNEL_RELEASE" ;;
        *) exit ;;
    esac

    NVIDIA_CUDA_VERSION=$($SUDO dkms status | awk -F: '/added/ { print $1 }')
    if [ -n "$NVIDIA_CUDA_VERSION" ]; then
        $SUDO dkms install "$NVIDIA_CUDA_VERSION"
    fi

    if lsmod | grep -q nouveau; then
        status 'Reboot to complete NVIDIA CUDA driver install.'
        exit
    fi

    $SUDO modprobe nvidia
fi


status "NVIDIA CUDA drivers installed."
