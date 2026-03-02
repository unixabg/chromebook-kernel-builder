# Chromebook Custom Kernel Builder

A layered, per-device kernel build system for x86_64 Chromebooks running
any Debian-based Linux distribution.

Designed to work alongside
[WeirdTreeThing/chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio)
for boards that need UCM/topology files installed after boot.

---

## The Problem This Solves

Stock distro kernels don't work correctly on all Chromebook hardware.
Some platforms need specific kernel compile-time options that can't be
fixed by loading modules after boot.

**AMD Stoneyridge — e.g., Acer CB315-2H, Lenovo 300e Gen2 AMD:**
- Stoney GPU firmware (`amdgpu/stoney_*.bin`) must be compiled into the
  kernel via `CONFIG_EXTRA_FIRMWARE`
- Without this, the I2S controller never probes correctly because AMDGPU
  isn't ready when the DW I2S driver initializes

This system assembles the right kernel config for your Chromebook platform
and builds installable `.deb` packages, either locally or via GitHub Actions.

---

## Audio Support

For most platforms, install the kernel then run
[chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio)
to install UCM configs and topology files:

```bash
git clone https://github.com/WeirdTreeThing/chromebook-linux-audio
cd chromebook-linux-audio && sudo ./setup-audio
```

**Stoney Ridge (6.19+):** Some users have reported full audio including
microphone working on a pristine install with no additional steps required.
Your experience may vary — if audio does not work,
[chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio)
is the recommended next step.

---

## Config Layer Architecture

Every kernel config is assembled from layers merged in order.
Later layers override earlier ones for any conflicting option.

```
Layer 0 — KNOWN-GOOD BASE
  configs/base/6.19.0-rc1.cfg
  A full working kernel config used as the foundation.

Layer 1 — CHROMEBOOK COMMON (always applied)
  configs/base/chromebooks-x86_64.cfg
  Contains: CrOS EC, input, MMC, WiFi, BT, SOF core, ALSA,
            common codecs, firmware loading, etc.

Layer 2 — PLATFORM (per SoC family)
  configs/platform/<platform>.cfg
  Contains: GPU driver settings, SOF/ACP backend, platform-specific
            codecs, built-in firmware requirements.

Layer 3 — DEVICE (per board codename, optional)
  configs/device/<codename>.cfg
  Contains: only what differs from the platform default
            (e.g., specific codec present/absent on this board)
```

The merge uses the kernel's own `scripts/kconfig/merge_config.sh`.

---

## Directory Structure

```
chromebook-kernel-builder/
├── configs/
│   ├── hardware_map.conf            ← Maps codename → platform + kernel version
│   ├── kernel_versions.conf         ← Kernel series tracking
│   ├── base/
│   │   ├── 6.19.0-rc1.cfg           ← Layer 0: known-good full config
│   │   └── chromebooks-x86_64.cfg   ← Layer 1: Chromebook common
│   ├── platform/
│   │   ├── stoney-ridge.cfg         ← AMD Stoneyridge (TREEYA360/GRUNT)
│   │   ├── amd-grunt.cfg            ← AMD GRUNT family
│   │   ├── amd-ryzen-zork.cfg       ← AMD Ryzen (Zork family)
│   │   ├── geminilake.cfg           ← Intel GeminiLake (PHASER360)
│   │   ├── intel-braswell.cfg       ← Intel Braswell (STRAGO)
│   │   └── intel-cometlake.cfg      ← Intel 10th Gen (HATCH)
│   └── device/
│       ├── aleena.cfg               ← Acer CB315-2H (DA7219 codec)
│       ├── treeya.cfg               ← Lenovo 300e Gen2 AMD (RT5682 codec)
│       ├── relm.cfg                 ← CTL NL61 (RT5650 codec)
│       └── setzer.cfg               ← HP Chromebook 11 G5 EE (RT5650 codec)

├── patches/
│   └── stoney-ridge/                ← Platform patches if needed
├── scripts/
│   ├── build_kernel.sh              ← Main build orchestrator
│   ├── merge_kernel_config.sh       ← Config layer merger + verification
│   ├── install_apt_pin.sh           ← APT pinning to protect custom kernel
│   └── add_device.sh                ← Helper: register a new board
└── output/                          ← Built .deb packages land here
```

