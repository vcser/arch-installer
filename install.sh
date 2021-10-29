#!/bin/bash

# configuracion
KEYMAP="la-latin1"
XKEYMAP="latam"
USER=
HOSTNAME=
DISK=

# instalacion
loadkeys $KEYMAP
# conectar a internet
# pendiente revisar iwctl
nmtui
timedatectl set-ntp true
if [[ -z "$DISK" ]]
then
    PS3="Select the disk where Arch Linux is going to be installed: "
    select ENTRY in $(lsblk -dpnoNAME|grep -P "/dev/sd|nvme|vd");
    do
        DISK=$ENTRY
        echo "Installing Arch Linux on $DISK."
        break
    done
fi

# EFI system partition
parted -s "$DISK" \
mklabel gpt \
mkpart ESP fat32 1MiB 513MiB \
set 1 esp on \
mkpart Cryptroot 513MiB 100% \

ESP="/dev/disk/by-partlabel/ESP"
Cryptroot="/dev/disk/by-partlabel/Cryptroot"

echo "Informing the Kernel about the disk changes."
partprobe "$DISK"

echo "Formatting the EFI Partition as FAT32."
mkfs.fat -F 32 $ESP &>/dev/null

# Creating a LUKS Container for the root partition.
echo "Creating LUKS Container for the root partition"
cryptsetup luksFormat $Cryptroot
echo "Opening the newly created LUKS Container."
cryptsetup open $Cryptroot cryptroot
ROOT="/dev/mapper/cryptroot"

# Formatting the LUKS Container as EXT4.
echo "Formatting the LUKS container as BTRFS."
mkfs.ext4 $ROOT &>/dev/null
mount $ROOT /mnt
mount $ESP /mnt/boot/

pacstrap /mnt base linux-zen linux-firmware amd-ucode neovim man-db man-pages texinfo
genfstab -U /mnt >> /mnt/etc/fstab

# Configuring /etc/mkinitcpio.conf
echo "Configuring /etc/mkinitcpio.conf for LUKS hook."
sed -i -e 's,modconf block filesystems keyboard,keyboard keymap modconf block encrypt filesystems,g' /mnt/etc/mkinitcpio.conf

# Configuring the system.    
arch-chroot /mnt /bin/bash -e <<EOFILE
# time zone
ln -sf /usr/share/zoneinfo/America/Santiago /etc/localtime
hwclock --systohc

# locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "es_CL.UTF-8 UTF-8" >> /etc/locale.gen
echo 'LANG=es_CL.UTF-8' >> /etc/locale.conf
locale-gen

# keymap
echo "KEYMAP=$KEYMAP" >> /etc/vconsole.conf

# hostname
echo "$HOSTNAME" >> /etc/hostname
cat <<EOF > /etc/hosts
127.0.0.1       localhost
::1             localhost
127.0.1.1       $HOSTNAME
EOF

# swapfile
echo "configuring swap file"
dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
printf "\n/swapfile none swap defaults 0 0" >> /etc/fstab

# EFISTUB o systemd-boot
UUID=$(blkid $Cryptroot | cut -f2 -d'"')
SWAP_DEVICE=$(findmnt -no UUID -T /swapfile)
OFFSET=$(filefrag -v /swapfile | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')
efibootmgr --disk "$DISK" --part 1 --create --label "Arch Linux" --loader /vmlinuz-linux-zen \
'--unicode "root=$ROOT rw" \
"resume=$SWAP_DEVICE resume_offset=$OFFSET" \
'initrd=\amd-ucode.img initrd=\initramfs-linux-zen.img' \
'quiet splash apparmor=1 --verbose'

# initramfs
mkinitcpio -P

# usuarios
if [ -n "$username" ]; then
    echo "Adding $username with root privilege."
    useradd -m -G wheel,audio,video,network,power,games,adm,rfkill "$username"
fi
echo "Setting root password."
passwd
[ -n "$username" ] && echo "Setting user password for ${username}." && passwd "$username"

#install packages
local packages
packages += "firefox mlocate openssh opendoas unrar unzip zip wget htop alsa-utils networkmanager xdg-user-dirs"
packages += " rofi ranger dunst"
packages += " git base-devel"
packages += " xorg-sever xorg-xinit libxinerama libx11 libxft"
packages += " mesa"
pacman -S --ignore sudo "$packages"

localectl --no-convert set-x11-keymap "$XKEYMAP"
xdg-user-dirs-update

#configure sudo
echo "permit persist :wheel" >> /etc/doas.conf
chown -c root:root /etc/doas.conf
chmod -c 0400 /etc/doas.conf
ln -s $(which doas) /usr/bin/sudo

# swappiness
mkdir -p /etc/sysctl.d
echo 'vm.swappiness=10' >> /etc/sysctl.d/99-swappiness.conf 

# hibernation
EOFILE


