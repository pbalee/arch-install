#!/bin/bash

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

echo "=== Arch Linux Automata Telepítő (pbalee Pro verzió) ==="

# Alapértelmezett adatok
read -p "Add meg a gépnevet (hostname) [alapértelmezett: bluelight]: " HOSTNAME
HOSTNAME=${HOSTNAME:-bluelight}

read -p "Add meg a felhasználónevet [alapértelmezett: pbalee]: " USERNAME
USERNAME=${USERNAME:-pbalee}

# Jelszavak bekérése fordítva és kétszer megerősítve
while true; do
  read -s -p "Add meg a ROOT jelszavát [alapértelmezett: root]: " ROOTPASSWORD
  ROOTPASSWORD=${ROOTPASSWORD:-root}
  echo
  read -s -p "Add meg a ROOT jelszavát újra: " ROOTPASSWORD2
  ROOTPASSWORD2=${ROOTPASSWORD2:-root}
  echo
  [ "$ROOTPASSWORD" == "$ROOTPASSWORD2" ] && break
  echo "❌ A jelszavak nem egyeznek! Próbáld újra."
done

while true; do
  read -s -p "Add meg a felhasználó ($USERNAME) jelszavát [alapértelmezett: pbalee]: " PASSWORD
  PASSWORD=${PASSWORD:-pbalee}
  echo
  read -s -p "Add meg a felhasználó jelszavát újra: " PASSWORD2
  PASSWORD2=${PASSWORD2:-pbalee}
  echo
  [ "$PASSWORD" == "$PASSWORD2" ] && break
  echo "❌ A jelszavak nem egyeznek! Próbáld újra."
done

# -- ASZTALI KÖRNYEZET VÁLASZTÁS --
echo -e "\nMilyen asztali környezetet szeretnél?"
echo "1) XFCE (Könnyű, gyors, megszokott) [Alapértelmezett]"
echo "2) GNOME (Modern, elegáns)"
echo "3) KDE Plasma (Extremül testreszabható)"
read -p "Válassz (1-3) [alapértelmezett: 1]: " DE_CHOICE
DE_CHOICE=${DE_CHOICE:-1}

DE_PACKAGES=""
if [ "$DE_CHOICE" == "1" ]; then
  DE_PACKAGES="xorg-server xfce4-session xfce4-settings xfce4-panel xfce4-appfinder xfce4-power-manager xfce4-taskmanager xfce4-terminal xfconf xfdesktop xfwm4 lightdm lightdm-gtk-greeter numlockx"
elif [ "$DE_CHOICE" == "2" ]; then
  DE_PACKAGES="xorg-server gnome gdm"
elif [ "$DE_CHOICE" == "3" ]; then
  DE_PACKAGES="xorg-server plasma kde-applications sddm"
fi

# -- GPU VÁLASZTÁS --
echo -e "\nMilyen grafikus kártya van a gépben?"
echo "1) NVIDIA (open illesztőprogramok + nvidia-drm beállítások)"
echo "2) AMD (radeon / amdgpu)"
echo "3) Intel (i915 / intel)"
echo "4) Egyéb / Alap (nincs extra driver)"
read -p "Válassz (1-4) [alapértelmezett: 4]: " GPU_CHOICE
GPU_CHOICE=${GPU_CHOICE:-4}

# -- DISK KIVÁLASZTÁS SZÁMOKKAL --
echo -e "\nElérhető lemezek:"
mapfile -t DISKS < <(lsblk -d -n -o NAME,SIZE,MODEL | grep -v "loop")
for i in "${!DISKS[@pliers]}"; do
  echo "$((i+1))) ${DISKS[$i]}"
done

read -p "Add meg a lemez sorszámát [alapértelmezett: 1]: " DISK_NUM
DISK_NUM=${DISK_NUM:-1}
SELECTED_LINE="${DISKS[$((DISK_NUM-1))]}"
DISK_NAME=$(echo "$SELECTED_LINE" | awk '{print $1}')
TARGET="/dev/$DISK_NAME"

echo -e "\nFIGYELEM: A(z) $TARGET lemez teljes tartalma felülíródhat!"
read -p "Biztosan folytatod? (igen/nem) [alapértelmezett: igen]: " CONFIRM
CONFIRM=${CONFIRM:-igen}
if [ "$CONFIRM" != "igen" ]; then
  echo "Telepítés megszakítva."
  exit 1
fi

# Extra meghajtók opció
read -p "Szeretnéd csatolni a Games (1TB Ext4) és Downloads (NTFS) extra meghajtókat? (igen/nem) [alapértelmezett: nem]: " ADD_EXTRA
ADD_EXTRA=${ADD_EXTRA:-nem}

# Particionálás kérdések (Swap & Home - mértékegység nélkül)
read -p "Szeretnél SWAP partíciót? (igen/nem) [alapértelmezett: igen]: " USE_SWAP
USE_SWAP=${USE_SWAP:-igen}

SWAP_SIZE="4"
if [ "$USE_SWAP" == "igen" ]; then
  TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
  SUGGESTED_SWAP=$((TOTAL_RAM_GB / 2))
  [ "$SUGGESTED_SWAP" -lt 1 ] && SUGGESTED_SWAP=1
  
  read -p "Add meg a SWAP méretét Gigabájtban (csak a szám) [Ajánlott: ${SUGGESTED_SWAP}]: " SWAP_SIZE
  SWAP_SIZE=${SWAP_SIZE:-${SUGGESTED_SWAP}}
fi

read -p "Szeretnél külön /home partíciót? (igen/nem) [alapértelmezett: igen]: " USE_HOME
USE_HOME=${USE_HOME:-igen}

