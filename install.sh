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

# Extra meghajtók opció (Kérdezzük meg ITT ELEGEN, mielőtt a partícionálás elindul!)
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

# Particionálás végrehajtása parted-del (Biztos GPT séma)
echo "Particionálás előkészítése..."
parted --script "$TARGET" mklabel gpt

# 1. EFI partíció (1MiB - 512MiB)
parted --script "$TARGET" mkpart "EFI" fat32 1MiB 512MiB
parted --script "$TARGET" set 1 esp on

# Partíciónevek meghatározása helyesen
if [[ "$TARGET" =~ "nvme" ]] || [[ "$TARGET" =~ "mmcblk" ]]; then
  EFI_PART="${TARGET}p1"
  P2="${TARGET}p2"
  P3="${TARGET}p3"
  P4="${TARGET}p4"
else
  EFI_PART="${TARGET}1"
  P2="${TARGET}2"
  P3="${TARGET}3"
  P4="${TARGET}4"
fi

# 2. Swap vagy Root logika
CURRENT_START="512MiB"

if [ "$USE_SWAP" == "igen" ]; then
  SWAP_END=$(echo "512 + ${SWAP_SIZE%GiB} * 1024" | bc) # Egyszerűsített számítás MiB-ben vagy használhatjuk közvetlenül a GiB-et
  # A parted kezeli a GiB-et is, ha pontosan adjuk meg:
  # Csináljuk tisztán:
  SWAP_END_VAL=$(echo 512 + $(echo $SWAP_SIZE | tr -d 'GiB')) # közelítés helyett:
  # Használjuk a parted natív méretezését:
  # Egyszerűbb: EFI után 512MiB-től indul a swap
  SWAP_START="512MiB"
  SWAP_STOP=$(echo 512 + $(echo $SWAP_SIZE | sed 's/[^0-9]*//g') * 1024)MiB 
  # Hogy elkerüljük a bash math hibákat, csináljuk így:
fi
