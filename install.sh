#!/bin/bash

# Magyar billentyűzetkiosztás és szép nagy betűtípus a Live telepítő környezetben
loadkeys hu
setfont ter-122b

# Ellenőrzés, hogy root-ként fut-e
if [ "$EUID" -ne 0 ]; then
  echo "Kérlek, futtasd rootként ezt a szkriptet! (sudo bash install.sh)"
  exit 1
fi

# 0. A Live ISO pacman.conf optimalizálása a gyors és látványos letöltésekért
echo "Live ISO pacman beállítások frissítése (Color, ILoveCandy, ParallelDownloads, Multilib)..."
sed -i 's/#Color/Color\nILoveCandy/' /etc/pacman.conf
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 9/' /etc/pacman.conf
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
  echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
fi
pacman -Sy

echo "=== Arch Linux Automata Telepítő (pbalee verzió) ==="
read -p "Add meg a gépnevet (hostname) [alapértelmezett: bluelight]: " HOSTNAME
HOSTNAME=${HOSTNAME:-bluelight}
read -p "Add meg a felhasználónevet [alapértelmezett: pbalee]: " USERNAME
USERNAME=${USERNAME:-pbalee}
read -s -p "Add meg a felhasználó jelszavát: " PASSWORD
echo
read -s -p "Add meg a root jelszavát: " ROOTPASSWORD
echo

# Disk kiválasztása
echo -e "\nElérhető lemezek:"
lsblk -d -n -o NAME,SIZE,MODEL
read -p "Add meg a telepítési lemez nevét (pl. sda vagy nvme0n1): " DISK

TARGET="/dev/$DISK"

echo -e "\nFIGYELEM: A(z) $TARGET lemez boot és root partíciói felülíródnak!"
read -p "Biztosan folytatod? (igen/nem): " CONFIRM
if [ "$CONFIRM" != "igen" ]; then
  echo "Telepítés megszakítva."
  exit 1
fi

# Particionálási kérdések
read -p "Van külön /home partíciód, amit meg szeretnél őrizni formázás NÉLKÜL? (igen/nem): " HAS_HOME

if [ "$HAS_HOME" == "igen" ]; then
  echo -e "\nJelenlegi partíciók a(z) $TARGET lemezen:"
  lsblk "$TARGET"
  read -p "Add meg a meglévő /home partíció teljes elérési útját (pl. /dev/sda3 vagy /dev/nvme0n1p3): " HOME_PART
fi

# Extra meghajtók opció
read -p "Szeretnéd csatolni a Games (1TB Ext4) és Downloads (NTFS) extra meghajtókat az fstab-hoz? (igen/nem) [alapértelmezett: igen]: " ADD_EXTRA
ADD_EXTRA=${ADD_EXTRA:-igen}

# 1. Particionálás (GPT: EFI + Root + opcionális Home)
echo "Particionálás előkészítése..."
if [ "$HAS_HOME" != "igen" ]; then
  parted --script "$TARGET" \
    mklabel gpt \
    mkpart "EFI" fat32 1MiB 512MiB \
    set 1 esp on \
    mkpart "root" ext4 512MiB 100%
else
  parted --script "$TARGET" \
    mklabel gpt \
    mkpart "EFI" fat32 1MiB 512MiB \
    set 1 esp on \
    mkpart "root" ext4 512MiB 60GiB
fi

# Partíciónevek meghatározása
if [[ "$TARGET" =~ "nvme" ]] || [[ "$TARGET" =~ "mmcblk" ]]; then
  EFI_PART="${TARGET}p1"
  ROOT_PART="${TARGET}p2"
else
  EFI_PART="${TARGET}1"
  ROOT_PART="${TARGET}2"
fi

# Formázás
echo "Formázás..."
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"

# Felcsatolások
echo "Fájlrendszer felcsatolása..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

if [ "$HAS_HOME" == "igen" ] && [ -n "$HOME_PART" ]; then
  echo "Meglévő /home csatolása (formázás NÉLKÜL)..."
  mkdir -p /mnt/home
  mount "$HOME_PART" /mnt/home
