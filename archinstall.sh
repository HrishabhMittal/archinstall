#!/bin/bash

# this file has not been tested, but it should work in theory



DEVICE="/dev/sda"
TIMEZONE="Asia/Kolkata"
HOST_NAME="arch"
USER_NAME="user"
BOOT_SIZE=100   # in MB
AP_SIZE=4     # in GB

echo "#####################################"
echo "######### SETTING UP DISK ###########"
echo "#####################################"

# Partition the disk
DISK_OUTPUT="$(fdisk "$DEVICE" <<EOF
n


+${BOOT_SIZE}M
n


+${SWAP_SIZE}G
n




w
EOF
)"

read boot swap main < <(echo "$DISK_OUTPUT" | grep -oP 'partition \K[0-9]+' | tr '\n' ' ')

if [[ "$DEVICE" =~ "/dev/nvme" ]]; then
    PART_PREFIX="${DEVICE}p"
else
    PART_PREFIX="$DEVICE"
fi

echo "Boot partition at: $PART_PREFIX$boot"
echo "Swap partition at: $PART_PREFIX$swap"
echo "Main partition at: $PART_PREFIX$main"

# Format partitions
mkfs.fat -F32 "$PART_PREFIX$boot"
mkswap "$PART_PREFIX$swap"
mkfs.ext4 "$PART_PREFIX$main"

# Mount filesystems
mount "$PART_PREFIX$main" /mnt
mkdir -p /mnt/boot/efi
mount "$PART_PREFIX$boot" /mnt/boot/efi
swapon "$PART_PREFIX$swap"

# install base system and essential tools
pacstrap /mnt base linux linux-firmware sof-firmware base-devel grub efibootmgr nano networkmanager

echo "#####################################"
echo "######### SETTING UP USER ###########"
echo "#####################################"

# generate fstab
genfstab /mnt > /mnt/etc/fstab

# enter chroot
arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -e

# timezone and clock
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# localization
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# hostname
echo "$HOST_NAME" > /etc/hostname

# root and user passwords
echo "Enter root password:"
passwd
useradd -m -G wheel -s /bin/bash "$USER_NAME"
echo "Enter password for user '$USER_NAME':"
passwd "$USER_NAME"

echo "%wheel ALL=(ALL) ALL" | EDITOR='tee -a' visudo

# Enable services
systemctl enable NetworkManager bluetooth

GPU_DRIVER="$GPU_DRIVER"
NVIDIA_PKGS=( ${NVIDIA_PKGS[@]} )

if [[ "$GPU_DRIVER" == "nvidia-dkms" ]]; then
    pacman -S --noconfirm "${NVIDIA_PKGS[@]}" linux-headers
else
    pacman -S --noconfirm "${NVIDIA_PKGS[@]}"
fi

sed -Ei 's/^MODULES=\((.*)\)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm \1)/' /etc/mkinitcpio.conf
mkinitcpio -P

GRUB_CFG=/etc/default/grub
if ! grep -q "nvidia-drm.modeset=1" "$GRUB_CFG"; then
    sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT="|GRUB_CMDLINE_LINUX_DEFAULT="nvidia-drm.modeset=1 nvidia-drm.fbdev=1 |' "$GRUB_CFG"
fi

systemctl enable nvidia-suspend.service nvidia-resume.service
modprobe -a nvidia nvidia_drm
lsmod | grep nvidia || echo "Warning: NVIDIA modules not loaded"
nvidia-smi || echo "Error: nvidia-smi failed"

echo "#####################################"
echo "######### INSTALLING GRUB ###########"
echo "#####################################"
grub-install "$DEVICE"
grub-mkconfig -o /boot/grub/grub.cfg


CHROOT_EOF



echo "installation complete. you may reboot now."
