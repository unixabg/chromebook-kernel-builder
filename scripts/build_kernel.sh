#!/usr/bin/env bash
# =============================================================================
# build_kernel.sh - Main orchestrator
#
# Detects hardware, assembles layered config, builds kernel .deb packages,
# and installs APT pinning to prevent upgrades.
#
# Usage:
#   sudo ./build_kernel.sh [OPTIONS]
#
# Options:
#   --codename NAME       Override auto-detected board codename
#   --kernel-version X.Y  Kernel series to build (default: from hardware_map)
#   --base-config PATH    Starting .config (default: defconfig)
#                         Use '/boot/config-$(uname -r)' to start from running kernel
#   --jobs N              Parallel jobs (default: nproc)
#   --output-dir PATH     Where to put .deb files (default: ./output)
#   --pin                 Install APT pin file on this machine (default: write to output dir only)
#   --install             Install the .deb files after building
#   --dry-run             Show what would be done without doing it
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HARDWARE_MAP="${REPO_DIR}/configs/hardware_map.conf"

# --- Read default kernel series from single source of truth ---
KERNEL_VERSIONS_CONF="${REPO_DIR}/configs/kernel_versions.conf"
if [[ -f "$KERNEL_VERSIONS_CONF" ]]; then
    DEFAULT_SERIES=$(grep "^DEFAULT_SERIES=" "$KERNEL_VERSIONS_CONF" | cut -d= -f2 | tr -d '[:space:]')
else
    DEFAULT_SERIES="6.6"
    echo "WARNING: $KERNEL_VERSIONS_CONF not found, using built-in default $DEFAULT_SERIES"
fi

# --- Defaults ---
OVERRIDE_CODENAME=""
KERNEL_VERSION=""        # empty = read from hardware_map, "default" = use DEFAULT_SERIES
BASE_CONFIG="defconfig"
JOBS=$(nproc)
OUTPUT_DIR="${REPO_DIR}/output"
DO_PIN=false
DO_INSTALL=false
DRY_RUN=false
BUILD_DIR="/tmp/cros-kernel-build"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --codename)        OVERRIDE_CODENAME="$2"; shift 2 ;;
        --kernel-version)  KERNEL_VERSION="$2";    shift 2 ;;
        --base-config)     BASE_CONFIG="$2";        shift 2 ;;
        --jobs)            JOBS="$2";               shift 2 ;;
        --output-dir)      OUTPUT_DIR="$2";         shift 2 ;;
        --pin)             DO_PIN=true;             shift   ;;
        --install)         DO_INSTALL=true;         shift   ;;
        --dry-run)         DRY_RUN=true;            shift   ;;
        --help)
            sed -n '/^# Usage:/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

mkdir -p "$OUTPUT_DIR"
LOG_FILE="${OUTPUT_DIR}/build-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*"; }
die() { echo "[$(date '+%H:%M:%S')] FATAL: $*"; exit 1; }

# ============================================================
# STEP 1: Detect hardware
# ============================================================
log "================================================================"
log " Chromebook Custom Kernel Builder"
log " Repo: $REPO_DIR"
log "================================================================"
log ""
log "=== STEP 1: Hardware Detection ==="

detect_hardware() {
    # Try cros_config first (most reliable on ChromeOS-derived systems)
    if command -v cros_config &>/dev/null; then
        local name
        name=$(cros_config / name 2>/dev/null || true)
        if [[ -n "$name" ]]; then
            echo "${name,,}"
            return
        fi
    fi

    # DMI board_name (works on x86 after normal firmware install)
    local board
    board=$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)
    if [[ -n "$board" && "$board" != "Unknown" ]]; then
        echo "${board,,}"
        return
    fi

    # DMI product_name fallback
    local product
    product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    if [[ -n "$product" && "$product" != "Unknown" ]]; then
        echo "${product,,}"
        return
    fi

    echo "unknown"
}

if [[ -n "$OVERRIDE_CODENAME" ]]; then
    CODENAME="${OVERRIDE_CODENAME,,}"
    log "Using overridden codename: $CODENAME"
else
    CODENAME=$(detect_hardware)
    log "Auto-detected codename: $CODENAME"
fi

