#!/bin/bash

set -e

# Size of .img file to build in MB.
size=7500

rootdir=`pwd`
basedir=`pwd`/pinebook-pro

mkdir -p ${basedir}
cd ${basedir}

export DEBIAN_FRONTEND="noninteractive"

apt-get update
apt-get install -y --no-install-recommends python3 bzip2 wget gcc-arm-none-eabi crossbuild-essential-arm64 make bison flex bc device-tree-compiler ca-certificates sed build-essential debootstrap qemu-user-static qemu-utils qemu-system-arm binfmt-support parted kpartx rsync git libssl-dev xz-utils

tfaver=2.3
ubootver=2020.07
imagename=elementary-pbp

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

export packages="elementary-minimal elementary-desktop elementary-standard initramfs-tools"
export architecture="arm64"
export codename="focal"
export channel="daily"

# Working directory
work_dir="${basedir}/elementary-${architecture}"

# Bootstrap an ubuntu minimal system
debootstrap --foreign --arch $architecture $codename elementary-$architecture http://ports.ubuntu.com/ubuntu-ports

# Add the QEMU emulator for running ARM executables
cp /usr/bin/qemu-arm-static elementary-$architecture/usr/bin/

# Run the second stage of the bootstrap in QEMU
LANG=C chroot elementary-$architecture /debootstrap/debootstrap --second-stage

# Add the rest of the ubuntu repos
cat << EOF > elementary-$architecture/etc/apt/sources.list
deb http://ports.ubuntu.com/ubuntu-ports $codename main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $codename-updates main restricted universe multiverse
EOF

# Copy in the elementary PPAs/keys/apt config
for f in ${rootdir}/etc/config/archives/*.list; do cp -- "$f" "elementary-$architecture/etc/apt/sources.list.d/$(basename -- $f)"; done
for f in ${rootdir}/etc/config/archives/*.key; do cp -- "$f" "elementary-$architecture/etc/apt/trusted.gpg.d/$(basename -- $f).asc"; done
for f in ${rootdir}/etc/config/archives/*.pref; do cp -- "$f" "elementary-$architecture/etc/apt/preferences.d/$(basename -- $f)"; done

# Set codename/channel in added repos
sed -i "s/@CHANNEL/$channel/" elementary-$architecture/etc/apt/sources.list.d/*.list*
sed -i "s/@BASECODENAME/$codename/" elementary-$architecture/etc/apt/sources.list.d/*.list*

echo "elementary" > elementary-$architecture/etc/hostname

cat << EOF > elementary-${architecture}/etc/hosts
127.0.0.1       elementary    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

mount -t proc proc elementary-$architecture/proc
mount -o bind /dev/ elementary-$architecture/dev/
mount -o bind /dev/pts elementary-$architecture/dev/pts

# Make a third stage that installs all of the metapackages
cat << EOF > elementary-$architecture/third-stage
#!/bin/bash
apt-get update
apt-get --yes upgrade
apt-get --yes install $packages
rm -f /third-stage
EOF

chmod +x elementary-$architecture/third-stage
LANG=C chroot elementary-$architecture /third-stage

# Pull in the wifi and bluetooth firmware from manjaro's git repository.
git clone https://gitlab.manjaro.org/manjaro-arm/packages/community/ap6256-firmware.git
cd ap6256-firmware
mkdir brcm
cp BCM4345C5.hcd brcm/BCM.hcd
cp BCM4345C5.hcd brcm/BCM4345C5.hcd
cp nvram_ap6256.txt brcm/brcmfmac43456-sdio.pine64,pinebook-pro.txt
cp fw_bcm43456c5_ag.bin brcm/brcmfmac43456-sdio.bin
cp brcmfmac43456-sdio.clm_blob brcm/brcmfmac43456-sdio.clm_blob
mkdir -p ${work_dir}/lib/firmware/brcm/
cp -a brcm/* ${work_dir}/lib/firmware/brcm/

# Time to build the kernel
cd ${work_dir}/usr/src
git clone https://gitlab.manjaro.org/tsys/linux-pinebook-pro.git --depth 1 linux
cd linux
touch .scmversion
patch -p1 --no-backup-if-mismatch < ${rootdir}/pinebookpro/patches/kernel/0001-net-smsc95xx-Allow-mac-address-to-be-set-as-a-parame.patch
patch -p1 --no-backup-if-mismatch < ${rootdir}/pinebookpro/patches/kernel/0008-board-rockpi4-dts-upper-port-host.patch
patch -p1 --no-backup-if-mismatch < ${rootdir}/pinebookpro/patches/kernel/0008-rk-hwacc-drm.patch
cp ${rootdir}/pinebookpro/config/kernel/pinebook-pro-5.7.config .config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=${work_dir} modules_install
cp arch/arm64/boot/Image ${work_dir}/boot
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_DTBS_PATH="${work_dir}/boot/dtbs" dtbs_install
# clean up because otherwise we leave stuff around that causes external modules
# to fail to build.
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- mrproper
cp ${rootdir}/pinebookpro/config/kernel/pinebook-pro-5.7.config .config

# Fix up the symlink for building external modules
# kernver is used to we don't need to keep track of what the current compiled
# version is
kernver=$(ls ${work_dir}/lib/modules)
cd ${work_dir}/lib/modules/${kernver}/
rm build
rm source
ln -s /usr/src/linux build
ln -s /usr/src/linux source
cd ${basedir}

# Build the initramfs for our kernel
cat << EOF > elementary-$architecture/build-initramfs
#!/bin/bash
update-initramfs -c -k ${kernver}
rm -f /build-initramfs
EOF

chmod +x elementary-$architecture/build-initramfs
LANG=C chroot elementary-$architecture /build-initramfs

# Create the disk and partition it
echo "Creating image file"
dd if=/dev/zero of=${basedir}/${imagename}.img bs=1M count=$size
parted ${imagename}.img --script -- mklabel msdos
parted ${imagename}.img --script -- mkpart primary ext3 32M 100%

# Set the partition variables
loopdevice=`losetup -f --show "${basedir}"/${imagename}.img`
device=`kpartx -va ${loopdevice} | sed 's/.*\(loop[0-9]\+\)p.*/\1/g' | head -1`
sleep 5
device="/dev/mapper/${device}"
rootp=${device}p1

