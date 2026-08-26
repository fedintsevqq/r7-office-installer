#!/usr/bin/env bash
# ============================================================================
#  Р7-Офис — установщик для РОСА «ХРОМ» 12.4 и новее
#
#  Это тонкая обёртка над универсальным install-r7.sh.
#  Профиль "rosa" переключает установщик на dnf и на имена пакетов
#  Mandriva-наследия: lib64gtk+2.0_0, lib64x11_6, lib64xscrnsaver1,
#  fonts-ttf-dejavu, fonts-ttf-liberation и так далее.
#
#  Запуск:  sudo ./update-r7-rosa.sh            (меню)
#           sudo ./update-r7-rosa.sh --help     (опции)
# ============================================================================

set -o pipefail

PROFILE="rosa"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_installer() {
    local c
    for c in "$SCRIPT_DIR/install-r7.sh" \
             /usr/local/bin/install-r7.sh \
             /opt/r7-installer/install-r7.sh; do
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