# ============================================================
# STEP 2: Look up hardware map
# ============================================================
log ""
log "=== STEP 2: Hardware Map Lookup ==="

PLATFORM=""
MAP_KERNEL_VER=""
PATCH_DIR=""
BOARD_NOTE=""

while IFS='|' read -r map_code map_plat map_kver map_patch map_note || [[ -n "$map_code" ]]; do
    [[ "$map_code" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${map_code// }" ]] && continue
    map_code="${map_code// /}"
    if [[ "$map_code" == "$CODENAME" ]]; then
        PLATFORM="${map_plat// /}"
        MAP_KERNEL_VER="${map_kver// /}"
        PATCH_DIR="${map_patch// /}"
        BOARD_NOTE="$map_note"
        break
    fi
done < "$HARDWARE_MAP"

if [[ -z "$PLATFORM" ]]; then
    warn "Codename '$CODENAME' not found in hardware map."
    warn "Attempting CPU vendor fallback..."
    cpu_vendor=$(grep -m1 vendor_id /proc/cpuinfo 2>/dev/null | awk '{print $3}' || echo "unknown")
    case "$cpu_vendor" in
        AuthenticAMD)
            # Try to distinguish Stoneyridge vs Ryzen by CPU family
            cpu_family=$(grep -m1 "cpu family" /proc/cpuinfo | awk '{print $4}' || echo "0")
            if [[ "$cpu_family" == "21" ]]; then
                PLATFORM="amd-stoneyridge"
                warn "Detected AMD family 21 (Stoneyridge) via cpuinfo fallback"
            else
                PLATFORM="amd-ryzen-zork"
                warn "Detected AMD (non-Stoneyridge) via cpuinfo fallback"
            fi
            ;;
        GenuineIntel)
            PLATFORM="intel-cometlake"
            warn "Detected Intel via cpuinfo fallback (assuming Comet Lake)"
            ;;
        *)
            die "Cannot determine platform for codename '$CODENAME'. Add it to hardware_map.conf"
            ;;
    esac
    PATCH_DIR="none"
    MAP_KERNEL_VER="default"
fi

# Resolve kernel version:
#   1. --kernel-version CLI flag wins if set
#   2. hardware_map entry (if not "default")
#   3. DEFAULT_SERIES from kernel_versions.conf
[[ -z "$KERNEL_VERSION" ]] && KERNEL_VERSION="$MAP_KERNEL_VER"
[[ "$KERNEL_VERSION" == "default" || -z "$KERNEL_VERSION" ]] && KERNEL_VERSION="$DEFAULT_SERIES"

log "Codename : $CODENAME"
log "Platform : $PLATFORM"
log "Board    : ${BOARD_NOTE:-unknown}"
log "Kernel   : $KERNEL_VERSION.x (LTS)  [DEFAULT_SERIES=$DEFAULT_SERIES from kernel_versions.conf]"
log "Patches  : $PATCH_DIR"

# Derive download URL from the resolved version (supports any vX.x series)
KERNEL_MAJOR="${KERNEL_VERSION%%.*}"
KERNEL_BASE_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x"

# ============================================================
# STEP 3: Dependencies
# ============================================================
log ""
log "=== STEP 3: Build Dependencies ==="

DEPS=(build-essential bc bison flex libssl-dev libelf-dev libncurses-dev
      dwarves pahole debhelper rsync kmod wget curl git xz-utils)
MISSING=()
for dep in "${DEPS[@]}"; do
    dpkg -l "$dep" &>/dev/null 2>&1 || MISSING+=("$dep")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "Installing: ${MISSING[*]}"
    [[ "$DRY_RUN" == false ]] && apt-get install -y "${MISSING[@]}"
else
    log "All dependencies satisfied."
fi

# Platform-specific build prerequisites check
# These are not installed automatically - run scripts/setup_build_env.sh first
if [[ "$PLATFORM" == "amd-stoneyridge" ]]; then
    if ! ls /lib/firmware/amdgpu/stoney_ce.bin &>/dev/null; then
        die "Stoneyridge firmware not found at /lib/firmware/amdgpu/stoney_ce.bin
       Run first: sudo ./scripts/setup_build_env.sh amd-stoneyridge"
    fi
    log "Stoneyridge firmware: OK"
