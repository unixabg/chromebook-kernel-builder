#!/usr/bin/env bash
# =============================================================================
# setup_build_env.sh
#
# Prepares the build machine or container with all prerequisites needed
# to build a kernel for the given platform. Run once before first build,
# or after setting up a fresh container.
#
# Usage: sudo ./scripts/setup_build_env.sh <platform>
#
# Examples:
#   sudo ./scripts/setup_build_env.sh amd-stoneyridge
#   sudo ./scripts/setup_build_env.sh amd-ryzen-zork
#   sudo ./scripts/setup_build_env.sh intel-cometlake
#
# If no platform is given, only the common build tools are installed.
# =============================================================================

set -euo pipefail

PLATFORM="${1:-}"

log()  { echo "[setup] $*"; }
die()  { echo "[setup] FATAL: $*"; exit 1; }
warn() { echo "[setup] WARNING: $*"; }

[[ "$EUID" -ne 0 ]] && die "Must run as root (sudo)"

# =============================================================================
# Common build dependencies - needed for all platforms
# =============================================================================
log "Installing common build dependencies..."
apt-get install -y \
    build-essential bc bison flex \
    libssl-dev libelf-dev libncurses-dev \
    dwarves pahole debhelper rsync \
    kmod wget curl git xz-utils
log "Common dependencies: OK"

# =============================================================================
# Platform-specific dependencies
# =============================================================================
if [[ -z "$PLATFORM" ]]; then
    log "No platform specified - skipping platform-specific setup"
    log "Re-run with a platform argument to install firmware and extras"
    exit 0
fi

log "Platform-specific setup for: $PLATFORM"

ensure_nonfree_firmware() {
    # Check if non-free-firmware is already in sources
    if grep -r "non-free-firmware" /etc/apt/sources.list.d/ &>/dev/null ||
       grep -r "non-free-firmware" /etc/apt/sources.list &>/dev/null; then
        log "non-free-firmware already in apt sources"
        return
    fi

    log "Adding non-free-firmware to apt sources..."

    # Handle deb822 format (.sources files) - modern Debian
    local sources_file
    sources_file=$(find /etc/apt/sources.list.d/ -name "*.sources" | head -1)
    if [[ -n "$sources_file" ]]; then
        sed -i 's/^Components: main$/Components: main non-free-firmware/' "$sources_file"
        log "Updated $sources_file"
    # Handle classic format (sources.list)
    elif [[ -f /etc/apt/sources.list ]]; then
        sed -i 's/^\(deb .*\) main$/\1 main non-free-firmware/' /etc/apt/sources.list
        log "Updated /etc/apt/sources.list"
    else
        die "Cannot find apt sources file to add non-free-firmware"
    fi

    apt-get update
}

case "$PLATFORM" in
    # -------------------------------------------------------------------------
    amd-stoneyridge)
        log "AMD Stoneyridge: firmware loads from filesystem at runtime."
        log "EXTRA_FIRMWARE is empty per validated working config - no firmware"
        log "needs to be compiled into the kernel."
        log ""
        log "On the TARGET Chromebook, ensure firmware-amd-graphics is installed:"
        log "  sudo apt-get install firmware-amd-graphics"
        log "  (requires non-free-firmware in apt sources on Debian)"
        log "  OR install linux-firmware on Ubuntu/VelvetOS"

        # Install firmware on this machine if it will also be the target
        # (i.e. building locally on the Chromebook itself)
        if [[ -d /sys/class/dmi/id ]]; then
            BOARD=$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)
            if [[ -n "$BOARD" ]]; then
                log "Detected local board: $BOARD - installing runtime firmware..."
                ensure_nonfree_firmware
                apt-get install -y firmware-amd-graphics 2>/dev/null || \
                    apt-get install -y linux-firmware 2>/dev/null || \
                    warn "Could not install AMD firmware - install manually on target"
            fi
        fi
        ;;

    # -------------------------------------------------------------------------
    amd-ryzen-zork|amd-mendocino|amd-phoenix)
        log "AMD Ryzen/Zork uses SOF - firmware loaded from initrd, no builtin required"
        ensure_nonfree_firmware
        apt-get install -y firmware-amd-graphics
        log "AMD firmware: OK"
        ;;

    # -------------------------------------------------------------------------
    intel-cometlake|intel-tigerlake|intel-alderlake)
        log "Intel platform - installing WiFi and DSP firmware"
        ensure_nonfree_firmware
        apt-get install -y firmware-iwlwifi
        log "Intel firmware: OK"
        ;;

    # -------------------------------------------------------------------------
    *)
        warn "Unknown platform '$PLATFORM' - only common deps installed"
        warn "Add platform-specific setup to this script if needed"
        ;;
esac

log ""
log "=== Setup complete for: ${PLATFORM:-common} ==="
log "You can now run: sudo ./scripts/build_kernel.sh --codename <codename>"
