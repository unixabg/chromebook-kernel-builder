#!/usr/bin/env bash
# =============================================================================
# scripts/merge_kernel_config_arm64.sh
#
# ARM64-only config merge. Kept separate from merge_kernel_config.sh so the
# working x86_64 pipeline is never touched.
#
# Strategy:
#   1. Pick the best available mainline defconfig for MediaTek MT8183:
#        a. mt8183_defconfig         -- ideal, SoC-specific if it exists
#        b. mediatek_defconfig       -- broader MediaTek coverage
#        c. defconfig                -- generic arm64 fallback
#      Logs clearly which was chosen so you know what you are building on.
#   2. make ARCH=arm64 olddefconfig  -- resolves any symbol changes
#   3. Apply configs/device/<codename>.cfg if it exists (optional overrides)
#   4. Verify critical MT8183 options are present, warn on anything missing
#
# Usage:
#   ./scripts/merge_kernel_config_arm64.sh \
#       --kernel-src /path/to/linux-6.x.y \
#       --platform   mediatek-mt8183 \
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

# ── Step 1: Pick best available mainline defconfig ────────────────────────────
CONFIGS_DIR="arch/arm64/configs"

log "Available defconfigs in ${CONFIGS_DIR}:"
ls "${CONFIGS_DIR}/" | sed 's/^/  /' || true

if [[ -f "${CONFIGS_DIR}/mt8183_defconfig" ]]; then
    BASE_DEFCONFIG="mt8183_defconfig"
    log "Selected: mt8183_defconfig (SoC-specific - best option)"
elif [[ -f "${CONFIGS_DIR}/mediatek_defconfig" ]]; then
    BASE_DEFCONFIG="mediatek_defconfig"
    log "Selected: mediatek_defconfig (MediaTek platform config)"
    log "  Note: review missing MT8183-specific options in the verify step below"
else
    BASE_DEFCONFIG="defconfig"
    log "Selected: defconfig (generic arm64 - expect warnings in verify step)"
    log "  Neither mt8183_defconfig nor mediatek_defconfig found in this kernel."
    log "  The device overlay and verify step will flag what needs attention."
fi

log "Building from: make ARCH=arm64 ${BASE_DEFCONFIG}"
make ARCH=arm64 "${BASE_DEFCONFIG}"

# ── Step 2: olddefconfig ──────────────────────────────────────────────────────
log "Running olddefconfig..."
make ARCH=arm64 olddefconfig

# ── Step 3: Optional device overlay ───────────────────────────────────────────
DEVICE_FRAG="${REPO_DIR}/configs/device/${CODENAME}.cfg"
KMERGE="${KERNEL_SRC}/scripts/kconfig/merge_config.sh"

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
log "=== Base defconfig used: ${BASE_DEFCONFIG} ==="
log ""

# ── Step 4: Verify critical MT8183 options ────────────────────────────────────
# WARNINGs here are not fatal - they tell you what to add to esche.cfg
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
        mediatek-mt8183)
            log "  -- SoC core --"
            check_y  "CONFIG_COMMON_CLK_MT8183" "SoC clocks missing - will not boot"
            check_ym "CONFIG_PINCTRL_MT8183"    "pinctrl missing - many devices will fail"
            check_ym "CONFIG_I2C_MT65XX"        "I2C missing - touchpad and codec will fail"
            check_ym "CONFIG_SPI_MT65XX"        "SPI missing - EC communication may fail"
            check_ym "CONFIG_MMC_MTK"           "eMMC will not be detected"

            log "  -- ChromeOS EC --"
            check_ym "CONFIG_CROS_EC"           "keyboard and touchpad will not work"
            check_ym "CONFIG_CROS_EC_SPI"       "EC SPI transport missing"

            log "  -- Display --"
            check_ym "CONFIG_DRM_PANFROST"      "GPU unavailable - no display"
            check_ym "CONFIG_DRM_MEDIATEK"      "display engine unavailable"

            log "  -- Audio --"
            check_ym "CONFIG_SND_SOC_MT8183"    "audio platform driver missing"

            log "  -- WiFi --"
            check_ym "CONFIG_ATH10K"            "ath10k missing (QCA6174A on esche)"
            check_ym "CONFIG_ATH10K_SDIO"       "ath10k SDIO missing (QCA6174A on esche)"

            log "  -- USB-C --"
            check_ym "CONFIG_TYPEC_FUSB302"     "USB-C PD controller unavailable"

            log "  -- Power --"
            check_ym "CONFIG_CHARGER_MT6360"    "battery charging unavailable"
            ;;
        *)
            log "  INFO: no checks defined for platform '$PLATFORM'"
            ;;
    esac

    log ""
    if [[ "$warnings" -gt 0 ]]; then
        log "  ${warnings} WARNING(s) above - add missing options to configs/device/${CODENAME}.cfg"
    else
        log "  All critical options present"
    fi
    log "=== Verification complete ==="
}

verify_config
