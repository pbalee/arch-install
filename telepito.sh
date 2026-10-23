#!/usr/bin/env bash
# Arch Linux interaktív telepítő – pbalee community edition
# FIGYELEM: a kiválasztott céllemez partíciós tábláját törli és újraformázza!
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="3.0"
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

pause() { read -r -p $'\nNyomj Entert a folytatáshoz…' _; }

cleanup_on_error() {
  local rc=$?
  printf '\n%sA telepítő hibával leállt (kilépési kód: %s).%s\n' "$RED" "$rc" "$RESET" >&2
  printf 'Nézd át az utolsó hibaüzenetet, és csak annak megértése után indítsd újra.\n' >&2
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

show_header() {
  clear 2>/dev/null || true
  printf '%s\n' "$CYAN"
  cat <<'BANNER'
    _             _      _     _ _                  _ _           _
   / \   _ __ ___| |__  | |   (_| |_   _ _ __  ___| (_)_ __  ___| |_
  / _ \ | '__/ __| '_ \ | |   | | | | | | '_ \/ __| | | '_ \/ __| __|
 / ___ \| | | (__| | | || |___| | | |_| | | | \__ \ | | | | \__ \ |_
/_/   \_\_|  \___|_| |_||_____|_|_|\__,_|_| |_|___/_|_|_| |_|___/\__|
BANNER
  printf '%s%s v%s%s\n' "$BOLD" "$SCRIPT_NAME" "$VERSION" "$RESET"
  printf 'Interaktív, UEFI-s Arch Linux telepítő\n'
  printf '%s\n\n' '────────────────────────────────────────────────────────────────────'
}

# ---------- Előfeltételek ----------
show_header
[[ $EUID -eq 0 ]] || die "Rootként futtasd: sudo bash install.sh"
[[ -d /sys/firmware/efi ]] || die "UEFI módban indított Arch ISO szükséges; Legacy/BIOS módban ez a telepítő nem futtatható."
for cmd in lsblk awk sed grep parted mkfs.fat mkfs.ext4 mkswap swapon mount umount pacstrap genfstab arch-chroot blkid; do
  need_command "$cmd"
done

if [[ ! -r /etc/pacman.conf ]]; then die "/etc/pacman.conf nem olvasható."; fi

warn "Ez a telepítő a kiválasztott céllemezt teljesen újraparticionálja. A rajta lévő adatok elvesznek."
info "A telepítés előtt ellenőrizd, hogy a hálózat működik, és az Arch ISO naprakész."

# ---------- Alapadatok ----------
HOSTNAME=$(ask_default "Gépnév (hostname)" "bluelight")
USERNAME=$(ask_default "Felhasználónév" "pbalee")
[[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] || die "Érvénytelen gépnév. Betű, szám, pont és kötőjel használható."
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Érvénytelen felhasználónév."
[[ "$USERNAME" != root ]] || die "A root felhasználónév nem választható."

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
warn "Ne használj egyszerű, könnyen kitalálható jelszót. A telepítő nem állít be előre ismert alapjelszót."
ROOTPASSWORD=$(read_password_pair "Root")
PASSWORD=$(read_password_pair "$USERNAME")

# ---------- Asztali környezet ----------
printf '\n%sAsztali környezet%s\n' "$BOLD" "$RESET"
printf '  1) XFCE – könnyű, X11-alapú\n  2) GNOME – modern, alapértelmezésben Wayland\n  3) KDE Plasma – testreszabható, Wayland/X11 elérhetősége csomagoktól függ\n'
DE_CHOICE=$(ask_number "Választás (1–3)" 1 1 3)
case "$DE_CHOICE" in
  1) DE_NAME="XFCE"; DE_PACKAGES=(xorg-server xfce4 xfce4-whiskermenu-plugin xdg-user-dirs lightdm lightdm-gtk-greeter numlockx) ;;
  2) DE_NAME="GNOME"; DE_PACKAGES=(gnome gdm xdg-user-dirs) ;;
  3) DE_NAME="KDE Plasma"; DE_PACKAGES=(plasma kde-applications sddm xdg-user-dirs) ;;
esac

# ---------- Grafikus kártya ----------
printf '\n%sGrafikus kártya%s\n' "$BOLD" "$RESET"
printf '  1) NVIDIA – nyílt kernelmodulok (csak támogatott GPU-val)\n  2) AMD – Mesa / AMDGPU\n  3) Intel – Mesa / Intel Vulkan\n  4) Egyéb / automatikus alapillesztő\n'
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

# Az automatikus lemezválasztás után még egyszer kiírjuk a pontos célt.
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "$TARGET"
printf '\n%sVESZÉLY: a következő lemez teljes partíciós táblája törlődik: %s%s\n' "$RED" "$TARGET" "$RESET"
read -r -p "A folytatáshoz írd be pontosan ezt: ${TARGET##*/} : " CONFIRM_DISK
[[ "$CONFIRM_DISK" == "${TARGET##*/}" ]] || die "A céllemez megerősítése nem egyezett; nem történt particionálás."

# Ne engedjük a jelenleg csatolt partíciók felülírását.
while read -r mounted; do
  [[ -n "$mounted" ]] || continue
  case "$mounted" in
    "$TARGET"|"$TARGET"[0-9]*|"$TARGET"p[0-9]*) die "A céllemez vagy egyik partíciója csatolva van ($mounted). Válaszd le, majd indítsd újra." ;;
  esac
