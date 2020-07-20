#!/bin/bash

set -e

rootdir=`pwd`
basedir=`pwd`/pinebook-pro

mkdir -p ${basedir}
cd ${basedir}

export DEBIAN_FRONTEND="noninteractive"

apt-get update
apt-get install -y --no-install-recommends python3 bzip2 wget gcc-arm-none-eabi crossbuild-essential-arm64 make bison flex bc device-tree-compiler ca-certificates sed build-essential debootstrap qemu-user-static qemu-utils qemu-system-arm binfmt-support parted kpartx rsync

tfaver=2.3
ubootver=2020.07

wget "https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git/snapshot/trusted-firmware-a-$tfaver.tar.gz"
wget "ftp://ftp.denx.de/pub/u-boot/u-boot-${ubootver}.tar.bz2"

echo "37f917922bcef181164908c470a2f941006791c0113d738c498d39d95d543b21 trusted-firmware-a-${tfaver}.tar.gz" | sha256sum --check
echo "c1f5bf9ee6bb6e648edbf19ce2ca9452f614b08a9f886f1a566aa42e8cf05f6a u-boot-${ubootver}.tar.bz2" | sha256sum --check

tar xf "trusted-firmware-a-${tfaver}.tar.gz"
tar xf "u-boot-${ubootver}.tar.bz2"
cd "trusted-firmware-a-${tfaver}"
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
CROSS_COMPILE=aarch64-linux-gnu- make PLAT=rk3399
cp build/rk3399/release/bl31/bl31.elf ../u-boot-${ubootver}/

cd ../u-boot-${ubootver}

patch -Np1 -i "${rootdir}/pinebookpro/patches/uboot/0001-Add-regulator-needed-for-usage-of-USB.patch"
patch -Np1 -i "${rootdir}/pinebookpro/patches/uboot/0002-Correct-boot-order-to-be-USB-SD-eMMC.patch"
patch -Np1 -i "${rootdir}/pinebookpro/patches/uboot/0003-rk3399-light-pinebook-power-and-standby-leds-during-early-boot.patch"
sed -i s/"CONFIG_BOOTDELAY=3"/"CONFIG_BOOTDELAY=0"/g configs/pinebook-pro-rk3399_defconfig

unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
CROSS_COMPILE=aarch64-linux-gnu- make pinebook-pro-rk3399_defconfig
echo 'CONFIG_IDENT_STRING=" elementary ARM"' >> .config
CROSS_COMPILE=aarch64-linux-gnu- make

cd "${basedir}"

# Make sure cross-running ARM ELF executables is enabled
update-binfmts --enable

export packages="elementary-minimal"
export architecture="arm64"
export codename="focal"
export channel="daily"

# Bootstrap an ubuntu minimal system
debootstrap --foreign --arch $architecture $codename elementary-$architecture http://ports.ubuntu.com/ubuntu-ports

# Add the QEMU emulator for running ARM executables
cp /usr/bin/qemu-arm-static elementary-$architecture/usr/bin/

# Run the second stage of the bootstrap in QEMU
LANG=C chroot elementary-$architecture /debootstrap/debootstrap --second-stage

