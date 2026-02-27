# Chromebook Custom Kernel Builder

A layered, per-device kernel build system for x86_64 Chromebooks running
[VelvetOS](https://github.com/velvet-os/imagebuilder), designed to work
alongside [WeirdTreeThing/chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio).

---

## The Problem This Solves

Stock distro kernels don't work correctly on all Chromebook hardware.
Some platforms need specific kernel compile-time options that can't be
fixed by loading modules after boot. The clearest example:

**AMD Stoneyridge (Carrizo/Bristol Ridge) — e.g., Acer CB315-2H, Lenovo 300e Gen2 AMD:**
- `CONFIG_DRM_AMDGPU` **must be `=y`** (built-in), not `=m` (module)
- Stoney GPU firmware (`amdgpu/stoney_*.bin`) **must be compiled into** the kernel via `CONFIG_EXTRA_FIRMWARE`
- Two commits in `sound/soc/dwc/` need reverting
- Without these, `setup-audio` from chromebook-linux-audio will install UCM
  configs correctly but audio will still not work — the I2S controller
  never probes because AMDGPU isn't ready when the DW I2S driver initializes

This system automates detecting which Chromebook you have and assembling
the right kernel config for it.

---

## Config Layer Architecture

Every kernel config is assembled from **three layers merged in order**.
Later layers override earlier ones for any conflicting option.

```
Layer 1 — BASE (always applied)
  configs/base/chromebooks-x86_64.cfg
  Inspired by hexdump0815/kernel-config-options
  Contains: CrOS EC, input, MMC, WiFi, BT, SOF core, ALSA,
            common codecs, firmware loading, etc.

Layer 2 — PLATFORM (per SoC family)
  configs/platform/<platform>.cfg
  Examples: amd-stoneyridge.cfg, amd-ryzen-zork.cfg,
            intel-cometlake.cfg, intel-tigerlake.cfg, intel-alderlake.cfg
  Contains: GPU driver (=y vs =m), SOF/ACP backend, platform-specific
            codecs, built-in firmware requirements

Layer 3 — DEVICE (per board codename, optional)
  configs/device/<codename>.cfg
  Examples: aleena.cfg, treeya.cfg, kohaku.cfg
  Contains: only what differs from the platform default
            (e.g., specific codec present/absent on this board)
```

The merge uses the kernel's own `scripts/kconfig/merge_config.sh` when
available, falling back to `scripts/config` for each option.

---

## Directory Structure

```
chromebook-kernel-builder/
├── configs/
│   ├── hardware_map.conf       ← Maps codename → platform + kernel version
│   ├── kernel_versions.conf    ← Maps kernel version
│   ├── base/
│   │   └── chromebooks-x86_64.cfg   ← Layer 1: always applied
│   ├── platform/
│   │   ├── amd-stoneyridge.cfg      ← Layer 2: AMD Stoneyridge
│   │   ├── amd-ryzen-zork.cfg       ← Layer 2: AMD Ryzen (Zork family)
│   │   ├── intel-cometlake.cfg      ← Layer 2: Intel 10th Gen (Hatch)
│   │   ├── intel-tigerlake.cfg      ← Layer 2: Intel 11th Gen (Volteer)
│   │   └── intel-alderlake.cfg      ← Layer 2: Intel 12th Gen (Brya)
│   └── device/
│       ├── aleena.cfg               ← Layer 3: Acer CB315-2H overrides
│       ├── treeya.cfg               ← Layer 3: Lenovo 300e Gen2 AMD
│       └── kohaku.cfg               ← Layer 3: HP x360 14c
├── patches/
│   └── amd-stoneyridge/
│       └── README                   ← How to get/generate the DW I2S patches
├── scripts/
│   ├── build_kernel.sh              ← Main build orchestrator
│   ├── merge_kernel_config.sh       ← 3-layer config merger
│   ├── install_apt_pin.sh           ← APT pinning
│   └── add_device.sh                ← Helper: register a new board
└── output/                          ← .deb packages land here
```

---

## Quick Start

### Build for the current machine (auto-detect):

```bash
sudo apt-get install build-essential bc bison flex libssl-dev libelf-dev \
     libncurses-dev dwarves pahole debhelper rsync
sudo ./scripts/build_kernel.sh
```

### Build for a specific codename:

```bash
sudo ./scripts/build_kernel.sh --codename aleena
```

### Start from your running kernel config instead of defconfig:

```bash
sudo ./scripts/build_kernel.sh --codename aleena --base-config running
```

### See what would happen without building:

```bash
./scripts/build_kernel.sh --codename morphius --dry-run
```

### Build and install in one step:

```bash
sudo ./scripts/build_kernel.sh --codename aleena --install
```

---

## AMD Stoneyridge Workflow

Stoneyridge is the most complex case. Full workflow:

```bash
# 1. Install prerequisites including AMD firmware
sudo apt-get install firmware-amd-graphics zstd

# 2. Get the DW I2S patches (see patches/amd-stoneyridge/README)
#    Option A: Use prebuilt patches from chrultrabook.sakamoto.pl
wget https://chrultrabook.sakamoto.pl/stoneyridge-kernel/patches/0001-revert-dwc-i2s.patch \
     -O patches/amd-stoneyridge/0001-revert-dwc-i2s.patch

# 3. Build
sudo ./scripts/build_kernel.sh --codename aleena   # or treeya, barla, etc.

# 4. Install
sudo dpkg -i output/linux-image-*-velvet-aleena*.deb \
            output/linux-headers-*-velvet-aleena*.deb

# 5. Reboot onto new kernel, then set up audio
git clone https://github.com/WeirdTreeThing/chromebook-linux-audio
cd chromebook-linux-audio && sudo ./setup-audio

# 6. Reboot
```

---

## Adding a New Device

If your board isn't in `hardware_map.conf`:

```bash
# Auto-detect current hardware and register it
sudo ./scripts/add_device.sh

# Or specify manually
sudo ./scripts/add_device.sh --codename mynewboard --platform intel-alderlake
```

Then edit `configs/device/mynewboard.cfg` to add any board-specific
overrides and rebuild.

Alternatively, edit `hardware_map.conf` and `configs/device/` by hand:

1. Add a line to `hardware_map.conf`:
   ```
   mynewboard|intel-alderlake|6.6|none|Acme Chromebook XYZ
   ```

2. Create `configs/device/mynewboard.cfg` with any overrides
   (leave it empty/minimal if the platform config is already correct)

---

## APT Pinning

After a successful build, `install_apt_pin.sh` writes
`/etc/apt/preferences.d/99-velvet-kernel-<codename>` which:

- Pins your custom kernel at priority **1001** (protected from all upgrades)
- Blocks kernel meta-packages (`linux-image-amd64`, `linux-generic`, etc.)
  at priority **-1** (never install)
- Runs `apt-mark hold` on the installed packages as a second layer

To check the pin is working:
```bash
apt-cache policy linux-image-$(uname -r)
# Should show: *** <version> 1001
```

To deliberately replace the kernel:
```bash
sudo rm /etc/apt/preferences.d/99-velvet-kernel-<codename>
sudo apt-mark unhold linux-image-<version> linux-headers-<version>
```

---

## Supported Platforms

| Platform | Config file | Chromebook families | Key notes |
|---|---|---|---|
| AMD Stoneyridge | `amd-stoneyridge.cfg` | GRUNT | AMDGPU=y, fw builtin, DW I2S patch |
| AMD Ryzen (Zork) | `amd-ryzen-zork.cfg` | ZORK | SOF/ACP, no special requirements |
| Intel Comet Lake | `intel-cometlake.cfg` | HATCH | SOF CML, standard path |
| Intel Tiger Lake | `intel-tigerlake.cfg` | VOLTEER | SOF TGL + SoundWire |
| Intel Alder Lake | `intel-alderlake.cfg` | BRYA | SOF ADL + SoundWire |

---

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

This project is inspired by and builds upon:
- [hexdump0815/kernel-config-options](https://github.com/hexdump0815/kernel-config-options) (GPL-3.0)
- [velvet-os/imagebuilder](https://github.com/velvet-os/imagebuilder) (GPL-3.0)
- [WeirdTreeThing/chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio) (BSD-3-Clause)

The kernel itself is GPL-2.0-only per its own license.

## Credits

- [hexdump0815/kernel-config-options](https://github.com/hexdump0815/kernel-config-options) — base config approach
- [WeirdTreeThing/chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio) — UCM/audio setup
- [velvet-os/imagebuilder](https://github.com/velvet-os/imagebuilder) — the OS images this targets