done < <(findmnt -rn -o SOURCE | sed 's/\[.*\]$//')

# ---------- Particionálási terv ----------
printf '\n%sParticionálási terv%s\n' "$BOLD" "$RESET"
if ask_yes_no "Legyen külön swap partíció?" "igen"; then USE_SWAP=igen; else USE_SWAP=nem; fi
if ask_yes_no "Legyen külön /home partíció?" "igen"; then USE_HOME=igen; else USE_HOME=nem; fi
SWAP_SIZE=0
if [[ "$USE_SWAP" == igen ]]; then
  RAM_GB=$(( $(awk '/MemTotal:/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  SUGGESTED_SWAP=$(( RAM_GB / 2 )); (( SUGGESTED_SWAP < 2 )) && SUGGESTED_SWAP=2
  SWAP_SIZE=$(ask_number "Swap mérete GiB-ban" "$SUGGESTED_SWAP" 1 128)
fi
ROOT_SIZE=0
if [[ "$USE_HOME" == igen ]]; then
  ROOT_SIZE=$(ask_number "A root (/) partíció mérete GiB-ban" 75 20 4096)
fi

if ask_yes_no "Csatoljam a saját Games (ext4) és Download (NTFS) meghajtókat?" "nem"; then ADD_EXTRA=igen; else ADD_EXTRA=nem; fi
if ask_yes_no "Telepítsem a Google Chrome-ot és a RustDesket az AUR-ból?" "nem"; then INSTALL_AUR_APPS=igen; else INSTALL_AUR_APPS=nem; fi
if [[ "$DE_CHOICE" == 1 ]] && ask_yes_no "Letöltsem a GitHubon lévő XFCE-profil mentésedet?" "nem"; then RESTORE_XFCE=igen; else RESTORE_XFCE=nem; fi

printf '\n%sÖsszefoglaló%s\n' "$BOLD" "$RESET"
printf '  Gépnév: %s\n  Felhasználó: %s\n  Asztali környezet: %s\n  GPU-beállítás: %s\n  Céllemez: %s\n  Külön /home: %s\n  Swap: %s%s\n' \
  "$HOSTNAME" "$USERNAME" "$DE_NAME" "$GPU_CHOICE" "$TARGET" "$USE_HOME" "$USE_SWAP" \
  "$( [[ "$USE_SWAP" == igen ]] && printf ' (%s GiB)' "$SWAP_SIZE" || true )"
warn "A folytatás törli a $TARGET lemez meglévő partíciós tábláját és partícióit."
read -r -p "Írd be pontosan, hogy TELEPITES: " FINAL_CONFIRM
[[ "$FINAL_CONFIRM" == TELEPITES ]] || die "A telepítést a felhasználó megszakította."

# ---------- Live ISO csomagadatbázis és pacman beállítások ----------
info "A live ISO pacman-beállításainak előkészítése…"
if ! grep -q '^Color$' /etc/pacman.conf; then sed -i '/^#Color$/s/^#//' /etc/pacman.conf || true; fi
if ! grep -q '^ILoveCandy$' /etc/pacman.conf; then sed -i '/^Color$/a ILoveCandy' /etc/pacman.conf; fi
if grep -q '^#ParallelDownloads = 5$' /etc/pacman.conf; then sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 9/' /etc/pacman.conf; fi
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
fi
pacman -Sy --noconfirm

# A méretellenőrzés a partíciós tábla törlése ELŐTT történik.
SECTORS=$(cat "/sys/class/block/$(basename "$TARGET")/size")
DISK_SIZE_MB=$((SECTORS / 2048))
END_MB=$((DISK_SIZE_MB - 2))
SWAP_MB=$((SWAP_SIZE * 1024))
CUR=1025
if [[ "$USE_HOME" == igen ]]; then CUR=$((CUR + ROOT_SIZE * 1024)); fi
if [[ "$USE_SWAP" == igen ]]; then
  SWAP_START=$((END_MB - SWAP_MB))
  (( SWAP_START > CUR )) || die "A megadott root- és swapméret nem fér el a lemezen. Nem történt particionálás."
else
  (( END_MB > CUR )) || die "A megadott rootméret nem fér el a lemezen. Nem történt particionálás."
fi

# ---------- Particionálás ----------
info "A céllemez újraparticionálása…"
parted --script "$TARGET" mklabel gpt
parted --script "$TARGET" mkpart ESP fat32 1MiB 1025MiB
parted --script "$TARGET" set 1 esp on
CUR=1025
ROOT_END=0
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

# Partíciónevek: SATA/SCSI = sda1, NVMe/eMMC = nvme0n1p1.
if [[ "$TARGET" =~ (nvme|mmcblk|loop)[0-9] ]]; then PART_PREFIX="${TARGET}p"; else PART_PREFIX="$TARGET"; fi
EFI_PART="${PART_PREFIX}1"
ROOT_PART="${PART_PREFIX}2"
HOME_PART=""
SWAP_PART=""
NEXT_PART=3
if [[ "$USE_HOME" == igen ]]; then HOME_PART="${PART_PREFIX}${NEXT_PART}"; ((NEXT_PART+=1)); fi
if [[ "$USE_SWAP" == igen ]]; then SWAP_PART="${PART_PREFIX}${NEXT_PART}"; fi
for part in "$EFI_PART" "$ROOT_PART"; do [[ -b "$part" ]] || die "Nem található létrehozott partíció: $part"; done
[[ -z "$HOME_PART" ]] || [[ -b "$HOME_PART" ]] || die "Nem található a /home partíció: $HOME_PART"
[[ -z "$SWAP_PART" ]] || [[ -b "$SWAP_PART" ]] || die "Nem található a swap partíció: $SWAP_PART"

# ---------- Formázás és csatolás ----------
info "Fájlrendszerek létrehozása…"
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
COMMON_PACKAGES=(pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber gst-plugin-pipewire pavucontrol firefox firefox-i18n-hu libreoffice-fresh libreoffice-fresh-hu hunspell-hu mythes-hu aspell-hu mc thunar thunar-archive-plugin thunar-media-tags-plugin thunar-volman file-roller 7zip unrar unzip keepassxc qbittorrent audacious parole ristretto galculator lutris gamemode gamescope mangohud wine wine-gecko wine-mono lib32-freetype2 lib32-gamemode lib32-gnutls lib32-libglvnd lib32-vulkan-icd-loader udisks2 gvfs gvfs-afc gvfs-gphoto2 gvfs-mtp gvfs-nfs gvfs-smb ntfs-3g exfatprogs dosfstools flatpak pacman-contrib reflector htop glances duf inxi lsb-release gnome-disk-utility)
if [[ "$DE_CHOICE" == 1 ]]; then COMMON_PACKAGES+=(mousepad); fi
if [[ "$GPU_CHOICE" == 2 || "$GPU_CHOICE" == 3 ]]; then COMMON_PACKAGES+=(lib32-mesa); fi

info "Arch Linux telepítése a célrendszerre…"
pacstrap -K /mnt "${BASE_PACKAGES[@]}" "${DE_PACKAGES[@]}" "${COMMON_PACKAGES[@]}" "${GPU_PACKAGES[@]}"

# ---------- Fstab és extra meghajtók ----------
genfstab -U /mnt > /mnt/etc/fstab
if [[ "$ADD_EXTRA" == igen ]]; then
  mkdir -p /mnt/mnt/Games /mnt/mnt/Download
  cat >> /mnt/etc/fstab <<'FSTAB_EOF'

# Opcionális külön meghajtók – csak akkor hagyd bent, ha ezek az UUID-k a saját lemezeidhez tartoznak.
UUID=9471a888-07ec-45ed-b516-eb6aa1513a64 /mnt/Games ext4 defaults,noatime,nofail,x-gvfs-show,x-gvfs-name=Games 0 2
UUID=7460557760554152 /mnt/Download ntfs3 defaults,noatime,uid=1000,gid=1000,umask=022,nofail,x-gvfs-show,x-gvfs-name=Downloads 0 0
FSTAB_EOF
fi

# A telepítendő rendszer beállításai változóátadással, nem interpolált chroot-szkripttel.
info "Rendszerbeállítások létrehozása…"
arch-chroot /mnt /usr/bin/env \
  HOSTNAME="$HOSTNAME" USERNAME="$USERNAME" ROOTPASSWORD="$ROOTPASSWORD" PASSWORD="$PASSWORD" \
  DE_CHOICE="$DE_CHOICE" GPU_CHOICE="$GPU_CHOICE" INSTALL_AUR_APPS="$INSTALL_AUR_APPS" RESTORE_XFCE="$RESTORE_XFCE" \
  /bin/bash -s <<'CHROOT_EOF'
set -Eeuo pipefail
ln -sf /usr/share/zoneinfo/Europe/Budapest /etc/localtime
hwclock --systohc

# Locale: ne duplikáljuk a sorokat, ha a telepítő később újrafutna.
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

if ! grep -q '^Color$' /etc/pacman.conf; then sed -i 's/^#Color$/Color/' /etc/pacman.conf || true; fi
if ! grep -q '^ILoveCandy$' /etc/pacman.conf; then sed -i '/^Color$/a ILoveCandy' /etc/pacman.conf; fi
if grep -q '^#ParallelDownloads = 5$' /etc/pacman.conf; then sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 9/' /etc/pacman.conf; fi
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf; fi

# A sed-módosítások helyett biztosan érvényes MAKEFLAGS beállítás.
if grep -q '^#\?MAKEFLAGS=' /etc/makepkg.conf; then
  sed -i 's/^#\?MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf
fi

case "$DE_CHOICE" in
  1) systemctl enable lightdm
     if grep -q '^\[Seat:\*\]' /etc/lightdm/lightdm.conf; then
       sed -i '/^\[Seat:\*\]/a display-setup-script=numlockx on' /etc/lightdm/lightdm.conf
     else
       printf '\n[Seat:*]\ndisplay-setup-script=numlockx on\n' >> /etc/lightdm/lightdm.conf
     fi ;;
  2) systemctl enable gdm ;;
  3) systemctl enable sddm ;;
