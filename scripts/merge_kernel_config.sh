#!/usr/bin/env bash
# =============================================================================
# merge_kernel_config.sh
#
# Merges kernel config fragments in order:
#   1. Base arch config (allmodconfig or existing .config from running system)
#   2. Base chromebook fragment (configs/base/chromebooks-x86_64.cfg)
#   3. Platform fragment (configs/platform/<platform>.cfg)
#   4. Device fragment (configs/device/<codename>.cfg) - if exists
#
# Each fragment is a PARTIAL config: only the options you want to set/override.
# Options not mentioned in a fragment are left as-is from previous layers.
# Later fragments WIN over earlier ones for any conflicting option.
#
# Usage:
#   ./merge_kernel_config.sh \
#       --kernel-src /path/to/linux-6.6.x \
#       --codename aleena \
#       --platform amd-stoneyridge \
#       --base-config [defconfig|/boot/config-$(uname -r)|none] \
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
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

[[ -z "$KERNEL_SRC" ]] && { echo "ERROR: --kernel-src required"; exit 1; }
[[ -z "$CODENAME"   ]] && { echo "ERROR: --codename required";   exit 1; }
[[ -z "$PLATFORM"   ]] && { echo "ERROR: --platform required";   exit 1; }
[[ -z "$OUTPUT_CONFIG" ]] && OUTPUT_CONFIG="${KERNEL_SRC}/.config"

log() { echo "[merge_config] $*"; }

# USE_KMERGE is determined after defconfig runs (kmerge script only exists post-build-prep)
KMERGE="${KERNEL_SRC}/scripts/kconfig/merge_config.sh"
USE_KMERGE=false  # resolved below after defconfig

# --- Collect fragments in order ---
FRAGMENTS=()

# Layer 2: Base chromebook options
BASE_FRAG="${REPO_DIR}/configs/base/chromebooks-x86_64.cfg"
[[ -f "$BASE_FRAG" ]] && FRAGMENTS+=("$BASE_FRAG") || log "WARNING: base fragment not found: $BASE_FRAG"

# Layer 3: Platform fragment
PLATFORM_FRAG="${REPO_DIR}/configs/platform/${PLATFORM}.cfg"
if [[ -f "$PLATFORM_FRAG" ]]; then
    FRAGMENTS+=("$PLATFORM_FRAG")
    log "Platform fragment: $PLATFORM_FRAG"
else
    log "WARNING: no platform fragment found at $PLATFORM_FRAG"
fi

# Layer 4: Device fragment (optional - not all codenames have one)
DEVICE_FRAG="${REPO_DIR}/configs/device/${CODENAME}.cfg"
if [[ -f "$DEVICE_FRAG" ]]; then
    FRAGMENTS+=("$DEVICE_FRAG")
    log "Device fragment: $DEVICE_FRAG"
else
    log "INFO: no device-specific fragment for '$CODENAME' (using platform defaults)"
fi

log "Fragment merge order:"
for f in "${FRAGMENTS[@]}"; do
    log "  $f"
done

# --- Step 1: Establish base .config ---
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

# --- Step 2: Apply fragments ---
# Check for kmerge NOW (after defconfig has run and kernel scripts are built)
if [[ -x "$KMERGE" ]]; then
    USE_KMERGE=true
    log "Using kernel merge_config.sh..."
else
    USE_KMERGE=false
    log "merge_config.sh not found, using scripts/config fallback..."
fi

if [[ "$USE_KMERGE" == true ]]; then
    # Use kernel's merge_config.sh - handles fragment merging properly
    # -m = merge into existing .config  -r = allow override warnings
    "${KMERGE}" -m -r .config "${FRAGMENTS[@]}"
    # merge_config.sh writes to .config.new in some versions
    [[ -f ".config.new" ]] && mv .config.new .config
else
    # Fallback: apply each fragment line by line using scripts/config
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
            # CONFIG_FOO=some_value (unquoted, e.g. numeric)
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


