cat << 'EOF' > telepito.sh
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

info()  { printf '\033[36mℹ\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m✔\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m⚠\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[31m✖ HIBA:\033[0m %s\n' "$*" >&2; exit 1; }

handle_error() {
  local rc=$?
  printf '\n\033[31mA telepítő hibával leállt (kilépési kód: %s).\033[0m\n' "$rc" >&2
  exit "$rc"
}
trap handle_error ERR

ask_default() {
  local prompt=$1 default=$2 answer
  read -r -p "$prompt [$default]: " answer
  printf '%s' "${answer:-$default}"
}

ask_yes_no() {
  local prompt=$1 default=${2:-igen} answer
  while true; do
    read -r -p "$prompt (igen/nem) [$default]: " answer
    answer=${answer:-$default}
    case "${answer,,}" in
      igen|i|y|yes) return 0 ;;
      nem|n|no) return 1 ;;
      *) warn "Kérlek, igen vagy nem választ adj meg." ;;
    esac
  done
}

ask_number() {
  local prompt=$1 default=$2 min=$3 max=$4 answer
  while true; do
    read -r -p "$prompt [$default]: " answer
    answer=${answer:-$default}
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= min && answer <= max )); then
      printf '%s' "$answer"; return 0
    fi
    warn "Egész számot adj meg $min és $max között."
  done
}

[[ $EUID -eq 0 ]] || die "Rootként futtasd: sudo bash telepito.sh"
[[ -d /sys/firmware/efi ]] || die "UEFI módban indított Arch ISO szükséges."

HOSTNAME=$(ask_default "Gépnév (hostname)" "bluelight")
USERNAME=$(ask_default "Felhasználónév" "pbalee")

read_password_pair() {
  local label=$1 first second
  while true; do
    read -r -s -p "$label jelszó: " first; printf '\n'
    read -r -s -p "$label jelszó újra: " second; printf '\n'
    [[ -n "$first" ]] || { warn "A jelszó nem lehet üres."; continue; }
    [[ "$first" == "$second" ]] || { warn "A két jelszó nem egyezik."; continue; }
    printf '%s' "$first"; return 0
  done
}

ROOTPASSWORD=$(read_password_pair "Root")
PASSWORD=$(read_password_pair "$USERNAME")

printf '\n\033[1mAsztali környezet\033[0m\n  1) XFCE\n  2) GNOME\n  3) KDE Plasma\n'
DE_CHOICE=$(ask_number "Választás (1–3)" 1 1 3)
case "$DE_CHOICE" in
  1) DE_PACKAGES=(xorg-server xfce4 xfce4-whiskermenu-plugin xdg-user-dirs lightdm lightdm-gtk-greeter numlockx mousepad) ;;
  2) DE_PACKAGES=(gnome gdm xdg-user-dirs) ;;
  3) DE_PACKAGES=(plasma kde-applications sddm xdg-user-dirs) ;;
esac

printf '\n\033[1mGrafikus kártya\033[0m\n  1) NVIDIA\n  2) AMD\n  3) Intel\n  4) Egyéb / alap\n'
GPU_CHOICE=$(ask_number "Választás (1–4)" 4 1 4)
GPU_PACKAGES=()
case "$GPU_CHOICE" in
  1) GPU_PACKAGES=(nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils opencl-nvidia libva-nvidia-driver libxnvctrl) ;;
  2) GPU_PACKAGES=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon) ;;
  3) GPU_PACKAGES=(mesa lib32-mesa intel-media-driver vulkan-intel lib32-vulkan-intel) ;;
  4) ;;
esac

printf '\n\033[1mElérhető fizikai lemezek\033[0m\n'
DISK_PATHS=()
for disk in $(lsblk -dno NAME,TYPE | awk '$2 == "disk" {print "/dev/"$1}'); do
  [[ -b "$disk" ]] && DISK_PATHS+=("$disk")
done

