#!/bin/bash
# =============================================================================
# scripts/build_kernel_arm64.sh
#
# Builds a mainline arm64 kernel for ARM64 Chromebooks
#
#   boot/Image-${kver}
#   boot/System.map-${kver}
#   boot/config-${kver}
#   boot/dtb-${kver}/<dtb-prefix>-*.dtb
#   boot/vmlinux.kpart-${kver}
#   lib/modules/${kver}/
#
# No initrd - boots directly to PARTUUID root (noinitrd in cmdline).
# Designed for native ubuntu-24.04-arm runners. Also cross-compiles from
# x86_64 if CROSS_COMPILE=aarch64-linux-gnu- is set in the environment.
#
# Usage:
#   ./scripts/build_kernel_arm64.sh <platform> <codename> <kernel-full-version> <dtb-prefix>
#
# Example:
#   ./scripts/build_kernel_arm64.sh mediatek-mt8183 esche 6.12.76 mt8183-kukui
#   ./scripts/build_kernel_arm64.sh mediatek-mt8183 oak   6.12.76 mt8173-elm
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCHES="${REPO_DIR}/patches"
RESULT_DIR="${REPO_DIR}/output"

PLATFORM="${1:-}"
CODENAME="${2:-}"
KVER_FULL="${3:-}"
DTB_PREFIX="${4:-}"

if [[ -z "$PLATFORM" || -z "$CODENAME" || -z "$KVER_FULL" || -z "$DTB_PREFIX" ]]; then
    echo "Usage: $0 <platform> <codename> <kernel-full-version> <dtb-prefix>"
    echo "  e.g: $0 mediatek-mt8183 esche 6.12.76 mt8183-kukui"
    echo "  e.g: $0 mediatek-mt8183 oak   6.12.76 mt8173-elm"
    exit 1
fi

# ── Locate kernel source ──────────────────────────────────────────────────────
KSRC=""
for d in "/var/tmp/kernel-build/linux-${KVER_FULL}" /compile/source/linux-stable-cbm; do
    [[ -f "$d/Makefile" ]] && KSRC="$d" && break
done

if [[ -z "$KSRC" ]]; then
    echo "ERROR: kernel source not found for linux-${KVER_FULL}"
    exit 1
fi

echo "==> Kernel source: $KSRC"
echo "==> Platform:      $PLATFORM"
echo "==> Codename:      $CODENAME"
echo "==> Kernel:        $KVER_FULL"

# ── Detect native vs cross-compile ───────────────────────────────────────────
if [[ "$(uname -m)" == "aarch64" ]]; then
    echo "==> Native arm64 build"
    CROSS_COMPILE_ARG=""
else
    echo "==> Cross-compiling from $(uname -m)"
    CROSS_COMPILE_ARG="CROSS_COMPILE=aarch64-linux-gnu-"
fi

cd "$KSRC"

