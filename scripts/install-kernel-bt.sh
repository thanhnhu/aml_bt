#!/bin/bash
# Build and install the mainline hci_aml kernel driver with W155S1 support.
#
#   ./scripts/install-kernel-bt.sh
#
# This replaces the userspace aml_hciattach setup (install-w1-bt.sh): the
# controller is brought up entirely in-kernel by hci_uart.ko, so no daemon and
# no /dev/ttyS7 are involved. sdio_bt.ko is still needed - it powers the BT
# core over SDIO before the serdev driver probes.
#
# Requires: install-w1-bt.sh already run once (sdio_bt.ko + firmware in place),
# kernel headers for $(uname -r), build-essential, device-tree-compiler, curl.
set -euo pipefail

REL="$(uname -r)"
KVER="${KVER:-$(echo "${REL}" | sed 's/-.*//')}"
KERNEL_SRC="/lib/modules/${REL}/build"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-/tmp/hci-aml-build}"
FW="${FW:-aml/w1_bt_fw_uart.bin}"
BT_DT_NODE="${BT_DT_NODE:-/soc/bus@fe000000/serial@80000/bluetooth}"

[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 1; }
[ -d "${KERNEL_SRC}" ] || { echo "missing kernel headers: ${KERNEL_SRC}"; exit 1; }
[ -f "/lib/firmware/${FW}" ] || { echo "missing firmware: /lib/firmware/${FW}"; exit 1; }

BOOT_REL="$(sed -n 's/^release=//p' /boot/boot.config 2>/dev/null | tail -1)"

find_dtb() {
    local box dtb_img
    box=$(sed -n 's/^box=//p' /boot/boot.config 2>/dev/null | tail -1)
    [ -n "${box}" ] && [ -n "${BOOT_REL}" ] || return 1
    dtb_img=$(sed -n 's/^dtb_img=//p' "/boot/box-config/box-${box}.config" 2>/dev/null | tail -1)
    [ -n "${dtb_img}" ] || return 1
    echo "/boot/${dtb_img//\$\{release\}/${BOOT_REL}}"
}

if [ -n "${BOOT_REL}" ] && [ "${BOOT_REL}" != "${REL}" ]; then
    echo "WARNING: running kernel is '${REL}' but u-boot boots '${BOOT_REL}'." >&2
fi

echo "==> Fetching drivers/bluetooth from Linux v${KVER}"
# Debian kernel headers ship only Kconfig/Makefile for drivers/bluetooth, so the
# sources have to come from upstream. Must match the running kernel exactly.
rm -rf "${WORK}"; mkdir -p "${WORK}/src"
curl -fsSL -o "${WORK}/bluetooth.tar.gz" \
    "https://kernel.googlesource.com/pub/scm/linux/kernel/git/stable/linux/+archive/refs/tags/v${KVER}/drivers/bluetooth.tar.gz"
tar xzf "${WORK}/bluetooth.tar.gz" -C "${WORK}/src"

echo "==> Applying the W155S1 patch"
patch -d "${WORK}/src" -p3 --no-backup-if-mismatch < "${REPO}/kernel/hci_aml-w155s1.patch"

echo "==> Building hci_uart.ko"
# Mirror drivers/bluetooth/Makefile for the protocols this kernel enables.
{
    echo 'obj-m += hci_uart.o'
    echo -n 'hci_uart-y := hci_ldisc.o'
    for opt in SERDEV:hci_serdev H4:hci_h4 BCSP:hci_bcsp LL:hci_ll ATH3K:hci_ath \
               3WIRE:hci_h5 INTEL:hci_intel BCM:hci_bcm QCA:hci_qca \
               AG6XX:hci_ag6xx MRVL:hci_mrvl AML:hci_aml; do
        if grep -qx "CONFIG_BT_HCIUART_${opt%%:*}=y" "/boot/config-${REL}"; then
            echo -n " ${opt##*:}.o"
        fi
    done
    echo
} > "${WORK}/src/Makefile"
make -C "${KERNEL_SRC}" M="${WORK}/src" modules

echo "==> Installing hci_uart.ko"
install -D -m 644 "${WORK}/src/hci_uart.ko" "/lib/modules/${REL}/updates/hci_uart.ko"
depmod -a "${REL}"

echo "==> Patching device tree (binds the BT UART to hci_aml)"
DTB="${DTB:-$(find_dtb || true)}"
if [ -z "${DTB}" ] || [ ! -f "${DTB}" ]; then
    echo "    SKIPPED: could not locate the active DTB, set DTB=/path/to.dtb" >&2
else
    [ -f "${DTB}.orig" ] || cp "${DTB}" "${DTB}.orig"
    # The stock X96 X4 DTB declares a "realtek,rtl8822cs-bt" child here; this
    # board has a W155S1. enable-gpios/vddio-supply/lpo are reused as-is, they
    # are all aml_parse_dt() asks for.
    fdtput -t s "${DTB}" "${BT_DT_NODE}" compatible "amlogic,w155s1-bt"
    fdtput -t s "${DTB}" "${BT_DT_NODE}" firmware-name "${FW}"
    fdtput -t s "${DTB}" "${BT_DT_NODE}" status "okay"
    echo "    patched ${DTB} (backup: ${DTB}.orig)"
fi

echo "==> Switching off the userspace loader"
systemctl disable --now aml-w1-bt.service 2>/dev/null || true
# hci_aml talks to a chip the SDIO side has already powered up.
grep -qx sdio_bt /etc/modules || echo sdio_bt >> /etc/modules

echo
echo "Done - reboot, then check:  dmesg | grep fw_version"