esac
systemctl enable NetworkManager

# Jelszavak változóként érkeznek; a szkript nem írja őket fájlba.
printf 'root:%s\n' "$ROOTPASSWORD" | chpasswd
useradd -m -G wheel,storage,power,input,vboxusers -s /bin/bash "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers.d/10-wheel >/dev/null

# GRUB: UEFI telepítés, os-prober alapértelmezésben kikapcsolva.
if grep -q '^#\?GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
  sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub
else
  printf '\nGRUB_DISABLE_OS_PROBER=true\n' >> /etc/default/grub
fi
if [[ "$GPU_CHOICE" == 1 ]]; then
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
    sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"$/ nvidia_drm.modeset=1 nvidia_drm.fbdev=1"/' /etc/default/grub
  fi
fi
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
grub-mkconfig -o /boot/grub/grub.cfg

# VirtualBox host modul betöltése induláskor.
mkdir -p /etc/modules-load.d
printf 'vboxdrv\n' > /etc/modules-load.d/virtualbox.conf

# Felhasználói könyvtárak és saját segédszkript.
runuser -u "$USERNAME" -- env HOME="/home/$USERNAME" xdg-user-dirs-update
cat > "/home/$USERNAME/.arch-clean.sh" <<'CLEAN_EOF'
#!/usr/bin/env bash
set -u
sudo paccache -r -k 2 || true
orphans=$(pacman -Qtdq 2>/dev/null || true)
if [[ -n "$orphans" ]]; then sudo pacman -Rns -- "$orphans"; fi
sudo journalctl --vacuum-time=7d
printf 'Takarítás kész!\n'
CLEAN_EOF
chmod 0755 "/home/$USERNAME/.arch-clean.sh"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.arch-clean.sh"

