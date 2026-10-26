#!/usr/bin/env bash
# BLACKICE GRUB theme installer — run on the target Linux machine as root.
set -euo pipefail

THEME_NAME="blackice"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$THEME_NAME"

if [[ ! -f "$SRC_DIR/theme.txt" ]]; then
    echo "error: $SRC_DIR/theme.txt not found — run from the repo root" >&2
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo "please run as root:  sudo ./install.sh" >&2
    exit 1
fi

GRUB_DIR=""
for d in /boot/grub /boot/grub2; do
    if [[ -d $d ]]; then GRUB_DIR=$d; break; fi
done
if [[ -z $GRUB_DIR ]]; then
    echo "error: cannot find /boot/grub or /boot/grub2" >&2
    exit 1
fi

THEME_DIR="$GRUB_DIR/themes/$THEME_NAME"
echo ":: installing theme to $THEME_DIR"
mkdir -p "$THEME_DIR"
cp -r "$SRC_DIR"/. "$THEME_DIR"/

# ── resolution ───────────────────────────────────────────────
# pass it as the first argument to skip the prompt: ./install.sh 1440
GFXMODE="1920x1080,auto"
case "${1:-}" in
    1440|2k|2K|2560x1440)
        GFXMODE="2560x1440,1920x1080,auto"
        ;;
    1080|1920x1080)
        ;;
    "")
        echo "select GRUB resolution:"
        echo "  1) 1920x1080  (default)"
        echo "  2) 2560x1440"
        read -rp "choice [1/2]: " choice || choice=""
        if [[ "$choice" == "2" ]]; then
            GFXMODE="2560x1440,1920x1080,auto"
        fi
        ;;
    *)
        echo "unknown resolution '$1', falling back to 1920x1080" >&2
        ;;
esac
echo ":: GRUB_GFXMODE = $GFXMODE"

DEFAULT=/etc/default/grub
BACKUP="$DEFAULT.bak.$(date +%Y%m%d%H%M%S)"
cp "$DEFAULT" "$BACKUP"
echo ":: backed up $DEFAULT -> $BACKUP"

set_kv() {
    local key=$1 val=$2
    if grep -qE "^#?${key}=" "$DEFAULT"; then
        sed -i -E "s|^#?${key}=.*|${key}=\"${val}\"|" "$DEFAULT"
    else
        echo "${key}=\"${val}\"" >> "$DEFAULT"
    fi
}
set_kv GRUB_THEME "$THEME_DIR/theme.txt"
set_kv GRUB_GFXMODE "$GFXMODE"
# console-only output would disable the graphical theme — comment it out
sed -i -E 's|^(GRUB_TERMINAL(_OUTPUT)?=.*console.*)|#\1|' "$DEFAULT"

echo ":: regenerating grub.cfg"
if command -v update-grub >/dev/null 2>&1; then
    update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o "$GRUB_DIR/grub.cfg"
elif command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o "$GRUB_DIR/grub.cfg"
else
    echo "warning: no grub-mkconfig found — regenerate grub.cfg manually" >&2
fi

echo ":: BLACKICE deployed. reboot to jack in."
