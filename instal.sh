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

echo "==> Installation du système de base"
pacstrap /mnt base linux linux-firmware lvm2 cryptsetup \
networkmanager sudo vim nano gcc make gdb \
xorg-server xorg-xinit i3-wm i3status i3lock dmenu alacritty feh \
network-manager-applet virtualbox virtualbox-host-modules-arch \
firefox htop grub efibootmgr

echo "==> Génération du fstab"
genfstab -U /mnt >> /mnt/etc/fstab

echo "==> Ajout de /tmp en tmpfs"
echo "tmpfs  /tmp  tmpfs  defaults,noexec,nosuid,nodev 0 0" >> /mnt/etc/fstab

echo "==> Configuration du système (chroot)"

arch-chroot /mnt /bin/bash -c "

echo $HOSTNAME > /etc/hostname
echo KEYMAP=fr > /etc/vconsole.conf

ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc

sed -i 's/#fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo LANG=fr_FR.UTF-8 > /etc/locale.conf

sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block keyboard encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

UUID=\$(blkid -s UUID -o value /dev/sda2)

sed -i \"s|GRUB_CMDLINE_LINUX=\\\"\\\"|GRUB_CMDLINE_LINUX=\\\"cryptdevice=UUID=\$UUID:cryptlvm root=/dev/vg0/root\\\"|\" /etc/default/grub
sed -i 's|#GRUB_ENABLE_CRYPTODISK=y|GRUB_ENABLE_CRYPTODISK=y|' /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

echo root:$PASSWORD | chpasswd

useradd -m -G wheel pere
useradd -m fils

echo pere:$PASSWORD | chpasswd
echo fils:$PASSWORD | chpasswd

sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

groupadd famille
usermod -aG famille pere
usermod -aG famille fils

chown :famille /share
chmod 770 /share

usermod -aG vboxusers pere

systemctl enable NetworkManager

mkdir -p /home/pere/.config/i3

cat > /home/pere/.config/i3/config <<I3
set \$mod Mod4
font pango:monospace 10
bindsym \$mod+Return exec alacritty
bindsym \$mod+d exec dmenu_run
bindsym \$mod+Shift+q kill
bindsym \$mod+Shift+r restart
bindsym \$mod+Shift+e exec \"i3-msg exit\"
set \$ws1 \"1: Dev\"
set \$ws2 \"2: Web\"
set \$ws3 \"3: VBox\"
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
    echo exec i3 > /home/\$user/.xinitrc
    chown \$user:\$user /home/\$user/.xinitrc
done

"

echo "==> Script terminé, redémarrage"
reboot