fi

# 2. Alap- és felhasználói csomagok telepítése (pacstrap) - JAVÍTVA (nincsenek csoportok és AUR csomagok)
echo "Csomagok telepítése a megadott szoftverlista alapján..."
pacstrap -K /mnt \
  base base-devel linux linux-firmware linux-headers nano micro git networkmanager \
  grub efibootmgr xorg-server xfce4-session xfce4-settings xfce4-panel xfce4-appfinder xfce4-power-manager xfce4-taskmanager xfce4-terminal xfconf xfdesktop xfwm4 lightdm lightdm-gtk-greeter numlockx \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber gst-plugin-pipewire pavucontrol \
  nvidia-open nvidia-settings nvidia-utils lib32-nvidia-utils opencl-nvidia libva-nvidia-driver libxnvctrl \
  firefox firefox-i18n-hu libreoffice-fresh libreoffice-fresh-hu hunspell-hu mythes-hu aspell-hu \
  mc mousepad thunar thunar-archive-plugin thunar-media-tags-plugin thunar-volman file-roller 7zip unrar unzip \
  keepassxc qbittorrent audacious parole ristretto galculator \
  lutris gamemode gamescope mangohud wine wine-gecko wine-mono \
  lib32-freetype2 lib32-gamemode lib32-gnutls lib32-libglvnd lib32-vulkan-icd-loader \
  udisks2 gvfs gvfs-afc gvfs-gphoto2 gvfs-mtp gvfs-nfs gvfs-smb ntfs-3g exfatprogs dosfstools \
  flatpak pacman-contrib reflector htop glances duf inxi lsb-release sudo

# 3. Fstab generálása
echo "Fstab generálása..."
genfstab -U /mnt >> /mnt/etc/fstab

# Ha kérték az extra meghajtókat, hozzáadjuk az fstab-hoz
if [ "$ADD_EXTRA" == "igen" ]; then
  echo "Extra meghajtók hozzáadása az fstab-hoz (Games & Downloads)..."
  mkdir -p /mnt/Games /mnt/Download
  cat << 'EOF' >> /mnt/etc/fstab

# Games Ext4 1TB
UUID=9471a888-07ec-45ed-b516-eb6aa1513a64 /Games ext4 defaults,noatime,nofail,x-gvfs-show,x-gvfs-name=Games 0 2

# Downloads NTFS
UUID=7460557760554152 /Download ntfs3 defaults,noatime,uid=1000,gid=1000,umask=022,nofail,x-gvfs-show,x-gvfs-name=Downloads 0 0
EOF
fi

# 4. Rendszerkonfiguráció a Chroot környezetben
echo "Konfiguráció az új rendszerben..."
arch-chroot /mnt /bin/bash <<EOF

# Időzóna & Óra
ln -sf /usr/share/zoneinfo/Europe/Budapest /etc/localtime
hwclock --systohc

# Nyelv (Locale)
echo "hu_HU.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=hu_HU.UTF-8" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname

# Pacman beállítások az új telepített rendszerben is
sed -i 's/#Color/Color\nILoveCandy/' /etc/pacman.conf
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 9/' /etc/pacman.conf
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
  echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
fi

# Makepkg teljesítmény és optimalizálás beállításai
sed -i 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j\$(nproc)"/' /etc/makepkg.conf
sed -i 's/^COMPRESSZST=(zstd -c -z -q -)/COMPRESSZST=(zstd -c -z -q --threads=0 -)/' /etc/makepkg.conf
sed -i 's/#BUILDDIR=\/tmp\/build/BUILDDIR=\/tmp\/build/' /etc/makepkg.conf

# LightDM NumLock beállítás
if grep -q "\[Seat:\*\]" /etc/lightdm/lightdm.conf; then
  sed -i '/\[Seat:\*\]/a display-setup-script=numlockx on' /etc/lightdm/lightdm.conf
else
  echo -e "\n[Seat:*]\ndisplay-setup-script=numlockx on" >> /etc/lightdm/lightdm.conf
fi