fi

# ============================================================
# STEP 4: Fetch kernel source
# ============================================================
log ""
log "=== STEP 4: Kernel Source ==="

mkdir -p "$BUILD_DIR"

# Find latest stable X.Y.Z in the requested series - pure bash, no python3 required
# kernel.org releases.json has lines like: "version": "6.6.78",
FULL_VERSION=$(curl -s --max-time 15 "https://www.kernel.org/releases.json" 2>/dev/null | \
    grep -o '"version": *"[0-9]*\.[0-9]*\.[0-9]*"' | \
    grep -o '"[0-9]*\.[0-9]*\.[0-9]*"' | \
    tr -d '"' | \
    grep "^${KERNEL_VERSION}\." | \
    sort -t. -k1,1n -k2,2n -k3,3n | \
    tail -1)

if [[ -z "$FULL_VERSION" ]]; then
    warn "Could not auto-detect latest ${KERNEL_VERSION}.x from kernel.org"
    FULL_VERSION="${KERNEL_VERSION}.0"
    log "Falling back to: $FULL_VERSION"
fi
log "Target kernel: linux-${FULL_VERSION}"

TARBALL="${BUILD_DIR}/linux-${FULL_VERSION}.tar.xz"
SRCDIR="${BUILD_DIR}/linux-${FULL_VERSION}"

if [[ "$DRY_RUN" == true ]]; then
    log "[DRY RUN] Would download linux-${FULL_VERSION}.tar.xz"
    log "[DRY RUN] Would build kernel and produce .deb packages in $OUTPUT_DIR"
    log "[DRY RUN] Config layers: base → $PLATFORM → $CODENAME (if exists)"
    exit 0
fi

if [[ ! -f "$TARBALL" ]]; then
    log "Downloading linux-${FULL_VERSION}.tar.xz..."
    wget -c -P "$BUILD_DIR" "${KERNEL_BASE_URL}/linux-${FULL_VERSION}.tar.xz" || \
    wget -c -P "$BUILD_DIR" "https://cdn.kernel.org/pub/linux/kernel/v${FULL_VERSION%%.*}.x/linux-${FULL_VERSION}.tar.xz"
fi

if [[ ! -d "$SRCDIR" ]]; then
    log "Extracting source..."
    tar -xf "$TARBALL" -C "$BUILD_DIR"
fi

# ============================================================
# STEP 5: Apply patches
# ============================================================
log ""
log "=== STEP 5: Patches ==="
cd "$SRCDIR"