((${#DISK_PATHS[@]} > 0)) || die "Nem található fizikai lemez."
for idx in "${!DISK_PATHS[@]}"; do
  path="${DISK_PATHS[$idx]}"
  details=$(lsblk -dnpo SIZE,MODEL "$path" \vert{} sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
  printf '  %d) %-18s %s\n' "$((idx+1))" "$path" "$details"
done

DISK_INDEX=$(ask_number "A céllemez sorszáma" 1 1 "${#DISK_PATHS[@]}")
TARGET="${DISK_PATHS[$((DISK_INDEX-1))]}"
[[ -b "$TARGET" ]] || die "A kiválasztott cél nem blokkeszköz: $TARGET"

USE_SWAP=igen
USE_HOME=igen
FORMAT_HOME=igen
SWAP_SIZE=4
ROOT_SIZE=75

if ask_yes_no "Szeretnél külön SWAP partíciót?" "igen"; then
  TOTAL_RAM_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
  TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
  SUGGESTED_SWAP=$((TOTAL_RAM_GB / 2))
  [ "$SUGGESTED_SWAP" -lt 1 ] && SUGGESTED_SWAP=1
  SWAP_SIZE=$(ask_number "Swap mérete GiB-ban" "$SUGGESTED_SWAP" 1 128)
else
  USE_SWAP=nem
fi

if ask_yes_no "Szeretnél külön /home partíciót?" "igen"; then
  ROOT_SIZE=$(ask_number "A root (/) partíció mérete GiB-ban" 75 20 4096)
  if ask_yes_no "Formázzuk a /home partíciót?" "igen"; then
    FORMAT_HOME=igen
  else
    FORMAT_HOME=nem
  fi
else
  USE_HOME=nem
  FORMAT_HOME=nem
fi

ADD_EXTRA=$(ask_yes_no "Csatoljam a Games (ext4) és Download (NTFS) extra meghajtókat?" "nem" && echo "igen" || echo "nem")
INSTALL_AUR_APPS=igen
RESTORE_XFCE=igen
[[ "$FORMAT_HOME" == nem ]] && RESTORE_XFCE=nem

sed -i 's/^#Color$/Color/' /etc/pacman.conf || true
grep -q '^ILoveCandy$' /etc/pacman.conf \vert{}\vert{} sed -i '/^Color$/a ILoveCandy' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 9/' /etc/pacman.conf || true
grep -q '^[multilib]' /etc/pacman.conf || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
pacman -Sy --noconfirm

SECTORS=$(cat "/sys/class/block/$(basename "$TARGET")/size")
DISK_SIZE_MB=$((SECTORS / 2048))
END_MB=$((DISK_SIZE_MB - 2))
SWAP_MB=$((SWAP_SIZE * 1024))

parted --script "$TARGET" mklabel gpt
parted --script "$TARGET" mkpart ESP fat32 1MiB 1025MiB
parted --script "$TARGET" set 1 esp on

CUR=1025
if [[ "$USE_HOME" == igen ]]; then
  ROOT_END=$((CUR + ROOT_SIZE * 1024))
  parted --script "$TARGET" mkpart root ext4 "${CUR}MiB" "${ROOT_END}MiB"
  CUR=$ROOT_END
fi

if [[ "$USE_SWAP" == igen ]]; then
  SWAP_START=$((END_MB - SWAP_MB))
  if [[ "$USE_HOME" == igen ]]; then
    parted --script "$TARGET" mkpart home ext4 "${CUR}MiB" "${SWAP_START}MiB"
  else
    parted --script "$TARGET" mkpart root ext4 "${CUR}MiB" "${SWAP_START}MiB"
  fi
  parted --script "$TARGET" mkpart swap linux-swap "${SWAP_START}MiB" "100%"
else
  if [[ "$USE_HOME" == igen ]]; then
    parted --script "$TARGET" mkpart home ext4 "${CUR}MiB" "100%"
  else
    parted --script "$TARGET" mkpart root ext4 "${CUR}MiB" "100%"
  fi
fi

partprobe "$TARGET"
sleep 2

if [[ "$TARGET" =~ (nvme|mmcblk|loop)[0-9] ]]; then PART_PREFIX="${TARGET}p"; else PART_PREFIX="$TARGET"; fi
EFI_PART="${PART_PREFIX}1"
ROOT_PART="${PART_PREFIX}2"
HOME_PART=""; SWAP_PART=""; NEXT_PART=3
if [[ "$USE_HOME" == igen ]]; then HOME_PART="${PART_PREFIX}${NEXT_PART}"; ((NEXT_PART+=1)); fi
if [[ "$USE_SWAP" == igen ]]; then SWAP_PART="${PART_PREFIX}${NEXT_PART}"; fi

mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"
if [[ -n "$HOME_PART" ]]; then
  if [[ "$FORMAT_HOME" == igen ]]; then
    info "A /home partíció formázása..."
    mkfs.ext4 -F "$HOME_PART"
  else
    info "A /home partíció meghagyása..."
  fi
fi
if [[ -n "$SWAP_PART" ]]; then mkswap "$SWAP_PART"; swapon "$SWAP_PART"; fi

mkdir -p /mnt
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot
if [[ -n "$HOME_PART" ]]; then mkdir -p /mnt/home; mount "$HOME_PART" /mnt/home; fi

BASE_PACKAGES=(base base-devel linux linux-firmware linux-headers nano micro git curl wget networkmanager grub efibootmgr sudo virtualbox virtualbox-host-dkms)
COMMON_PACKAGES=(pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber gst-plugin-pipewire pavucontrol firefox firefox-i18n-hu libreoffice-fresh libreoffice-fresh-hu hunspell-hu mythes-hu aspell-hu mc thunar thunar-archive-plugin thunar-media-tags-plugin thunar-volman file-roller 7zip unrar unzip keepassxc qbittorrent audacious parole ristretto galculator lutris gamemode gamescope mangohud wine wine-gecko wine-mono lib32-freetype2 lib32-gamemode lib32-gnutls lib32-libglvnd lib32-vulkan-icd-loader udisks2 gvfs gvfs-afc gvfs-gphoto2 gvfs-mtp gvfs-nfs gvfs-smb ntfs-3g exfatprogs dosfstools flatpak pacman-contrib reflector htop glances duf inxi lsb-release gnome-disk-utility okular fastfetch)

pacstrap -K /mnt "${BASE_PACKAGES[@]}" "${DE_PACKAGES[@]}" "${COMMON_PACKAGES[@]}" "${GPU_PACK