# ── Apply patches ─────────────────────────────────────────────────────────────
apply_patches() {
    local patch_dir="$1"
    [[ -d "$patch_dir" ]] || return 0
    shopt -s nullglob
    local patches=("$patch_dir"/*.patch)
    [[ ${#patches[@]} -eq 0 ]] && return 0
    echo "==> Applying ${#patches[@]} patch(es) from $(basename "$patch_dir")..."
    for p in "${patches[@]}"; do
        echo "    $(basename "$p")"
        patch -p1 --forward < "$p" \
            || echo "    WARNING: patch may already be applied, continuing"
    done
}

apply_patches "${PATCHES}/common"
apply_patches "${PATCHES}/${PLATFORM}"

# ── Merge kernel config ───────────────────────────────────────────────────────
echo "==> Merging kernel config..."
chmod +x "${SCRIPT_DIR}/merge_kernel_config_arm64.sh"
"${SCRIPT_DIR}/merge_kernel_config_arm64.sh" \
    --kernel-src "$KSRC" \
    --platform   "$PLATFORM" \
    --codename   "$CODENAME"

# ── Build ─────────────────────────────────────────────────────────────────────
NCPUS=$(nproc)
echo "==> Building with ${NCPUS} CPUs..."
make ARCH=arm64 ${CROSS_COMPILE_ARG} -j"${NCPUS}" Image dtbs modules

kver=$(make ARCH=arm64 ${CROSS_COMPILE_ARG} kernelrelease)
echo "==> Kernel version: ${kver}"

# ── Stage into a temporary tree ───────────────────────────────────────────────
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

BOOT="${STAGE}/boot"
mkdir -p "${BOOT}"

make ARCH=arm64 ${CROSS_COMPILE_ARG} \
    INSTALL_MOD_PATH="${STAGE}" \
    INSTALL_MOD_STRIP=1 \
    modules_install

cp -v .config               "${BOOT}/config-${kver}"
cp -v arch/arm64/boot/Image "${BOOT}/Image-${kver}"
cp -v System.map            "${BOOT}/System.map-${kver}"

# DTBs - copy all DTBs matching the device prefix from hardware_map.conf
mkdir -p "${BOOT}/dtb-${kver}"
echo "==> Copying DTBs matching: arch/arm64/boot/dts/mediatek/${DTB_PREFIX}-*.dtb"
find arch/arm64/boot/dts/mediatek -name "${DTB_PREFIX}-*.dtb" \
    -exec cp -v {} "${BOOT}/dtb-${kver}/" \;
DTB_COUNT=$(find "${BOOT}/dtb-${kver}" -name '*.dtb' | wc -l)
echo "==> Staged ${DTB_COUNT} DTB(s)"
if [[ "$DTB_COUNT" -eq 0 ]]; then
    echo "ERROR: no DTBs matching ${DTB_PREFIX}-*.dtb produced"
    echo "  Check kernel config, patches, and DTB_PREFIX in hardware_map.conf"
    exit 1
fi

# ── ChromeOS FIT image (vmlinux.kpart) ───────────────────────────────────────
echo "==> Creating vmlinux.kpart..."

CMDLINE_FILE="${REPO_DIR}/configs/cmdline/chromebook-kukui.cmdline"
if [[ ! -f "$CMDLINE_FILE" ]]; then
    echo "ERROR: cmdline file not found: $CMDLINE_FILE"
    exit 1
fi

# lz4-compress the raw kernel Image
lz4 -f "${BOOT}/Image-${kver}" "${STAGE}/Image.lz4"

# Empty bootloader stub required by vbutil_kernel
dd if=/dev/zero of="${STAGE}/bootloader.bin" bs=512 count=1 2>/dev/null

# Collect DTBs for mkimage
DTB_ARGS=()
while IFS= read -r -d '' dtb; do
    DTB_ARGS+=(-b "$dtb")
done < <(find "${BOOT}/dtb-${kver}" -name '*.dtb' -print0 | sort -z)

# FIT image: lz4 Image + all kukui DTBs
mkimage \
    -D "-I dts -O dtb -p 2048" \
    -f auto \
    -A arm64 \
    -O linux \
    -T kernel \
    -C lz4 \
    -a 0 \
    -d "${STAGE}/Image.lz4" \
    "${DTB_ARGS[@]}" \
    "${STAGE}/kernel.itb"

# Sign with ChromeOS developer keys
vbutil_kernel \
    --pack "${BOOT}/vmlinux.kpart-${kver}" \
    --keyblock    /usr/share/vboot/devkeys/kernel.keyblock \
    --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
    --version 1 \
    --config      "${CMDLINE_FILE}" \
    --bootloader  "${STAGE}/bootloader.bin" \
    --vmlinuz     "${STAGE}/kernel.itb" \
    --arch arm

# Verify before packaging so a bad image fails here, not on the device
echo "==> Verifying signed image..."
vbutil_kernel \
    --verify "${BOOT}/vmlinux.kpart-${kver}" \
    --signpubkey /usr/share/vboot/devkeys/kernel_subkey.vbpubk

# ── Package ───────────────────────────────────────────────────────────────────
mkdir -p "${RESULT_DIR}"
TARBALL="${RESULT_DIR}/${kver}-${PLATFORM}.tar.gz"

echo "==> Packaging ${TARBALL}..."
tar czf "${TARBALL}" \
    -C "${STAGE}" \
    "boot/Image-${kver}" \
    "boot/System.map-${kver}" \
    "boot/config-${kver}" \
    "boot/dtb-${kver}" \
    "boot/vmlinux.kpart-${kver}" \
    "lib/modules/${kver}"

cp -v "${KSRC}/.config" "${RESULT_DIR}/config.${PLATFORM}-${kver}"

echo ""
echo "==> Done: ${TARBALL}"
echo ""
echo "Installation on device:"
echo "  sudo tar xzf $(basename "${TARBALL}") -C /"
echo "  KERN=\$(cgpt find -t kernel /dev/mmcblk1 | head -1)"
echo "  sudo dd if=/boot/vmlinux.kpart-${kver} of=\"\${KERN}\" bs=4M"
echo "  sudo cgpt add -i \"\${KERN##*p}\" -P 15 -T 1 -S 1 /dev/mmcblk1"
echo "  sudo reboot"
