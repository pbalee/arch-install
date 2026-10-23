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
if ! grep -q "^[multilib]" /etc/pacman.conf; then
  echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
fi
pacman -Sy

echo "=== Arch Linux Automata Telepítő (pbalee GPU-választós stabil verzió) ==="

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
read -p "Válassz (1-4) [alapértelmezett: 4]: " GPU_CHOICE
GPU_CHOICE=${GPU_CHOICE:-4}

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

# Extra meghajtók opció
read -p "Szeretnéd csatolni a Games (1TB Ext4) és Downloads (NTFS) extra meghajtókat? (igen/nem) [alapértelmezett: nem]: " ADD_EXTRA
ADD_EXTRA=${ADD_EXTRA:-nem}

# Particionálás kérdések (Swap & Home)
read -p "Szeretnél SWAP partíciót? (igen/nem) [alapértelmezett: igen]: " USE_SWAP
USE_SWAP=${USE_SWAP:-igen}

SWAP_SIZE="4GiB"
if [ "$USE_SWAP" == "igen" ]; then
  TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
  SUGGESTED_SWAP=$((TOTAL_RAM_GB / 2))
  [ "$SUGGESTED_SWAP" -lt 1 ] && SUGGESTED_SWAP=1
  
  read -p "Add meg a SWAP méretét mértékegységgel (pl. 4GiB, 8GiB) [Ajánlott: ${SUGGESTED_SWAP}GiB]: " SWAP_SIZE
  SWAP_SIZE=${SWAP_SIZE:-${SUGGESTED_SWAP}GiB}
fi

read -p "Szeretnél külön /home partíciót? (igen/nem) [alapértelmezett: igen]: " USE_HOME
USE_HOME=${USE_HOME:-igen}

ROOT_SIZE="75GiB"
if [ "$USE_HOME" == "igen" ]; then
  read -p "Mekkora legyen a gyökér (root) partíció mérete mértékegységgel (pl. 75GiB)? [alapértelmezett: 75GiB]: " ROOT_SIZE
  ROOT_SIZE=${ROOT_SIZE:-75GiB}
fi

# Particionálás végrehajtása parted-del (Biztos GPT séma, százalékok vagy fix méretek helyett pontos eltolásokkal)
echo "Particionálás előkészítése..."
parted --script "$TARGET" mklabel gpt

# 1. EFI partíció
parted --script "$TARGET" mkpart "EFI" fat32 1MiB 512MiB
parted --script "$TARGET" set 1 esp on

# Következő kezdőpont fixen 512MiB
CUR=512

# 2. Swap partíció (ha kérték)
if [ "$USE_SWAP" == "igen" ]; then
  SWAP_VAL=$(echo "$SWAP_SIZE" | sed 's/[^0-9]*//g')
  SWAP_UNIT=$(echo "$SWAP_SIZE" | sed 's/[0-9]*//g')
  [ -z "$SWAP_UNIT" ] && SWAP_UNIT="GiB"
  
  SWAP_END=$((CUR + SWAP_VAL))
  parted --script "$TARGET" mkpart "swap" linux-swap "${CUR}MiB" "${SWAP_END}${SWAP_UNIT}"
  CUR=$SWAP_END
fi

# Partíciónevek meghatározása dinamikusan a választások alapján
if [[ "$TARGET" =~ "nvme" ]] \vert{}\vert{} [[ "$TARGET" =~ "mmcblk" ]]; then
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

# 3. Root és Home partíciók létrehozása
if [ "$USE_HOME" == "igen" ]; then
  ROOT_VAL=$(echo "$ROOT_SIZE" | sed 's/[^0-9]*//g')
  ROOT_UNIT=$(echo "$ROOT_SIZE" | sed 's/[0-9]*//g')
  [ -z "$ROOT_UNIT" ] && ROOT_UNIT="GiB"
  
  # Ha a swap GiB-ben volt, de a CUR MiB-ben, kezeljük le egyszerűsítve:
  # Legbiztosabb, ha a parted-nek közvetlenül a maradék helyeket adjuk meg:
  parted --script "$TARGET" mkpart "root" ext4 "${CUR}MiB" "${ROOT_SIZE}"
  parted --script "$TARGET" mkpart "home" ext4 "${ROOT_SIZE}" 100%
else
  parted --script "$TARGET" mkpart "root" ext4 "${CUR}MiB" 100%
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
  GPU_PACKAGES="mesa lib32-mesa xf86-video-amdgpu vulkan-radeon lib32-vulkan-
