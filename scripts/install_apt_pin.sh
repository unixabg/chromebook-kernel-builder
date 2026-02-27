#!/usr/bin/env bash
# =============================================================================
# install_apt_pin.sh
#
# Pins the custom velvet kernel to prevent apt from:
#   - Upgrading it to a newer version
#   - Replacing it with a generic distro kernel
#   - Auto-installing new kernel meta-packages that would pull in stock kernels
#
# Pinning strategy:
#   - Priority 1001 on our specific package: always keep, never replace
#   - Priority -1 on kernel meta-packages: never auto-install generic kernels
#   - apt-mark hold as a second layer of protection
#
# Usage: sudo ./install_apt_pin.sh <full-version-string> <codename> <platform>
# =============================================================================

set -euo pipefail

# --generate mode: write pin file to a specified path without installing it
# Usage: install_apt_pin.sh --generate <version> <codename> <platform> <output-path>
# Normal mode (install on this machine):
# Usage: install_apt_pin.sh <version> <codename> <platform>

GENERATE_ONLY=false
if [[ "${1:-}" == "--generate" ]]; then
    GENERATE_ONLY=true
    shift
fi

FULL_VERSION="${1:?Usage: $0 [--generate] <version> <codename> <platform> [output-path]}"
CODENAME="${2:?}"
PLATFORM="${3:-unknown}"
OUTPUT_PATH="${4:-}"

if [[ "$GENERATE_ONLY" == true && -z "$OUTPUT_PATH" ]]; then
    echo "FATAL: --generate requires an output path as 4th argument"
    exit 1
fi

PIN_FILE="${OUTPUT_PATH:-/etc/apt/preferences.d/99-velvet-kernel-${CODENAME}}"

log() { echo "[apt-pin] $*"; }

# The exact package names produced by bindeb-pkg
IMAGE_PKG="linux-image-${FULL_VERSION}"
HEADERS_PKG="linux-headers-${FULL_VERSION}"

cat > "$PIN_FILE" << EOF
# =============================================================================
# Velvet OS custom kernel APT pin
# Codename  : ${CODENAME}
# Platform  : ${PLATFORM}
# Version   : ${FULL_VERSION}
# Generated : $(date -u)
# =============================================================================
#
# This file prevents apt from upgrading or replacing the custom-built kernel.
# Remove this file ONLY if you intentionally want to replace this kernel.
#
# Pin priority guide:
#   1001 = installed and protected (overrides dist-upgrade)
#    990 = installed but allows newer versions in same release
#    500 = default priority
#    100 = only install if explicitly requested
#     -1 = never install
# =============================================================================

# --- PROTECT: Our custom kernel image - never upgrade or remove ---
Package: linux-image-${FULL_VERSION}
Pin: version ${FULL_VERSION}*
Pin-Priority: 1001

Package: linux-image-${FULL_VERSION}-*
Pin: version *
Pin-Priority: 1001

# --- PROTECT: Our custom kernel headers ---
Package: linux-headers-${FULL_VERSION}
Pin: version ${FULL_VERSION}*
Pin-Priority: 1001

Package: linux-headers-${FULL_VERSION}-*
Pin: version *
Pin-Priority: 1001

# --- BLOCK: Generic kernel meta-packages (prevent them dragging in stock kernels) ---
Package: linux-image-amd64
Pin: release *
Pin-Priority: -1

Package: linux-image-generic
Pin: release *
Pin-Priority: -1

Package: linux-image-generic-hwe-*
Pin: release *
Pin-Priority: -1

Package: linux-generic
Pin: release *
Pin-Priority: -1

Package: linux-generic-hwe-*
Pin: release *
Pin-Priority: -1

Package: linux-headers-generic
Pin: release *
Pin-Priority: -1

Package: linux-headers-amd64
Pin: release *
Pin-Priority: -1

# Note: Individual versioned stock kernels (e.g. linux-image-6.1.0-28-amd64)
# are NOT blocked here so they can still be manually installed if needed.
# Only the meta-packages that would auto-select the "latest" are blocked.
EOF

log "Pin file written: $PIN_FILE"

# Second layer: dpkg hold - only when installing on this machine
if [[ "$GENERATE_ONLY" == false ]]; then
    INSTALLED_IMAGE=$(dpkg -l "${IMAGE_PKG}" 2>/dev/null | awk '/^ii/{print $2}' | head -1 || true)
    INSTALLED_HDRS=$(dpkg -l "${HEADERS_PKG}" 2>/dev/null | awk '/^ii/{print $2}' | head -1 || true)
    if [[ -n "$INSTALLED_IMAGE" ]]; then
        apt-mark hold "$INSTALLED_IMAGE"
        log "Held: $INSTALLED_IMAGE"
    fi
    if [[ -n "$INSTALLED_HDRS" ]]; then
        apt-mark hold "$INSTALLED_HDRS"
        log "Held: $INSTALLED_HDRS"
    fi
fi

log ""
log "=== APT pin summary ==="
log "Pin file    : $PIN_FILE"
log "Kernel pkg  : $IMAGE_PKG (priority 1001)"
log "Headers pkg : $HEADERS_PKG (priority 1001)"
log "Meta-pkgs   : blocked (priority -1)"
if [[ "$GENERATE_ONLY" == true ]]; then
    log ""
    log "To install on target: sudo cp $(basename "$PIN_FILE") /etc/apt/preferences.d/"
else
    log ""
    log "To verify: apt-cache policy ${IMAGE_PKG}"
    log "To remove pin: rm $PIN_FILE && apt-mark unhold ${IMAGE_PKG} ${HEADERS_PKG}"
fi
