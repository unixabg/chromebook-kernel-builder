#!/usr/bin/env bash
# =============================================================================
# scripts/merge_kernel_config_arm64.sh
#
# ARM64-only config merge. Replicates hexdump0815's exact pipeline then
# applies local fixes and device overrides on top.
#
# Strategy (mirrors hexdump0815 readme.mt8 pipeline):
#   1. ARM64 defconfig as starting point
#   2. kernel-config-options/chromebooks-aarch64.cfg
#   3. kernel-config-options/<platform-short>.cfg  (e.g. mediatek.cfg)
#   4. kernel-config-options/docker-options.cfg
#   5. kernel-config-options/options-to-remove-generic.cfg
#   6. misc.cbm/options/options-to-remove-special.cfg
#   7. kernel-config-options/additional-options-generic.cfg
#   8. kernel-config-options/additional-options-aarch64.cfg
#   9. misc.cbm/options/additional-options-special.cfg
#  10. make ARCH=arm64 olddefconfig
#  11. configs/base/arm64-common-fixes.cfg  (our fixes, applied LAST)
#  12. configs/device/<codename>.cfg        (device overrides, applied LAST)
#  13. make ARCH=arm64 olddefconfig
#  14. Verify critical options
#
# Fallback (when ARM64_KCO_DIR not set):
#   Uses configs/base/<platform>.cfg if it has CONFIG_ lines,
#   otherwise uses hexdump's config.cbm from ARM64_EXT_DIR.
#
# Usage:
#   ./scripts/merge_kernel_config_arm64.sh \
#       --kernel-src /path/to/linux-6.x.y \
#       --platform   mediatek-mt81xx \
#       --codename   esche
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────
KERNEL_SRC=""
PLATFORM=""
CODENAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-src) KERNEL_SRC="$2"; shift 2 ;;
        --platform)   PLATFORM="$2";   shift 2 ;;
        --codename)   CODENAME="$2";   shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ -z "$KERNEL_SRC" ]] && { echo "ERROR: --kernel-src required"; exit 1; }
[[ -z "$PLATFORM"   ]] && { echo "ERROR: --platform required";   exit 1; }
[[ -z "$CODENAME"   ]] && { echo "ERROR: --codename required";   exit 1; }

log() { echo "[merge_config_arm64] $*"; }

cd "$KERNEL_SRC"

KMERGE="${KERNEL_SRC}/scripts/kconfig/merge_config.sh"
KCO_DIR="${ARM64_KCO_DIR:-}"
EXT_DIR="${ARM64_EXT_DIR:-}"

# Detect the misc subdir in the external repo (misc.cbm, misc.rkc, etc.)
MISC_OPTIONS_DIR=""
if [[ -n "$EXT_DIR" ]]; then
    for subdir in misc.cbm misc.rkc misc.rk3 misc; do
        if [[ -d "${EXT_DIR}/${subdir}/options" ]]; then
            MISC_OPTIONS_DIR="${EXT_DIR}/${subdir}/options"
            break
        fi
    done
fi

# Derive short platform name for kernel-config-options file lookup
# mediatek-mt81xx -> mediatek,  rockchip-rk33xx -> rockchip
PLATFORM_SHORT=$(echo "$PLATFORM" | cut -d- -f1)

