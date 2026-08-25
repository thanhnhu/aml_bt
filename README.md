# Amlogic W155S1 Bluetooth (aml_w1 / 0x8888)

Bluetooth support for the Amlogic W155S1 (chip ID `0x8888`) combo chip on mainline Linux —
the BT half of the WiFi chip driven by [wifi-amlogic-w1](https://github.com/thanhnhu/wifi-amlogic-w1).

## How it works

The W155S1 is a combo die: the Bluetooth core shares the chip's power management with WiFi, but
speaks HCI over a **separate UART**. So two pieces are needed:

| Piece | What it does |
|-------|--------------|
| `sdio_bt.ko` | Powers up the BT core by poking the chip's PMU registers **over the WiFi SDIO link**. Needs `aml_sdio.ko` from the WiFi driver loaded first. |
| `aml_hciattach` | Userspace tool: downloads `w1_bt_fw_uart.bin` to the BT core over the UART, then attaches the port to the kernel's `hci_uart` line discipline. |

```
aml_sdio.ko ──SDIO──> [ W155S1 : WiFi core | BT core ]
                                              │
sdio_bt.ko  ──SDIO──> PMU power-on            │ UART (uart_E)
                                              ▼
aml_hciattach ──/dev/ttyS7──> firmware download ──> hci0
```

> Since Linux 6.13 the kernel has its own driver for this family (`hci_aml`), which replaces
> `aml_hciattach` entirely. It needs a one-line patch to support the W155S1 — see
> [section VIII](#viii-kernel-driver-no-userspace-loader).

## Compatibility

### Kernels

| Kernel | Status |
|--------|--------|
| 4.14 – 5.15 | Original target (Amlogic Android/BSP kernels) |
| 6.x — mainline | Supported (symbol names, serdev/DT, `platform_driver.remove` signature) |
| 6.18.40-meson64 ([devmfc/debian-on-amlogic](https://github.com/devmfc/debian-on-amlogic)) | **Tested OK** — BLE + Classic scanning. This is what the [prebuilt release](../../releases) targets |
| 6.12.30-meson64 (same image) | Builds cleanly in CI, **not tested on hardware**. No prebuilt release — [build it yourself](#build-a-release-manually-github-actions) |

> **Modules are locked to one exact kernel.** `sdio_bt.ko` only loads on the `uname -r` it was
> built against. The devmfc images ship several kernels side by side, each with **its own DTB
> tree** (`/boot/dtb-<version>/`), so the device-tree patch is per-kernel too. Switching the
> kernel means re-running the installer under it — the scripts warn if the running kernel differs
> from the one `release=` in `/boot/boot.config` selects.

### Devices (TV boxes)

Same hardware scope as the WiFi driver — any box whose combo chip is the **W155S1 / W155S2
(chip ID `0x8888`)**:

| TV box | SoC | Status |
|--------|-----|--------|
| Magicsee N5 Max X4 | S905X4 (SC2) | **Tested OK** — BT 5.0, `hci0` on uart_E, BLE + Classic scanning |
| X96 Max+ / X96 Max Plus (X4 variants) | S905X4 | Expected to work (same W155S1 module) |
| Other S905X4 / S905X2 / S922X boxes | S905X4, S905X2, S922X | Expected to work if the chip ID is `0x8888`; the BT UART node may differ |

**Check your device before building:**

```bash
# Vendor/device of the SDIO card - must be 0x8888 / 0x8888
cat /sys/bus/sdio/devices/*/{vendor,device} 2>/dev/null
```

> **Note on the Magicsee N5 Max X4:** devmfc/debian-on-amlogic has no dedicated box config for it,
> so it runs `box=x96x4` — i.e. it boots `meson-sc2-x96x4.dtb`. That is the DTB the installer
> patches, and it is also why the DTB declares a Realtek BT chip that this board does not have
> (see [section V](#v-why-the-device-tree-needs-patching)). If your box uses a different
> `box=` config, the installer follows it automatically.

**Prerequisite:** the [aml_w1 WiFi driver](https://github.com/thanhnhu/wifi-amlogic-w1) must already
be installed and working. `sdio_bt.ko` links against symbols exported by its `aml_sdio.ko`.

---

## Quick install (prebuilt release)

If a [release](../../releases) exists for **your exact kernel version** (`uname -r`):

```bash
tar xzf aml-w1-bt-<kernel-version>.tar.gz
cd aml-w1-bt-<kernel-version>
sudo ./install.sh
sudo reboot        # only the first time, to apply the device-tree patch
hciconfig -a
```

`install.sh` patches the DTB, installs the module + firmware + `aml_hciattach`, and enables the
systemd service that brings `hci0` up on every boot.

> The `.ko` file only loads on the **exact** kernel it was built for. If there is no release for
> your `uname -r`, build from source below.

---

## I. Get the source

```bash
git clone https://github.com/thanhnhu/aml_bt.git
cd aml_bt
```

## II. Install build dependencies

```bash
sudo apt install build-essential device-tree-compiler bluez
# Kernel headers: see the WiFi driver README, section II
sudo apt install linux-headers-$(uname -r)     # or the devmfc .deb for meson64 kernels
```

## III. Build and install

```bash
sudo ./scripts/install-w1-bt.sh
sudo reboot        # only the first time, to apply the device-tree patch
```

The script is idempotent — re-run it any time. It:

1. Finds the DTB u-boot loads (from `/boot/boot.config` + `box-config/`) and disables the bogus
   Bluetooth serdev child on the BT UART (see [section V](#v-why-the-device-tree-needs-patching)).
2. Builds and installs `sdio_bt.ko`.
3. Builds `aml_hciattach` for the right tty and installs it to `/usr/local/sbin`.
4. Installs firmware to `/lib/firmware/aml/`.
5. Installs and enables `aml-w1-bt.service`.

Override the defaults if your box differs:

```bash
sudo BT_UART=/dev/ttyS7 \
     BT_DT_NODE=/soc/bus@fe000000/serial@80000/bluetooth \
     DTB=/boot/dtb-$(uname -r)/amlogic/meson-sc2-x96x4.dtb \
     ./scripts/install-w1-bt.sh
```

## IV. Verify

```bash
systemctl status aml-w1-bt
hciconfig -a                       # hci0 should be UP RUNNING
timeout 12 btmgmt find             # BLE scan
timeout 15 hcitool scan --flush    # Classic inquiry
bluetoothctl                       # pair a device
```

Expected:

```
hci0:   Type: Primary  Bus: UART
        BD Address: 22:22:xx:xx:xx:xx  ACL MTU: 1021:8  SCO MTU: 120:10
        UP RUNNING
        HCI Version: 5.0 (0x9)  Manufacturer: not assigned (3205)
```

The BD address is generated on first run and persisted in `/etc/bluetooth/aml/bt_addr`, so it is
stable across reboots.

---

## V. Why the device tree needs patching

Stock TV-box DTBs assume a Realtek combo chip and declare a serdev child on the BT UART. On the
Magicsee N5 Max X4 (running `box=x96x4`, i.e. `meson-sc2-x96x4.dtb`):

```dts
serial@80000 {                       /* uart_E, has RTS/CTS */
        status = "okay";
        bluetooth {
                compatible = "realtek,rtl8822cs-bt";
                ...
        };
};
```

That child binds the port to the **serdev bus**, so no `/dev/ttyS*` node is created and
`aml_hciattach` has nothing to open. This board carries an Amlogic W155S1, not an RTL8822CS, so the
node is wrong anyway. Setting `status = "disabled"` on it makes `meson_uart` register a plain
`ttyS7` instead.

`install-w1-bt.sh` does this with `fdtput` and keeps a `.orig` backup next to the DTB. To revert:

```bash
sudo cp /boot/dtb-$(uname -r)/amlogic/meson-sc2-x96x4.dtb.orig \
        /boot/dtb-$(uname -r)/amlogic/meson-sc2-x96x4.dtb
```

> A DT **overlay** (`dts/aml-w1-bt-uart.dts`) is provided and is the cleaner mechanism, but the
> stock Amlogic u-boot on these boxes silently fails to `fdt apply` it. It is kept for boards
> running mainline u-boot.

---

## VI. After a kernel update

A new kernel ships its own unpatched DTB and needs the module rebuilt. Re-run:

```bash
sudo ./scripts/install-w1-bt.sh && sudo reboot
```

Until then `hci0` is simply absent — the service is skipped via `ConditionPathExists`, so it does
not restart-loop and **boot is unaffected**. (WiFi needs rebuilding too; see its README.)

---

## VII. Changes made to the Amlogic vendor drop

Everything under `aml_bt/` is the vendor source; only these were touched to make it build and run
on a mainline kernel:

| File | Change |
|------|--------|
| `sdio_driver_bt/bt_hal_plateform.h` | Map the vendor's `w1_`-prefixed symbol names onto the unprefixed ones exported by the mainline WiFi driver |
| `sdio_driver_bt/bt_hal_plateform.c` | Drop `MODULE_IMPORT_NS(W1-AML)`; bound four unlimited chip-handshake loops (one spun while holding the WiFi SDIO power lock, which could wedge the system) |
| `sdio_driver_bt/Makefile` | Don't rebuild `aml_sdio.o` (the WiFi driver provides it); `$(PWD)` → `$(CURDIR)` |
| `aml_hciattach/aml_multibt.c` | Missing Amlogic-BSP `btpower_evt` sysfs node is no longer fatal — `sdio_bt.ko` handles power instead |

`scripts/` and `dts/` at the repository root are not part of the vendor drop.

---

## VIII. Kernel driver (no userspace loader)

Mainline `drivers/bluetooth/hci_aml.c` (Linux 6.13+) does everything `aml_hciattach` does, in
kernel space: firmware download, RF config, chip start, `hci0`. It ships support for the W155S2 and
W265S2 but not the **W155S1** — and with the W155S2 settings the W155S1 dies right after the
firmware download:

```
Bluetooth: hci0: command 0xfc1a tx timeout
Bluetooth: hci0: Failed to get fw version (error: -110)
```

Everything else matches: same TCI opcodes, same register map, same `[8B header][ICCM][DCCM]`
firmware layout, same 256 KB ICCM offset. The only difference is how long the controller CPU takes
to boot after the hardware reset — **600 ms on the W155S1, against the 60 ms `aml_setup()` waits**.
Amlogic's own loader waits exactly 600 ms at the same point (`MAC_DELAY` in `hciattach_aml.c`).

`kernel/hci_aml-w155s1.patch` turns that wait into per-device data and adds an
`amlogic,w155s1-bt` compatible.

```bash
sudo ./scripts/install-kernel-bt.sh
sudo reboot
dmesg | grep fw_version        # Bluetooth: hci0: fw_version: date = 52.26, number = 0x7458
```

The script fetches `drivers/bluetooth` for your exact kernel version from upstream (Debian headers
ship only its `Kconfig`/`Makefile`), applies the patch, builds `hci_uart.ko` against the protocols
your kernel enables, installs it to `/lib/modules/$(uname -r)/updates/`, repoints the DTB node at
`amlogic,w155s1-bt`, and disables `aml-w1-bt.service`.

`sdio_bt.ko` is still required — it powers the BT core over SDIO before the serdev driver probes —
so run `install-w1-bt.sh` first. The DT node needs `enable-gpios`, `firmware-name`, `vddio-supply`
and an `lpo` clock; the stock Realtek node already provides all but `firmware-name`.

**Tested on 6.18.40-meson64 / Magicsee N5 Max X4:** `hci0` up with a real BD address, Classic +
BLE scanning, A2DP playback to a Bluetooth speaker, zero `tx timeout`s.

To go back to the userspace loader:

```bash
sudo rm /lib/modules/$(uname -r)/updates/hci_uart.ko && sudo depmod -a
sudo sed -i '/^sdio_bt$/d' /etc/modules
sudo ./scripts/install-w1-bt.sh && sudo reboot
```

> Re-pairing is needed when switching either way: the two paths derive different BD addresses, so
> BlueZ sees a different adapter and starts with an empty pairing database.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `/dev/ttyS7` missing | DTB not patched, or it was replaced by a kernel update — re-run `install-w1-bt.sh` and reboot |
| `Initialization timed out` in the log | BT core already running FW. The service power-cycles it via `modprobe -r sdio_bt` on start; do the same manually |
| `Can't find WiFi driver path: /lib/modules/*/aml` | The symlink dir is missing — re-run `install-w1-bt.sh` |
| `modpost: "g_w1_hif_ops" undefined` when building | Expected. `CONFIG_MODVERSIONS` is off, so these resolve at load time. Set `EXTRA_SYMBOLS_PATH` to the WiFi driver's `Module.symvers` to silence it |
| `hci0` present but won't scan | Check `rfkill list`, and that `bluetooth.service` is running |

Logs:

```bash
journalctl -u aml-w1-bt -b
dmesg | grep btHAL
```

---

## Build a release manually (GitHub Actions)

The published release targets **6.18.40-meson64** and is built automatically when a `v*` git tag is
pushed. To build for a *different* kernel that has no release yet, trigger the workflow by hand —
the example below uses `6.12.30-meson64`, the other kernel devmfc images ship:

1. Repo → **Actions** tab → **Build and Release** → **Run workflow**.
2. Fill in:
   - **kernel_version** — the target `uname -r`, e.g. `6.12.30-meson64`.
   - **headers_deb_url** — URL of the matching `linux-headers` `.deb` from the
     [devmfc/debian-on-amlogic releases](https://github.com/devmfc/debian-on-amlogic/releases).
   - **bt_uart** — the tty the BT UART shows up as (default `/dev/ttyS7`).
   - **release_tag** — leave **empty** to only get a downloadable artifact, or set a tag
     (e.g. `v6.12.30-meson64-1`) to publish a **Release** as well.

Or with the GitHub CLI:

```bash
gh workflow run build-release.yml \
  -f kernel_version=6.12.30-meson64 \
  -f headers_deb_url=https://github.com/devmfc/debian-on-amlogic/releases/download/v6.12.30/linux-headers-6.12.30-meson64_20250522_arm64.deb \
  -f bt_uart=/dev/ttyS7 \
  -f release_tag=v6.12.30-meson64-1   # omit this flag to skip publishing a release
```