ROOT_SIZE="75"
if [ "$USE_HOME" == "igen" ]; then
  read -p "Mekkora legyen a gyökér (root) partíció Gigabájtban (csak a szám) [alapértelmezett: 75]: " ROOT_SIZE
  ROOT_SIZE=${ROOT_SIZE:-75}
fi

# Particionálás végrehajtása parted-del (Sorrend: EFI -> Root -> Home -> Swap)
echo "Particionálás előkészítése..."
parted --script "$TARGET" mklabel gpt

# 1. EFI partíció (Fix 512MiB)
parted --script "$TARGET" mkpart "EFI" fat32 1MiB 512MiB
parted --script "$TARGET" set 1 esp on

CUR=512

# 2. Root partíció
if [ "$USE_HOME" == "igen" ]; then
  ROOT_END_MB=$(echo "$CUR + $ROOT_SIZE * 1024" | bc)
  parted --script "$TARGET" mkpart "root" ext4 "${CUR}MiB" "${ROOT_END_MB}MiB"
  CUR=$ROOT_END_MB
  
  # 3. Home partíció (A Swap előtt, ha van swap, a maradékból levonva, vagy ha nincs swap, a végéig)
  if [ "$USE_SWAP" == "igen" ]; then
    HOME_END_MB=$(echo "100% - $SWAP_SIZE * 1024" | bc) # Könnyebb százalékkal vagy számítással
    # Pontosabb számítás MiB-ben: lemez teljes méretének lekérdezése
    DISK_SIZE_MB=$(parted -s "$TARGET" unit MiB print | grep Disk | awk '{print $2}' | tr -d 'MiB')
    SWAP_START_MB=$(echo "$DISK_SIZE_MB - $SWAP_SIZE * 1024" | bc)
    
    parted --script "$TARGET" mkpart "home" ext4 "${CUR}MiB" "${SWAP_START_MB}MiB"
    parted --script "$TARGET" mkpart "swap" linux-swap "${SWAP_START_MB}MiB" "100%"
  else
    parted --script "$TARGET" mkpart "home" ext4 "${CUR}MiB" "100%"
  fi
else
  # Nincs külön Home
  if [ "$USE_SWAP" == "igen" ]; then
    DISK_SIZE_MB=$(parted -s "$TARGET" unit MiB print | grep Disk | awk '{print $2}' | tr -d 'MiB')
    SWAP_START_MB=$(echo "$DISK_SIZE_MB - $SWAP_SIZE * 1024" | bc)
    
    parted --script "$TARGET" mkpart "root" ext4 "${CUR}MiB" "${SWAP_START_MB}MiB"
    parted --script "$TARGET" mkpart "swap" linux-swap "${SWAP_START_MB}MiB" "100%"
  else
    parted --script "$TARGET" mkpart "root" ext4 "${CUR}MiB" "100%"
  fi
fi

# Partíciónevek dinamikus meghatározása a sorrend alapján (EFI -> Root -> Home -> Swap)
if [[ "$TARGET" =~ "nvme" ]] || [[ "$TARGET" =~ "mmcblk" ]]; then
  EFI_PART="${TARGET}p1"
  if [ "$USE_SWAP" == "igen" ] && [ "$USE_HOME" == "igen" ]; then
    ROOT_PART="${TARGET}p2"
    HOME_PART="${TARGET}p3"
    SWAP_PART="${TARGET}p4"
  elif [ "$USE_SWAP" == "igen" ]; then
    ROOT_PART="${TARGET}p2"
    SWAP_PART="${TARGET}p3"
  elif [ "$USE_HOME" == "igen" ]; then
    ROOT_PART="${TARGET}p2"
    HOME_PART="${TARGET}p3"
  else
    ROOT_PART="${TARGET}p2"
  fi
else
  EFI_PART="${TARGET}1"
  if [ "$USE_SWAP" == "igen" ] && [ "$USE_HOME" == "igen" ]; then
    ROOT_PART="${TARGET}2"
    HOME_PART="${TARGET}3"
    SWAP_PART="${TARGET}4"
  elif [ "$USE_SWAP" == "igen" ]; then
    ROOT_PART="${TARGET}2"
    SWAP_PART="${TARGET}3"
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

if [ "$USE_HOME" == "igen" ]; then
  mkfs.ext4 -F "$HOME_PART"
fi

if [ "$USE_SWAP" == "igen" ]; then
  mkswap "$SWAP_PART"
  swapon "$SWAP_PART"
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

# Csomagok telepítése (pacstrap)
echo "Csomagok telepítése..."
pacstrap -K /mnt \
  base base-devel linux linux-firmware linux-headers nano micro git networkmanager \
  grub efibootmgr $DE_PACKAGES \
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

# Display Manager kezelés (LightDM vagy GDM vagy SDDM)
if [ "$DE_CHOICE" == "1" ]; then
  systemctl enable lightdm
  if grep -q "\[Seat:\*\]" /etc/lightdm/lightdm.conf; then
    sed -i '/\[Seat:\*\]/a display-setup-script=numlockx on' /etc/lightdm/lightdm.conf
  else
    echo -e "\n[Seat:*]\ndisplay-setup-script=numlockx on" >> /etc/lightdm/lightdm.conf
  fi
elif [ "$DE_CHOICE" == "2" ]; then
  systemctl enable gdm
elif [ "$DE_CHOICE" == "3" ]; then
  systemctl enable sddm
fi

systemctl enable NetworkManager

# Felhasználók
echo "root:$ROOTPASSWORD" | chpasswd
useradd -m -G wheel,storage,power,input -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# -- GRUB beállítások: os-prober tiltás --
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