# =============================================================================
# Primary pipeline: replicate hexdump0815's exact layer order
# =============================================================================
if [[ -n "$KCO_DIR" ]]; then
    log "Using hexdump0815 pipeline (kernel-config-options + external repo)"
    log "  KCO_DIR : $KCO_DIR"
    log "  EXT_DIR : ${EXT_DIR:-none}"
    log "  MISC_DIR: ${MISC_OPTIONS_DIR:-none}"

    # Step 1: Start from ARM64 defconfig
    log "Starting from ARM64 defconfig..."
    make ARCH=arm64 defconfig

    # Build fragment list in hexdump's exact order
    FRAGMENTS=()

    # chromebooks-aarch64.cfg - generic Chromebook ARM64 options
    [[ -f "${KCO_DIR}/chromebooks-aarch64.cfg" ]] && \
        FRAGMENTS+=("${KCO_DIR}/chromebooks-aarch64.cfg") && \
        log "  + chromebooks-aarch64.cfg"

    # <platform>.cfg - platform-specific options (mediatek.cfg, rockchip.cfg etc.)
    [[ -f "${KCO_DIR}/${PLATFORM_SHORT}.cfg" ]] && \
        FRAGMENTS+=("${KCO_DIR}/${PLATFORM_SHORT}.cfg") && \
        log "  + ${PLATFORM_SHORT}.cfg"

    # docker-options.cfg - container support
    [[ -f "${KCO_DIR}/docker-options.cfg" ]] && \
        FRAGMENTS+=("${KCO_DIR}/docker-options.cfg") && \
        log "  + docker-options.cfg"

    # options-to-remove-generic.cfg - generic removals
    [[ -f "${KCO_DIR}/options-to-remove-generic.cfg" ]] && \
        FRAGMENTS+=("${KCO_DIR}/options-to-remove-generic.cfg") && \
        log "  + options-to-remove-generic.cfg"

    # options-to-remove-special.cfg - platform-specific removals
    [[ -n "$MISC_OPTIONS_DIR" && -f "${MISC_OPTIONS_DIR}/options-to-remove-special.cfg" ]] && \
        FRAGMENTS+=("${MISC_OPTIONS_DIR}/options-to-remove-special.cfg") && \
        log "  + options-to-remove-special.cfg (external)"

    # additional-options-generic.cfg - generic additions
    [[ -f "${KCO_DIR}/additional-options-generic.cfg" ]] && \
        FRAGMENTS+=("${KCO_DIR}/additional-options-generic.cfg") && \
        log "  + additional-options-generic.cfg"

    # additional-options-aarch64.cfg - ARM64-specific additions
    [[ -f "${KCO_DIR}/additional-options-aarch64.cfg" ]] && \
        FRAGMENTS+=("${KCO_DIR}/additional-options-aarch64.cfg") && \
        log "  + additional-options-aarch64.cfg"

    # additional-options-special.cfg - platform-specific additions
    [[ -n "$MISC_OPTIONS_DIR" && -f "${MISC_OPTIONS_DIR}/additional-options-special.cfg" ]] && \
        FRAGMENTS+=("${MISC_OPTIONS_DIR}/additional-options-special.cfg") && \
        log "  + additional-options-special.cfg (external)"

    # Apply all fragments in one merge_config.sh call (hexdump's approach)
    if [[ ${#FRAGMENTS[@]} -gt 0 ]]; then
        if [[ -x "$KMERGE" ]]; then
            log "Merging ${#FRAGMENTS[@]} fragments..."
            ARCH=arm64 "${KMERGE}" -m -r .config "${FRAGMENTS[@]}"
            [[ -f ".config.new" ]] && mv .config.new .config
        else
            log "ERROR: merge_config.sh not found at $KMERGE"
            exit 1
        fi
    fi

    log "Running olddefconfig..."
    make ARCH=arm64 olddefconfig

# =============================================================================
# Fallback pipeline: no kernel-config-options repo available
# =============================================================================
else
    log "WARNING: ARM64_KCO_DIR not set - falling back to base config pipeline"
    BASE_CONFIG="${REPO_DIR}/configs/base/${PLATFORM}.cfg"

    if [[ -f "$BASE_CONFIG" ]] && grep -q "^CONFIG_" "$BASE_CONFIG"; then
        log "Using local base config: configs/base/${PLATFORM}.cfg"
        cp "$BASE_CONFIG" .config
    elif [[ -n "$EXT_DIR" ]]; then
        log "Searching external repo for base config..."
        EXT_CONFIG=""
        for candidate in \
            "${EXT_DIR}/config.cbm" \
            "${EXT_DIR}/config.rkc" \
            "${EXT_DIR}/config.rk3" \
            "${EXT_DIR}/config.mt8" \
            "${EXT_DIR}/config.mt7"; do
            if [[ -f "$candidate" ]]; then
                EXT_CONFIG="$candidate"
                break
            fi
        done
        [[ -z "$EXT_CONFIG" ]] && { log "ERROR: no base config found"; exit 1; }
        log "Using external base config: $(basename "$EXT_CONFIG")"
        cp "$EXT_CONFIG" .config
    else
        log "ERROR: no base config available - set ARM64_KCO_DIR or ARM64_EXT_DIR"
        exit 1
    fi

    log "Running olddefconfig..."
    make ARCH=arm64 olddefconfig

    # Apply external special options in fallback mode
    if [[ -n "$MISC_OPTIONS_DIR" ]]; then
        log "Applying external special options..."
        RM_CFG="${MISC_OPTIONS_DIR}/options-to-remove-special.cfg"
        ADD_CFG="${MISC_OPTIONS_DIR}/additional-options-special.cfg"
        if [[ -f "$ADD_CFG" && -x "$KMERGE" ]]; then
            ARCH=arm64 "${KMERGE}" -m -r .config "$ADD_CFG"
            [[ -f ".config.new" ]] && mv .config.new .config
            make ARCH=arm64 olddefconfig
        fi
        if [[ -f "$RM_CFG" ]]; then
            SC="${KERNEL_SRC}/scripts/config"
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "${line//[[:space:]]/}" ]] && continue
                [[ "$line" == \#* && ! "$line" == *"is not set"* ]] && continue
                if [[ "$line" =~ ^(CONFIG_[A-Z0-9_]+)=n$ ]]; then
                    "$SC" --disable "${BASH_REMATCH[1]#CONFIG_}"
                elif [[ "$line" =~ ^#[[:space:]]+(CONFIG_[A-Z0-9_]+)[[:space:]]+is[[:space:]]+not[[:space:]]+set ]]; then
                    "$SC" --disable "${BASH_REMATCH[1]#CONFIG_}"
                fi
            done < "$RM_CFG"
            make ARCH=arm64 olddefconfig
        fi
    fi
fi

# =============================================================================
# Our additions — applied LAST so they cannot be overridden by any external layer
# =============================================================================

# ARM64 common fixes (fixes for issues found in hexdump's pipeline — PR candidates)
COMMON_FIXES="${REPO_DIR}/configs/base/arm64-common-fixes.cfg"
if [[ -f "$COMMON_FIXES" ]]; then
    log "Applying ARM64 common fixes: $COMMON_FIXES"
    if [[ -x "$KMERGE" ]]; then
        ARCH=arm64 "${KMERGE}" -m -r .config "$COMMON_FIXES"
        [[ -f ".config.new" ]] && mv .config.new .config
    fi
    make ARCH=arm64 olddefconfig
else
    log "INFO: no arm64-common-fixes.cfg found - skipping"
fi

# Device overlay
DEVICE_FRAG="${REPO_DIR}/configs/device/${CODENAME}.cfg"
if [[ -f "$DEVICE_FRAG" ]]; then
    log "Applying device overlay: $DEVICE_FRAG"
    if [[ -x "$KMERGE" ]]; then
        ARCH=arm64 "${KMERGE}" -m -r .config "$DEVICE_FRAG"
        [[ -f ".config.new" ]] && mv .config.new .config
    fi
    make ARCH=arm64 olddefconfig
else
    log "INFO: no device overlay for '$CODENAME'"
fi

log ""
log "=== Config merge complete: ${KERNEL_SRC}/.config ==="
log "=== Pipeline: hexdump0815 layers + arm64-common-fixes + device overlay ==="
log ""

# ── Step 5: Verify critical MT8183 options ────────────────────────────────────
verify_config() {
    local cfg="${KERNEL_SRC}/.config"
    local warnings=0

    log "=== Verifying critical options for platform: $PLATFORM ==="

    check_y() {
        if grep -q "^${1}=y" "$cfg"; then
            log "  OK:      ${1}=y"
        else
            log "  WARNING: ${1} not =y  - ${2}"
            (( warnings++ )) || true
        fi
    }
    check_ym() {
        if grep -qE "^${1}=[ym]" "$cfg"; then
            log "  OK:      ${1} enabled"
        else
            log "  WARNING: ${1} not set - ${2}"
            (( warnings++ )) || true
        fi
    }

    case "$PLATFORM" in
        mediatek-mt81xx)
            log "  -- SoC core --"
            check_y  "CONFIG_COMMON_CLK_MT8183" "SoC clocks missing - will not boot"
            check_ym "CONFIG_PINCTRL_MT8183"    "pinctrl missing - many devices will fail"
            check_y  "CONFIG_I2C_MT65XX"        "I2C must be built-in"
            check_y  "CONFIG_SPI_MT65XX"        "SPI must be built-in"
            check_ym "CONFIG_MMC_MTK"           "eMMC will not be detected"
            check_y  "CONFIG_MTK_PMIC_WRAP"     "PMIC bus missing - power management broken"
            check_y  "CONFIG_MTK_IOMMU"         "IOMMU missing - display/GPU DMA broken"
            check_y  "CONFIG_MTK_CMDQ"          "display command queue missing"

            log "  -- ChromeOS EC --"
            check_ym "CONFIG_CROS_EC"           "keyboard and touchpad will not work"
            check_ym "CONFIG_CROS_EC_SPI"       "EC SPI transport missing"

            log "  -- Display --"
            check_ym "CONFIG_DRM_PANFROST"           "GPU unavailable"
            check_ym "CONFIG_DRM_MEDIATEK"           "display engine unavailable"
            check_y  "CONFIG_DRM_DISPLAY_DSC_HELPER" "panel-ilitek-ili9882t will fail to link on 7.0+"

            log "  -- Audio --"
            check_ym "CONFIG_SND_SOC_MT8183"    "audio platform driver missing"

            log "  -- WiFi --"
            check_ym "CONFIG_ATH10K"            "ath10k missing"
            check_ym "CONFIG_ATH10K_SDIO"       "ath10k SDIO missing"

            log "  -- Filesystem --"
            check_y  "CONFIG_BTRFS_FS"          "btrfs must be built-in (velvet-os root, no initramfs)"
            ;;
        *)
            log "  INFO: no checks defined for platform '$PLATFORM'"
            ;;
    esac

    log ""
    if [[ "$warnings" -gt 0 ]]; then
        log "  ${warnings} WARNING(s) - build aborted"
        log "  Add missing options to configs/base/arm64-common-fixes.cfg or configs/device/${CODENAME}.cfg"
        exit 1
    else
        log "  All critical options present"
    fi
    log "=== Verification complete ==="
}

verify_config
