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

# Correction warning vconsole
arch-chroot /mnt /bin/bash -c "echo KEYMAP=fr > /etc/vconsole.conf"

echo "==> Configuration de mkinitcpio pour LUKS et LVM"
arch-chroot /mnt /bin/bash -c "
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block keyboard encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
"

echo "==> Installation et configuration de GRUB pour UEFI + LUKS"
arch-chroot /mnt /bin/bash -c "
pacman -S --noconfirm grub efibootmgr

UUID=\$(blkid -s UUID -o value /dev/sda2)

sed -i \"s|GRUB_CMDLINE_LINUX=\\\"\\\"|GRUB_CMDLINE_LINUX=\\\"cryptdevice=UUID=\$UUID:cryptlvm root=/dev/vg0/root\\\"|\" /etc/default/grub
sed -i 's|#GRUB_ENABLE_CRYPTODISK=y|GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
"

echo "==> Le volume secret est chiffré et sera monté manuellement par l'utilisateur"
echo "==> Script terminé, la partie de ton pote peut prendre la suite !"
lsblk -f

echo "==> Installation des logiciels de base"
pacstrap /mnt base linux linux-firmware networkmanager sudo vim nano gcc make gdb xorg-server xorg-xinit i3 i3status dmenu alacritty feh network-manager-applet gnome gnome-extra gdm virtualbox virtualbox-host-modules-arch firefox htop neofetch lvm2 cryptsetup
genfstab -U /mnt >> /mnt/etc/fstab

echo "==> Modification de la Timezone"
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
sed -i 's/#fr_FR.UTF-8/fr_FR.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf

echo "==> Configuration des utilisateurs"
useradd -m -G wheel pere
useradd -m fils
echo "pere:azerty123" | chpasswd
echo "fils:azerty123" | chpasswd

echo "==> Configuration des groupes et volume partagé"
groupadd famille
usermod -aG famille pere
usermod -aG famille fils
chown :famille /share
chmod 770 /share

echo "==> Activation du Réseau et de Gnome"
systemctl enable NetworkManager
systemctl enable gdm

echo "==> Configuration de base i3"
mkdir -p /home/pere/.config/i3
cat <<I3 > /home/pere/.config/i3/config
set \$mod Mod4
font pango:monospace 10
bindsym \$mod+Return exec alacritty
bindsym \$mod+d exec dmenu_run
bindsym \$mod+Shift+q kill
bindsym \$mod+Shift+r restart
bindsym \$mod+Shift+e exec "i3-msg exit"
set \$ws1 "1: Dev"
set \$ws2 "2: Web"
set \$ws3 "3: VBox"
bindsym \$mod+1 workspace \$ws1
bindsym \$mod+2 workspace \$ws2
bindsym \$mod+3 workspace \$ws3
bar {
status_command i3status
}
exec --no-startup-id nm-applet
I3

chown -R pere:pere /home/pere/.config

for user in pere fils; do
echo "exec i3" > /home/\$user/.xinitrc
chown \$user:\$user /home/\$user/.xinitrc
done

echo "==> Redémarrage du système"
reboot
