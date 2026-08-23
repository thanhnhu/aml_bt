#!/bin/bash
# Install prebuilt aml_w1 Bluetooth support from a release tarball.
# Run as root:  sudo ./install.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REL="$(uname -r)"
TARGET_KVER="$(cat "${DIR}/KERNEL_VERSION" 2>/dev/null || true)"
BT_UART="${BT_UART:-$(cat "${DIR}/BT_UART" 2>/dev/null || echo /dev/ttyS7)}"
# DT path of the UART the BT chip is wired to (uart_E on SC2/S905X4).
BT_DT_NODE="${BT_DT_NODE:-/soc/bus@fe000000/serial@80000/bluetooth}"

[ "$(id -u)" -eq 0 ] || { echo "Please run as root: sudo ./install.sh" >&2; exit 1; }

if [ -n "${TARGET_KVER}" ] && [ "${TARGET_KVER}" != "${REL}" ]; then
  echo "WARNING: sdio_bt.ko was built for kernel '${TARGET_KVER}'"
  echo "         but you are running '${REL}'."
  echo "         It will almost certainly fail to load. Build from source instead."
  printf "Continue anyway? [y/N] "
  read -r ans
  case "${ans}" in y|Y) ;; *) echo "Aborted."; exit 1 ;; esac
fi

if ! lsmod | grep -q '^aml_sdio'; then
  echo "ERROR: the aml_w1 WiFi driver (aml_sdio.ko) is not loaded." >&2
  echo "       Install https://github.com/thanhnhu/wifi-amlogic-w1 first." >&2
  exit 1
fi

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
    echo "         sdio_bt.ko only loads on '${REL}'; it will be missing after a reboot." >&2
fi

echo "==> Patching device tree (frees the BT UART from the serdev bus)"
NEED_REBOOT=0
DTB="${DTB:-$(find_dtb || true)}"
if [ -z "${DTB}" ] || [ ! -f "${DTB}" ]; then
    echo "    SKIPPED: could not locate the active DTB, set DTB=/path/to.dtb" >&2
elif [ "$(fdtget -t s "${DTB}" "${BT_DT_NODE}" status 2>/dev/null || true)" = "disabled" ]; then
    echo "    already patched: ${DTB}"
else
    [ -f "${DTB}.orig" ] || cp "${DTB}" "${DTB}.orig"
    fdtput -t s "${DTB}" "${BT_DT_NODE}" status disabled
    dtc -I dtb -O dts "${DTB}" > /dev/null
    echo "    patched ${DTB} (backup: ${DTB}.orig)"
    NEED_REBOOT=1
fi

echo "==> Installing sdio_bt.ko"
install -d "/lib/modules/${REL}/kernel/drivers/net/wireless" "/lib/modules/${REL}/aml"
install -m 644 "${DIR}/sdio_bt.ko" "/lib/modules/${REL}/kernel/drivers/net/wireless/"
depmod -a
# aml_hciattach looks for the modules under /lib/modules/*/aml
ln -sf "/lib/modules/${REL}/kernel/drivers/net/wireless/aml_sdio.ko" "/lib/modules/${REL}/aml/aml_sdio.ko"
ln -sf "/lib/modules/${REL}/kernel/drivers/net/wireless/sdio_bt.ko"  "/lib/modules/${REL}/aml/sdio_bt.ko"

echo "==> Installing aml_hciattach, firmware and config"
install -m 755 "${DIR}/aml_hciattach" /usr/local/sbin/aml_hciattach
install -d /lib/firmware/aml /etc/bluetooth/aml
install -m 644 "${DIR}/firmware/w1_bt_fw_uart.bin"  /lib/firmware/aml/
install -m 644 "${DIR}/firmware/aml_bt_rf.txt"      /lib/firmware/aml/
install -m 644 "${DIR}/firmware/a2dp_mode_cfg.txt"  /lib/firmware/aml/
install -m 644 "${DIR}/firmware/aml_bt.conf"        /lib/firmware/aml/

echo "==> Installing systemd service"
sed "s|@BT_UART@|${BT_UART}|" "${DIR}/aml-w1-bt.service" > /etc/systemd/system/aml-w1-bt.service
systemctl daemon-reload
systemctl enable aml-w1-bt.service

echo
if [ "${NEED_REBOOT}" -eq 1 ]; then
    echo "Done. Reboot to apply the device-tree patch, then check:  hciconfig -a"
else
    systemctl restart aml-w1-bt.service
    echo "Done. Check the adapter with:  hciconfig -a"
fi
