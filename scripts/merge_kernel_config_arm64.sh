#!/usr/bin/env bash
# =============================================================================
# scripts/merge_kernel_config_arm64.sh
#
# ARM64-only config merge. Kept separate from merge_kernel_config.sh so the
# working x86_64 pipeline is never touched.
#
# Strategy:
#   1. Use configs/base/<platform>.config as the base (known-working config)
#   2. make ARCH=arm64 olddefconfig  -- adapts it to whatever kernel version
#      we are actually building (fills new symbols with Kconfig defaults,
#      drops removed symbols)
#   3. Apply configs/device/<codename>.cfg if it exists (optional overrides)
#   4. Verify critical MT8183 options are present, warn on anything missing
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

# ── Step 1: Copy known-working base config ────────────────────────────────────
BASE_CONFIG="${REPO_DIR}/configs/base/${PLATFORM}.config"

if [[ ! -f "$BASE_CONFIG" ]]; then
    log "ERROR: base config not found: $BASE_CONFIG"
    log "  Expected a known-working config at configs/base/${PLATFORM}.config"
    exit 1
fi

log "Using base config: configs/base/${PLATFORM}.config"
log "  ($(wc -l < "$BASE_CONFIG") lines)"
cp "$BASE_CONFIG" .config

# ── Step 2: olddefconfig ──────────────────────────────────────────────────────
# Adapts the base config to the kernel version we are actually building.
# New symbols introduced since the base config was made get their Kconfig
# default values. Removed symbols are dropped cleanly.
log "Running olddefconfig to adapt base config to $(basename "$KERNEL_SRC")..."
make ARCH=arm64 olddefconfig

# Defined here so both Step 3 and Step 4 can use it
KMERGE="${KERNEL_SRC}/scripts/kconfig/merge_config.sh"

# ── Step 3: Optional external config options (hexdump0815 misc.cbm/options/) ──
# If ARM64_EXT_DIR is set (populated by the workflow clone step), apply
# additional-options-special.cfg and process options-to-remove-special.cfg.
# This keeps us in sync with hexdump0815's known-working config fragment
# without manually copying files into this repo.
EXT_DIR="${ARM64_EXT_DIR:-}"
if [[ -n "$EXT_DIR" && -d "${EXT_DIR}/misc.cbm/options" ]]; then
    OPTIONS_DIR="${EXT_DIR}/misc.cbm/options"
    log "Applying external config options from: $OPTIONS_DIR"

    # additions
    ADD_CFG="${OPTIONS_DIR}/additional-options-special.cfg"
    if [[ -f "$ADD_CFG" ]]; then
        log "  additional-options-special.cfg ($(wc -l < "$ADD_CFG") lines)"
        if [[ -x "$KMERGE" ]]; then
            ARCH=arm64 "${KMERGE}" -m -r .config "$ADD_CFG"
            [[ -f ".config.new" ]] && mv .config.new .config
        else
            SC="${KERNEL_SRC}/scripts/config"
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "${line//[[:space:]]/}" ]] && continue
                [[ "$line" == \#* && ! "$line" == *"is not set"* ]] && continue
                if [[ "$line" =~ ^(CONFIG_[A-Z0-9_]+)=([ym])$ ]]; then
                    key="${BASH_REMATCH[1]#CONFIG_}"
                    [[ "${BASH_REMATCH[2]}" == "y" ]] && "$SC" --enable "$key" || "$SC" --module "$key"
                elif [[ "$line" =~ ^#[[:space:]]+(CONFIG_[A-Z0-9_]+)[[:space:]]+is[[:space:]]+not[[:space:]]+set ]]; then
                    "$SC" --disable "${BASH_REMATCH[1]#CONFIG_}"
                elif [[ "$line" =~ ^(CONFIG_[A-Z0-9_]+)=\"(.*)\"$ ]]; then
                    "$SC" --set-str "${BASH_REMATCH[1]#CONFIG_}" "${BASH_REMATCH[2]}"
                elif [[ "$line" =~ ^(CONFIG_[A-Z0-9_]+)=(.+)$ ]]; then
                    "$SC" --set-val "${BASH_REMATCH[1]#CONFIG_}" "${BASH_REMATCH[2]}"
                fi
            done < "$ADD_CFG"
        fi
        make ARCH=arm64 olddefconfig
    fi

    # removals (lines like CONFIG_FOO=n or # CONFIG_FOO is not set)
    RM_CFG="${OPTIONS_DIR}/options-to-remove-special.cfg"
    if [[ -f "$RM_CFG" ]]; then
        log "  options-to-remove-special.cfg ($(wc -l < "$RM_CFG") lines)"
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
else
    log "INFO: ARM64_EXT_DIR not set or missing misc.cbm/options - skipping external config fragments"
fi

# ── Step 4: Optional device overlay ──────────────────────────────────────────
DEVICE_FRAG="${REPO_DIR}/configs/device/${CODENAME}.cfg"

if [[ -f "$DEVICE_FRAG" ]]; then
    log "Applying device overlay: $DEVICE_FRAG"
    if [[ -x "$KMERGE" ]]; then
        ARCH=arm64 "${KMERGE}" -m -r .config "$DEVICE_FRAG"
        [[ -f ".config.new" ]] && mv .config.new .config
    else
        SC="${KERNEL_SRC}/scripts/config"
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "${line//[[:space:]]/}" ]] && continue
            [[ "$line" == \#* && ! "$line" == *"is not set"* ]] && continue
            if [[ "$line" =~ ^(CONFIG_[A-Z0-9_]+)=([ym])$ ]]; then
                key="${BASH_REMATCH[1]#CONFIG_}"
                [[ "${BASH_REMATCH[2]}" == "y" ]] && "$SC" --enable "$key" || "$SC" --module "$key"
            elif [[ "$line" =~ ^#[[:space:]]+(CONFIG_[A-Z0-9_]+)[[:space:]]+is[[:space:]]+not[[:space:]]+set ]]; then
                "$SC" --disable "${BASH_REMATCH[1]#CONFIG_}"
            elif [[ "$line" =~ ^(CONFIG_[A-Z0-9_]+)=\"(.*)\"$ ]]; then
                "$SC" --set-str "${BASH_REMATCH[1]#CONFIG_}" "${BASH_REMATCH[2]}"
            elif [[ "$line" =~ ^(CONFIG_[A-Z0-9_]+)=(.+)$ ]]; then
                "$SC" --set-val "${BASH_REMATCH[1]#CONFIG_}" "${BASH_REMATCH[2]}"
            fi
        done < "$DEVICE_FRAG"
    fi
    make ARCH=arm64 olddefconfig
else
    log "INFO: no device overlay for '$CODENAME'"
fi

log ""
log "=== Config merge complete: ${KERNEL_SRC}/.config ==="
log "=== Base: configs/base/${PLATFORM}.config + olddefconfig for $(basename "$KERNEL_SRC") ==="
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
            check_ym "CONFIG_DRM_PANFROST"      "GPU unavailable"
            check_ym "CONFIG_DRM_MEDIATEK"      "display engine unavailable"

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
        log "  ${warnings} WARNING(s) - add missing options to configs/device/${CODENAME}.cfg"
    else
        log "  All critical options present"
    fi
    log "=== Verification complete ==="
}

verify_config
