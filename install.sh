#!/usr/bin/env bash
# =============================================================================
#  Arch Linux automata telepítő  –  "AGENT SYSTEM 2.0"   (pbalee, v3.3)
#
#  Indítás (Arch ISO-ról bootolva, működő hálózattal):
#
#     bash <(curl -fsSL https://raw.githubusercontent.com/pbalee/arch-install/main/install.sh)
# =============================================================================
set -uo pipefail

############################ BEÁLLÍTÁSOk – szabadon átírhatod ###################
GH_USER="pbalee"
GH_REPO="arch-install"
GH_BRANCH="main"
XFCE_PROFILE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}/xfce-backup.tar.gz"

DEFAULT_HOSTNAME="bluelight"
DEFAULT_USER="pbalee"
TIMEZONE="Europe/Budapest"
MAIN_LOCALE="hu_HU.UTF-8"
KEYMAP="hu"
CONSOLE_FONT="ter-122b"

ESP_SIZE_GIB=1          # EFI/boot partíció mérete (új partíciózásnál)
DEFAULT_ROOT_GIB=75     # root alapméret, ha külön /home is lesz

# Extra meghajtók (opcionális, fstab-ba kerülnek, nofail-lel)
GAMES_UUID="9471a888-07ec-45ed-b516-eb6aa1513a64"   # ext4, /Games
DOWNLOAD_UUID="7460557760554152"                    # ntfs, /Download

LOG_FILE="/tmp/arch-install.log"
BACKTITLE="Arch Linux Telepítő  ::  AGENT SYSTEM 2.0"
#################################################################################

export LANG=C.UTF-8
RST=$'\e[0m'; RED=$'\e[1;31m'; GRN=$'\e[1;32m'; YEL=$'\e[1;33m'
BLU=$'\e[1;34m'; CYN=$'\e[1;36m'; WHT=$'\e[1;37m'

step() { printf '\n%s==>%s %s%s%s\n' "$BLU" "$RST" "$CYN" "$*" "$RST"; }
ok()   { printf '%s [OK]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s [!]%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '\n%s [HIBA]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }
must() { "$@" || die "Sikertelen parancs: $*  (napló: $LOG_FILE)"; }
cancel() { clear; printf '%sA telepítés megszakítva.%s\n' "$YEL" "$RST"; exit 1; }

# ---------------------------------------------------------------- dialog -----
d()    { dialog --backtitle "$BACKTITLE" --cr-wrap --no-collapse "$@" 3>&1 1>&2 2>&3; }
yn()   { d --title "$1" --yesno "$2" 0 0; }
ynn()  { d --title "$1" --defaultno --yesno "$2" 0 0; }
msg()  { d --title "$1" --msgbox "$2" 0 0; }
menu() { local t=$1 q=$2; shift 2; d --title "$t" --menu "$q" 0 0 0 "$@"; }
ask()  { d --title "$1" --inputbox "$2" 0 70 "${3:-}"; }

ask_int() {
  local v
  while true; do
    v=$(ask "$1" "$2" "$3") || return 1
    if [[ $v =~ ^[0-9]+$ ]] && (( v >= $4 && v <= $5 )); then printf '%s' "$v"; return 0; fi
    msg "Hibás érték" "Egész számot adj meg ($4 – $5 között)."
  done
}

ask_password() {
  local a b
  while true; do
    a=$(d --insecure --title "$1" --passwordbox "Jelszó:" 0 50) || return 1
    b=$(d --insecure --title "$1" --passwordbox "Jelszó újra:" 0 50) || return 1
    if [[ -z $a ]]; then msg "Hiba" "A jelszó nem lehet üres."; continue; fi
    if [[ $a != "$b" ]]; then msg "Hiba" "A két jelszó nem egyezik, próbáld újra."; continue; fi
    printf '%s' "$a"; return 0
  done
}

