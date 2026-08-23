#!/bin/bash
# Build and install Bluetooth support for the Amlogic W155S1 (aml_w1, chip 0x8888)
# on a mainline/Debian arm64 kernel. Run natively on the TV box as root.
#
#   ./scripts/install-w1-bt.sh
#
# Re-run it after every kernel update: the new kernel ships its own (unpatched)
# DTB and needs sdio_bt.ko rebuilt against its headers.
#
# Requires: the aml_w1 WiFi driver (aml_sdio.ko + vlsicomm.ko) already working,
# kernel headers for $(uname -r), build-essential, device-tree-compiler.
set -euo pipefail

REL="$(uname -r)"
KERNEL_SRC="/lib/modules/${REL}/build"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Amlogic vendor drop, kept unmodified apart from the mainline port patches.
SRC="${REPO}/aml_bt"
BT_UART="${BT_UART:-/dev/ttyS7}"
# DT path of the UART the BT chip is wired to (uart_E on SC2/S905X4).
BT_DT_NODE="${BT_DT_NODE:-/soc/bus@fe000000/serial@80000/bluetooth}"

[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 1; }
[ -d "${KERNEL_SRC}" ] || { echo "missing kernel headers: ${KERNEL_SRC}"; exit 1; }

# Resolve the DTB u-boot actually loads: /boot/boot.config picks the box config,
# which in turn defines dtb_img (containing a literal ${release}).
BOOT_REL="$(sed -n 's/^release=//p' /boot/boot.config 2>/dev/null | tail -1)"

find_dtb() {
    local box dtb_img
    box=$(sed -n 's/^box=//p' /boot/boot.config 2>/dev/null | tail -1)
    [ -n "${box}" ] && [ -n "${BOOT_REL}" ] || return 1
    dtb_img=$(sed -n 's/^dtb_img=//p' "/boot/box-config/box-${box}.config" 2>/dev/null | tail -1)
    [ -n "${dtb_img}" ] || return 1
    echo "/boot/${dtb_img//\$\{release\}/${BOOT_REL}}"
}

# These boxes keep several kernels installed, each with its own DTB tree.
if [ -n "${BOOT_REL}" ] && [ "${BOOT_REL}" != "${REL}" ]; then
    echo "WARNING: running kernel is '${REL}' but u-boot boots '${BOOT_REL}'." >&2
    echo "         sdio_bt.ko is being built for '${REL}' and will not load after" >&2
    echo "         a reboot. Boot into '${REL}' first, or re-run this there." >&2
fi

echo "==> Patching device tree (frees the BT UART from the serdev bus)"
DTB="${DTB:-$(find_dtb || true)}"
if [ -z "${DTB}" ] || [ ! -f "${DTB}" ]; then
    echo "    SKIPPED: could not locate the active DTB, set DTB=/path/to.dtb" >&2
elif [ "$(fdtget -t s "${DTB}" "${BT_DT_NODE}" status 2>/dev/null || true)" = "disabled" ]; then
    echo "    already patched: ${DTB}"
else
    # The stock X96 X4 DTB declares a "realtek,rtl8822cs-bt" serdev child on the
    # BT UART, which stops a /dev/ttyS* node from being created. This board has
    # an Amlogic W155S1 instead, driven from userspace over a plain tty.
    [ -f "${DTB}.orig" ] || cp "${DTB}" "${DTB}.orig"
    fdtput -t s "${DTB}" "${BT_DT_NODE}" status disabled
    dtc -I dtb -O dts "${DTB}" > /dev/null
    echo "    patched ${DTB} (backup: ${DTB}.orig) - reboot required"
fi

echo "==> Building sdio_bt.ko"
make -C "${SRC}/sdio_driver_bt" clean >/dev/null 2>&1 || true
# aml_sdio.ko comes from the WiFi driver; without its Module.symvers the
# cross-module symbols are resolved at load time (CONFIG_MODVERSIONS is off).
make -C "${SRC}/sdio_driver_bt" KERNEL_SRC="${KERNEL_SRC}" KBUILD_MODPOST_WARN=1

echo "==> Installing sdio_bt.ko"
install -d "/lib/modules/${REL}/kernel/drivers/net/wireless" "/lib/modules/${REL}/aml"
install -m 644 "${SRC}/sdio_driver_bt/sdio_bt.ko" "/lib/modules/${REL}/kernel/drivers/net/wireless/"
depmod -a
# aml_hciattach looks for the modules under /lib/modules/*/aml
ln -sf "/lib/modules/${REL}/kernel/drivers/net/wireless/aml_sdio.ko" "/lib/modules/${REL}/aml/aml_sdio.ko"
ln -sf "/lib/modules/${REL}/kernel/drivers/net/wireless/sdio_bt.ko"  "/lib/modules/${REL}/aml/sdio_bt.ko"

echo "==> Building aml_hciattach for ${BT_UART}"
make -C "${SRC}/aml_hciattach" clean >/dev/null
make -C "${SRC}/aml_hciattach" \
    CFLAGS="-Wall -O2 -Wno-unused-function -Wunused-result -Wno-unused-variable -DUART_DEV_PORT_BT=\\\"${BT_UART}\\\""
install -m 755 "${SRC}/aml_hciattach/aml_hciattach" /usr/local/sbin/aml_hciattach

echo "==> Installing firmware and config"
install -d /lib/firmware/aml /etc/bluetooth/aml
install -m 644 "${SRC}/firmware/w1_bt_fw_uart.bin"      /lib/firmware/aml/
install -m 644 "${SRC}/aml_hciattach/aml_bt_rf.txt"     /lib/firmware/aml/
install -m 644 "${SRC}/aml_hciattach/a2dp_mode_cfg.txt" /lib/firmware/aml/
install -m 644 "${SRC}/aml_hciattach/aml_bt.conf"       /lib/firmware/aml/

echo "==> Installing systemd service"
sed "s|@BT_UART@|${BT_UART}|" "${REPO}/scripts/aml-w1-bt.service" \
    > /etc/systemd/system/aml-w1-bt.service
systemctl daemon-reload
systemctl enable aml-w1-bt.service

echo
echo "Done. If the DTB was just patched, reboot; otherwise start now with:"
echo "    systemctl start aml-w1-bt.service && hciconfig -a"
