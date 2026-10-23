#!/bin/bash

# Magyar billentyűzetkiosztás és szép nagy betűtípus a Live telepítő környezetben
loadkeys hu
setfont ter-122b

# Ellenőrzés, hogy root-ként fut-e
if [ "$EUID" -ne 0 ]; then
  echo "Kérlek, futtasd rootként ezt a szkriptet! (sudo bash install.sh)"
  exit 1
fi

# 0. A Live ISO pacman.conf optimalizálása
echo "Live ISO pacman beállítások frissítése (Color, ILoveCandy, ParallelDownloads, Multilib)..."
sed -i 's/#Color/Color\nILoveCandy/' /etc/pacman.conf
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 9/' /etc/pacman.conf
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
  echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
fi
pacman -Sy

echo "=== Arch Linux Automata Telepítő (pbalee GPU-választós verzió) ==="

# Alapértelmezett adatok
read -p "Add meg a gépnevet (hostname) [alapértelmezett: bluelight]: " HOSTNAME
HOSTNAME=${HOSTNAME:-bluelight}

read -p "Add meg a felhasználónevet [alapértelmezett: pbalee]: " USERNAME
USERNAME=${USERNAME:-pbalee}

read -s -p "Add meg a felhasználó jelszavát [alapértelmezett: pbalee]: " PASSWORD
PASSWORD=${PASSWORD:-pbalee}
echo

read -s -p "Add meg a root jelszavát [alapértelmezett: root]: " ROOTPASSWORD
ROOTPASSWORD=${ROOTPASSWORD:-root}
echo

# -- GPU VÁLASZTÁS --
echo -e "\nMilyen grafikus kártya van a gépben?"
echo "1) NVIDIA (open illesztőprogramok + nvidia-drm beállítások)"
echo "2) AMD (radeon / amdgpu)"
echo "3) Intel (i915 / intel)"
echo "4) Egyéb / Alap (nincs extra driver)"
read -p "Válassz (1-4) [alapértelmezett: 1 - NVIDIA]: " GPU_CHOICE
GPU_CHOICE=${GPU_CHOICE:-1}

# Disk kiválasztása
echo -e "\nElérhető lemezek:"
lsblk -d -n -o NAME,SIZE,MODEL
read -p "Add meg a telepítési lemez nevét [alapértelmezett: sda]: " DISK
DISK=${DISK:-sda}
TARGET="/dev/$DISK"

echo -e "\nFIGYELEM: A(z) $TARGET lemez teljes tartalma felülíródhat!"
read -p "Biztosan folytatod? (igen/nem) [alapértelmezett: igen]: " CONFIRM
CONFIRM=${CONFIRM:-igen}
if [ "$CONFIRM" != "igen" ]; then
  echo "Telepítés megszakítva."
  exit 1
fi

# Particionálás kérdések (Swap & Home)
read -p "Szeretnél SWAP partíciót? (igen/nem) [alapértelmezett: igen]: " USE_SWAP
USE_SWAP=${USE_SWAP:-igen}

SWAP_SIZE="2GiB"
if [ "$USE_SWAP" == "igen" ]; then
  TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
  SUGGESTED_SWAP=$((TOTAL_RAM_GB / 2))
  [ "$SUGGESTED_SWAP" -lt 1 ] && SUGGESTED_SWAP=1
  
  read -p "Add meg a SWAP méretét (pl. 2GiB, 4GiB) [Ajánlott: ${SUGGESTED_SWAP}GiB]: " SWAP_SIZE
  SWAP_SIZE=${SWAP_SIZE:-${SUGGESTED_SWAP}GiB}
fi

read -p "Szeretnél külön /home partíciót? (igen/nem) [alapértelmezett: igen]: " USE_HOME
USE_HOME=${USE_HOME:-igen}

if [ "$USE_HOME" == "igen" ]; then
  read -p "Mekkora legyen a gyökér (root) partíció mérete? [alapértelmezett: 75GiB]: " ROOT_SIZE
  ROOT_SIZE=${ROOT_SIZE:-75GiB}
fi

# Particionálás végrehajtása parted-del
echo "Particionálás előkészítése..."
parted --script "$TARGET" mklabel gpt
parted --script "$TARGET" mkpart "EFI" fat32 1MiB 512MiB
parted --script "$TARGET" set 1 esp on

CURRENT_START="512MiB"

if [ "$USE_SWAP" == "igen" ]; then
  SWAP_END=$(echo "$CURRENT_START + $SWAP_SIZE" | bc 2>/dev/null || echo "2.5GiB")
  parted --script "$TARGET" mkpart "swap" linux-swap "$CURRENT_START" "$SWAP_END"
  CURRENT_START="$SWAP_END"
