#!/usr/bin/env bash
# Arch Linux interaktív telepítő – pbalee community edition
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="3.3"
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
mapfile -t DISK_PATHS < <(lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}')
((${#DISK_PATHS[@]} > 0)) || die "Nem található fizikai lemez."
for idx in "${!DISK_PATHS[@]}"; do
  path=${DISK_PATHS[$idx]}
  details=$(lsblk -dnpo SIZE,MODEL "$path" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
  printf '  %d) %-18s %s\n' "$((idx+1))" "$path" "$details"
done
DISK_INDEX=$(ask_number "A céllemez sorszáma" 1 1 "${#DISK_PATHS[@]}")
TARGET=${DISK_PATHS[$((DISK_INDEX-1))]}
[[ -b "$TARGET" ]] || die "A kiválasztott cél nem blokkeszköz: $TARGET"

# ---------- Particionálási terv opciók ----------
USE_SWAP=igen
USE_HOME=igen
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
else
  USE_HOME=nem
fi

ADD_EXTRA=$(ask_yes_no "Csatoljam a Games (ext4) és Download (NTFS) extra meghajtókat?" "nem" && echo "igen" || echo "nem")
INSTALL_AUR_APPS=igen
RESTORE_XFCE=igen

# ---------- Pacman beállítások ----------
sed -i 's/^#Color$/Color/' /etc/pacman.conf || true
grep -q '^ILoveCandy$' /etc/pacman.conf || sed -i '/^Color$/a ILoveCandy' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 9/' /etc/pacman.conf || true
grep -q '^\[multilib\]' /etc/pacman.conf || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
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
    parted --script "$TARGET" mkpart root ext4 "${CUR}MiB" "100%"
  fi
fi

partprobe "$TARGET"
sleep 2

if [[ "$TARGET" =~ (nvme|mmcblk|loop)[0-9] ]]; then PART_PREFIX="${TARGET}p"; else PART_PREFIX="$TARGET"; fi
EFI_PART="${PART_PREFIX}1"
ROOT_PART="${PART_PREFIX}2"
HOME_PART=""
SWAP_PART=""
NEXT_PART=3
if [[ "$USE_HOME" == igen ]]; then HOME_PART="${PART_PREFIX}${NEXT_PART}"; ((NEXT_PART+=1)); fi
if [[ "$USE_SWAP" == igen ]]; then SWAP_PART="${PART_PREFIX}${NEXT_PART}"; fi

# ---------- Formázás és csatolás ----------
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"
[[ -z "$HOME_PART" ]] || mkfs.ext4 -F "$HOME_PART"
if [[ -n "$SWAP_PART" ]]; then mkswap "$SWAP_PART"; swapon "$SWAP_PART"; fi

mkdir -p /mnt
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot
if [[ -n "$HOME_PART" ]]; then mkdir -p /mnt/home; mount "$HOME_PART" /mnt/home; fi

# ---------- Csomaglista ----------
BASE_PACKAGES=(base base-devel linux linux-firmware linux-headers nano micro git curl wget networkmanager grub efibootmgr sudo virtualbox virtualbox-host-dkms)
COMMON_PACKAGES=(pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber gst-plugin-pipewire pavucontrol firefox firefox-i18n-hu libreoffice-fresh libreoffice-fresh-hu hunspell-hu mythes-hu aspell-hu mc thunar thunar-archive-plugin thunar-media-tags-plugin thunar-volman file-roller 7zip unrar unzip keepassxc qbittorrent audacious parole ristretto galculator lutris gamemode gamescope mangohud wine wine-gecko wine-mono lib32-freetype2 lib32-gamemode lib32-gnutls lib32-libglvnd lib32-vulkan-icd-loader udisks2 gvfs gvfs-afc gvfs-gphoto2 gvfs-mtp gvfs-nfs gvfs-smb ntfs-3g exfatprogs dosfstools flatpak pacman-contrib reflector htop glances duf inxi lsb-release gnome-disk-utility okular fastfetch)
if [[ "$DE_CHOICE" == 1 ]]; then COMMON_PACKAGES+=(mousepad); fi
if [[ "$GPU_CHOICE" == 2 || "$GPU_CHOICE" == 3 ]]; then COMMON_PACKAGES+=(lib32-mesa); fi

pacstrap -K /mnt "${BASE_PACKAGES[@]}" "${DE_PACKAGES[@]}" "${COMMON_PACKAGES[@]}" "${GPU_PACKAGES[@]}"

genfstab -U /mnt > /mnt/etc/fstab
if [[ "$ADD_EXTRA" == igen ]]; then
  mkdir -p /mnt/mnt/Games /mnt/mnt/Download
  cat >> /mnt/etc/fstab <<'FSTAB_EOF'
UUID=9471a888-07ec-45ed-b516-eb6aa1513a64 /mnt/Games ext4 defaults,noatime,nofail,x-gvfs-show,x-gvfs-name=Games 0 2
UUID=7460557760554152 /mnt/Download ntfs3 defaults,noatime,uid=1000,gid=1000,umask=022,nofail,x-gvfs-show,x-gvfs-name=Downloads 0 0
FSTAB_EOF
fi

# ---------- Chroot beállítások (javított, nem idézetezett heredoc-kal a változók átadásához) ----------
export HOSTNAME USERNAME ROOTPASSWORD PASSWORD DE_CHOICE GPU_CHOICE INSTALL_AUR_APPS RESTORE_XFCE
arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -Eeuo pipefail
ln -sf /usr/share/zoneinfo/Europe/Budapest /etc/localtime
hwclock --systohc

for locale_line in 'hu_HU.UTF-8 UTF-8' 'en_US.UTF-8 UTF-8'; do
  grep -qxF "$locale_line" /etc/locale.gen || printf '%s\n' "$locale_line" >> /etc/locale.gen
done
locale-gen
printf 'LANG=hu_HU.UTF-8\n' > /etc/locale.conf
printf '%s\n' "$HOSTNAME" > /etc/hostname

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<'KB_EOF'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "hu"
EndSection
KB_EOF

sed -i 's/^#Color$/Color/' /etc/pacman.conf || true
grep -q '^ILoveCandy$' /etc/pacman.conf || sed -i '/^Color$/a ILoveCandy' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 9/' /etc/pacman.conf || true
grep -q '^\[multilib\]' /etc/pacman.conf || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf

case "$DE_CHOICE" in
  1) systemctl enable lightdm
     printf '\n[Seat:*]\ndisplay-setup-script=numlockx on\n' >> /etc/lightdm/lightdm.conf ;;
  2) systemctl enable gdm ;;
  3) systemctl enable sddm ;;
esac
systemctl enable NetworkManager

printf 'root:%s\n' "\$ROOTPASSWORD" | chpasswd
useradd -m -G wheel,storage,power,input,vboxusers -s /bin/bash "\$USERNAME"
printf '%s:%s\n' "\$USERNAME" "\$PASSWORD" | chpasswd
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel

sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub || printf '\nGRUB_DISABLE_OS_PROBER=true\n' >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
grub-mkconfig -o /boot/grub/grub.cfg

printf 'vboxdrv\n' > /etc/modules-load.d/virtualbox.conf

runuser -u "\$USERNAME" -- env HOME="/home/\$USERNAME" xdg-user-dirs-update

cat >> "/home/\$USERNAME/.bashrc" <<'BASHRC_EOF'
alias cl='clear'
alias e='exit'
alias y='yay -Syu'
alias sr='sudo reboot'
alias in='sudo pacman -S'
fastfetch
BASHRC_EOF
chown "\$USERNAME:\$USERNAME" "/home/\$USERNAME/.bashrc"

if [[ "\$INSTALL_AUR_APPS" == igen ]]; then
  useradd -m -s /bin/bash aurbuilder
  printf 'aurbuilder ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman\n' > /etc/sudoers.d/aurbuilder
  chmod 0440 /etc/sudoers.d/aurbuilder
  for pkg in yay-bin google-chrome rustdesk-bin; do
    runuser -u aurbuilder -- bash -lc "cd /tmp && rm -rf '$pkg' && git clone 'https://aur.archlinux.org/$pkg.git' '$pkg' && cd '$pkg' && makepkg -si --noconfirm"
  done
  userdel -r aurbuilder || true
  rm -f /etc/sudoers.d/aurbuilder
  systemctl enable rustdesk.service || true
fi

if [[ "\$RESTORE_XFCE" == igen ]]; then
  profile='/home/'"\$USERNAME"'/xfce-backup.tar.gz'
  curl --fail --location --show-error --output "\$profile" 'https://raw.githubusercontent.com/pbalee/arch-install/main/xfce-backup.tar.gz'
  tar -xzf "\$profile" -C "/home/\$USERNAME"
  rm -f "\$profile"
  chown -R "\$USERNAME:\$USERNAME" "/home/\$USERNAME/.config"
fi
CHROOT_EOF

ok "Telepítés sikeresen lefutott! Indítsd újra a gépet."
