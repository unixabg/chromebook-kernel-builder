#!/usr/bin/env bash
# =============================================================================
# merge_kernel_config.sh
#
# Merges kernel config fragments in order:
#   1. Base config (configs/base/chromebooks-x86_64.cfg or defconfig)
#      Full curated Chromebook config - the single source of truth for
#      generic options (filesystems, crypto, networking, wifi, etc.)
#   2. platform/<platform>.cfg      - SoC-specific: GPU, audio path, WiFi
#   3. device/<codename>.cfg        - per-board overrides (optional)
#
# Each fragment is a PARTIAL config: only the options you want to set/override.
# Options not mentioned in a fragment are left as-is from previous layers.
# Later fragments WIN over earlier ones for any conflicting option.
#
# Usage:
#   ./merge_kernel_config.sh \
#       --kernel-src /path/to/linux-6.12.x \
#       --codename treeya \
#       --platform stoney-ridge \
#       --base-config /path/to/configs/base/chromebooks-x86_64.cfg \
#       --output /path/to/output/.config
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Defaults
KERNEL_SRC=""
CODENAME=""
PLATFORM=""
BASE_CONFIG="defconfig"
OUTPUT_CONFIG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-src)   KERNEL_SRC="$2";    shift 2 ;;
        --codename)     CODENAME="$2";      shift 2 ;;
        --platform)     PLATFORM="$2";      shift 2 ;;
        --base-config)  BASE_CONFIG="$2";   shift 2 ;;
        --output)       OUTPUT_CONFIG="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ -z "$KERNEL_SRC" ]] && { echo "ERROR: --kernel-src required"; exit 1; }
[[ -z "$PLATFORM"   ]] && { echo "ERROR: --platform required";   exit 1; }
# CODENAME is optional - if not provided the device layer is skipped
[[ -z "$OUTPUT_CONFIG" ]] && OUTPUT_CONFIG="${KERNEL_SRC}/.config"

log() { echo "[merge_config] $*"; }

KMERGE="${KERNEL_SRC}/scripts/kconfig/merge_config.sh"

# =============================================================================
# Collect fragments in layer order
# =============================================================================
FRAGMENTS=()

# Layer 1: Platform fragment
# SoC-specific: GPU driver, CPU frequency driver, platform audio path, WiFi
PLATFORM_FRAG="${REPO_DIR}/configs/platform/${PLATFORM}.cfg"
if [[ -f "$PLATFORM_FRAG" ]]; then
    FRAGMENTS+=("$PLATFORM_FRAG")
    log "Platform fragment: $PLATFORM_FRAG"
else
    log "WARNING: no platform fragment found at $PLATFORM_FRAG"
fi

# Layer 2: Device fragment (optional - not all codenames have one)
if [[ -n "$CODENAME" ]]; then
    DEVICE_FRAG="${REPO_DIR}/configs/device/${CODENAME}.cfg"
    if [[ -f "$DEVICE_FRAG" ]]; then
        FRAGMENTS+=("$DEVICE_FRAG")
        log "Device fragment: $DEVICE_FRAG"
    else
        log "INFO: no device-specific fragment for '$CODENAME' (using platform defaults)"
    fi
else
    log "INFO: no codename provided - skipping device layer"
fi

log "Fragment merge order:"
for f in "${FRAGMENTS[@]}"; do
    log "  $f"
done

# =============================================================================
# Step 1: Establish base .config
# =============================================================================
cd "$KERNEL_SRC"

