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
        log "AMD Stoneyridge requires firmware blobs compiled into the kernel."
        log "These must exist as uncompressed .bin files at build time."

        ensure_nonfree_firmware
        apt-get install -y firmware-amd-graphics zstd

        # Decompress any .zst blobs - kernel EXTRA_FIRMWARE needs plain .bin
        STONEY_BLOBS=(ce me mec pfp rlc sdma uvd vce)
        MISSING_FW=()
        for blob in "${STONEY_BLOBS[@]}"; do
            bin="/lib/firmware/amdgpu/stoney_${blob}.bin"
            zst="${bin}.zst"
            if [[ -f "$bin" ]]; then
                log "  OK: $bin"
            elif [[ -f "$zst" ]]; then
                log "  Decompressing: $zst"
                zstd -d "$zst" -o "$bin"
                log "  OK: $bin"
            else
                MISSING_FW+=("stoney_${blob}.bin")
            fi
        done

        if [[ ${#MISSING_FW[@]} -gt 0 ]]; then
            warn "Still missing after install: ${MISSING_FW[*]}"
            warn "Trying direct download from linux-firmware git..."
            for blob in "${MISSING_FW[@]}"; do
                wget -q "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/amdgpu/${blob}" \
                     -O "/lib/firmware/amdgpu/${blob}" && \
                log "  Downloaded: $blob" || \
                warn "  Failed to download: $blob"
            done
        fi

        # Final check
        STILL_MISSING=()
        for blob in "${STONEY_BLOBS[@]}"; do
            [[ ! -f "/lib/firmware/amdgpu/stoney_${blob}.bin" ]] && \
                STILL_MISSING+=("stoney_${blob}.bin")
        done

        if [[ ${#STILL_MISSING[@]} -gt 0 ]]; then
            die "Cannot find firmware: ${STILL_MISSING[*]}
     Audio will not work without these files present at kernel build time."
        fi

        log "All Stoneyridge firmware blobs present:"
        ls -lh /lib/firmware/amdgpu/stoney_*.bin
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