# Create file systems
mkfs.ext3 ${rootp}

# Create the dirs for the partitions and mount them
mkdir -p "${basedir}"/root
mount ${rootp} "${basedir}"/root

# Create an fstab so that we don't mount / read-only.
UUID=$(blkid -s UUID -o value ${rootp})
echo "UUID=$UUID /               ext3    errors=remount-ro 0       1" >> "${basedir}"/elementary-${architecture}/etc/fstab

mkdir ${work_dir}/boot/extlinux/

cat << EOF > ${work_dir}/boot/extlinux/extlinux.conf
LABEL elementary ARM
KERNEL /boot/Image
FDT /boot/dtbs/rockchip/rk3399-pinebook-pro.dtb
APPEND initrd=/boot/initrd.img-${kernver} console=tty1 console=ttyS2,1500000 root=UUID=${UUID} rw rootwait video=eDP-1:1920x1080@60 video=HDMI-A-1:1920x1080@60
EOF
cd ${basedir}

mkdir -p ${work_dir}/etc/udev/hwdb.d/
cat << EOF > ${work_dir}/etc/udev/hwdb.d/10-usb-kbd.hwdb
evdev:input:b0003v258Ap001E*
  KEYBOARD_KEY_700a5=brightnessdown
  KEYBOARD_KEY_700a6=brightnessup
  KEYBOARD_KEY_70066=sleep
EOF

cat << EOF > elementary-$architecture/cleanup
#!/bin/bash

apt-get install --no-install-recommends -f -q -y git
git clone --depth 1 https://github.com/elementary/seeds.git --single-branch --branch $codename
git clone --depth 1 https://github.com/elementary/platform.git --single-branch --branch $codename
for package in \$(cat 'platform/blacklist' 'seeds/blacklist' | grep -v '#'); do
    apt-get autoremove --purge -f -q -y "\$package"
done
apt-get autoremove --purge -f -q -y git
rm -R ../seeds ../platform
rm -rf /root/.bash_history
apt-get clean
rm -f /0
rm -f /hs_err*
rm -f /cleanup
rm -f /usr/bin/qemu*
rm -f /var/lib/apt/lists/*_Packages
rm -f /var/lib/apt/lists/*_Sources
rm -f /var/lib/apt/lists/*_Translation-*
EOF

chmod +x elementary-$architecture/cleanup
LANG=C chroot elementary-$architecture /cleanup

umount elementary-$architecture/dev/pts
umount elementary-$architecture/dev/
umount elementary-$architecture/proc

echo "Rsyncing rootfs into image file"
rsync -HPavz -q "${basedir}"/elementary-${architecture}/ "${basedir}"/root/

cp "${basedir}"/u-boot-"${ubootver}"/idbloader.img "${basedir}"/u-boot-"${ubootver}"/u-boot.itb "${basedir}"/root/boot/
dd if="${basedir}"/u-boot-"${ubootver}"/idbloader.img of=${loopdevice} seek=64 conv=notrunc
dd if="${basedir}"/u-boot-"${ubootver}"/u-boot.itb of=${loopdevice} seek=16384 conv=notrunc

# Unmount partitions
sync
umount ${rootp}

kpartx -dv ${loopdevice}
losetup -d ${loopdevice}

echo "Compressing ${imagename}.img"
xz -z "${basedir}"/${imagename}.img

cd "${rootdir}"

KEY="$1"
SECRET="$2"
ENDPOINT="$3"
BUCKET="$4"
IMGPATH="${basedir}"/${imagename}.img.xz
IMGNAME=$(basename "$IMGPATH")

apt-get install -y curl python3 python3-distutils

curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
python3 get-pip.py
pip install boto3

python3 upload.py "$KEY" "$SECRET" "$ENDPOINT" "$BUCKET" "$IMGPATH" "$IMGNAME" || exit 1