---

## Quick Start

### Install build dependencies

```bash
sudo apt-get install build-essential bc bison flex libssl-dev libelf-dev \
     libncurses-dev dwarves pahole debhelper rsync ccache zstd
```

### Build for the current machine (auto-detect):

```bash
sudo ./scripts/build_kernel.sh
```

### Build for a specific codename:

```bash
sudo ./scripts/build_kernel.sh --codename aleena
```

### Start from your running kernel config:

```bash
sudo ./scripts/build_kernel.sh --codename aleena --base-config running
```

### Dry run (no build):

```bash
./scripts/build_kernel.sh --codename treeya --dry-run
```

### Build and install in one step:

```bash
sudo ./scripts/build_kernel.sh --codename aleena --install
```

---

## GitHub Actions

This repo includes a workflow that builds kernels automatically on push
or on a weekly schedule, publishing `.deb` packages as release artifacts.

To trigger a manual build:
1. Go to **Actions** → **Build Chromebook Kernels**
2. Click **Run workflow**
3. Optionally specify a kernel series or platform filter
4. Download the artifact from the completed run

Pre-built kernels are published on the
[Releases](../../releases) page.

---

## Installing a Pre-built Kernel

```bash
# Find your board codename
cat /sys/class/dmi/id/board_name

# Look up your platform in hardware_map.conf, then install
PLATFORM=stoney-ridge
sudo dpkg -i linux-image-*-chromebook-${PLATFORM}*.deb \
             linux-headers-*-chromebook-${PLATFORM}*.deb

# Pin to prevent apt upgrades overwriting this kernel
sudo cp 99-chromebook-kernel-${PLATFORM} /etc/apt/preferences.d/

# Reboot, then set up audio if needed
git clone https://github.com/WeirdTreeThing/chromebook-linux-audio
cd chromebook-linux-audio && sudo ./setup-audio
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
overrides (codec drivers, disabled options, etc.) and rebuild.

---

## APT Pinning

After a successful build, `install_apt_pin.sh` writes a pin file which:

- Pins your custom kernel at priority **1001** (protected from all upgrades)
- Blocks kernel meta-packages at priority **-1** (never auto-install)
- Runs `apt-mark hold` as a second layer of protection

Check the pin is working:
```bash
apt-cache policy linux-image-$(uname -r)
# Should show: *** <version> 1001
```

Remove pinning to replace the kernel:
```bash
sudo rm /etc/apt/preferences.d/99-chromebook-kernel-<platform>
sudo apt-mark unhold linux-image-<version> linux-headers-<version>
```

---

## Supported Platforms

| Platform config | Chromebook family | Devices | Audio notes |
|---|---|---|---|
| `stoney-ridge.cfg` | TREEYA360 | Lenovo 300e Gen2 AMD | Audio works out of box on 6.19+ |
| `amd-grunt.cfg` | GRUNT | Aleena, Barla, Careena, etc. | chromebook-linux-audio recommended |
| `amd-ryzen-zork.cfg` | ZORK | Morphius, Dalboz, Vilboz, etc. | chromebook-linux-audio recommended |
| `geminilake.cfg` | PHASER360 | Lenovo 500e Gen2, C340, etc. | chromebook-linux-audio recommended |
| `intel-braswell.cfg` | STRAGO | Gnawty, Relm, Setzer, etc. | chromebook-linux-audio recommended |
| `intel-cometlake.cfg` | HATCH | Kohaku, Helios, etc. | chromebook-linux-audio recommended |


---

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

## Credits

- [hexdump0815/kernel-config-options](https://github.com/hexdump0815/kernel-config-options) — base config approach
- [WeirdTreeThing/chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio) — UCM/audio setup (BSD-3-Clause)
- [velvet-os/imagebuilder](https://github.com/velvet-os/imagebuilder) — original target OS (GPL-3.0)
