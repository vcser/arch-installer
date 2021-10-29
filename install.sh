#!/bin/bash

# configuracion
KEYMAP="la-latin1"
XKEYMAP="latam"
USER=
HOSTNAME=
SWAPSIZE=8192
DISK=

# instalacion
loadkeys $KEYMAP
# conectar a internet
# pendiente revisar iwctl
#nmtui
timedatectl set-ntp true
if [[ -z "$DISK" ]]
then
    PS3="Selecciona el disco en donde se instalara Arch Linux: "
    select ENTRY in $(lsblk -dpnoNAME|grep -P "/dev/sd|nvme|vd");
    do
        DISK=$ENTRY
        echo "Installing Arch Linux on $DISK."
        break
    done
fi

[[ -z "$HOSTNAME" ]] && read -p "hostname: " HOSTNAME

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
echo "Formatting the LUKS container as EXT4."
mkfs.ext4 $ROOT &>/dev/null
mount $ROOT /mnt
mount $ESP /mnt/boot/

pacstrap /mnt base linux-zen linux-firmware amd-ucode neovim man-db man-pages texinfo efibootmgr
genfstab -U /mnt >> /mnt/etc/fstab

# Configuring /etc/mkinitcpio.conf
echo "Configuring /etc/mkinitcpio.conf for LUKS hook."
sed -i -e 's,modconf block filesystems keyboard,keyboard keymap modconf block encrypt filesystems,g' /mnt/etc/mkinitcpio.conf
UUID=$(blkid "$Cryptroot" | cut -f2 -d'"')

# Configuring the system.    
arch-chroot /mnt /bin/bash -e <<EOFILE
# time zone
ln -sf /usr/share/zoneinfo/America/Santiago /etc/localtime
hwclock --systohc

# locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "es_CL.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo 'LANG=es_CL.UTF-8' >> /etc/locale.conf

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
dd if=/dev/zero of=/swapfile bs=1M count="$SWAPSIZE" status=progress
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
printf "/swapfile none swap defaults 0 0" >> /etc/fstab

# EFISTUB
SWAP_DEVICE=$(findmnt -no UUID -T /swapfile)
OFFSET=$(filefrag -v /swapfile | awk '$1=="0:" {print substr($4, 1, length($4)-2)}')
efibootmgr --disk "$DISK" --part 1 --create \
--label "Arch Linux" \
--loader /vmlinuz-linux-zen \
--unicode "root=UUID=$UUID rw" \
"resume=$SWAP_DEVICE resume_offset=$OFFSET" \
'initrd=\amd-ucode.img initrd=\initramfs-linux-zen.img' \
'quiet apparmor=1' --verbose

# comando de un loco
# sudo efibootmgr --disk /dev/nvme0n1 --part 1 --create \
# 	--label "Arch Linux" \
# 	--loader /vmlinuz-linux \
# 	--unicode 'initrd=\intel-ucode.img initrd=\initramfs-linux.img \
# 	rd.luks.name={luks-volume-UUID}=luks rd.luks.options=allow-discards \
# 	root=UUID={BTRFS-partition-UUID} rootflags=rw,subvol=@ \
# 	quiet loglevel=3 rd.systemd.show_status=auto rd.udev.log-priority=3 vga=current i915.fastboot=1 \
#   elevator=bfq apparmor=1 security=apparmor' --verbose

# comando de otro loco
# efibootmgr --disk /dev/nvme0n1 --part 1 --create 
# --label "Arch Linux AMD Zen NVMe" 
# --loader /vmlinuz-linux-zen 
# --unicode 'root=PARTUUID=<output of lsblk -o NAME,PARTUUID> rw 
# initrd=\amd-ucode.img initrd=\initramfs-linux-zen.img 
# quiet libahci.ignore_sss=1 apparmor=1 lsm=capability,lockdown,yama,apparmor' --verbose

# initramfs
mkinitcpio -P

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

# usuarios
if [ -n "$USER" ]; then
    echo "Adding $USER with root privilege."
    useradd -m -G wheel,audio,video,network,power,games,adm,rfkill "$USER"
fi
EOFILE

echo "Setting root password."
arch-chroot /mnt /bin/passwd
[ -n "$USER" ] && echo "Setting user password for ${USER}." && arch-chroot /mnt /bin/passwd "$USER"