# Szolgáltatások engedélyezése
systemctl enable NetworkManager
systemctl enable lightdm

# UDisks2 konfig (USB csatolások)
mkdir -p /etc/udisks2
cat << 'UCONF' > /etc/udisks2/mount_options.conf
[defaults]
vfat_defaults=uid=\$UID,gid=\$GID,shortname=mixed,utf8=1,showexec,flush
exfat_defaults=uid=\$UID,gid=\$GID,iocharset=utf8,errors=remount-ro
UCONF

# USB írási puffer (Dirty Bytes)
cat << 'SYSCONF' > /etc/sysctl.d/99-usb-dirty-bytes.conf
vm.dirty_background_bytes = 16777216
vm.dirty_bytes = 50331648
SYSCONF

# Root és Felhasználó fiók
echo "root:$ROOTPASSWORD" | chpasswd
useradd -m -G wheel,storage,power,input -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd

# Sudo engedélyezése a wheel csoportnak
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Bootloader (GRUB) telepítése --removable kapcsolóval
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
grub-mkconfig -o /boot/grub/grub.cfg

# Rejtett Arch takarító szkript létrehozása a felhasználó saját mappájában (.arch-clean.sh)
cat << 'CLEAN_EOF' > /home/$USERNAME/.arch-clean.sh
#!/usr/bin/env bash
set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "\${BLUE}🧹 Arch Linux takarítás...\${NC}"
sudo paccache -r -k 2 || true

orphans=\$(pacman -Qtdq || true)
if [ -n "\$orphans" ]; then
    sudo pacman -Rns \$orphans
fi

if command -v yay >/dev/null 2>&1; then
    aur_orphans=\$(yay -Qtdq || true)
    if [ -n "\$aur_orphans" ]; then
        yay -Rns --noconfirm \$aur_orphans
    fi
fi

sudo journalctl --vacuum-time=7d

if command -v flatpak >/dev/null 2>&1; then
    flatpak uninstall --unused -y
fi

[ -d "\$HOME/.cache/yay" ] && rm -rf "\$HOME/.cache/yay/"*
[ -d "\$HOME/.cache/thumbnails" ] && rm -rf "\$HOME/.cache/thumbnails/"*

echo -e "\${GREEN}✅ Takarítás kész!\${NC}"
CLEAN_EOF

chmod +x /home/$USERNAME/.arch-clean.sh
chown $USERNAME:$USERNAME /home/$USERNAME/.arch-clean.sh

# Hasznos aliasok és frissítő függvény hozzáadása a .bashrc-hez
cat << 'BASHRC_EOF' >> /home/$USERNAME/.bashrc

# Egyéni aliasok és funkciók (pbalee)
alias cl='clear'
alias e='exit'
alias y='yay -Syu'
alias sr='sudo reboot'
alias in='sudo pacman -S '
alias rem="\$HOME/.arch-clean.sh"

u() {
    echo "==> Pacman frissítés..."
    sudo pacman -Syu --noconfirm || return 1

    echo "==> Flatpak frissítés..."
    flatpak update -y
}
BASHRC_EOF

chown $USERNAME:$USERNAME /home/$USERNAME/.bashrc

EOF

# 5. AUR csomagok (Google Chrome és ProtonUp-Qt) telepítése kézi makepkg módszerrel
echo "AUR csomagok (Google Chrome, ProtonUp-Qt) telepítése..."
arch-chroot /mnt /bin/bash -c "
  # Google Chrome
  cd /tmp
  sudo -u $USERNAME git clone https://aur.archlinux.org/google-chrome.git
  cd google-chrome
  sudo -u $USERNAME makepkg -si --noconfirm
  cd /tmp && rm -rf google-chrome

  # ProtonUp-Qt
  cd /tmp
  sudo -u $USERNAME git clone https://aur.archlinux.org/protonup-qt.git
  cd protonup-qt
  sudo -u $USERNAME makepkg -si --noconfirm
  cd /tmp && rm -rf protonup-qt
"

echo -e "\n=== Telepítés sikeresen kész! Lépj ki és indítsd újra a gépet (reboot). ==="
