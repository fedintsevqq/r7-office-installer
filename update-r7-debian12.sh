#!/usr/bin/env bash
# ============================================================================
#  Р7-Офис — установщик для Debian 12 (Bookworm)
#
#  Это тонкая обёртка над универсальным install-r7.sh.
#  Вся логика живёт там, здесь только жёстко задан профиль ОС —
#  чтобы скрипт работал одинаково даже на нестандартной сборке Debian 12
#  или в контейнере, где /etc/os-release заполнен непривычно.
#
#  Запуск:  sudo ./update-r7-debian12.sh            (меню)
#           sudo ./update-r7-debian12.sh --help     (опции)
# ============================================================================

set -o pipefail

PROFILE="debian12"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ищем универсальный скрипт: рядом, затем в стандартных местах установки
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
