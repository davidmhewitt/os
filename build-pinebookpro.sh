#!/bin/bash

set -e

export packages="elementary-minimal initramfs-tools linux-firmware"
export architecture="arm64"
export codename="focal"
export channel="daily"

version=6.0
YYYYMMDD="$(date +%Y%m%d)"
imagename=elementaryos-$version-$channel-pinebookpro-$YYYYMMDD

tfaver=2.3
ubootver=2020.07

# Free space on rootfs in MiB
free_space="500"

rootdir=`pwd`
basedir=`pwd`/pinebook-pro

mkdir -p ${basedir}
cd ${basedir}

export DEBIAN_FRONTEND="noninteractive"
# Config to stop flash-kernel trying to detect the hardware in chroot
export FK_MACHINE=none

apt-get update
apt-get install -y --no-install-recommends python3 bzip2 wget gcc-arm-none-eabi crossbuild-essential-arm64 make bison flex bc device-tree-compiler ca-certificates sed build-essential debootstrap qemu-user-static qemu-utils qemu-system-arm binfmt-support parted kpartx rsync git libssl-dev xz-utils coreutils util-linux

wget "https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git/snapshot/trusted-firmware-a-$tfaver.tar.gz"
wget "ftp://ftp.denx.de/pub/u-boot/u-boot-${ubootver}.tar.bz2"

echo "37f917922bcef181164908c470a2f941006791c0113d738c498d39d95d543b21 trusted-firmware-a-${tfaver}.tar.gz" | sha256sum --check
echo "c1f5bf9ee6bb6e648edbf19ce2ca9452f614b08a9f886f1a566aa42e8cf05f6a u-boot-${ubootver}.tar.bz2" | sha256sum --check

tar xf "trusted-firmware-a-${tfaver}.tar.gz"
tar xf "u-boot-${ubootver}.tar.bz2"
rm "trusted-firmware-a-${tfaver}.tar.gz"
rm "u-boot-${ubootver}.tar.bz2"

cd "trusted-firmware-a-${tfaver}"
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
CROSS_COMPILE=aarch64-linux-gnu- make PLAT=rk3399
cp build/rk3399/release/bl31/bl31.elf ../u-boot-${ubootver}/

cd ../u-boot-${ubootver}
rm -r "../trusted-firmware-a-${tfaver}"

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

# Working directory
work_dir="${basedir}/elementary-${architecture}"

# Bootstrap an ubuntu minimal system
debootstrap --foreign --arch $architecture $codename elementary-$architecture http://ports.ubuntu.com/ubuntu-ports

# Add the QEMU emulator for running ARM executables
cp /usr/bin/qemu-arm-static ${work_dir}/usr/bin/

# Run the second stage of the bootstrap in QEMU
LANG=C chroot ${work_dir} /debootstrap/debootstrap --second-stage

# Add the rest of the ubuntu repos
cat << EOF > ${work_dir}/etc/apt/sources.list
deb http://ports.ubuntu.com/ubuntu-ports $codename main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $codename-updates main restricted universe multiverse
EOF

