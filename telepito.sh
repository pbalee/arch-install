#!/usr/bin/env bash
# Arch Linux interaktív telepítő – pbalee community edition
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="3.6"
SCRIPT_NAME="Arch Linux kényelmes telepítő"

# ---------- Színek és segédfüggvények ----------
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi

info()  { printf '%sℹ%s %s\n' "$CYAN" "$RESET" "$*"; }
ok()    { printf '%s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s⚠%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()   { printf '%s✖ HIBA:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

cleanup_on_error() {
  local rc=$?
  printf '\n%sA telepítő hibával leállt (kilépési kód: %s).%s\n' "$RED" "$rc" "$RESET" >&2
  exit "$rc"
}
trap cleanup_on_error ERR

ask_default() {
  local prompt=$1 default=$2 answer
  read -r -p "$prompt [$default]: " answer
  printf '%s' "${answer:-$default}"
}

ask_yes_no() {
  local prompt=$1 default=${2:-nem} answer
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

need_command() { command -v "$1" >/dev/null 2>&1 || die "Hiányzó parancs: $1. Arch ISO alatt indítottad a telepítőt?"; }

# ---------- Előfeltételek ----------
[[ $EUID -eq 0 ]] || die "Rootként futtasd: sudo bash telepito.sh"
[[ -d /sys/firmware/efi ]] || die "UEFI módban indított Arch ISO szükséges."
for cmd in lsblk awk sed grep parted mkfs.fat mkfs.ext4 mkswap swapon mount umount pacstrap genfstab arch-chroot blkid; do
  need_command "$cmd"
done

# ---------- Alapadatok ----------
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

# ---------- Asztali környezet ----------
printf '\n%sAsztali környezet%s\n' "$BOLD" "$RESET"
printf '  1) XFCE\n  2) GNOME\n  3) KDE Plasma\n'
DE_CHOICE=$(ask_number "Választás (1–3)" 1 1 3)
case "$DE_CHOICE" in
  1) DE_NAME="XFCE"; DE_PACKAGES=(xorg-server xfce4 xfce4-whiskermenu-plugin xdg-user-dirs lightdm lightdm-gtk-greeter numlockx) ;;
  2) DE_NAME="GNOME"; DE_PACKAGES=(gnome gdm xdg-user-dirs) ;;
  3) DE_NAME="KDE Plasma"; DE_PACKAGES=(plasma kde-applications sddm xdg-user-dirs) ;;
esac

# ---------- Grafikus kártya ----------
printf '\n%sGrafikus kártya%s\n' "$BOLD" "$RESET"
printf '  1) NVIDIA\n  2) AMD\n  3) Intel\n  4) Egyéb / alap\n'
GPU_CHOICE=$(ask_number "Választás (1–4)" 4 1 4)
GPU_PACKAGES=()
case "$GPU_CHOICE" in
  1) GPU_PACKAGES=(nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils opencl-nvidia libva-nvidia-driver libxnvctrl) ;;
  2) GPU_PACKAGES=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon) ;;
  3) GPU_PACKAGES=(mesa lib32-mesa intel-media-driver vulkan-intel lib32-vulkan-intel) ;;
  4) ;;
esac

# ---------- Lemez kiválasztása ----------
printf '\n%sElérhető fizikai lemezek%s\n' "$BOLD" "$RESET"
mapfile -t DISK_PATHS < <(lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}') ((${#DISK_PATHS[@]} > 0)) || die "Nem található fizikai lemez."
for idx in "${!DISK_PATHS[@]}"; do
  path=${DISK_PATHS[$idx]}
  details=$(lsblk -dnpo SIZE,MODEL "$path" \vert{} sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
  printf '  %d) %-18s %s\n' "$((idx+1))" "$path" "$details"
done
DISK_INDEX=$(ask_number "A céllemez sorszáma" 1 1 "${#DISK_PATHS[@]}")
TARGET=${DISK_PATHS[$((DISK_INDEX-1))]}
[[ -b "$TARGET" ]] || die "A kiválasztott cél nem blokkeszköz: $TARGET"

# ---------- Particionálási terv opciók ----------
USE_SWAP=igen
USE_HOME=igen
FORMAT_HOME=igen
SWAP_SIZE=4
ROOT_SIZE=75

if ask_yes_no "Szeretnél külön SWAP partíciót?" "igen"; then
  USE_SWAP=igen
  TOTAL_RAM_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
  TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
  SUGGESTED_SWAP=$((TOTAL_RAM_GB / 2))
  [ "$SUGGESTED_SWAP" -lt 1 ] && SUGGESTED_SWAP=1
  SWAP_SIZE=$(ask_number "Swap mérete GiB-ban" "$SUGGESTED_SWAP" 1 128)
else
  USE_SWAP=nem
fi

if ask_yes_no "Szeretnél külön /home partíciót?" "igen"; then
  USE_HOME=igen
  ROOT_SIZE=$(ask_number "A root (/) partíció mérete GiB-ban" 75 20 4096)
  
  if ask_yes_no "Formázzuk a meglévő /home partíciót? (Nem = Meglévő /home meghagyása adatokkal)" "nem"; then
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

if [[ "$FORMAT_HOME" == nem ]]; then
  RESTORE_XFCE=nem
  info "Meglévő /home partíció kiválasztva: az XFCE profil visszatöltése kihagyva a meglévő adatok védelmében."
fi

# ---------- Pacman beállítások ----------
sed -i 's/^#Color$/Color/' /etc/pacman.conf || true
grep -q '^ILoveCandy$' /etc/pacman.conf \vert{}\vert{} sed -i '/^Color$/a ILoveCandy' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 9/' /etc/pacman.conf || true
grep -q '^[multilib]' /etc/pacman.conf || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
pacman -Sy --noconfirm

# ---------- Particionálás dinamikus számítással ----------
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