cat >> "/home/$USERNAME/.bashrc" <<'BASHRC_EOF'

# --- Saját beállítások ---
alias cl='clear'
alias e='exit'
alias y='yay -Syu'
alias sr='sudo reboot'
alias in='sudo pacman -S'
alias rem='$HOME/.arch-clean.sh'
BASHRC_EOF
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bashrc"

# NVIDIA DRM paraméterek az initramfs előtt.
if [[ "$GPU_CHOICE" == 1 ]]; then
  if ! grep -q '^MODULES=.*nvidia' /etc/mkinitcpio.conf; then
    sed -i 's/^MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf
  fi
  mkinitcpio -P
fi

# AUR-csomagok csak külön kérésre, nem rootként futó makepkg-val.
if [[ "$INSTALL_AUR_APPS" == igen ]]; then
  pacman -S --needed --noconfirm git base-devel sudo
  useradd -m -s /bin/bash aurbuilder
  printf 'aurbuilder ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman\n' > /etc/sudoers.d/aurbuilder
  chmod 0440 /etc/sudoers.d/aurbuilder
  visudo -cf /etc/sudoers.d/aurbuilder >/dev/null
  for pkg in yay-bin google-chrome rustdesk-bin; do
    runuser -u aurbuilder -- bash -lc "cd /tmp && rm -rf '$pkg' && git clone 'https://aur.archlinux.org/$pkg.git' '$pkg' && cd '$pkg' && makepkg -si --noconfirm"
  done
  userdel -r aurbuilder || true
  rm -f /etc/sudoers.d/aurbuilder
  systemctl enable rustdesk.service || printf 'Figyelem: a rustdesk.service unit nem található; ellenőrizd a telepített RustDesk csomagot.\n'