# Copy in the elementary PPAs/keys/apt config
for f in ${rootdir}/etc/config/archives/*.list; do cp -- "$f" "${work_dir}/etc/apt/sources.list.d/$(basename -- $f)"; done
for f in ${rootdir}/etc/config/archives/*.key; do cp -- "$f" "${work_dir}/etc/apt/trusted.gpg.d/$(basename -- $f).asc"; done
for f in ${rootdir}/etc/config/archives/*.pref; do cp -- "$f" "${work_dir}/etc/apt/preferences.d/$(basename -- $f)"; done

# Set codename/channel in added repos
sed -i "s/@CHANNEL/$channel/" ${work_dir}/etc/apt/sources.list.d/*.list*
sed -i "s/@BASECODENAME/$codename/" ${work_dir}/etc/apt/sources.list.d/*.list*

echo "elementary" > ${work_dir}/etc/hostname

cat << EOF > ${work_dir}/etc/hosts
127.0.0.1       elementary    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

mount -t proc proc ${work_dir}/proc
mount -o bind /dev/ ${work_dir}/dev/
mount -o bind /dev/pts ${work_dir}/dev/pts

# Make a third stage that installs all of the metapackages
cat << EOF > ${work_dir}/third-stage
#!/bin/bash
apt-get update
apt-get --yes upgrade
apt-get --yes install $packages

# Prevents shutdown from working properly
apt-get --yes remove irqbalance

rm -f /third-stage
EOF

chmod +x ${work_dir}/third-stage
LANG=C chroot ${work_dir} /third-stage

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

cd ..
rm -r ap6256-firmware

# Install kernel
cat << EOF > ${work_dir}/hardware
#!/bin/bash

apt-get --yes install linux-image-unsigned-5.8.0-41-generic

mkdir -p /boot/dtbs

cp -r /lib/firmware/*/device-tree/rockchip /boot/dtbs

rm -f /hardware
EOF

chmod +x ${work_dir}/hardware
LANG=C chroot ${work_dir} /hardware

# mkdir ${work_dir}/hooks
# cp ${rootdir}/etc/config/hooks/live/*.chroot ${work_dir}/hooks

# for f in ${work_dir}/hooks/*
# do
#     base=`basename ${f}`
#     LANG=C chroot ${work_dir} "/hooks/${base}"
# done

# rm -r "${work_dir}/hooks"

# Calculate the space to create the image.
root_size=$(du -s -B1K ${work_dir} | cut -f1)
raw_size=$(($((${free_space}*1024))+${root_size}))

# Create the disk and partition it
echo "Creating image file"

# Sometimes fallocate fails if the filesystem or location doesn't support it, fallback to slower dd in this case
if ! fallocate -l $(echo ${raw_size}Ki | numfmt --from=iec-i --to=si --format=%.1f) ${basedir}/${imagename}.img
then
    dd if=/dev/zero of=${basedir}/${imagename}.img bs=1024 count=${raw_size}
fi

parted ${imagename}.img --script -- mklabel msdos
parted ${imagename}.img --script -- mkpart primary ext4 32M 100%

# Set the partition variables
loopdevice=`losetup -f --show "${basedir}"/${imagename}.img`
device=`kpartx -va ${loopdevice} | sed 's/.*\(loop[0-9]\+\)p.*/\1/g' | head -1`
sleep 5
device="/dev/mapper/${device}"
rootp=${device}p1

# Create file systems
mkfs.ext4 ${rootp}

# Create the dirs for the partitions and mount them
mkdir -p "${basedir}"/root
mount ${rootp} "${basedir}"/root

# Create an fstab so that we don't mount / read-only.
UUID=$(blkid -s UUID -o value ${rootp})
echo "UUID=$UUID /               ext4    errors=remount-ro 0       1" >> ${work_dir}/etc/fstab

mkdir ${work_dir}/boot/extlinux/

# U-boot config
cat << EOF > ${work_dir}/boot/extlinux/extlinux.conf
LABEL elementary ARM
KERNEL /boot/vmlinuz
FDT /boot/dtbs/rockchip/rk3399-pinebook-pro.dtb
APPEND initrd=/boot/initrd.img console=ttyS2,1500000 console=tty1 root=UUID=${UUID} rw rootwait video=eDP-1:1920x1080@60 video=HDMI-A-1:1920x1080@60 quiet splash plymouth.ignore-serial-consoles
EOF
cd ${basedir}

mkdir -p ${work_dir}/etc/udev/hwdb.d/
cat << EOF > ${work_dir}/etc/udev/hwdb.d/10-usb-kbd.hwdb
# Make the sleep and brightness Fn hotkeys work
evdev:input:b0003v258Ap001E*
  KEYBOARD_KEY_700a5=brightnessdown
  KEYBOARD_KEY_700a6=brightnessup
  KEYBOARD_KEY_70066=sleep

