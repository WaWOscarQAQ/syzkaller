#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")" && pwd -P)
if (( EUID == 0 )) || [[ $(uname -m) != x86_64 ]]; then
    echo 'Run as a regular user on an x86_64 Linux host.' >&2
    exit 1
fi
out="$repo/build/md-vm"
mkdir -p -- "$out"
exec 9>"$out/.lock"
flock 9

kernel="$out/linux-7.3.6"
if [[ ! -d $kernel/.git ]]; then
    echo '[build] 拉取 Linux 7.3.6'
    git clone --depth 1 --branch v7.3.6 https://github.com/gregkh/linux.git "$kernel"
fi

echo '[build] 配置并编译 Linux 7.3.6'
(
    cd -- "$kernel"
    make defconfig
    scripts/config \
        --enable DEBUG_FS --enable KCOV --enable KCOV_INSTRUMENT_ALL \
        --disable DEBUG_INFO_NONE --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
        --disable DEBUG_INFO_BTF --enable DEBUG_INFO_DWARF4 \
        --enable CONFIGFS_FS --enable SECURITYFS --enable SYSFS \
        --enable DEVTMPFS --enable DEVTMPFS_MOUNT --enable EXT4_FS \
        --enable ATA --enable ATA_PIIX --enable SCSI --enable BLK_DEV_SD \
        --enable E1000 --enable VIRTIO_PCI \
        --enable MD --enable BLK_DEV_MD --enable BLK_DEV_RAM \
        --enable MD_RAID0 --enable MD_RAID1 --enable MD_RAID10 --enable MD_RAID456 \
        --set-val BLK_DEV_RAM_COUNT 16 --set-val BLK_DEV_RAM_SIZE 4096
    make olddefconfig
    for option in KCOV BLK_DEV_MD BLK_DEV_RAM MD_RAID0 MD_RAID1 MD_RAID10 MD_RAID456; do
        grep -qx "CONFIG_${option}=y" .config || { echo "Missing CONFIG_${option}=y" >&2; exit 1; }
    done
    grep -qx 'CONFIG_BLK_DEV_RAM_COUNT=16' .config
    grep -qx 'CONFIG_BLK_DEV_RAM_SIZE=4096' .config
    make -j"${JOBS:-$(nproc)}" bzImage vmlinux
)

if [[ ! -s $out/trixie/trixie.img || ! -s $out/trixie/trixie.id_rsa ]]; then
    echo '[build] 创建 Debian Trixie 镜像'
    guest=$(mktemp -d "$out/trixie.XXXXXXXX")
    rootfs="$guest/rootfs"
    key="$guest/trixie.id_rsa"
    image="$guest/trixie.img"
    packages=systemd-sysv,openssh-server,iproute2,kmod,ca-certificates
    sudo debootstrap --arch=amd64 --variant=minbase --include="$packages" \
        trixie "$rootfs" https://deb.debian.org/debian
    ssh-keygen -q -t rsa -N '' -f "$key"
    sudo install -d -m 0700 "$rootfs/root/.ssh"
    sudo install -m 0600 "$key.pub" "$rootfs/root/.ssh/authorized_keys"
    sudo install -d "$rootfs/etc/ssh/sshd_config.d" "$rootfs/etc/systemd/network"
    printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\n' |
        sudo tee "$rootfs/etc/ssh/sshd_config.d/10-syzkaller.conf" >/dev/null
    printf '[Match]\nName=e*\n\n[Network]\nDHCP=ipv4\n' |
        sudo tee "$rootfs/etc/systemd/network/10-qemu.network" >/dev/null
    sudo systemctl --root="$rootfs" enable systemd-networkd.service ssh.service
    truncate -s 2G "$image"
    sudo mkfs.ext4 -q -F -d "$rootfs" "$image"
    mv -T -- "$guest" "$out/trixie"
fi

echo '[build] 完成'