fi

if [[ "$RESTORE_XFCE" == igen ]]; then
  profile='/home/'"$USERNAME"'/xfce-backup.tar.gz'
  curl --fail --location --show-error --output "$profile" 'https://raw.githubusercontent.com/pbalee/arch-install/main/xfce-backup.tar.gz'
  tar -tzf "$profile" >/dev/null
  tar -xzf "$profile" -C "/home/$USERNAME"
  rm -f "$profile"
  chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"
fi
CHROOT_EOF

# Változók törlése az aktuális shellből, amennyire lehetséges.
unset ROOTPASSWORD PASSWORD
ok "A rendszer telepítése és alapbeállítása befejeződött."
printf '\n%sFontos utólagos teendők:%s\n' "$BOLD" "$RESET"
printf '  • Indítsd újra a gépet, és vedd ki az Arch telepítő adathordozót.\n'
printf '  • Ellenőrizd a grafikus illesztőprogramot, a hangot és a hálózatot.\n'
printf '  • Az AUR-csomagokat és az XFCE-profil visszaállítását csak akkor választottad, ha külön engedélyezted.\n'
printf '  • Ha a Games/Download UUID-k nem a saját lemezeidhez tartoznak, távolítsd el a hozzáadott fstab-sorokat.\n'
printf '\n%sTelepítés kész. Viszlát!%s\n' "$GREEN" "$RESET"
