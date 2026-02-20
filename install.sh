#!/bin/bash


DISK="/dev/sda"
PASSWORD="azerty123"
HOSTNAME="archsib"

echo "==> On efface tout sur le disque et on crée la table GPT"
wipefs -a $DISK
parted -s $DISK mklabel gpt

echo "==> Création de la partition EFI (1Go)"
parted -s $DISK mkpart ESP fat32 1MiB 1025MiB
parted -s $DISK set 1 esp on

echo "==> Création de la partition principale (tout le reste)"
parted -s $DISK mkpart primary 1025MiB 100%

echo "==> Chiffrement LUKS de la partition principale"
echo -n "$PASSWORD" | cryptsetup luksFormat /dev/sda2 -
echo -n "$PASSWORD" | cryptsetup open /dev/sda2 cryptlvm -

echo "==> Création du groupe LVM et des volumes logiques"
pvcreate /dev/mapper/cryptlvm
vgcreate vg0 /dev/mapper/cryptlvm

lvcreate -L 10G vg0 -n root
lvcreate -L 8G  vg0 -n swap
lvcreate -L 20G vg0 -n virtbox
lvcreate -L 5G  vg0 -n share
lvcreate -L 10G vg0 -n secret
lvcreate -l 100%FREE vg0 -n home

echo "==> Formatage des partitions et volumes"
mkfs.fat -F32 /dev/sda1
mkfs.ext4 /dev/vg0/root
mkswap /dev/vg0/swap
mkfs.ext4 /dev/vg0/virtbox
mkfs.ext4 /dev/vg0/share
mkfs.ext4 /dev/vg0/home

echo "==> Chiffrement du volume secret (montage manuel plus tard)"
echo -n "$PASSWORD" | cryptsetup luksFormat /dev/vg0/secret -

echo "==> Montage des volumes"
mount /dev/vg0/root /mnt

mkdir -p /mnt/boot/efi
mkdir -p /mnt/home
mkdir -p /mnt/share
mkdir -p /mnt/var/lib/virtualbox

mount /dev/sda1 /mnt/boot/efi
mount /dev/vg0/home /mnt/home
mount /dev/vg0/share /mnt/share
mount /dev/vg0/virtbox /mnt/var/lib/virtualbox

swapon /dev/vg0/swap

echo "==> Installation du système de base (pacstrap)"
pacstrap /mnt base linux linux-firmware lvm2 vim sudo

echo "==> Génération du fstab"
genfstab -U /mnt >> /mnt/etc/fstab

echo "==> Ajout de /tmp en tmpfs dans le fstab"
echo "tmpfs  /tmp  tmpfs  defaults,noexec,nosuid,nodev 0 0" >> /mnt/etc/fstab

echo "==> Définition du hostname"
arch-chroot /mnt /bin/bash -c "echo $HOSTNAME > /etc/hostname"

echo "==> Configuration de mkinitcpio pour LUKS et LVM"
arch-chroot /mnt /bin/bash -c "
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block keyboard encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
"

echo "==> Installation et configuration de GRUB pour UEFI + LUKS"
# On récupère l'UID de sda2 et on le passe à grub pour qu'il sache que le disque est chiffré
arch-chroot /mnt /bin/bash -c "
UUID=\$(blkid -s UUID -o value /dev/sda2)
sed -i \"s|GRUB_CMDLINE_LINUX=\\\"\\\"|GRUB_CMDLINE_LINUX=\\\"cryptdevice=UUID=\$UUID:cryptlvm root=/dev/vg0/root\\\"|\" /etc/default/grub
sed -i 's|#GRUB_ENABLE_CRYPTODISK=y|GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
"

echo "==> Le volume secret est chiffré et sera monté manuellement par l'utilisateur"
echo "==> Script terminé, la partie de ton pote peut prendre la suite !"
lsblk -f