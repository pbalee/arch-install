#!/usr/bin/env bash
# Arch Linux interaktív telepítő – pbalee community edition
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="4.1"
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
DE_CHOICE=$(ask_number "Választás (1–3)" 1