fi

if [ "$USE_HOME" == "igen" ]; then
  ROOT_END=$(echo "$CURRENT_START + $ROOT_SIZE" | bc 2>/dev/null || echo "75.5GiB")
  parted --script "$TARGET" mkpart "root" ext4 "$CURRENT_START" "$ROOT_END"
  parted --script "$TARGET" mkpart "home" ext4 "$ROOT_END" 100%
else
  parted --script "$TARGET" mkpart "root" ext4 "$CURRENT_START" 100%
fi

# Partíciónevek lekérdezése dinamikusan
if [[ "$TARGET" =~ "nvme" ]] || [[ "$TARGET" =~ "mmcblk" ]]; then
  EFI_PART="${TARGET}p1"
  if [ "$USE_SWAP" == "igen" ] && [ "$USE_HOME" == "igen" ]; then
    SWAP_PART="${TARGET}p2"
    ROOT_PART="${TARGET}p3"
    HOME_PART="${TARGET}p4"
  elif [ "$USE_SWAP" == "igen" ]; then
    SWAP_PART="${TARGET}p2"
    ROOT_PART="${TARGET}p3"
  elif [ "$USE_HOME" == "igen" ]; then
    ROOT_PART="${TARGET}p2"
    HOME_PART="${TARGET}p3"
  else
    ROOT_PART="${TARGET}p2"
  fi
else
  EFI_PART="${TARGET}1"
  if [ "$USE_SWAP" == "igen" ] && [ "$USE_HOME" == "igen" ]; then
    SWAP_PART="${TARGET}2"
    ROOT_PART="${TARGET}3"
    HOME_PART="${TARGET}4"
  elif [ "$USE_SWAP" == "igen" ]; then
    SWAP_PART="${TARGET}2"
    ROOT_PART="${TARGET}3"
  elif [ "$USE_HOME" == "igen" ]; then
    ROOT_PART="${TARGET}2"
    HOME_PART="${TARGET}3"
  else
    ROOT_PART="${TARGET}2"
  fi
fi

# Formázások és SWAP bekapcsolás
echo "Formázás..."
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"

if [ "$USE_SWAP" == "igen" ]; then
  mkswap "$SWAP_PART"
  swapon "$SWAP_PART"
fi

if [ "$USE_HOME" == "igen" ]; then
  mkfs.ext4 -F "$HOME_PART"
fi

# Felcsatolások
echo "Fájlrendszer felcsatolása..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

if [ "$USE_HOME" == "igen" ]; then
  mkdir -p /mnt/home
  mount "$HOME_PART" /mnt/home
fi

# GPU alapú csomagok összeállítása
GPU_PACKAGES=""
if [ "$GPU_CHOICE" == "1" ]; then
  GPU_PACKAGES="nvidia-open nvidia-settings nvidia-utils lib32-nvidia-utils opencl-nvidia libva-nvidia-driver libxnvctrl"
elif [ "$GPU_CHOICE" == "2" ]; then
  GPU_PACKAGES="mesa lib32-mesa xf86-video-amdgpu vulkan-radeon lib32-vulkan-radeon"
elif [ "$GPU_CHOICE" == "3" ]; then
  GPU_PACKAGES="mesa lib32-mesa intel-media-driver vulkan-intel lib32-vulkan-intel"
fi

# Extra meghajtók opció
read -p "Szeretnéd csatolni a Games (1TB Ext4) és Downloads (NTFS) extra meghajtókat? (igen/nem) [alapértelmezett: igen]: " ADD_EXTRA
ADD_EXTRA=${ADD_EXTRA:-igen}

# Csomagok telepítése (pacstrap)
echo "Csomagok telepítése..."
pacstrap -K /mnt \
  base base-devel linux linux-firmware linux-headers nano micro git networkmanager \
  grub efibootmgr xorg-server xfce4-session xfce4-settings xfce4-panel xfce4-appfinder xfce4-power-manager xfce4-taskmanager xfce4-terminal xfconf xfdesktop xfwm4 lightdm lightdm-gtk-greeter numlockx \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber gst-plugin-pipewire pavucontrol \
  $GPU_PACKAGES \
  firefox firefox-i18n-hu libreoffice-fresh libreoffice-fresh-hu hunspell-hu mythes-hu aspell-hu \
  mc mousepad thunar thunar-archive-plugin thunar-media-tags-plugin thunar-volman file-roller 7zip unrar unzip \
  keepassxc qbittorrent audacious parole ristretto galculator \
  lutris gamemode gamescope mangohud wine wine-gecko wine-mono \
  lib32-freetype2 lib32-gamemode lib32-gnutls lib32-libglvnd lib32-vulkan-icd-loader \
  udisks2 gvfs gvfs-afc gvfs-gphoto2 gvfs-mtp gvfs-nfs gvfs-smb ntfs-3g exfatprogs dosfstools \
  flatpak pacman-contrib reflector htop glances duf inxi lsb-release sudo