# --- Step 3: Copy to output if different path ---
if [[ "$OUTPUT_CONFIG" != "${KERNEL_SRC}/.config" ]]; then
    cp "${KERNEL_SRC}/.config" "$OUTPUT_CONFIG"
fi

log ""
log "=== Config merge complete ==="
log "Output: $OUTPUT_CONFIG"
log ""

# --- Step 4: Verify critical options for the platform ---
verify_config() {
    local config_file="${KERNEL_SRC}/.config"
    log "=== Verifying critical config options for platform: $PLATFORM ==="
    
    case "$PLATFORM" in
        amd-stoneyridge)
            # AMDGPU: =m is correct per validated 6.19 working config
            # Firmware is loaded from filesystem at runtime (EXTRA_FIRMWARE="")
            # Probe ordering is handled by DRM_AMD_ACP=y in the platform config
            if grep -q "^CONFIG_DRM_AMDGPU=y" "$config_file"; then
                log "  WARNING: CONFIG_DRM_AMDGPU=y (built-in)"
                log "  Validated working configs use =m - firmware loads from filesystem"
            elif grep -q "^CONFIG_DRM_AMDGPU=m" "$config_file"; then
                log "  OK: CONFIG_DRM_AMDGPU=m"
            else
                log "  WARNING: CONFIG_DRM_AMDGPU not set"
            fi

            # DRM_AMD_ACP must be built-in for audio probe ordering
            if grep -q "^CONFIG_DRM_AMD_ACP=y" "$config_file"; then
                log "  OK: CONFIG_DRM_AMD_ACP=y"
            else
                log "  WARNING: CONFIG_DRM_AMD_ACP not =y - audio probe ordering may fail"
            fi

            # DW I2S: =m is correct per validated 6.19 working config
            if grep -q "^CONFIG_SND_DESIGNWARE_I2S=m" "$config_file"; then
                log "  OK: CONFIG_SND_DESIGNWARE_I2S=m"
            elif grep -q "^CONFIG_SND_DESIGNWARE_I2S=y" "$config_file"; then
                log "  WARNING: CONFIG_SND_DESIGNWARE_I2S=y (built-in not needed)"
            fi

            # ACP3x native driver for Stoneyridge audio
            if grep -q "^CONFIG_SND_SOC_AMD_ACP3x=m" "$config_file"; then
                log "  OK: CONFIG_SND_SOC_AMD_ACP3x=m"
            else
                log "  WARNING: CONFIG_SND_SOC_AMD_ACP3x not set - Stoneyridge audio may not work"
            fi

            # AMD pstate for CPU frequency scaling
            if grep -q "^CONFIG_X86_AMD_PSTATE=y" "$config_file"; then
                log "  OK: CONFIG_X86_AMD_PSTATE=y"
            else
                log "  WARNING: CONFIG_X86_AMD_PSTATE not set - CPU may not scale frequency"
            fi
            ;;
        
        amd-ryzen-zork)
            if grep -q "^CONFIG_SND_SOC_SOF_AMD_RENOIR" "$config_file"; then
                log "  OK: SOF AMD Renoir present"
            else
                log "  WARNING: CONFIG_SND_SOC_SOF_AMD_RENOIR not found"
            fi
            ;;
        
        intel-*)
            local sof_key=""
            case "$PLATFORM" in
                intel-cometlake) sof_key="CONFIG_SND_SOC_SOF_COMETLAKE" ;;
                intel-tigerlake) sof_key="CONFIG_SND_SOC_SOF_TIGERLAKE" ;;
                intel-alderlake) sof_key="CONFIG_SND_SOC_SOF_ALDERLAKE" ;;
            esac
            if [[ -n "$sof_key" ]]; then
                if grep -q "^${sof_key}=" "$config_file"; then
                    log "  OK: ${sof_key} present"
                else
                    log "  WARNING: ${sof_key} not found - audio may not work"
                fi
            fi
            ;;
    esac
    
    log "=== Verification complete ==="
}

verify_config
