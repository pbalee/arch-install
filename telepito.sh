cat << 'EOF' > telepito.sh
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

info()  { printf '\033[36mℹ\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m✔\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m⚠\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[31m✖ HIBA:\033[0m %s\n' "$*" >&2; exit 1; }

trap 'local rc=$?; echo -e "\n\033[31mA telepítő hibával leállt (kilépési kód: $rc).\033[0m" >&2; exit "$rc"' ERR

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
  2) GPU_PACKAGES=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon lib32-mesa) ;;
  3) GPU_PACKAGES=(mesa lib32-mesa intel-media-driver vulkan-intel lib32-vulkan-intel) ;;
  4) ;;
esac

printf '\n\033[1mElérhető fizikai lemezek\033[0m\n'
DISK_PATHS=()
while read -r disk_path; do
  [[ -n "$disk_path" ]] && DISK_PATHS+=("$disk_path")
done < <(lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}')

((${#DISK_PATHS[@]} > 0)) || die "Nem található fizikai lemez."
for idx in "${!DISK_PATHS[@]}"; do
  path="${DISK_PATHS[$idx]}"
  details=$(lsblk -dnpo SIZE,MODEL "$path" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
  printf '  %d) %-18s %s\n' "$((idx+1))" "$path" "$details"
done

DISK_INDEX=$(ask_number "A céllemez sorszáma" 1 1 "${#DISK_PATHS[@]}")
TARGET="${DISK_PATHS[$((DISK_INDEX-1))]}"
[[ -b "$TARGET" ]] || die "A kiválasztott cél nem blokkeszköz: $TARGET"

USE_SWAP=igen; USE_HOME=igen; FORMAT_HOME=igen; SWAP_SIZE=4; ROOT_SIZE=75

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
grep -q '^ILoveCandy$' /etc/pacman.conf || sed -i '/^Color$/a ILoveCandy' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 9/' /etc/pacman.conf || true
grep -q '^\[multilib\]' /etc/pacman.conf || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
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

pacstrap -K /mnt "${BASE_PACKAGES[@]}" "${DE_PACKAGES[@]}" "${COMMON_PACKAGES[@]}" "${GPU_PACKAGES[@]}"

genfstab -U /mnt > /mnt/etc/fstab
if [[ "$ADD_EXTRA" == igen ]]; then
  mkdir -p /mnt/mnt/Games /mnt/mnt/Download
  cat >> /mnt/etc/fstab <<'FSTAB_EOF'
UUID=9471a888-07ec-45ed-b516-eb6aa1513a64 /mnt/Games ext4 defaults,noatime,nofail,x-gvfs-show,x-gvfs-name=Games 0 2
UUID=7460557760554152 /mnt/Download ntfs3 defaults,noatime,uid=1000,gid=1000,umask=022,nofail,x-gvfs-show,x-gvfs-name=Downloads 0 0
FSTAB_EOF
fi

ln -sf /usr/share/zoneinfo/Europe/Budapest /mnt/etc/localtime
arch-chroot /mnt hwclock --systohc

for locale_line in 'hu_HU.UTF-8 UTF-8' 'en_US.UTF-8 UTF-8'; do
  grep -qxF "$locale_line" /mnt/etc/locale.gen || printf '%s\n' "$locale_line" >> /mnt/etc/locale.gen
done
arch-chroot /mnt locale-gen
printf 'LANG=hu_HU.UTF-8\n' > /mnt/etc/locale.conf
printf '%s\n' "$HOSTNAME" > /mnt/etc/hostname

mkdir -p /mnt/etc/X11/xorg.conf.d
cat > /mnt/etc/X11/xorg.conf.d/00-keyboard.conf <<'KB_EOF'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "hu"
EndSection
KB_EOF

sed -i 's/^#Color$/Color/' /mnt/etc/pacman.conf || true
grep -q '^ILoveCandy$' /mnt/etc/pacman.conf || sed -i '/^Color$/a ILoveCandy' /mnt/etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 9/' /mnt/etc/pacman.conf || true
grep -q '^\[multilib\]' /mnt/etc/pacman.conf || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /mnt/etc/pacman.conf

case "$DE_CHOICE" in
  1) arch-chroot /mnt systemctl enable lightdm
     printf '\n[Seat:*]\ndisplay-setup-script=numlockx on\n' >> /mnt/etc/lightdm/lightdm.conf ;;
  2) arch-chroot /mnt systemctl enable gdm ;;
  3) arch-chroot /mnt systemctl enable sddm ;;
esac
arch-chroot /mnt systemctl enable NetworkManager

printf 'root:%s\n' "$ROOTPASSWORD" | arch-chroot /mnt chpasswd

if arch-chroot /mnt id "$USERNAME" &>/dev/null; then
  printf 'A(z) %s felhasználó már létezik, jelszó frissítése...\n' "$USERNAME"
  printf '%s:%s\n' "$USERNAME" "$PASSWORD" | arch-chroot /mnt chpasswd
else
  arch-chroot /mnt useradd -m -G wheel,storage,power,input,vboxusers -s /bin/bash "$USERNAME"
  printf '%s:%s\n' "$USERNAME" "$PASSWORD" | arch-chroot /mnt chpasswd
fi

printf '%%wheel ALL=(ALL:ALL) ALL\n' > /mnt/etc/sudoers.d/10-wheel
chmod 0440 /mnt/etc/sudoers.d/10-wheel

sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /mnt/etc/default/grub || printf '\nGRUB_DISABLE_OS_PROBER=true\n' >> /mnt/etc/default/grub
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

printf 'vboxdrv\n' > /mnt/etc/modules-load.d/virtualbox.conf
arch-chroot /mnt runuser -u "$USERNAME" -- env HOME="/home/$USERNAME" xdg-user-dirs-update || true

cat > "/mnt/home/$USERNAME/.arch-clean.sh" <<'CLEAN_EOF'
#!/usr/bin/env bash
set -u
sudo paccache -r -k 2 || true
orphans=$(pacman -Qtdq 2>/dev/null || true)
[[ -n "$orphans" ]] && sudo pacman -Rns -- "$orphans"
sudo journalctl --vacuum-time=7d
printf 'Takarítás kész!\n'
CLEAN_EOF
chmod 0755 "/mnt/home/$USERNAME/.arch-clean.sh"
arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/.arch-clean.sh"

cat >> "/mnt/home/$USERNAME/.bashrc" <<'BASHRC_EOF'

# --- Saját beállítások ---
alias cl='clear'
alias e='exit'
alias y='yay -Syu'
alias sr='sudo reboot'
alias in='sudo pacman -S '
alias rem="$HOME/.arch-clean.sh"

u() {
    echo "==> Pacman frissítés..."
    sudo pacman -Syu --noconfirm || return 1
    echo "==> Flatpak frissítés..."
    flatpak update -y
}

fastfetch
BASHRC_EOF
arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bashrc"

if [[ "$INSTALL_AUR_APPS" == igen ]]; then
  arch-chroot /mnt useradd -m -s /bin/bash aurbuilder
  printf 'aurbuilder ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman\n' > /mnt/etc/sudoers.d/aurbuilder
  chmod 0440 /mnt/etc/sudoers.d/aurbuilder
  for pkg in yay-bin google-chrome rustdesk-bin; do
    arch-chroot /mnt runuser -u aurbuilder -- bash -lc "cd /tmp && rm -rf '$pkg' && git clone 'https://aur.archlinux.org/$pkg.git' '$pkg' && cd '$pkg' && makepkg -si --noconfirm"
  done
  arch-chroot /mnt userdel -r aurbuilder || true
  rm -f /mnt/etc/sudoers.d/aurbuilder
  arch-chroot /mnt systemctl enable rustdesk.service || true
fi

if [[ "$RESTORE_XFCE" == igen ]]; then
  profile="/home/$USERNAME/xfce-backup.tar.gz"
  curl --fail --location --show-error --output "/mnt$profile" 'https://raw.githubusercontent.com/pbalee/arch-install/main/xfce-backup.tar.gz'
  arch-chroot /mnt tar -xzf "$profile" -C "/home/$USERNAME"
  rm -f "/mnt$profile"
  arch-chroot /mnt chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"
fi

ok "Telepítés sikeresen lefutott! Indítsd újra a gépet."
EOF