if [[ "$PATCH_DIR" != "none" && -d "${REPO_DIR}/patches/${PATCH_DIR}" ]]; then
    shopt -s nullglob
    patches=("${REPO_DIR}/patches/${PATCH_DIR}"/*.patch)
    shopt -u nullglob
    if [[ ${#patches[@]} -gt 0 ]]; then
        log "Applying ${#patches[@]} patch(es) from patches/${PATCH_DIR}/"
        for p in "${patches[@]}"; do
            log "  patch: $(basename "$p")"
            patch -p1 --forward < "$p" || {
                warn "Patch $(basename "$p") did not apply cleanly."
                warn "It may already be applied, or be incompatible with this kernel version."
            }
        done
    else
        log "Patch dir exists but contains no .patch files (check patches/${PATCH_DIR}/README)"
    fi
else
    log "No patches for this platform."
fi

# ============================================================
# STEP 6: Merge config
# ============================================================
log ""
log "=== STEP 6: Config Assembly (3-layer merge) ==="

# Handle 'running' shortcut
if [[ "$BASE_CONFIG" == "running" ]]; then
    RUNNING_CONFIG="/boot/config-$(uname -r)"
    if [[ -f "$RUNNING_CONFIG" ]]; then
        BASE_CONFIG="$RUNNING_CONFIG"
        log "Using running kernel config: $BASE_CONFIG"
    else
        warn "Running kernel config not found at $RUNNING_CONFIG, using defconfig"
        BASE_CONFIG="defconfig"
    fi
fi

"${REPO_DIR}/scripts/merge_kernel_config.sh" \
    --kernel-src "$SRCDIR" \
    --codename   "$CODENAME" \
    --platform   "$PLATFORM" \
    --base-config "$BASE_CONFIG" \
    --output "${SRCDIR}/.config"

# ============================================================
# STEP 7: Build
# ============================================================
log ""
log "=== STEP 7: Build (jobs: $JOBS) ==="

# Local version string embeds codename - makes the kernel uniquely identifiable
# and prevents it matching any upstream package name
LOCAL_VERSION="-velvet-${CODENAME}"
FULL_PKG_VERSION="${FULL_VERSION}${LOCAL_VERSION}"

log "Package version will be: ${FULL_PKG_VERSION}"
log "This uniquely identifies this build and enables APT pinning."

time make ARCH=x86_64 \
     LOCALVERSION="${LOCAL_VERSION}" \
     KDEB_PKGVERSION="${FULL_PKG_VERSION}-1" \
     KDEB_COMPRESS="xz" \
     bindeb-pkg \
     -j"$JOBS"

# ============================================================
# STEP 8: Collect output
# ============================================================
log ""
log "=== STEP 8: Collecting .deb packages ==="
mkdir -p "$OUTPUT_DIR"

find "$BUILD_DIR" -maxdepth 1 -name "linux-*.deb" | while read -r deb; do
    cp "$deb" "$OUTPUT_DIR/"
    log "  → $OUTPUT_DIR/$(basename "$deb")"
done

DEB_IMAGE=$(find "$OUTPUT_DIR" -name "linux-image-${FULL_PKG_VERSION}*.deb" | head -1)
DEB_HEADERS=$(find "$OUTPUT_DIR" -name "linux-headers-${FULL_PKG_VERSION}*.deb" | head -1)

log ""
log "Built packages:"
ls -lh "${OUTPUT_DIR}"/*.deb

# ============================================================
# STEP 9: APT Pin file
# Generate the pin file into the output directory.
# The user installs it on the TARGET machine, not the build machine.
# Use --pin to also install it on this machine (e.g. building locally).
# ============================================================
log ""
log "=== STEP 9: Generating APT pin file ==="
PIN_FILE="${OUTPUT_DIR}/99-velvet-kernel-${CODENAME}"
"${REPO_DIR}/scripts/install_apt_pin.sh"     --generate "$FULL_PKG_VERSION" "$CODENAME" "$PLATFORM" "$PIN_FILE"
log "Pin file written to output: $PIN_FILE"

if [[ "$DO_PIN" == true ]]; then
    cp "$PIN_FILE" "/etc/apt/preferences.d/99-velvet-kernel-${CODENAME}"
    log "Pin file also installed on this machine."
fi

# ============================================================
# STEP 10: Install (optional)
# ============================================================
if [[ "$DO_INSTALL" == true ]]; then
    log ""
    log "=== STEP 10: Installing kernel ==="
    if [[ -n "$DEB_IMAGE" && -n "$DEB_HEADERS" ]]; then
        dpkg -i "$DEB_IMAGE" "$DEB_HEADERS"
        log "Kernel installed. Reboot to use it."
    else
        warn "Could not find .deb files to install"
    fi
fi

# ============================================================
# Summary
# ============================================================
log ""
log "================================================================"
log " BUILD COMPLETE"
log "================================================================"
log " Codename  : $CODENAME"
log " Platform  : $PLATFORM"
log " Kernel    : $FULL_PKG_VERSION"
log " Output    : $OUTPUT_DIR"
log " Log       : $LOG_FILE"
log ""
log " To install on target Chromebook:"
log "   sudo dpkg -i linux-image-${FULL_PKG_VERSION}*.deb \\"
log "               linux-headers-${FULL_PKG_VERSION}*.deb"
log ""
log " To pin the kernel (prevents apt upgrades):"
log "   sudo cp 99-velvet-kernel-${CODENAME} /etc/apt/preferences.d/"
log "   sudo apt-mark hold linux-image-${FULL_PKG_VERSION}"
log ""
if [[ "$PLATFORM" == "amd-stoneyridge" ]]; then
    log " STONEYRIDGE: After rebooting onto the new kernel, run:"
    log "   git clone https://github.com/WeirdTreeThing/chromebook-linux-audio"
    log "   cd chromebook-linux-audio && sudo ./setup-audio"
    log ""
fi
log "================================================================"