# Fstab generálása
genfstab -U /mnt >> /mnt/etc/fstab

if [ "$ADD_EXTRA" == "igen" ]; then
  mkdir -p /mnt/Games /mnt/Download
  cat << 'EOF' >> /mnt/etc/fstab

# Games Ext4 1TB
UUID=9471a888-07ec-45ed-b516-eb6aa1513a64 /Games ext4 defaults,noatime,nofail,x-gvfs-show,x-gvfs-name=Games 0 2

# Downloads NTFS
UUID=7460557760554152 /Download ntfs3 defaults,noatime,uid=1000,gid=1000,umask=022,nofail,x-gvfs-show,x-gvfs-name=Downloads 0 0
EOF
fi

# Chroot konfig
arch-chroot /mnt /bin/bash <<EOF

ln -sf /usr/share/zoneinfo/Europe/Budapest /etc/localtime
hwclock --systohc

echo "hu_HU.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=hu_HU.UTF-8" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname

# Pacman & Makepkg tuning
sed -i 's/#Color/Color\nILoveCandy/' /etc/pacman.conf
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 9/' /etc/pacman.conf
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
  echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
fi

sed -i 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j\$(nproc)"/' /etc/makepkg.conf
sed -i 's/^COMPRESSZST=(zstd -c -z -q -)/COMPRESSZST=(zstd -c -z -q --threads=0 -)/' /etc/makepkg.conf
sed -i 's/#BUILDDIR=\/tmp\/build/BUILDDIR=\/tmp\/build/' /etc/makepkg.conf

# LightDM NumLock
if grep -q "\[Seat:\*\]" /etc/lightdm/lightdm.conf; then
  sed -i '/\[Seat:\*\]/a display-setup-script=numlockx on' /etc/lightdm/lightdm.conf
else
  echo -e "\n[Seat:*]\ndisplay-setup-script=numlockx on" >> /etc/lightdm/lightdm.conf
fi

systemctl enable NetworkManager
systemctl enable lightdm

# Felhasználók
echo "root:$ROOTPASSWORD" | chpasswd
useradd -m -G wheel,storage,power,input -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# -- GRUB beállítások: os-prober tiltás --
sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub
if ! grep -q "GRUB_DISABLE_OS_PROBER=true" /etc/default/grub; then
  echo "GRUB_DISABLE_OS_PROBER=true" >> /etc/default/grub
fi

# -- HA NVIDIA lett választva, beírjuk a kernel paramétereket a GRUB-ba --
if [ "$GPU_CHOICE" == "1" ]; then
  echo "NVIDIA kernel paraméterek hozzáadása a GRUB-hoz..."
  sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1 nvidia_drm.fbdev=1"/' /etc/default/grub
fi

# GRUB telepítés
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
grub-mkconfig -o /boot/grub/grub.cfg

# Takarító szkript & Aliasok
cat << 'CLEAN_EOF' > /home/$USERNAME/.arch-clean.sh
#!/usr/bin/env bash
set -e
sudo paccache -r -k 2 || true
orphans=\$(pacman -Qtdq || true)
[ -n "\$orphans" ] && sudo pacman -Rns \$orphans
sudo journalctl --vacuum-time=7d
echo "✅ Takarítás kész!"
CLEAN_EOF
chmod +x /home/$USERNAME/.arch-clean.sh
chown $USERNAME:$USERNAME /home/$USERNAME/.arch-clean.sh

cat << 'BASHRC_EOF' >> /home/$USERNAME/.bashrc
alias cl='clear'
alias e='exit'
alias y='yay -Syu'
alias sr='sudo reboot'
alias in='sudo pacman -S '
alias rem="\$HOME/.arch-clean.sh"
BASHRC_EOF
chown $USERNAME:$USERNAME /home/$USERNAME/.bashrc

EOF

# Google Chrome AUR-ból
echo "Google Chrome telepítése..."
arch-chroot /mnt /bin/bash -c "
  cd /tmp
  sudo -u $USERNAME git clone https://aur.archlinux.org/google-chrome.git
  cd google-chrome
  sudo -u $USERNAME makepkg -si --noconfirm
  rm -rf /tmp/google-chrome
"

echo -e "\n=== Telepítés sikeresen kész! Lépj ki és indítsd újra a gépet (reboot). ==="
