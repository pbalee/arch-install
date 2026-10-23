# arch-install
01. Vanilla Arch Linux rendszer, XFCE asztali környezet, NVIDIA támogatással.

Automatizált Arch Linux Telepítő Szkript

Ez az útmutató és szkript lehetővé teszi, hogy egyetlen parancssori indítással feltelepítsd a saját, személyre szabott Vanilla Arch Linux rendszeredet XFCE asztali környezettel, NVIDIA támogatással és a kiválasztott csomagjaiddal.

1. Lépés: Kód feltöltése a saját GitHub fiókodba

Hozz létre egy új publikus repót a GitHubon (például arch-install néven).

Hozd létre benne az install.sh fájlt, és másold bele a lent található szkript tartalmát.

Mentsd el a változtatásokat a fő ágba (main).

2. Lépés: Telepítés az Arch ISO-ról

Bootolj be a hivatalos Arch Linux ISO-ról.

Győződj meg róla, hogy van működő internetkapcsolatod:

ping -c 3 archlinux.org


(Ha Wi-Fi-t használsz, indítsd el az iwctl parancsot a csatlakozáshoz).

Indítsd el a szkriptet közvetlenül a GitHub fiókodból a következő paranccsal (cseréld ki a FELHASZNÁLÓNEVED-et a saját GitHub nevedre):

bash <(curl -s https://raw.githubusercontent.com/FELHASZNÁLÓNEVED/arch-install/main/install.sh)


Mit csinál a szkript automatikusan?

Rendszeralapok:

Felkínálja a céllemez kiválasztását (pl. /dev/sda vagy /dev/nvme0n1).

Létrehozza az EFI és Gyökér (/) partíciókat, formázza őket (fat32 és ext4).

Telepíti a base, linux, linux-firmware és base-devel csomagokat.

Lokalizáció és Hálózat:

Beállítja a magyar billentyűzetkiosztást, az hu_HU.UTF-8 UTF-8 locale-t és a budapesti időzónát.

Beállítja a gépnevet és engedélyezi a NetworkManager-t.

Felhasználó és Rendszertöltő:

Bekéri a root és a normál felhasználó jelszavát.

Hozzáadja a felhasználót a wheel (sudo) csoporthoz.

Telepíti és beállítja a GRUB bootloadert (UEFI módhoz).

Grafikus Környezet és Illesztőprogramok:

Telepíti a tiszta XFCE4 környezetet és az Xorg szervert.

Beállítja a stabil lightdm kijelzőkezelőt a lightdm-gtk-greeter-rel (megelőzve az alvás utáni lefagyást).

Telepíti az NVIDIA nyílt keretrendszerű illesztőprogramjait (nvidia-open, nvidia-utils, lib32-nvidia-utils).

Létrehozza a ~/.xprofile fájlt a globális egérkurzor skálázási hibák megelőzésére (XCURSOR_SIZE=24).

Azonnali AUR Telepítés (Google Chrome):

Telepítés után a szkript automatikusan leklónozza a google-chrome AUR receptet és lefordítja a hivatalos Google szerveres forrásból (makepkg -si).
