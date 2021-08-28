#!/bin/bash

[ "$EUID" != "0" ] && echo "please run as root" && exit 1

set -e
set -o pipefail

os="openwrt"
rootsize=$((`stat $(OPENWRT) -c %s`/1024/1024))
origin="base-arm64"
target="catdrive"

tmpdir="tmp"
output="output"
rootfs_mount_point="/mnt/${os}_rootfs"
qemu_static="./tools/qemu/qemu-aarch64-static"

cur_dir=$(pwd)
DTB=armada-3720-catdrive.dtb

gen_new_name() {
	local rootfs=$1
	echo "`basename $rootfs | sed "s/${origin}/${target}/" | sed 's/.tar.gz$//'`"
}
func_generate()) {
	local rootfs=$1
	local rootfs_rescue=$2
	img_name=$(gen_new_name $rootfs)
	if [ "$BUILD_RESCUE" = "y" ]; then
		offset=$(sfdisk -J $tmpdir/$DISK |jq .partitiontable.partitions[0].start)
		mkdir -p $rootfs_mount_point
		mount -o loop,offset=$((offset*512)) $tmpdir/$DISK $rootfs_mount_point
		tar -cJpf ./tools/rescue/rescue-${img_name}.tar.xz -C $rootfs_mount_point .
		umount -l $rootfs_mount_point
	else
		[ ! -f $rootfs_rescue ] && echo "rescue rootfs not found!" && return 1

		# calc size
		img_size=$((`stat $tmpdir/$DISK -c %s`/1024/1024))
		img_size=$((img_size+300))

		echo "create mbr rescue img, size: ${img_size}M"
		dd if=/dev/zero bs=1M status=none conv=fsync count=$img_size of=$tmpdir/${img_name}.img
		parted -s $tmpdir/${img_name}.img -- mktable msdos
		parted -s $tmpdir/${img_name}.img -- mkpart p ext4 8192s -1s

		# get PTUUID
		eval `blkid -o export -s PTUUID $tmpdir/${img_name}.img`

		# mkfs.ext4
		echo "mount loopdev to format ext4 rescue img"
		modprobe loop
		lodev=$(losetup -f)
		losetup -P $lodev $tmpdir/${img_name}.img
		mkfs.ext4 -q -m 2 ${lodev}"p1"

		# mount rescue rootfs
		echo "mount rescue rootfs"
		mkdir -p $rootfs_mount_point
		mount ${lodev}"p1" $rootfs_mount_point

		# extract rescue rootfs
		echo "extract rescue rootfs($rootfs_rescue) to $rootfs_mount_point"
		tar -xpf $rootfs_rescue -C $rootfs_mount_point
		cp -f ./tools/rescue/emmc-install.sh $rootfs_mount_point/sbin
		echo "rootdev=PARTUUID=${PTUUID}-01" >> $rootfs_mount_point/boot/uEnv.txt

		echo "add ${os} img to rescue rootfs"
		mv -f rootfs $rootfs_mount_point/root/rootfs.img

		umount -l $rootfs_mount_point
		losetup -d $lodev

		mkdir -p $output/${os}
		mv -f $tmpdir/${img_name}.img $output/$os

		if [ -n "$TRAVIS_TAG" ]; then
			mkdir -p $output/release
			xz -T0 -v -f $output/$os/${img_name}.img
			mv $output/$os/${img_name}.img.xz $output/release
		fi
	fi

	rm -rf $tmpdir

	echo "release ${os} image done"
}
}

case "$1" in
generate)
	func_generate "$2" "$3"
	;;
*)
	exit 1
	;;
esac
