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
[[ -z "$USER" ]] && read -p "user: " USER

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
mkdir /mnt/boot
mount $ESP /mnt/boot/

pacstrap /mnt base linux-zen linux-firmware amd-ucode neovim man-db man-pages texinfo efibootmgr opendoas which
genfstab -U /mnt >> /mnt/etc/fstab

# Configuring /etc/mkinitcpio.conf
echo "Configuring /etc/mkinitcpio.conf for LUKS hook."
sed -i -e 's,modconf block filesystems keyboard,keyboard keymap modconf block encrypt filesystems,g' /mnt/etc/mkinitcpio.conf
UUID=$(blkid "$Cryptroot" | cut -f2 -d'"')

# Configuring the system.
echo "entrando a chroot"
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

# initramfs
echo "generando initramfs"
mkinitcpio -P

# echo "configurando xkeymap"
# localectl --no-convert set-x11-keymap "$XKEYMAP"
# xdg-user-dirs-update

#configure sudo
echo "configurando sudo"
echo "permit persist :wheel" >> /etc/doas.conf
chown -c root:root /etc/doas.conf
chmod -c 0400 /etc/doas.conf
ln -s $(which doas) /usr/bin/sudo

# swappiness
echo "configurando swappiness"
mkdir -p /etc/sysctl.d
echo 'vm.swappiness=10' >> /etc/sysctl.d/99-swappiness.conf 

# usuarios
if [ -n "$USER" ]; then
    echo "Adding $USER with root privilege."
    useradd -m -G wheel,audio,video,network,power,games,adm,rfkill "$USER"
fi

#install packages
echo "instalando paquetes"
pacman -S --needed --noconfirm firefox mlocate openssh unrar unzip zip wget htop alsa-utils networkmanager xdg-user-dirs xorg-server xorg-xinit libxinerama libx11 libxft xclip git binutils file findutils gawk grep make sed gcc rofi ranger dunst mesa

xdg-user-dirs-update
EOFILE
echo "saliendo de chroot"

echo "Setting root password."
arch-chroot /mnt /bin/passwd
[ -n "$USER" ] && echo "Setting user password for ${USER}." && arch-chroot /mnt /bin/passwd "$USER"
