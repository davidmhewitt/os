#!/bin/bash

set -e

rootdir=`pwd`
basedir=`pwd`/pinebook-pro

mkdir -p ${basedir}
cd ${basedir}

export DEBIAN_FRONTEND="noninteractive"

apt-get update
apt-get install -y --no-install-recommends python3 bzip2 wget gcc-arm-none-eabi crossbuild-essential-arm64 make bison flex bc device-tree-compiler ca-certificates build-essential

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
make PLAT=rk3399
cp build/rk3399/release/bl31/bl31.elf ../u-boot-${ubootver}/

cd ../u-boot-${pkgver}
ls

