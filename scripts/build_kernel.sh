#!/bin/bash
# chromebook-kernel-builder - build script
# Modeled after hexdump0815/linux-mainline-and-mali-generic-stable-kernel build pattern
# Usage: ./build-kernel.sh <platform> [kernel-version]
# Example: ./build-kernel.sh geminilake 6.12.30

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIGS="${SCRIPT_DIR}/configs"
PATCHES="${SCRIPT_DIR}/patches"
RESULT_DIR="${SCRIPT_DIR}/output"

PLATFORM="${1:-}"
KVER="${2:-}"

if [ -z "$PLATFORM" ]; then
    echo "Usage: $0 <platform> [kernel-version]"
    echo "Platforms: geminilake  stoney-ridge  braswell"
    exit 1
fi

# Resolve platform config
case "$PLATFORM" in
    geminilake)
        PLATFORM_CFG="${CONFIGS}/platform/geminilake.cfg"
        ;;
    stoney-ridge)
        PLATFORM_CFG="${CONFIGS}/platform/stoney-ridge.cfg"
        ;;
    braswell)
        PLATFORM_CFG="${CONFIGS}/platform/braswell.cfg"
        ;;
    *)
        echo "Unknown platform: $PLATFORM"
        echo "Platforms: geminilake  stoney-ridge  braswell"
        exit 1
        ;;
esac

# Find kernel source - look in standard locations
KSRC=""
for d in /compile/source/linux-stable-cbx /var/tmp/kernel-build/linux-* /usr/src/linux-*; do
    if [ -f "$d/Makefile" ]; then
        KSRC="$d"
        break
    fi
done

if [ -z "$KSRC" ]; then
    echo "ERROR: No kernel source found. Clone kernel to /compile/source/linux-stable-cbx"
    echo "  git clone --depth 1 -b v6.12.30 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git /compile/source/linux-stable-cbx"
    exit 1
fi

echo "==> Kernel source: $KSRC"
echo "==> Platform: $PLATFORM"
cd "$KSRC"

# ── Apply patches ─────────────────────────────────────────────────────────────
if [ -d "${PATCHES}/common" ]; then
    for p in "${PATCHES}/common"/*.patch; do
        [ -f "$p" ] || continue
        echo "==> Applying patch: $(basename $p)"
        patch -p1 < "$p"
    done
fi

if [ -d "${PATCHES}/${PLATFORM}" ]; then
    for p in "${PATCHES}/${PLATFORM}"/*.patch; do
        [ -f "$p" ] || continue
        echo "==> Applying patch: $(basename $p)"
        patch -p1 < "$p"
    done
fi

# ── Merge configs ─────────────────────────────────────────────────────────────
# Order: base → platform
echo "==> Merging kernel config..."
cp "${CONFIGS}/base/chromebooks-x86_64.cfg" .config
scripts/kconfig/merge_config.sh -m .config \
    "${PLATFORM_CFG}"

make olddefconfig

# ── Build ─────────────────────────────────────────────────────────────────────
NCPUS=$(nproc)
echo "==> Building kernel with ${NCPUS} CPUs..."
make -j${NCPUS} bzImage modules

export kver=$(make kernelrelease)
echo "==> Kernel version: ${kver}"

# ── Install ───────────────────────────────────────────────────────────────────
echo "==> Installing modules..."
make modules_install

cp -v .config /boot/config-${kver}
cp -v arch/x86/boot/bzImage /boot/vmlinuz-${kver}
cp -v System.map /boot/System.map-${kver}

# ── Chromebook vboot signing ──────────────────────────────────────────────────
if command -v vbutil_kernel >/dev/null 2>&1; then
    echo "==> Creating Chromebook vboot kernel..."
    dd if=/dev/zero of=bootloader.bin bs=512 count=1
    printf "console=ttyS0,115200n8 console=tty1 root=PARTUUID=%%U/PARTNROFF=1 rootwait rw noinitrd" > cmdline
    vbutil_kernel \
        --pack vmlinux.kpart \
        --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
        --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
        --version 1 \
        --config cmdline \
        --bootloader bootloader.bin \
        --vmlinuz arch/x86/boot/bzImage \
        --arch x86_64
    cp -v vmlinux.kpart /boot/vmlinux.kpart-${kver}
    rm -f bootloader.bin cmdline vmlinux.kpart
fi

# ── Initrd ────────────────────────────────────────────────────────────────────
echo "==> Generating initrd..."
update-initramfs -c -k ${kver}

# ── Package ───────────────────────────────────────────────────────────────────
mkdir -p "${RESULT_DIR}"
tar czf "${RESULT_DIR}/${kver}-${PLATFORM}.tar.gz" \
    /boot/vmlinuz-${kver} \
    /boot/System.map-${kver} \
    /boot/config-${kver} \
    /boot/initrd.img-${kver} \
    /lib/modules/${kver}

echo "==> Done: ${RESULT_DIR}/${kver}-${PLATFORM}.tar.gz"
cp -v "${KSRC}/.config" "${RESULT_DIR}/config.${PLATFORM}-${kver}"
