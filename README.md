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

## Compatibility

### Kernels

| Kernel | Status |
|--------|--------|
| 4.14 – 5.15 | Original target (Amlogic Android/BSP kernels) |
| 6.x — mainline | Supported (symbol names, serdev/DT, `platform_driver.remove` signature) |
| 6.18.40-meson64 ([devmfc/debian-on-amlogic](https://github.com/devmfc/debian-on-amlogic)) | **Tested OK** — BLE + Classic scanning |
| 6.12.30-meson64 (same image) | Builds, untested |

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
git clone https://github.com/thanhnhu/aml-bt-amlogic-w1.git
cd aml-bt-amlogic-w1
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