case "$BASE_CONFIG" in
    defconfig)
        log "Starting from x86_64 defconfig..."
        make ARCH=x86_64 defconfig
        ;;
    none)
        log "Starting from empty (allnoconfig)..."
        make ARCH=x86_64 allnoconfig
        ;;
    /*)
        if [[ -f "$BASE_CONFIG" ]]; then
            log "Starting from existing config: $BASE_CONFIG"
            cp "$BASE_CONFIG" .config
            make ARCH=x86_64 olddefconfig
        else
            log "ERROR: base config file not found: $BASE_CONFIG"
            exit 1
        fi
        ;;
    *)
        log "ERROR: --base-config must be 'defconfig', 'none', or an absolute path"
        exit 1
        ;;
esac

# =============================================================================
# Step 2: Apply fragments
# =============================================================================
if [[ -x "$KMERGE" ]]; then
    log "Using kernel merge_config.sh..."
    "${KMERGE}" -m -r .config "${FRAGMENTS[@]}"
    # merge_config.sh writes to .config.new in some kernel versions
    [[ -f ".config.new" ]] && mv .config.new .config
else
    log "merge_config.sh not found, using scripts/config fallback..."
    SCRIPTS_CONFIG="${KERNEL_SRC}/scripts/config"
    for frag in "${FRAGMENTS[@]}"; do
        log "  Applying: $(basename "$frag")"
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip blank lines and full-line comments
            [[ -z "${line//[[:space:]]/}" ]] && continue
            [[ "$line" == \#* && ! "$line" == *"is not set"* ]] && continue

            # CONFIG_FOO=y or CONFIG_FOO=m
            if [[ "$line" =~ ^(CONFIG_[A-Z0-9_]+)=([ym])$ ]]; then
                key="${BASH_REMATCH[1]#CONFIG_}"
                val="${BASH_REMATCH[2]}"
                if [[ "$val" == "y" ]]; then
                    "$SCRIPTS_CONFIG" --enable "$key"
                else
                    "$SCRIPTS_CONFIG" --module "$key"
                fi
            # # CONFIG_FOO is not set
            elif [[ "$line" =~ ^#[[:space:]]+(CONFIG_[A-Z0-9_]+)[[:space:]]+is[[:space:]]+not[[:space:]]+set ]]; then
                key="${BASH_REMATCH[1]#CONFIG_}"
                "$SCRIPTS_CONFIG" --disable "$key"
            # CONFIG_FOO="some string"
            elif [[ "$line" =~ ^(CONFIG_[A-Z0-9_]+)=\"(.*)\"$ ]]; then
                key="${BASH_REMATCH[1]#CONFIG_}"
                val="${BASH_REMATCH[2]}"
                "$SCRIPTS_CONFIG" --set-str "$key" "$val"
            # CONFIG_FOO=value (unquoted numeric etc.)
            elif [[ "$line" =~ ^(CONFIG_[A-Z0-9_]+)=(.+)$ ]]; then
                key="${BASH_REMATCH[1]#CONFIG_}"
                val="${BASH_REMATCH[2]}"
                "$SCRIPTS_CONFIG" --set-val "$key" "$val"
            fi
        done < "$frag"
    done
fi

# Resolve any new/changed symbols to a consistent state
make ARCH=x86_64 olddefconfig

# =============================================================================
# Step 3: Copy to output if a different path was requested
# =============================================================================
if [[ "$OUTPUT_CONFIG" != "${KERNEL_SRC}/.config" ]]; then
    cp "${KERNEL_SRC}/.config" "$OUTPUT_CONFIG"
fi

log ""
log "=== Config merge complete ==="
log "Output: $OUTPUT_CONFIG"
log ""

# =============================================================================
# Step 4: Verify critical options per platform
# =============================================================================
verify_config() {
    local config_file="${KERNEL_SRC}/.config"
    log "=== Verifying critical config options for platform: $PLATFORM ==="

    # Helper: check a config option and log OK or WARNING
    check_y() {
        local key="$1" msg="$2"
        if grep -q "^${key}=y" "$config_file"; then
            log "  OK: ${key}=y"
        else
            log "  WARNING: ${key} not =y - ${msg}"
        fi
    }
    check_ym() {
        local key="$1" msg="$2"
        if grep -qE "^${key}=[ym]" "$config_file"; then
            log "  OK: ${key} enabled"
        else
            log "  WARNING: ${key} not set - ${msg}"
        fi
    }
    check_not_set() {
        local key="$1" msg="$2"
        if grep -q "^# ${key} is not set" "$config_file"; then
            log "  OK: ${key} disabled"
        else
            log "  WARNING: ${key} not disabled - ${msg}"
        fi
    }

    # ── Universal checks (all platforms) ─────────────────────────────────────
    check_y  "CONFIG_USER_NS"      "systemd services (upower, colord) will fail"
    check_y  "CONFIG_BTRFS_FS"     "btrfs root filesystem not supported"
    check_y  "CONFIG_RD_ZSTD"      "zstd initrd will not decompress - system will hang at boot"
    check_y  "CONFIG_RD_LZ4"       "lz4 initrd will not decompress"
    check_y  "CONFIG_RD_GZIP"      "gzip initrd will not decompress"
    check_y  "CONFIG_SECURITY_APPARMOR" "AppArmor not available"
    check_ym "CONFIG_CROS_EC"      "ChromeOS EC not available - keyboard/touchpad may fail"
    check_y  "CONFIG_MMC_SDHCI_ACPI" "eMMC may not be detected"

    # ── Platform-specific checks ──────────────────────────────────────────────
    case "$PLATFORM" in

        stoney-ridge)
            log "  -- stoney-ridge checks --"
            # amdgpu works as module or built-in (working kernel confirmed =m is fine)
            if grep -qE "^CONFIG_DRM_AMDGPU=[ym]" "$config_file"; then
                log "  OK: CONFIG_DRM_AMDGPU enabled"
            else
                log "  WARNING: CONFIG_DRM_AMDGPU not set - no display"
            fi
            # Firmware must be embedded
            if grep -q "^CONFIG_EXTRA_FIRMWARE=" "$config_file"; then
                log "  OK: CONFIG_EXTRA_FIRMWARE set (stoney blobs embedded)"
            else
                log "  WARNING: CONFIG_EXTRA_FIRMWARE not set - stoney firmware not embedded"
            fi
            check_y  "CONFIG_DRM_AMD_ACP"           "audio probe ordering will fail"
            check_ym "CONFIG_SND_DESIGNWARE_I2S"    "audio probe ordering will fail"
            check_ym "CONFIG_SND_SOC_AMD_ACP3x"     "Stoney Ridge audio not available"
            check_ym "CONFIG_ATH10K_PCI"             "WiFi (QCA6174) not available"
            check_ym "CONFIG_X86_ACPI_CPUFREQ"      "CPU frequency scaling not available"
            ;;

        amd-grunt)
            log "  -- amd-grunt checks --"
            check_ym "CONFIG_DRM_AMDGPU"            "no display"
            check_ym "CONFIG_SND_SOC_AMD_ACP3x"     "GRUNT audio not available"
            check_ym "CONFIG_SND_SOC_AMD_CZ_DA7219MX98357_MACH" "GRUNT machine driver missing"
            check_y  "CONFIG_AMD_IOMMU"              "AMD IOMMU not available"
            ;;

        amd-ryzen-zork)
            log "  -- amd-ryzen-zork checks --"
            check_ym "CONFIG_DRM_AMDGPU"            "no display"
            check_ym "CONFIG_SND_SOC_SOF_AMD_RENOIR" "ZORK SOF audio not available"
            check_ym "CONFIG_SND_SOC_AMD_RENOIR"     "ZORK ACP audio not available"
            check_y  "CONFIG_X86_AMD_PSTATE"         "CPU frequency scaling not available"
            ;;

        amd-mendocino)
            log "  -- amd-mendocino checks --"
            check_ym "CONFIG_DRM_AMDGPU"            "no display"
            check_ym "CONFIG_SND_SOC_SOF_AMD_COMMON" "Mendocino SOF audio not available"
            ;;

        geminilake)
            log "  -- geminilake checks --"
            check_ym "CONFIG_DRM_I915"              "no display"
            check_y  "CONFIG_SND_SOC_SOF_GEMINILAKE_SUPPORT" "GeminiLake SOF audio not available"
            check_y  "CONFIG_X86_INTEL_PSTATE"      "CPU frequency scaling not available"
            check_ym "CONFIG_IWLWIFI"               "Intel WiFi not available"
            ;;

        intel-braswell)
            log "  -- intel-braswell checks --"
            check_ym "CONFIG_DRM_I915"              "no display"
            check_y  "CONFIG_SND_SOC_SOF_BAYTRAIL_SUPPORT" "Braswell/CHT SOF audio not available"
            check_y  "CONFIG_X86_INTEL_PSTATE"      "CPU frequency scaling not available"
            check_ym "CONFIG_IWLWIFI"               "Intel WiFi not available"
            ;;

        intel-cometlake)
            log "  -- intel-cometlake checks --"
            check_ym "CONFIG_DRM_I915"              "no display"
            check_y  "CONFIG_SND_SOC_SOF_COMETLAKE_LP_SUPPORT" "CometLake SOF audio not available"
            check_y  "CONFIG_X86_INTEL_PSTATE"      "CPU frequency scaling not available"
            ;;

        intel-tigerlake)
            log "  -- intel-tigerlake checks --"
            check_ym "CONFIG_DRM_I915"              "no display"
            check_y  "CONFIG_SND_SOC_SOF_TIGERLAKE_SUPPORT" "TigerLake SOF audio not available"
            check_y  "CONFIG_X86_INTEL_PSTATE"      "CPU frequency scaling not available"
            ;;

        intel-alderlake)
            log "  -- intel-alderlake checks --"
            check_ym "CONFIG_DRM_I915"              "no display"
            check_y  "CONFIG_X86_INTEL_PSTATE"      "CPU frequency scaling not available"
            ;;

        *)
            log "  INFO: no specific checks defined for platform '$PLATFORM'"
            ;;
    esac

    log "=== Verification complete ==="
}

verify_config