# Disable the "keyboard mouse" in libinput. This is reported by the keyboard firmware
# and is probably a placeholder for a TrackPoint style mouse that doesn't exist
evdev:input:b0003v258Ap001Ee0110-e0,1,2,4,k110,111,112,r0,1,am4,lsfw
  ID_INPUT=0
  ID_INPUT_MOUSE=0

EOF

# Mark the keyboard as internal, so that "disable when typing" works for the touchpad
mkdir -p ${work_dir}/etc/libinput/
cat << EOF > ${work_dir}/etc/libinput/local-overrides.quirks
[Pinebook Pro Keyboard]
MatchUdevType=keyboard
MatchBus=usb
MatchVendor=0x258A
MatchProduct=0x001E
AttrKeyboardIntegration=internal
EOF

# Make resume from suspend work
sed -i s/"#SuspendState=mem standby freeze"/"SuspendState=freeze"/g ${work_dir}/etc/systemd/sleep.conf

# Disable ondemand scheduler so we can default to schedutil
rm ${work_dir}/etc/systemd/system/multi-user.target.wants/ondemand.service

# Make sound work
mkdir -p ${work_dir}/var/lib/alsa/
cp ${rootdir}/pinebookpro/config/alsa/asound.state ${work_dir}/var/lib/alsa/

# Add a oneshot service to grow the rootfs on first boot
install -m 755 -o root -g root ${rootdir}/pinebookpro/files/resizerootfs "${work_dir}/usr/sbin/resizerootfs"
install -m 644 -o root -g root ${rootdir}/pinebookpro/files/resizerootfs.service "${work_dir}/etc/systemd/system"
mkdir -p "${work_dir}/etc/systemd/system/systemd-remount-fs.service.requires/"
ln -s /etc/systemd/system/resizerootfs.service "${work_dir}/etc/systemd/system/systemd-remount-fs.service.requires/resizerootfs.service"

# Tweak the minimum frequencies of the GPU and CPU governors to get a bit more performance
mkdir -p ${work_dir}/etc/tmpfiles.d/
cat << EOF > ${work_dir}/etc/tmpfiles.d/cpufreq.conf
w- /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq - - - - 1200000
w- /sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq - - - - 1008000
w- /sys/class/devfreq/ff9a0000.gpu/min_freq - - - - 600000000
EOF

umount ${work_dir}/dev/pts
umount ${work_dir}/dev/
umount ${work_dir}/proc

echo "Rsyncing rootfs into image file"
rsync -HPavz -q ${work_dir}/ "${basedir}"/root/

# Flash u-boot into the early sectors of the image
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

cd "${basedir}"

md5sum ${imagename}.img.xz > ${imagename}.md5.txt
sha256sum ${imagename}.img.xz > ${imagename}.sha256.txt

cd "${rootdir}"

KEY="$1"
SECRET="$2"
ENDPOINT="$3"
BUCKET="$4"
IMGPATH="${basedir}"/${imagename}.img.xz
IMGNAME=${channel}-pinebookpro/$(basename "$IMGPATH")

apt-get install -y curl python3 python3-distutils

curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
python3 get-pip.py
pip install boto3

python3 upload.py "$KEY" "$SECRET" "$ENDPOINT" "$BUCKET" "$IMGPATH" "$IMGNAME" || exit 1

CHECKSUMPATH="${basedir}"/${imagename}.md5.txt
CHECKSUMNAME=${channel}-pinebookpro/$(basename "$CHECKSUMPATH")

python3 upload.py "$KEY" "$SECRET" "$ENDPOINT" "$BUCKET" "$CHECKSUMPATH" "$CHECKSUMNAME" || exit 1

CHECKSUMPATH="${basedir}"/${imagename}.sha256.txt
CHECKSUMNAME=${channel}-pinebookpro/$(basename "$CHECKSUMPATH")

python3 upload.py "$KEY" "$SECRET" "$ENDPOINT" "$BUCKET" "$CHECKSUMPATH" "$CHECKSUMNAME" || exit 1
