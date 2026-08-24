#!/usr/bin/env bash
# ============================================================================
#  Р7-Офис — установщик для Альт Linux 10 и новее
#
#  Это тонкая обёртка над универсальным install-r7.sh.
#  Профиль "alt" переключает установщик на apt-rpm и на имена пакетов,
#  принятые в Альте: libgtk+3 вместо libgtk-3-0, libXScrnSaver вместо
#  libxss1, fonts-ttf-liberation вместо fonts-liberation и так далее.
#
#  Особенности Альта, которые учитывает профиль:
#    • пакеты .rpm, но менеджер — apt-get (apt-rpm), не dnf;
#    • если apt-get не осилил локальный файл, зависимости добираются
#      разбором rpm -qpR и ставятся по именам provides;
#    • оптимизация RDP не выполняется — она только для РЕД ОС.
#
#  Запуск:  sudo ./update-r7-alt.sh            (меню)
#           sudo ./update-r7-alt.sh --help     (опции)
# ============================================================================

set -o pipefail

PROFILE="alt"
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