# ---------------------------------------------------------------- logó -------
banner() {
  clear
  printf '%s' "$CYN"
  cat <<'ART'
                .-'''''''''''-.
          .-''      .-----.      ''-.
       .'                             '.
.--.  /                                 \  .--.
/    \|           .---------.           |/    \
|  () |                                 | ()  |
|  () |                                 | ()  |
|  () |.------------.     .------------.| ()  |
|  () || _|-.  /\   |-----| _|-.  /\   || ()  |
|  () || |_  _/  \  |     | |_  _/  \  || ()  |
|  () ||   '-' /__\ |     |   '-' /__\ || ()  |
\    /|'------------'     '------------'|\    /
       \          '-._____.-'          /
          '-.                     .-'
             '-._______________.-'
ART
  printf '%s' "$RST"
  printf '%s       B L U E L I G H T   ::   A R C H   I N S T A L L E R%s\n' "$WHT" "$RST"
  printf '%s              [ Customized by pbalee ]%s\n\n' "$CYN" "$RST"
  printf '   Arch Linux Automata Telepítő  |  Blackice GRUB  |  UEFI\n\n'
}

# ------------------------------------------------------- pacman.conf --------
tune_pacman() {
  local f=$1
  sed -i 's/^#Color$/Color/' "$f"
  grep -q '^ILoveCandy' "$f" || sed -i '/^Color$/a ILoveCandy' "$f"
  sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' "$f"
  sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 9/' "$f"
  sed -i '/^#\[multilib\]$/,/^#Include/ s/^#//' "$f"
  if ! grep -q '^\[multilib\]' "$f"; then
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> "$f"
  fi
}

# ------------------------------------------------------- előkészítés --------
preflight() {
  [[ $EUID -eq 0 ]] || die "Rootként futtasd!"
  [[ -d /sys/firmware/efi ]] || die "A gép nem UEFI módban indult."
  command -v pacstrap >/dev/null || die "Ez a szkript az Arch Linux telepítő ISO-ról fut."

  setfont "$CONSOLE_FONT" 2>/dev/null || setfont lat2-16 2>/dev/null || true
  loadkeys "$KEYMAP" 2>/dev/null || true

  step "Hálózat ellenőrzése"
  curl -fsS --max-time 10 -o /dev/null https://archlinux.org || die "Nincs internet."
  ok "Van internet."
  timedatectl set-ntp true 2>/dev/null || true

  step "Live rendszer pacman beállítása"
  tune_pacman /etc/pacman.conf
  must pacman -Sy --noconfirm
  must pacman -S --noconfirm --needed archlinux-keyring dialog gptfdisk terminus-font
  ok "Kész."
}

# ------------------------------------------------------- lemez-listák -------
live_disk_name() {
  local src
  src=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  [[ -n $src ]] && lsblk -no PKNAME "$src" 2>/dev/null | head -n1
  return 0
}

list_disks() {
  local live line NAME SIZE MODEL TYPE
  live=$(live_disk_name)
  while read -r line; do
    eval "$line"
    [[ $TYPE == disk ]] || continue
    [[ -n $live && ${NAME##*/} == "$live" ]] && continue
    printf '%s\n%s\n' "$NAME" "$SIZE  ${MODEL:-?}"
  done < <(lsblk -dpnP -o NAME,SIZE,MODEL,TYPE)
}

USED_PARTS=()
list_parts() {
  local live line NAME SIZE FSTYPE LABEL TYPE PKNAME
  live=$(live_disk_name)
  while read -r line; do
    eval "$line"
    [[ $TYPE == part ]] || continue
    [[ -n $live && ${PKNAME##*/} == "$live" ]] && continue
    [[ " ${USED_PARTS[*]-} " == *" $NAME "* ]] && continue
    printf '%s\n%s\n' "$NAME" "$SIZE  ${FSTYPE:--}  ${LABEL:-}"
  done < <(lsblk -pnP -o NAME,SIZE,FSTYPE,LABEL,TYPE,PKNAME)
}

pick_part() {
  local -a items
  mapfile -t items < <(list_parts)
  (( ${#items[@]} > 0 )) || { msg "Hiba" "Nem találtam szabad partíciót."; return 1; }
  menu "$1" "$2" "${items[@]}"
}

part_path() {
  if [[ $1 =~ [0-9]$ ]]; then printf '%sp%s' "$1" "$2"; else printf '%s%s' "$1" "$2"; fi
}

pick_fs() {
  menu "$1" "Melyik fájlrendszert használjuk?" \
    ext4  "Ext4  - megbízható, alapértelmezett" \
    btrfs "Btrfs - pillanatképek, tömörítés" \
    xfs   "XFS   - nagy fájlokhoz, gyors"
}

# ---------------------------------------------------------- kérdések --------
ask_basics() {
  while true; do
    HOSTNAME_=$(ask "Gépnév" "Add meg a gép nevét (hostname):" "$DEFAULT_HOSTNAME") || cancel
    [[ $HOSTNAME_ =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] && break
    msg "Hibás gépnév" "Csak betű, szám és kötőjel lehet benne."
  done
  while true; do
    USERNAME_=$(ask "Felhasználó" "Add meg a felhasználónevet (kisbetűkkel):" "$DEFAULT_USER") || cancel
    [[ $USERNAME_ =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
    msg "Hibás név" "Kisbetű, szám, _ és - lehet benne, betűvel kezdődjön."
  done
  ROOTPW=$(ask_password "ROOT jelszó") || cancel
  USERPW=$(ask_password "Jelszó a(z) $USERNAME_ felhasználónak") || cancel
}

ask_software() {
  DE=$(menu "Asztali környezet" "Milyen asztali környezetet szeretnél?" \
      xfce  "XFCE   - könnyű, gyors, Whisker menü (alapértelmezett)" \
      gnome "GNOME  - modern, letisztult" \
      kde   "KDE Plasma - testreszabható" \
      none  "Nincs  - csak konzolos rendszer") || cancel

  GPU=$(menu "Videókártya" "Milyen grafikus kártya van a gépben?" \
      other  "Egyéb / alap (nincs extra driver)" \
      nvidia "NVIDIA (nvidia-open + DRM modeset)" \
      amd    "AMD (mesa + vulkan-radeon)" \
      intel  "Intel (mesa + vulkan-intel + media driver)") || cancel

  local on_profile=off
  [[ $DE == xfce ]] && on_profile=on
  EXTRAS=$(d --separate-output --title "Extra csomagok és szolgáltatások" \
      --checklist "Szóköz = kijelölés, Enter = tovább" 0 0 0 \
      office    "LibreOffice (magyar nyelvi csomagokkal)"      on \
      gaming    "Játék: Lutris, Wine, GameMode, Xbox kontroller" on \
      vbox      "VirtualBox (host + dkms)"                     on \
      aur       "AUR: yay, Chrome, GLava, ksuperkey"           on \
      flatpak   "Flatpak + Flathub"                           on \
      samba     "Samba fájlmegosztás (WORKGROUP)"              on \
      media     "Média eszközök: yt-dlp, ffmpeg, xscreensaver" on \
      profile   "XFCE profil visszatöltése GitHubról"         "$on_profile" \
      drives    "Extra meghajtók fstab-ba (/Games, /Download)" off) || cancel
}
has() { grep -qx "$1" <<<"$EXTRAS"; }

ask_disk() {
  MODE=$(menu "Lemezkezelés" "Hogyan állítsuk össze a partíciókat?" \
      new      "ÚJ partíciós tábla egy lemezen (TELJES törlés)" \
      existing "MEGLÉVŐ partíciók használata (pl. /home megtartása)") || cancel

  USE_HOME=0; USE_SWAP=0; FORMAT_HOME=1; FORMAT_ESP=1
  ROOT_FS=ext4; HOME_FS=ext4; SWAP_GIB=0; ROOT_GIB=0
  ESP_PART=""; ROOT_PART=""; HOME_PART=""; SWAP_PART=""; TARGET=""
  USED_PARTS=()

  if [[ $MODE == new ]]; then ask_disk_new; else ask_disk_existing; fi
}

ask_disk_new() {
  local -a dm
  mapfile -t dm < <(list_disks)
  (( ${#dm[@]} > 0 )) || die "Nem találtam telepíthető lemezt."
  TARGET=$(menu "Célmeghajtó" "Melyik lemezre telepítsünk?\n(A lemez TELJES tartalma törlődni fog!)" "${dm[@]}") || cancel
  DISK_GIB=$(( $(blockdev --getsize64 "$TARGET") / 1073741824 ))
  (( DISK_GIB >= 20 )) || die "A lemez túl kicsi ($DISK_GIB GiB), legalább 20 GiB kell."

  local ram_kb ram_gib swap_def
  ram_kb=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
  ram_gib=$(( (ram_kb + 1048575) / 1048576 ))
  swap_def=$(( (ram_gib + 1) / 2 ))
  (( swap_def < 1 )) && swap_def=1
  SWAP_GIB=$(ask_int "Swap" "Swap mérete GiB-ben. Ajánlott: ${swap_def} GiB.\n0 = NINCS swap." "$swap_def" 0 64) || cancel
  (( SWAP_GIB > 0 )) && USE_SWAP=1

  if yn "Külön /home" "Legyen külön /home partíció?"; then
    USE_HOME=1
    local root_def=$DEFAULT_ROOT_GIB
    if (( DISK_GIB < 150 )); then root_def=$(( DISK_GIB / 2 )); fi
    ROOT_GIB=$(ask_int "Root mérete" "A root (/) partíció mérete GiB-ben.\nA /home a maradék helyet kapja." "$root_def" 15 "$DISK_GIB") || cancel
    HOME_FS=$(pick_fs "/home fájlrendszere") || cancel
  fi
  ROOT_FS=$(pick_fs "Root (/) fájlrendszere") || cancel

  ESP_PART=$(part_path "$TARGET" 1)
  ROOT_PART=$(part_path "$TARGET" 2)
  local n=3
  (( USE_HOME )) && { HOME_PART=$(part_path "$TARGET" $n); n=$((n+1)); }
  (( USE_SWAP )) && SWAP_PART=$(part_path "$TARGET" $n)
  ESP_MOUNT=/boot
}

ask_disk_existing() {
  msg "Meglévő partíciók" "Válaszd ki a partíciókat. A meglévő /home adatait is itt döntheted el."
  ESP_PART=$(pick_part "EFI (boot) partíció" "Melyik az EFI System Partition (FAT32)?") || cancel
  USED_PARTS+=("$ESP_PART")
  local esp_fs; esp_fs=$(blkid -s TYPE -o value "$ESP_PART" 2>/dev/null || true)
  if [[ $esp_fs == vfat ]]; then
    ynn "EFI formázása" "Formázzam az EFI partíciót?\n\nNEM ajánlott, ha Windows is használja!" && FORMAT_ESP=1 || FORMAT_ESP=0
  else
    FORMAT_ESP=1
  fi

  ROOT_PART=$(pick_part "Root (/) partíció" "Melyik partícióra kerüljön a rendszer?") || cancel
  USED_PARTS+=("$ROOT_PART")
  ROOT_FS=$(pick_fs "Root (/) fájlrendszere") || cancel

  if yn "Külön /home" "Van külön /home partíció?"; then
    USE_HOME=1
    HOME_PART=$(pick_part "/home partíció" "Melyik partíció legyen a /home?") || cancel
    USED_PARTS+=("$HOME_PART")
    if ynn "/home formázása" "Formázzam a /home partíciót?\n\nIGEN = Minden adat törlődik tiszta lappal.\nNEM = A meglévő fájlok és beállítások MEGMARADNAK."; then
      FORMAT_HOME=1
      HOME_FS=$(pick_fs "/home fájlrendszere") || cancel
    else
      FORMAT_HOME=0
      HOME_FS=$(blkid -s TYPE -o value "$HOME_PART" 2>/dev/null || true)
      [[ -n $HOME_FS ]] || die "A $HOME_PART partíción nem ismerhető fel fájlrendszer."
    fi
  fi

  if yn "Swap" "Használjunk swap partíciót?"; then
    SWAP_PART=$(pick_part "Swap partíció" "Melyik partíció legyen a swap?") || cancel
    USED_PARTS+=("$SWAP_PART"); USE_SWAP=1
  fi

  local esp_mb; esp_mb=$(( $(blockdev --getsize64 "$ESP_PART") / 1048576 ))
  if (( FORMAT_ESP == 1 && esp_mb >= 500 )); then ESP_MOUNT=/boot; else ESP_MOUNT=/boot/efi; fi
}

confirm_all() {
  local s=""
  s+="Gépnév:         $HOSTNAME_\n"
  s+="Felhasználó:    $USERNAME_\n"
  s+="Asztali:        $DE     Videókártya: $GPU\n"
  s+="Extrák:         $(tr '\n' ' ' <<<"$EXTRAS")\n\n"
  s+="Elindítsuk a telepítést?"
  dialog --backtitle "$BACKTITLE" --colors --cr-wrap --no-collapse --defaultno \
         --title "Összegzés" --yesno "$s" 0 0 || cancel
}

# ----------------------------------------------------- lemezműveletek -------
mkfs_any() {
  case $1 in
    ext4)  must mkfs.ext4 -q -F -L "$3" "$2" ;;
    btrfs) must mkfs.btrfs -q -f -L "$3" "$2" ;;
    xfs)   must mkfs.xfs -q -f -L "$3" "$2" ;;
  esac
}

prepare_disks() {
  step "Előző csatolások és swap leválasztása"
  swapoff -a 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true

  if [[ $MODE == new ]]; then
    step "Particionálás: $TARGET"
    must wipefs -af "$TARGET"
    must sgdisk --zap-all "$TARGET"
    must sgdisk -n "1:0:+${ESP_SIZE_GIB}G" -t 1:ef00 -c 1:EFI "$TARGET"
    if (( USE_HOME )); then
      must sgdisk -n "2:0:+${ROOT_GIB}G" -t 2:8300 -c 2:root "$TARGET"
      if (( USE_SWAP )); then
        must sgdisk -n "3:0:-${SWAP_GIB}G" -t 3:8300 -c 3:home "$TARGET"
        must sgdisk -n "4:0:0" -t 4:8200 -c 4:swap "$TARGET"
      else
        must sgdisk -n "3:0:0" -t 3:8300 -c 3:home "$TARGET"
      fi
    else
      if (( USE_SWAP )); then
        must sgdisk -n "2:0:-${SWAP_GIB}G" -t 2:8300 -c 2:root "$TARGET"
        must sgdisk -n "3:0:0" -t 3:8200 -c 3:swap "$TARGET"
      else
        must sgdisk -n "2:0:0" -t 2:8300 -c 2:root "$TARGET"
      fi
    fi
    partprobe "$TARGET" 2>/dev/null || true
    udevadm settle
    sleep 2
  fi

  step "Formázás"
  (( FORMAT_ESP )) && must mkfs.fat -F32 -n EFI "$ESP_PART"
  mkfs_any "$ROOT_FS" "$ROOT_PART" root
  if (( USE_HOME && FORMAT_HOME )); then mkfs_any "$HOME_FS" "$HOME_PART" home; fi
  if (( USE_SWAP )); then must mkswap -L swap "$SWAP_PART"; must swapon "$SWAP_PART"; fi

  step "Csatolás"
  must mount -o noatime "$ROOT_PART" /mnt
  must mkdir -p "/mnt$ESP_MOUNT"
  must mount "$ESP_PART" "/mnt$ESP_MOUNT"
  if (( USE_HOME )); then
    must mkdir -p /mnt/home
    must mount -o noatime "$HOME_PART" /mnt/home
  fi
  ok "Lemezek előkészítve."
}

# ----------------------------------------------------------- csomagok -------
build_package_list() {
  local ucode=""
  grep -q GenuineIntel /proc/cpuinfo && ucode=intel-ucode
  grep -q AuthenticAMD /proc/cpuinfo && ucode=amd-ucode

  PKGS=(base base-devel linux linux-firmware linux-headers $ucode terminus-font
        nano micro git sudo curl wget networkmanager
        grub efibootmgr os-prober dosfstools ntfs-3g exfatprogs e2fsprogs
        bash-completion man-db man-pages pacman-contrib reflector
        htop glances duf inxi lsb-release mc unzip unrar 7zip
        udisks2 gvfs gvfs-afc gvfs-gphoto2 gvfs-mtp gvfs-nfs gvfs-smb
        gnome-disk-utility bluez bluez-utils blueberry xboxdrv
        pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber gst-plugin-pipewire pavucontrol
        noto-fonts noto-fonts-emoji ttf-dejavu ttf-liberation
        firefox firefox-i18n-hu keepassxc qbittorrent audacious)

  [[ $ROOT_FS == btrfs || $HOME_FS == btrfs ]] && PKGS+=(btrfs-progs)
  [[ $ROOT_FS == xfs   || $HOME_FS == xfs   ]] && PKGS+=(xfsprogs)

  case $DE in
    xfce)  PKGS+=(xorg-server xfce4-session xfce4-settings xfce4-panel xfce4-appfinder xfce4-power-manager
                  xfce4-taskmanager xfce4-terminal xfce4-notifyd xfce4-screenshooter xfce4-pulseaudio-plugin
                  xfce4-whiskermenu-plugin xfconf xfdesktop xfwm4 thunar thunar-archive-plugin
                  thunar-media-tags-plugin thunar-volman file-roller mousepad ristretto galculator parole
                  lightdm lightdm-gtk-greeter numlockx network-manager-applet adwaita-icon-theme xdg-user-dirs) ;;
    gnome) PKGS+=(xorg-server gnome gdm xdg-user-dirs) ;;
    kde)   PKGS+=(xorg-server plasma-meta sddm konsole dolphin kate ark xdg-user-dirs) ;;
    none)  PKGS+=(xdg-user-dirs) ;;
  esac

  case $GPU in
    nvidia) PKGS+=(nvidia-open nvidia-settings nvidia-utils lib32-nvidia-utils opencl-nvidia libva-nvidia-driver) ;;
    amd)    PKGS+=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver) ;;
    intel)  PKGS+=(mesa lib32-mesa intel-media-driver vulkan-intel lib32-vulkan-intel) ;;
  esac

  has office  && PKGS+=(libreoffice-fresh libreoffice-fresh-hu hunspell-hu mythes-hu aspell-hu)
  has gaming  && PKGS+=(lutris gamemode lib32-gamemode gamescope mangohud wine wine-gecko wine-mono
                        lib32-freetype2 lib32-gnutls lib32-libglvnd lib32-vulkan-icd-loader)
  has vbox    && PKGS+=(virtualbox virtualbox-host-dkms)
  has flatpak && PKGS+=(flatpak)
  has samba   && PKGS+=(samba)
  has media   && PKGS+=(yt-dlp ffmpeg xscreensaver)
}

filter_packages() {
  declare -A HAVE=()
  local p
  while read -r p; do HAVE["$p"]=1; done < <(pacman -Slq; pacman -Sgq)
  FINAL=(); SKIPPED=()
  for p in "${PKGS[@]}"; do
    if [[ -n ${HAVE[$p]:-} ]]; then FINAL+=("$p"); else SKIPPED+=("$p"); fi
  done
}

install_base() {
  step "Csomaglisták összeállítása és pacstrap"
  build_package_list
  filter_packages
  
  local n=0
  until pacstrap -K /mnt "${FINAL[@]}" 2>&1 | tee -a "$LOG_FILE"; do
    n=$((n+1))
    (( n >= 3 )) && die "A pacstrap hibás."
    sleep 5
  done

  step "fstab generálás és extra lemezek"
  must genfstab -U /mnt > /mnt/etc/fstab
  if has drives; then
    must mkdir -p /mnt/Games /mnt/Download
    cat >> /mnt/etc/fstab <<EOF
UUID=${GAMES_UUID} /Games ext4 defaults,noatime,nofail,x-gvfs-show,x-gvfs-name=Games 0 2
UUID=${DOWNLOAD_UUID} /Download ntfs3 defaults,noatime,uid=1000,gid=1000,umask=022,nofail,x-gvfs-show,x-gvfs-name=Downloads 0 0
EOF
  fi

  tune_pacman /mnt/etc/pacman.conf
  sed -i "s/^#\?MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/" /mnt/etc/makepkg.conf
}

# ---------------------------------------------------- chroot szkript --------
write_chroot_script() {
  local home_new=1
  (( USE_HOME && FORMAT_HOME == 0 )) && home_new=0
  {
    printf 'I_HOST=%q\n'  "$HOSTNAME_"
    printf 'I_USER=%q\n'  "$USERNAME_"
    printf 'I_DE=%q\n'    "$DE"
    printf 'I_GPU=%q\n'   "$GPU"
    printf 'I_EXTRAS=%q\n' "$EXTRAS"
    printf 'I_TZ=%q\n'    "$TIMEZONE"
    printf 'I_LOCALE=%q\n' "$MAIN_LOCALE"
    printf 'I_KEYMAP=%q\n' "$KEYMAP"
    printf 'I_FONT=%q\n'    "$CONSOLE_FONT"
    printf 'I_ESP=%q\n'   "$ESP_MOUNT"
    printf 'I_ESP_FORMATTED=%q\n' "$FORMAT_ESP"
    printf 'I_HOME_NEW=%q\n' "$home_new"
    printf 'I_XFCE_URL=%q\n' "$XFCE_PROFILE_URL"
    printf 'I_GH_USER=%q\n' "$GH_USER"
    printf 'I_GH_REPO=%q\n' "$GH_REPO"
    printf 'I_GH_BRANCH=%q\n' "$GH_BRANCH"
  } > /mnt/root/install.env
  chmod 600 /mnt/root/install.env

  cat > /mnt/root/chroot-setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -u
source /root/install.env
has() { grep -qx "$1" <<<"$I_EXTRAS"; }
say()  { printf '\n\e[1;36m  -> %s\e[0m\n' "$*"; }
warn() { printf '\e[1;33m  [!] %s\e[0m\n' "$*"; }

ALIASES=$(cat <<'ALIASBLOCK'
alias cl='clear'
alias e='exit'
alias sr='sudo reboot'
alias in='sudo pacman -S '
alias rem='arch-clean'
alias up='sudo pacman -Syu'
alias ll='ls -lah --color=auto'
alias ls='ls --color=auto'
alias grep='grep --color=auto'
if command -v yay >/dev/null 2>&1; then alias y='yay -Syu'; else alias y='sudo pacman -Syu'; fi
ALIASBLOCK
)
add_aliases() { grep -q 'pbalee aliasok' "$1" 2>/dev/null || printf '\n%s\n' "$ALIASES" >> "$1"; }

phase1() {
  say "Idő, nyelv, billentyűzet, konzol betűtípus ($I_FONT), gépnév"
  ln -sf "/usr/share/zoneinfo/$I_TZ" /etc/localtime
  hwclock --systohc
  sed -i -e 's/^#\(hu_HU.UTF-8 UTF-8\)/\1/' -e 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  locale-gen
  echo "LANG=$I_LOCALE" > /etc/locale.conf
  
  cat > /etc/vconsole.conf <<EOF
KEYMAP=$I_KEYMAP
FONT=$I_FONT
EOF

  echo "$I_HOST" > /etc/hostname
  cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $I_HOST.localdomain $I_HOST
EOF

  mkdir -p /etc/X11/xorg.conf.d
  cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$I_KEYMAP"
EndSection
EOF

  say "USB dirty bytes, udisks2 mount opciók és udev szabályok"
  mkdir -p /etc/sysctl.d /etc/udisks2 /etc/udev/rules.d
  cat > /etc/sysctl.d/99-usb-dirty-bytes.conf <<'EOF'
vm.dirty_background_bytes = 16777216
vm.dirty_bytes = 50331648
EOF

  cat > /etc/udisks2/mount_options.conf <<'EOF'
[defaults]
vfat_defaults=uid=$UID,gid=$GID,shortname=mixed,utf8=1,showexec,flush
exfat_defaults=uid=$UID,gid=$GID,iocharset=utf8,errors=remount-ro
EOF

  cat > /etc/udev/rules.d/99-usb-flush.rules <<'EOF'
ACTION=="add", SUBSYSTEMS=="usb", KERNEL=="sd*", ENV{ID_FS_TYPE}=="vfat", RUN+="/usr/bin/udisksctl mount -b /dev/%k --options flush"
EOF

  say "Samba (WORKGROUP) konfigurálása"
  if has samba; then
    mkdir -p /etc/samba
    cat > /etc/samba/smb.conf <<'EOF'
[global]
   workgroup = WORKGROUP
   security = user
   map to guest = Bad User
EOF
  fi

  say "Takarítószkript és aliasok"
  cat > /usr/local/bin/arch-clean <<'ARCHCLEAN'
#!/usr/bin/env bash
echo "==> Csomag-gyorsítótár takarítása (2 verzió marad)"
sudo paccache -rk2
orphans=$(pacman -Qtdq 2>/dev/null || true)
if [[ -n $orphans ]]; then
  echo "==> Árva csomagok eltávolítása"
  sudo pacman -Rns --noconfirm $orphans
fi
echo "==> Journal takarítása (7 nap marad)"
sudo journalctl --vacuum-time=7d
echo "Takarítás kész!"
ARCHCLEAN
  chmod +x /usr/local/bin/arch-clean
  add_aliases /etc/skel/.bashrc
  add_aliases /root/.bashrc

  say "Felhasználó és sudo"
  echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
  chmod 440 /etc/sudoers.d/10-wheel
  local groups="" g
  for g in wheel storage power input video audio optical vboxusers uucp; do
    getent group "$g" >/dev/null && groups+="${groups:+,}$g"
  done
  useradd -m -G "$groups" -s /bin/bash "$I_USER" || warn "Useradd figyelmeztetés."
  cp -rn /etc/skel/. "/home/$I_USER/" 2>/dev/null
  add_aliases "/home/$I_USER/.bashrc"
  chown -R "$I_USER:$I_USER" "/home/$I_USER"

  say "Szolgáltatások engedélyezése"
  systemctl enable NetworkManager bluetooth fstrim.timer paccache.timer
  has samba && systemctl enable smb nmb
  
  case $I_DE in
    xfce)
      systemctl enable lightdm
      sed -i 's/^#\?greeter-session=.*/greeter-session=lightdm-gtk-greeter/' /etc/lightdm/lightdm.conf
      sed -i 's/^#\?display-setup-script=.*/display-setup-script=numlockx on/' /etc/lightdm/lightdm.conf
      # LightDM X11 kényszerítés (Wayland tiltása)
      if grep -q "^#\?user-session=" /etc/lightdm/lightdm.conf; then
        sed -i 's/^#\?user-session=.*/user-session=xfce/' /etc/lightdm/lightdm.conf
      else
        sed -i '/\[Seat:\*\]/a user-session=xfce' /etc/lightdm/lightdm.conf
      fi
      ;;
    gnome) systemctl enable gdm ;;
    kde)   systemctl enable sddm ;;
  esac

  say "Blackice GRUB Téma telepítése GitHubról"
  local grub_dir="/boot/grub"
  [[ -d /boot/grub2 ]] && grub_dir="/boot/grub2"
  mkdir -p "$grub_dir/themes"
  
  if curl -fsSL -o /tmp/repo.tar.gz "https://github.com/${I_GH_USER}/${I_GH_REPO}/archive/refs/heads/${I_GH_BRANCH}.tar.gz" && tar -xzf /tmp/repo.tar.gz -C /tmp; then
    local extracted_dir="/tmp/${I_GH_REPO}-${I_GH_BRANCH}"
    if [[ -d "$extracted_dir/blackice" ]]; then
      cp -r "$extracted_dir/blackice" "$grub_dir/themes/blackice"
      
      setvar() {
        if grep -q "^#\?$1=" /etc/default/grub; then sed -i "s|^#\?$1=.*|$1=$2|" /etc/default/grub
        else echo "$1=$2" >> /etc/default/grub; fi
      }
      setvar GRUB_DISABLE_OS_PROBER false
      setvar GRUB_TIMEOUT 5
      setvar GRUB_THEME "\"$grub_dir/themes/blackice/theme.txt\""
      setvar GRUB_GFXMODE "\"1920x1080,auto\""
      sed -i -E 's|^(GRUB_TERMINAL(_OUTPUT)?=.*console.*)|#\1|' /etc/default/grub
    fi
  fi
  rm -rf /tmp/repo.tar.gz /tmp/${I_GH_REPO}-${I_GH_BRANCH} 2>/dev/null || true

  mkdir -p /run/udev
  [[ -d /udev-host ]] && mount --bind /udev-host /run/udev
  grub-install --target=x86_64-efi --efi-directory="$I_ESP" --bootloader-id=GRUB --recheck --removable
  grub-mkconfig -o "$grub_dir/grub.cfg"
  mountpoint -q /run/udev && umount /run/udev
}

phase2() {
  say "Csomagadatbázis frissítése"
  pacman -Sy --noconfirm

  runuser -l "$I_USER" -c "LANG=$I_LOCALE xdg-user-dirs-update" 2>/dev/null

  say "GitHub képek letöltése (Avatar, Wallpaper, Menu)"
  local pic_dir="/home/$I_USER/Pictures"
  mkdir -p "$pic_dir"
  curl -fsSL -o "$pic_dir/Avatar.png" "https://raw.githubusercontent.com/${I_GH_USER}/${I_GH_REPO}/${I_GH_BRANCH}/Pictures/Avatar.png" || true
  curl -fsSL -o "$pic_dir/Wallpaper.jpg" "https://raw.githubusercontent.com/${I_GH_USER}/${I_GH_REPO}/${I_GH_BRANCH}/Pictures/Wallpaper.jpg" || true
  curl -fsSL -o "$pic_dir/menu.png" "https://raw.githubusercontent.com/${I_GH_USER}/${I_GH_REPO}/${I_GH_BRANCH}/Pictures/menu.png" || true

  # XFCE Wallpaper beállítása
  if [[ -f "$pic_dir/Wallpaper.jpg" && "$I_DE" == "xfce" ]]; then
    runuser -l "$I_USER" -c "xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/workspace0/last-image -s '$pic_dir/Wallpaper.jpg' 2>/dev/null || true"
  fi

  if has profile && [[ $I_DE == xfce ]]; then
    if [[ $I_HOME_NEW == 1 ]]; then
      say "XFCE profil visszatöltése"
      curl -fsSL -o /tmp/xfce-backup.tar.gz "$I_XFCE_URL" && tar -xzf /tmp/xfce-backup.tar.gz -C "/home/$I_USER" || true
      rm -f /tmp/xfce-backup.tar.gz
    fi
  fi

  chown -R "$I_USER:$I_USER" "/home/$I_USER"

  if has flatpak; then
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
  fi

  if has aur; then
    say "AUR csomagok (yay-bin, google-chrome, glava, ksuperkey)"
    useradd -m -s /bin/bash builder
    echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-builder
    chmod 440 /etc/sudoers.d/99-builder
    
    for pkg in yay-bin google-chrome glava ksuperkey; do
      say "AUR: $pkg"
      runuser -l builder -c "rm -rf /tmp/$pkg && cd /tmp && git clone https://aur.archlinux.org/$pkg.git && cd $pkg && makepkg -si --noconfirm" || warn "Nem sikerült: $pkg"
    done
    userdel -r builder 2>/dev/null
    rm -f /etc/sudoers.d/99-builder

    if [[ $I_DE == xfce ]]; then
      mkdir -p "/home/$I_USER/.config/autostart" "/home/$I_USER/.config/glava"
      cp -r /etc/xdg/glava/* "/home/$I_USER/.config/glava/" 2>/dev/null || true

      cat > "/home/$I_USER/.config/autostart/ksuperkey.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=KSuperKey
Exec=ksuperkey
X-GNOME-Autostart-enabled=true
EOF

      cat > "/home/$I_USER/.config/autostart/glava.desktop" <<EOF
[Desktop Entry]
Type=Application
Exec=sh -c 'sleep 10 && glava --desktop'
X-GNOME-Autostart-enabled=true
Name=GLava
EOF

      if command -v xscreensaver >/dev/null 2>&1; then
        cat > "/home/$I_USER/.config/autostart/xscreensaver.desktop" <<EOF
[Desktop Entry]
Type=Application
Exec=xscreensaver -nosplash
X-GNOME-Autostart-enabled=true
Name=XScreensaver
EOF
      fi

      # Whisker menü ikon beállítása a menu.png-re (ha létezik)
      if [[ -f "$pic_dir/menu.png" ]]; then
        mkdir -p "/home/$I_USER/.config/xfce4/panel"
        # XFConf beállítás a Whisker menü ikonjára
        runuser -l "$I_USER" -c "xfconf-query -c xfce4-panel -p /plugins/plugin-$(xfconf-query -c xfce4-panel -l -v | grep whiskermenu | awk '{print $1}' | grep -o '[0-9]*' | head -n1) -s '$pic_dir/menu.png' 2>/dev/null || true"
      fi

      chown -R "$I_USER:$I_USER" "/home/$I_USER/.config"
    fi
  fi
}

case "${1:-}" in
  phase1) phase1 ;;
  phase2) phase2 ;;
esac
CHROOT
  chmod +x /mnt/root/chroot-setup.sh
}

configure_system() {
  write_chroot_script
  step "Chroot fázis 1"
  must mkdir -p /mnt/udev-host
  mount --bind /run/udev /mnt/udev-host 2>/dev/null || true
  arch-chroot /mnt /root/chroot-setup.sh phase1 2>&1 | tee -a "$LOG_FILE"
  umount /mnt/udev-host 2>/dev/null || true
  rmdir /mnt/udev-host 2>/dev/null || true

  step "Jelszavak beállítása"
  printf '%s:%s\n' root "$ROOTPW"        | arch-chroot /mnt chpasswd
  printf '%s:%s\n' "$USERNAME_" "$USERPW" | arch-chroot /mnt chpasswd

  step "Chroot fázis 2 (AUR, profilok, Képek)"
  arch-chroot /mnt /root/chroot-setup.sh phase2 2>&1 | tee -a "$LOG_FILE"

  rm -f /mnt/root/install.env /mnt/root/chroot-setup.sh
  cp "$LOG_FILE" /mnt/var/log/arch-install.log 2>/dev/null || true
}

finish() {
  sync
  umount -R /mnt 2>/dev/null || true
  swapoff -a 2>/dev/null || true
  clear
  printf '%s=== A telepítés sikeresen elkészült! ===%s\n\n' "$GRN" "$RST"
  if yn "Kész" "Indítsuk újra a gépet?"; then
    reboot
  fi
}

main() {
  : > "$LOG_FILE"
  banner
  read -rp "  Nyomj Entert a folytatáshoz... " _
  preflight
  ask_basics
  ask_software
  ask_disk
  confirm_all
  prepare_disks
  install_base
  configure_system
  finish
}
main "$@"
