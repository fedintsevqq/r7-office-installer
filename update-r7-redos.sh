#!/usr/bin/env bash
# ============================================================================
#  Р7-Офис — установщик для РЕД ОС 7.3 и новее
#
#  Это тонкая обёртка над универсальным install-r7.sh.
#  Здесь жёстко задан профиль ОС "redos", вся логика — в основном скрипте.
#
#  Профиль использует dnf и имена пакетов RPM-семейства (gtk3, nss,
#  alsa-lib). Дополнительно предлагается оптимизация RDP: буферы TCP,
#  глубина цвета и уровень шифрования в /etc/xrdp/xrdp.ini.
#
#  Запуск:  sudo ./update-r7-redos.sh            (меню)
#           sudo ./update-r7-redos.sh --help     (опции)
# ============================================================================

set -o pipefail

PROFILE="redos"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_installer() {
    local c
    for c in "$SCRIPT_DIR/install-r7.sh"              /usr/local/bin/install-r7.sh              /opt/r7-installer/install-r7.sh; do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

INSTALLER="$(find_installer)"

if [ -z "$INSTALLER" ]; then
    echo "❌ Не найден install-r7.sh — основной скрипт установщика."
    echo "   Положите его рядом с этим файлом:"
    echo "   $SCRIPT_DIR/install-r7.sh"
    exit 1
fi

exec bash "$INSTALLER" --os "$PROFILE" "$@"
