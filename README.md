# Chromebook Custom Kernel Builder

A layered, per-device kernel build system for x86_64 and ARM64 (aarch64)
Chromebooks running any Debian-based Linux distribution.

x86_64 builds are designed to work alongside
[WeirdTreeThing/chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio)
for boards that need UCM/topology files installed after boot.

ARM64 builds target [velvet-os](https://github.com/velvet-os/velvet-os.github.io)
and are managed on-device using
[velvet-tools](https://github.com/velvet-os/velvet-tools).

---

## The Problem This Solves

Stock distro kernels don't always work correctly on Chromebook hardware.
Some platforms benefit from specific kernel compile-time options or config
tweaks that can't easily be fixed after the fact — this project is a
starting point for building kernels that address those gaps on a
per-platform and per-device basis.

A few examples:

**AMD Stoneyridge — e.g., Acer CB315-2H, Lenovo 300e Gen2 AMD:**
Some Stoney boards work better with GPU firmware compiled directly into
the kernel rather than loaded as a module, which can help the audio
subsystem initialize correctly on boot.

**MediaTek MT8183 — e.g., HP Chromebook 11MK G9 EE (esche):**
ARM64 Chromebooks using depthcharge require a FIT image (kernel + device
tree blobs) packed into a signed kpart. An initramfs is also needed so
the system can find USB storage before the rootfs mount times out.

These configs are not guaranteed to be perfect for every board or use
case — they are a community-maintained starting point. Testing and
contributions are very welcome.

---

## Audio Support

### x86_64

For most x86 platforms, install the kernel then run
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

### ARM64 (MT8183)

chromebook-linux-audio is x86-only and does not support ARM platforms.
Audio support for MT8183 depends on mainline ASoC drivers and is handled
differently per board. This is an area where community contributions and
testing reports are especially welcome.

---

## Config Layer Architecture

Every kernel config is assembled from layers merged in order.
Later layers override earlier ones for any conflicting option.

### x86_64

```
Layer 0 — BASE (always applied)
  configs/base/chromebooks-x86_64.cfg
  Full curated Chromebook config. Contains: CrOS EC, input, MMC, WiFi,
  BT, SOF core, ALSA, common codecs, crypto, filesystems, Virtio, etc.

Layer 1 — PLATFORM (per SoC family)
  configs/platform/<platform>.cfg
  Contains: GPU driver settings, SOF/ACP backend, platform-specific
            codecs, built-in firmware requirements.

Layer 2 — DEVICE (per board codename, optional)
  configs/device/<codename>.cfg
  Contains: only what differs from the platform default
            (e.g., specific codec present/absent on this board)
```

The merge uses the kernel's own `scripts/kconfig/merge_config.sh`.

### ARM64

```
Layer 0 — BASE
  configs/base/<platform>.config  if present and non-empty (local override)
  OR hexdump0815's config.cbm/config.rkc from the external repo (fallback)
  The external repo URL is set per-vendor in kernel_versions.conf:
    ARM64_EXTERNAL_REPO_URL_MEDIATEK=https://github.com/hexdump0815/...

  make ARCH=arm64 olddefconfig is run after this step to adapt the
  base config to the kernel version being built.

Layer 1 — ARM64 COMMON FIXES (always applied)
  configs/base/arm64-common-fixes.cfg
  Options required for all ARM64 Chromebook builds not always present
  in upstream base configs (e.g. CONFIG_DRM_DISPLAY_DSC_HELPER).

Layer 2 — EXTERNAL OPTIONS (from hexdump0815 repo, applied automatically)
  misc.cbm/options/additional-options-special.cfg  <- additions
  misc.cbm/options/options-to-remove-special.cfg   <- removals
  Pulled at build time from the external repo. Not stored in this repo.

Layer 3 — DEVICE (per board codename, optional)
  configs/device/<codename>.cfg
  Contains only options absent from or wrong in the upstream base.
  Keep this minimal - if hexdump0815 already provides it correctly,
  it does not need to be repeated here.
```

The ARM64 merge is handled by `scripts/merge_kernel_config_arm64.sh`.

---

## Directory Structure

```
chromebook-kernel-builder/
├── configs/
│   ├── hardware_map.conf            ← Maps codename → platform + kernel version
│   ├── kernel_versions.conf         ← Kernel series tracking
│   ├── base/
│   │   ├── chromebooks-x86_64.cfg       ← Layer 0: full curated x86_64 base config
│   │   ├── arm64-common-fixes.cfg       ← ARM64: fixes applied to all ARM64 builds
│   │   └── mediatek-mt81xx.config       ← ARM64: local base override (empty = use hexdump's base)
│   ├── cmdline/
│   │   └── chromebook-kukui.cmdline ← Kernel cmdline for MT8183 kpart
│   ├── platform/
│   │   ├── stoney-ridge.cfg         ← AMD Stoneyridge (TREEYA360/GRUNT)
│   │   ├── amd-grunt.cfg            ← AMD GRUNT family
│   │   ├── amd-ryzen-zork.cfg       ← AMD Ryzen (Zork family)
│   │   ├── geminilake.cfg           ← Intel GeminiLake (PHASER360)
│   │   ├── intel-braswell.cfg       ← Intel Braswell (STRAGO)
│   │   └── intel-cometlake.cfg      ← Intel 10th Gen (HATCH)
│   │   (ARM64 has no platform cfg - base comes from hexdump0815 external repo)
│   └── device/
│       ├── aleena.cfg               ← Acer CB315-2H (DA7219 codec)
│       ├── treeya.cfg               ← Lenovo 300e Gen2 AMD (RT5682 codec)
│       ├── relm.cfg                 ← CTL NL61 (RT5650 codec)
│       ├── setzer.cfg               ← HP Chromebook 11 G5 EE (RT5650 codec)
│       └── esche.cfg                ← HP Chromebook 11MK G9 EE (MT8183)

├── patches/
│   └── stoney-ridge/                ← Platform patches if needed
├── scripts/
│   ├── build_kernel.sh              ← Main build orchestrator (x86_64)
│   ├── merge_kernel_config.sh       ← Config layer merger + verification
│   ├── merge_kernel_config_arm64.sh ← ARM64 config merger
│   ├── install_apt_pin.sh           ← APT pinning to protect custom kernel
│   └── add_device.sh                ← Helper: register a new board
└── output/                          ← Built artifacts land here
```

---

## Quick Start (x86_64)

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

This repo includes workflows that build kernels automatically on push
or on a weekly schedule, publishing artifacts to the
[Releases](../../releases) page.

### Commit message triggers

Push builds are controlled by tags in the commit message. No tag means
no build — this prevents every commit from triggering a full kernel build.

| Commit message | Effect |
|---|---|
| `[build:all]` | Build all platforms, default kernel version |
| `[build:stoney-ridge]` | Build one platform, default kernel version |
| `[build:esche]` | Build one device (arm64), default kernel version |
| `[build:all][kernel:6.12]` | Build all, resolve latest 6.12.x |
| `[build:esche][kernel:6.12.80]` | Build one device, exact kernel version |
| `[build:stoney-ridge][kernel:6.19.6]` | Build one platform, exact version |

The `[kernel:x.y]` tag resolves the latest point release in that series.
The `[kernel:x.y.z]` tag uses that exact version directly.
Omitting `[kernel:]` uses the default series from `configs/kernel_versions.conf`.

### Manual trigger (workflow_dispatch)

1. Go to **Actions** → select the relevant workflow
2. Click **Run workflow**
3. Optionally specify a kernel series, platform, or codename filter
4. Download artifacts from the completed run, or wait for the release to publish

### Weekly schedule

Builds run automatically every Sunday — x86_64 at 02:00 UTC, ARM64 at
04:00 UTC — and publish a pre-release to the
[Releases](../../releases) page. No commit needed.

### Workflows

- **build.yml** — x86_64 Chromebooks, produces `.deb` packages
- **build_arm64.yml** — ARM64 Chromebooks (MT8183), produces a signed
  kpart tarball for use with velvet-os

---

## ARM64 / MediaTek MT8183 (velvet-os)

ARM64 builds target [velvet-os](https://github.com/velvet-os/velvet-os.github.io)
images. The GitHub Actions workflow produces a `.tar.gz` containing the
signed kpart, Image, DTBs, and kernel modules.

On-device kernel management is handled by
[velvet-tools](https://github.com/velvet-os/velvet-tools), which
automates test-booting and permanently flashing new kernels via the
two depthcharge kernel partitions.

### Supported devices

| Codename | Device | SoC |
|---|---|---|
| esche | HP Chromebook 11MK G9 EE | MT8183 |

Other kukui-family boards (Acer 311, Lenovo Duet, Lenovo 10e) share the
same MT8183 platform config and DTBs and should work with minimal changes.
Community testing reports are welcome — see [Contributing](#contributing).

### Installing a new kernel on velvet-os

**Prerequisites:** velvet-tools must be installed on the target system.
See [velvet-tools](https://github.com/velvet-os/velvet-tools) for
installation instructions.

**1. Download the tarball** from the [Releases](../../releases) page and
extract it to the root of your velvet-os install:

```bash
sudo tar xzf <kver>-velvet-os-<date>.tar.gz -C /
```

This places the kernel Image, DTBs, modules, and kpart under `/boot` and
`/lib/modules`.

**2. Generate the initramfs** — required for USB boot. Without it the
system will hang waiting for storage to enumerate:

```bash
sudo update-initramfs -c -k <kver>
```

**3. velvet-tools takes over** — if `init_gen_hook=y` is set in
`/etc/velvettools/config` (the default), velvet-tools automatically
rebuilds the kpart with the new initramfs and test-flashes it to the
secondary kernel partition (`sda2`).

**4. Reboot** — depthcharge boots once from the secondary partition.
On successful boot, `vtcheck` permanently promotes the new kernel to
the primary partition (`sda1`). If the boot fails, depthcharge
automatically falls back to the previous kernel on the next boot.

```bash
sudo reboot
```

### velvet-os partition layout (USB)

| Partition | Label | Role |
|---|---|---|
| sda1 | — | Primary kernel (kpart, depthcharge) |
| sda2 | — | Secondary kernel (test boots) |
| sda3 | bootpart | /boot (ext4) |
| sda4 | rootpart | / (btrfs) |

### Useful velvet-tools commands

```bash
vtlist                    # list available kernel versions
vtbuild <kver>            # rebuild kpart for a kernel version
vttest <kver> /dev/sda    # manually test-flash to secondary partition
vtflash <kver> /dev/sda   # permanently flash to primary partition
vtdisable /dev/sda        # make a partition unbootable
```

For full documentation see
[velvet-tools](https://github.com/velvet-os/velvet-tools) and the
[velvet-os kernel docs](https://github.com/velvet-os/velvet-os.github.io/tree/main/chromebooks/kernel).

---

## Installing a Pre-built x86_64 Kernel

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

## Contributing

Contributions are welcome — the configs in this repo are a starting point,
not a finished product, and real-world testing on real hardware is the only
way to improve them.

---

### Adding a new x86_64 device

**Files to edit or create:**

| File | Required | What to do |
|---|---|---|
| `configs/hardware_map.conf` | ✅ | Add one line for your board |
| `configs/device/<codename>.cfg` | ✅ | Create with any board-specific overrides (can be empty) |
| `patches/<platform>/` | only if needed | Drop a `.patch` file here if your board needs a kernel patch |

**`hardware_map.conf` format:**
```
CODENAME|PLATFORM|KERNEL_SERIES|PATCH_DIR|ARCH|DTB_PREFIX|NOTES
```

Example:
```
myboard|intel-cometlake|default|none|x86_64|none|Acme Chromebook XYZ
```

- `CODENAME` — ChromeOS board codename (check `cat /sys/class/dmi/id/board_name`)
- `PLATFORM` — must match an existing `configs/platform/<platform>.cfg`
- `KERNEL_SERIES` — use `default` unless your board needs a specific series (e.g. `6.12`)
- `PATCH_DIR` — subdirectory under `patches/` to apply, or `none`
- `ARCH` — `x86_64` for Intel/AMD boards
- `DTB_PREFIX` — `none` for x86_64 boards
- `NOTES` — human-readable device name

**`configs/device/<codename>.cfg`:**
Only include options that differ from the platform default. If the platform
config works as-is, the file can be empty. Do not copy the entire platform
config — keep it minimal.

---

### Adding a new ARM64 device

ARM64 builds run entirely through GitHub Actions — there is no local build
script. Adding a device means adding config files; the CI pipeline handles
the rest.

**Config layering for ARM64** — understand this before creating files:

The base config comes automatically from hexdump0815's external repo
(`config.cbm` for MediaTek, `config.rkc` for Rockchip). You do not need
to copy or maintain this. On top of that, `arm64-common-fixes.cfg` and
hexdump's special options are applied automatically. Your `configs/device/
<codename>.cfg` is applied last and should contain **only** options that
are absent from or wrong in hexdump's base. Keep it minimal.

**Files to edit or create:**

| File | Required | What to do |
|---|---|---|
| `configs/hardware_map.conf` | ✅ | Add one line for your board |
| `configs/device/<codename>.cfg` | ✅ | Create with board-specific overrides only (can be empty) |
| `configs/cmdline/<codename>.cmdline` | only if needed | Create if your board needs different kernel parameters than the platform default |
| `patches/<platform>/` | only if needed | Drop a `.patch` file here for device-specific kernel patches |

**`hardware_map.conf` entry for ARM64:**
```
myboard|mediatek-mt81xx|default|none|arm64|mt8183-kukui|Acme Chromebook ARM
```

Note: `ARCH` must be `arm64` and `DTB_PREFIX` must match the DTB glob prefix
for your SoC (e.g. `mt8183-kukui`, `rk3399-gru`) — this is what tells the
build workflow which device tree blobs to include in the kpart.

**Platform-level patches** (mt8183 and mt81xx patches) are automatically
pulled from the upstream hexdump0815 repo at build time — you do not need
to include those. Only add patches to `patches/<platform>/` if your device
needs something board-specific on top of the upstream set.

**Cmdline fallback order** — the build looks for cmdline files in this order:
1. `configs/cmdline/<codename>.cmdline` — your device
2. `configs/cmdline/<platform>.cmdline` — your platform
3. `configs/cmdline/chromebook-kukui.cmdline` — generic MT8183 fallback

If the generic kukui cmdline works for your board, no cmdline file is needed.

---

### What to include in a Pull Request

Whether x86_64 or ARM64, a good PR includes:

- **The config files** — `hardware_map.conf` entry + `configs/device/<codename>.cfg`
- **Board codename and full device name**
- **Kernel version tested** (from `uname -r`)
- **What works** — boot, WiFi, display, keyboard/touchpad, audio, suspend, camera
- **What doesn't work or is untested**
- **For ARM64** — which DTB was used, whether velvet-tools handled the kpart
  correctly, and whether any cmdline changes were needed

Keep the PR focused on one device. If you find a fix that helps the whole
platform (not just your board), note that in the PR description and we can
apply it to the platform config instead.

---

### Not ready to open a PR? Open an Issue instead

If you've tested a kernel on your device but aren't sure the config is
ready to merge, open an **Issue** using the *Device Support* template.
Partial reports — even just "it boots and WiFi works" — are useful for
tracking community coverage across devices.

---

### General guidelines

- Keep device configs minimal — if an option fixes something that affects
  the whole SoC family, it belongs in the platform config, not the device config
- If a config option fixes a regression, note the kernel version where it
  was introduced
- Tested-on reports in PRs and Issues are just as valuable as code changes

---

## Supported Platforms

### x86_64

| Platform config | Chromebook family | Devices | Audio notes |
|---|---|---|---|
| `stoney-ridge.cfg` | TREEYA360 | Lenovo 300e Gen2 AMD | Audio works out of box on 6.19+ |
| `amd-grunt.cfg` | GRUNT | Aleena, Barla, Careena, etc. | chromebook-linux-audio recommended |
| `amd-ryzen-zork.cfg` | ZORK | Morphius, Dalboz, Vilboz, etc. | chromebook-linux-audio recommended |
| `geminilake.cfg` | PHASER360 | Lenovo 500e Gen2, C340, etc. | chromebook-linux-audio recommended |
| `intel-braswell.cfg` | STRAGO | Gnawty, Relm, Setzer, etc. | chromebook-linux-audio recommended |
| `intel-cometlake.cfg` | HATCH | Kohaku, Helios, etc. | chromebook-linux-audio recommended |

### ARM64

| Codename | Device | SoC | Base config | Notes |
|---|---|---|---|---|
| `esche` | HP Chromebook 11MK G9 EE | MT8183 | hexdump0815 config.cbm | velvet-os + velvet-tools required |

---

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

## Credits

- [hexdump0815/kernel-config-options](https://github.com/hexdump0815/kernel-config-options) — base config approach
- [WeirdTreeThing/chromebook-linux-audio](https://github.com/WeirdTreeThing/chromebook-linux-audio) — x86 UCM/audio setup (BSD-3-Clause)
- [velvet-os/velvet-os.github.io](https://github.com/velvet-os/velvet-os.github.io) — target OS for ARM64 builds (GPL-3.0)
- [velvet-os/velvet-tools](https://github.com/velvet-os/velvet-tools) — on-device kernel management (MIT)
