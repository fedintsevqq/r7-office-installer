#!/usr/bin/env bash
# ============================================================================
#  Р7-ОФИС — УНИВЕРСАЛЬНЫЙ УСТАНОВЩИК
#  Поддержка: Debian 12/13, Astra Linux 1.7+, Альт Linux 10+/11+,
#             РЕД ОС 7.3+/8+, РОСА «ХРОМ» 12.4+
#  Версия: 2.1
#
#  Запуск:   sudo ./install-r7.sh            (интерактивное меню)
#            sudo ./install-r7.sh --help     (все опции)
# ============================================================================

set -o pipefail

SCRIPT_VERSION="2.1"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------- НАСТРОЙКИ (можно переопределить) -----------------
LOG_FILE="${R7_LOG:-/var/log/r7-update.log}"
STATE_DIR="${R7_STATE:-/var/lib/r7-installer}"
DOWNLOAD_DIR="${R7_DIR:-}"          # если пусто — определим автоматически
PKG_NAME="r7-office"                 # имя основного пакета

# ------------------------- ЦВЕТА --------------------------------------------
setup_colors() {
    if [ "$NO_COLOR_MODE" = true ] || [ ! -t 1 ]; then
        RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; WHITE=''; BOLD=''; NC=''
    else
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
        MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; BOLD='\033[1m'; NC='\033[0m'
    fi
}

# ------------------------- ФЛАГИ КОМАНДНОЙ СТРОКИ ---------------------------
CMD_VERSION=""
CMD_LATEST=false
CMD_FAST=false
CMD_URL=""
CMD_CHECK=false
CMD_MD5=""
CMD_GUI=false
CMD_HELP=false
CMD_LIST_DEPS=false
CMD_INSTALL_DEPS=false
CMD_FIX_WAYLAND=false
CMD_HEALTH=false
CMD_REMOVE=false
CMD_FORCE_OS=""
CMD_CONFIG=""
CMD_NO_IDLE=false
CMD_RESTORE_IDLE=false
CMD_VERIFY=false
CMD_CHECK_DEPS=false
CMD_HISTORY=false
CMD_HISTORY_N=10
CMD_REPORT=false
CMD_REPORT_MODE="open"
DRY_RUN=false
ASSUME_YES=false
NO_COLOR_MODE=false
CMD_YES_SET=false      # -y передали явно в CLI — конфиг не имеет права его выключить
CMD_DIR_SET=false      # --dir передали явно в CLI — конфиг не переопределяет папку

# ------------------------- КОНФИГ-ФАЙЛ (можно переопределить) ---------------
# Приоритет источников: аргументы CLI > переменные окружения > /etc/r7-installer.conf > умолчания.
CONFIG_FILE_DEFAULT="/etc/r7-installer.conf"
CONFIG_LOADED=""        # путь к реально подхваченному конфигу (для --health)
CFG_DOWNLOAD_DIR=""
CFG_LOG_FILE=""
CFG_STATE_DIR=""
CFG_ASSUME_YES=""
CFG_REQUIRE_MD5=""
CFG_SKIP_RDP=""
CFG_ENABLE_REPORT=true  # отчёты по умолчанию включены
CFG_ENABLE_HISTORY=true # история установок по умолчанию включена
CFG_ENABLE_IDLE_CONTROL=""
CFG_UPGRADE_URL=""

# ------------------------- БАЗОВЫЙ ВЫВОД ------------------------------------
separator() { echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"; }
ok()    { echo -e "  ${GREEN}✅${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠️ ${NC} $*"; }
fail()  { echo -e "  ${RED}❌${NC} $*"; }
step()  { echo -e "${BLUE}→${NC} $*"; }
info()  { echo -e "${CYAN}$*${NC}"; }

log() {
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [ -w "$(dirname "$LOG_FILE")" ] 2>/dev/null || [ -w "$LOG_FILE" ] 2>/dev/null; then
        echo "[$ts] $1" >> "$LOG_FILE" 2>/dev/null
    fi
}

init_log() {
    local dir; dir="$(dirname "$LOG_FILE")"
    if ! mkdir -p "$dir" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="/tmp/r7-update.log"
        touch "$LOG_FILE" 2>/dev/null
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR="/tmp/r7-installer"
    mkdir -p "$STATE_DIR" 2>/dev/null
    log "=== Запуск $SCRIPT_NAME v$SCRIPT_VERSION ==="
}

# ============================================================================
#  КОНФИГ-ФАЙЛ /etc/r7-installer.conf
#
#  Специально не через `source` — конфиг лежит в /etc и его может подложить
#  кто угодно с доступом на запись туда; `source` выполнил бы произвольный
#  bash-код от root. Вместо этого — построчный разбор по белому списку ключей,
#  без eval и без интерпретации значений как кода.
# ============================================================================

# Разрешённые ключи конфига (значение — не используется, только сам факт наличия)
config_key_allowed() {
    case "$1" in
        DOWNLOAD_DIR|LOG_FILE|STATE_DIR|ASSUME_YES|REQUIRE_MD5|\
        SKIP_RDP|ENABLE_REPORT|ENABLE_HISTORY|ENABLE_IDLE_CONTROL|UPGRADE_URL) return 0 ;;
        *) return 1 ;;
    esac
}

load_config() {
    local file="${CMD_CONFIG:-$CONFIG_FILE_DEFAULT}"
    [ -f "$file" ] || { [ -n "$CMD_CONFIG" ] && warn "Конфиг не найден: $file"; return 0; }

    # Владелец должен быть root, права — не шире 644 (нет записи для группы/остальных).
    local owner mode
    owner="$(stat -c '%u' "$file" 2>/dev/null)"
    mode="$(stat -c '%a' "$file" 2>/dev/null)"
    if [ "$owner" != "0" ]; then
        warn "Конфиг $file: владелец не root — игнорирую из соображений безопасности"
        log "Конфиг отклонён (владелец не root): $file"
        return 0
    fi
    if [ -n "$mode" ] && [ $(( 8#$mode & 8#022 )) -ne 0 ]; then
        warn "Конфиг $file: права $mode шире 644 (запись для группы/остальных) — игнорирую"
        log "Конфиг отклонён (небезопасные права $mode): $file"
        return 0
    fi

    local line key value bad_keys=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"                                  # срезаем комментарий
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        case "$line" in
            *=*) key="${line%%=*}"; value="${line#*=}" ;;
            *) continue ;;
        esac
        key="$(echo "$key" | sed -e 's/[[:space:]]*$//')"
        value="$(echo "$value" | sed -e 's/^[[:space:]]*//')"
        value="${value%\"}"; value="${value#\"}"             # снимаем кавычки по краям
        value="${value%\'}"; value="${value#\'}"

        if ! config_key_allowed "$key"; then
            warn "Конфиг $file: неизвестный ключ '$key' — пропущен"
            bad_keys=$((bad_keys + 1))
            continue
        fi

        case "$key" in
            ASSUME_YES|REQUIRE_MD5|SKIP_RDP|ENABLE_REPORT|ENABLE_HISTORY|ENABLE_IDLE_CONTROL)
                case "$value" in
                    true|false) printf -v "CFG_$key" '%s' "$value" ;;
                    *) warn "Конфиг $file: $key=$value — ожидалось true/false, пропущено" ;;
                esac
                ;;
            *) printf -v "CFG_$key" '%s' "$value" ;;
        esac
    done < "$file"

    CONFIG_LOADED="$file"
    log "Загружен конфиг $file (отклонено ключей: $bad_keys)"

    # Применяем значения — только там, где источник с более высоким приоритетом молчал.
    [ -z "${R7_LOG:-}" ]   && [ -n "$CFG_LOG_FILE" ]     && LOG_FILE="$CFG_LOG_FILE"
    [ -z "${R7_STATE:-}" ] && [ -n "$CFG_STATE_DIR" ]    && STATE_DIR="$CFG_STATE_DIR"
    if [ "$CMD_DIR_SET" != true ] && [ -z "${R7_DIR:-}" ] && [ -n "$CFG_DOWNLOAD_DIR" ]; then
        DOWNLOAD_DIR="$CFG_DOWNLOAD_DIR"
    fi
    if [ "$CMD_YES_SET" != true ] && [ "$CFG_ASSUME_YES" = true ]; then
        ASSUME_YES=true
    fi
    if [ "$CMD_CHECK" != true ] && [ -z "$CMD_MD5" ] && [ "$CFG_REQUIRE_MD5" = true ]; then
        CMD_CHECK=true
        log "Конфиг требует проверку целостности (REQUIRE_MD5=true)"
    fi
}

header() {
    [ "$CMD_GUI" = true ] && return 0
    clear 2>/dev/null
    separator
    echo -e "${BOLD}${WHITE}  🚀  Р7 ОФИС — УНИВЕРСАЛЬНЫЙ УСТАНОВЩИК  v$SCRIPT_VERSION${NC}"
    echo -e "${BOLD}${WHITE}  🖥️   ${OS_PRETTY:-определение ОС...}${NC}"
    separator
    echo ""
}

pause() {
    [ "$ASSUME_YES" = true ] && return 0
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read -r
}

# Спросить да/нет. По умолчанию — да.
confirm() {
    local prompt="$1" default="${2:-Y}"
    [ "$ASSUME_YES" = true ] && return 0
    local hint="[Y/n]"; [ "$default" = "N" ] && hint="[y/N]"
    echo -n -e "${BOLD}$prompt $hint: ${NC}"
    read -r answer
    if [ -z "$answer" ]; then [ "$default" = "Y" ]; return $?; fi
    [[ "$answer" =~ ^[YyДд] ]]
}

# ------------------------- СПИННЕР ДЛЯ ТИХИХ КОМАНД -------------------------
# Только для run() — там, где вывод команды спрятан в лог и скрипт иначе
# выглядит зависшим (makecache и подобное). run_v() не трогаем: у него
# уже есть свой видимый вывод через tee.
#
# pv намеренно не используем: его нет по умолчанию ни на одной из шести ОС,
# а dpkg -i через pv не прогонишь — dpkg не читает пакет со stdin. apt и dnf
# и так рисуют собственный прогресс поверх run_v().
SPINNER_PID=""

spinner_start() {
    (
        local chars='|/-\' i=0
        while :; do
            i=$(( (i + 1) % 4 ))
            printf '\r  %s %.60s' "${chars:$i:1}" "$1"
            sleep 0.15
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null
}

spinner_stop() {
    [ -n "$SPINNER_PID" ] || return 0
    kill "$SPINNER_PID" 2>/dev/null
    wait "$SPINNER_PID" 2>/dev/null
    printf '\r%*s\r' 70 ""
    SPINNER_PID=""
}

# Выполнить команду: тихо в лог
run() {
    log "CMD: $*"
    if [ "$DRY_RUN" = true ]; then echo -e "  ${MAGENTA}[dry-run]${NC} $*"; return 0; fi

    local with_spinner=false
    if [ -t 1 ] && [ "$NO_COLOR_MODE" != true ] && [ "$CMD_GUI" != true ]; then
        with_spinner=true
        spinner_start "$*"
    fi

    "$@" >>"$LOG_FILE" 2>&1
    local rc=$?
    [ "$with_spinner" = true ] && spinner_stop
    return $rc
}

# Выполнить команду: вывод на экран и в лог, код возврата — самой команды
run_v() {
    log "CMD: $*"
    if [ "$DRY_RUN" = true ]; then echo -e "  ${MAGENTA}[dry-run]${NC} $*"; return 0; fi
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}❌ Скрипт должен запускаться от root.${NC}"
        echo -e "${YELLOW}   Используйте: sudo $SCRIPT_NAME $*${NC}"
        exit 1
    fi
}

# ============================================================================
#  🎛️  АРГУМЕНТЫ КОМАНДНОЙ СТРОКИ
# ============================================================================

show_help() {
    cat <<'HELPEOF'
Р7-Офис — универсальный установщик (Debian 12/13, Astra, Альт, РЕД ОС, РОСА)

ИСПОЛЬЗОВАНИЕ:
  sudo ./install-r7.sh [ОПЦИИ]

  Без опций запускается интерактивное меню.

ОСНОВНЫЕ ОПЦИИ:
  -v, --version ВЕРСИЯ   Установить конкретную версию (например: 2815 или 8.1.0-1234)
  -l, --latest           Установить самый свежий пакет из папки
  -f, --fast             Fast-lane: зависимости + самая новая версия, без вопросов
  -u, --url URL          Скачать пакет по ссылке и установить
  -h, --help             Эта справка

ПРОВЕРКА ЦЕЛОСТНОСТИ:
      --check            Проверять контрольную сумму (спросит MD5, если файла нет)
      --md5 ХЭШ          MD5 из документа Word — сверить перед установкой

ЗАВИСИМОСТИ И ДИАГНОСТИКА:
      --list-deps        Показать список зависимостей для текущей ОС
      --check-deps       То же, но с версиями: установлена/в репозитории/
                         вердикт (не подключает сторонние репозитории)
      --install-deps     Только установить зависимости, без установки Р7
      --health           Диагностика системы (health-check)
      --verify           Smoke-тест: реально ли соберутся зависимости
                         бинарника (ldd), без переустановки
      --history [N]      Последние N установок/удалений (по умолчанию 10)
      --report           Открыть последний HTML-отчёт об установке
      --report list      Список сохранённых отчётов
      --report json      Последний отчёт в JSON — в stdout (для CI)
      --fix-wayland      Исправить проблемы запуска под Wayland (Debian 13 и др.)
      --remove           Меню удаления Р7-Офис

РЕЖИМЫ И ОТЛАДКА:
      --gui              Графический режим (zenity)
      --os ИМЯ           Принудительный профиль ОС:
                         debian12 | debian13 | astra | alt | redos | rosa
      --dir ПУТЬ         Папка с пакетами (.deb/.rpm)
      --config ПУТЬ      Свой конфиг вместо /etc/r7-installer.conf
      --dry-run          Показать команды, ничего не устанавливая
  -y, --yes              Не задавать вопросов (для автоматизации)
      --no-color         Вывод без цветов (для логов и CI)

ПРОСТОЙ ЭКРАНА (для ночных прогонов и soak-тестов):
      --no-idle          Не трогать засыпание/блокировку экрана
      --restore-idle     Вручную вернуть настройки экрана (если скрипт
                         прервали и авто-восстановление не сработало)

ПРИМЕРЫ:
  sudo ./install-r7.sh                                # меню
  sudo ./install-r7.sh -l --md5 a1b2c3d4...           # свежая версия + проверка MD5
  sudo ./install-r7.sh -v 8.1.0-1234                  # конкретная версия
  sudo ./install-r7.sh -f -y                          # полностью автоматически
  sudo ./install-r7.sh -u https://example.ru/r7.deb   # скачать и поставить
  sudo ./install-r7.sh --install-deps                 # только зависимости
  sudo ./install-r7.sh --fix-wayland                  # починить Wayland
  sudo ./install-r7.sh --health                       # диагностика

ФАЙЛЫ:
  Лог:       /var/log/r7-update.log
  Состояние: /var/lib/r7-installer/
  Конфиг:    /etc/r7-installer.conf (необязательный, см. README)
  Простой:   /var/lib/r7-installer/idle-saved.state (временный, до восстановления)
HELPEOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -v|--version)   CMD_VERSION="${2:-}"; shift 2 ;;
            -l|--latest)    CMD_LATEST=true; shift ;;
            -f|--fast)      CMD_FAST=true; shift ;;
            -u|--url)       CMD_URL="${2:-}"; shift 2 ;;
            --check)        CMD_CHECK=true; shift ;;
            --md5)          CMD_MD5="${2:-}"; CMD_CHECK=true; shift 2 ;;
            --gui)          CMD_GUI=true; shift ;;
            --list-deps)    CMD_LIST_DEPS=true; shift ;;
            --install-deps) CMD_INSTALL_DEPS=true; shift ;;
            --fix-wayland)  CMD_FIX_WAYLAND=true; shift ;;
            --health)       CMD_HEALTH=true; shift ;;
            --verify)       CMD_VERIFY=true; shift ;;
            --check-deps)   CMD_CHECK_DEPS=true; shift ;;
            --history)
                CMD_HISTORY=true
                case "${2:-}" in
                    ''|*[!0-9]*) shift ;;                       # без числа — умолчание
                    *)           CMD_HISTORY_N="$2"; shift 2 ;;
                esac
                ;;
            --report)
                CMD_REPORT=true
                case "${2:-}" in
                    list|json) CMD_REPORT_MODE="$2"; shift 2 ;;
                    *)         shift ;;
                esac
                ;;
            --remove)       CMD_REMOVE=true; shift ;;
            --os)           CMD_FORCE_OS="${2:-}"; shift 2 ;;
            --config)       CMD_CONFIG="${2:-}"; shift 2 ;;
            --no-idle)      CMD_NO_IDLE=true; shift ;;
            --restore-idle) CMD_RESTORE_IDLE=true; shift ;;
            --dir)          DOWNLOAD_DIR="${2:-}"; CMD_DIR_SET=true; shift 2 ;;
            --dry-run)      DRY_RUN=true; shift ;;
            -y|--yes)       ASSUME_YES=true; CMD_YES_SET=true; shift ;;
            --no-color)     NO_COLOR_MODE=true; shift ;;
            -h|--help)      CMD_HELP=true; shift ;;
            *)
                echo "Неизвестная опция: $1"
                echo "   Список опций: $SCRIPT_NAME --help"
                exit 2 ;;
        esac
    done
}

# ============================================================================
#  ОПРЕДЕЛЕНИЕ ОС
#  Заполняет: OS_ID (debian12|debian13|astra|alt|redos|rosa), OS_PRETTY, OS_VER,
#             PKG_FMT (deb|rpm), PM (apt|apt-rpm|dnf), FEAT_*
# ============================================================================

OS_ID="unknown"; OS_PRETTY="неизвестная ОС"; OS_VER=""
PKG_FMT=""; PM=""
FEAT_RDP=false             # авто-оптимизация RDP (РЕД ОС)
FEAT_GCONF_BACKPORT=false  # доставка libgconf-2-4 извне репозитория

# ver_ge 1.7.4 1.7 -> истина
ver_ge() {
    [ "$1" = "$2" ] && return 0
    local greater
    greater="$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)"
    [ "$greater" = "$1" ]
}

detect_os() {
    local id="" id_like="" ver="" pretty=""

    if [ -r /etc/os-release ]; then
        . /etc/os-release
        id="${ID:-}"; id_like="${ID_LIKE:-}"; ver="${VERSION_ID:-}"; pretty="${PRETTY_NAME:-}"
    fi

    if [ -n "$CMD_FORCE_OS" ]; then
        case "$CMD_FORCE_OS" in
            debian12|debian13|astra|alt|redos|rosa) OS_ID="$CMD_FORCE_OS" ;;
            *) echo "Неизвестный профиль ОС: $CMD_FORCE_OS"; exit 2 ;;
        esac
        OS_PRETTY="${pretty:-$CMD_FORCE_OS} (профиль задан вручную)"
        OS_VER="$ver"
    elif [ -f /etc/altlinux-release ] || [ "$id" = "altlinux" ] || [ "$id" = "alt" ]; then
        OS_ID="alt"
        OS_PRETTY="$(head -1 /etc/altlinux-release 2>/dev/null)"
        [ -z "$OS_PRETTY" ] && OS_PRETTY="${pretty:-ALT Linux}"
        OS_VER="$ver"
        [ -z "$OS_VER" ] && OS_VER="$(echo "$OS_PRETTY" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)"
    elif [ -f /etc/redos-release ] || [ "$id" = "redos" ]; then
        OS_ID="redos"
        OS_PRETTY="$(head -1 /etc/redos-release 2>/dev/null)"
        [ -z "$OS_PRETTY" ] && OS_PRETTY="${pretty:-RED OS}"
        OS_VER="$ver"
        [ -z "$OS_VER" ] && OS_VER="$(echo "$OS_PRETTY" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    elif [ -f /etc/astra_version ] || [ "$id" = "astra" ]; then
        OS_ID="astra"
        OS_VER="$(head -1 /etc/astra_version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
        [ -z "$OS_VER" ] && OS_VER="$ver"
        OS_PRETTY="${pretty:-Astra Linux} $OS_VER"
    elif [ -f /etc/rosa-release ] || [ "$id" = "rosa" ]; then
        OS_ID="rosa"
        OS_PRETTY="$(head -1 /etc/rosa-release 2>/dev/null)"
        [ -z "$OS_PRETTY" ] && OS_PRETTY="${pretty:-ROSA Linux}"
        OS_VER="$ver"
        [ -z "$OS_VER" ] && OS_VER="$(echo "$OS_PRETTY" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)"
    elif [ "$id" = "debian" ] || [ -f /etc/debian_version ]; then
        local dver="$ver"
        if [ -z "$dver" ] && [ -r /etc/debian_version ]; then
            dver="$(cat /etc/debian_version)"
        fi
        case "$dver" in
            11*|bullseye*)    OS_ID="debian12" ;;
            12*|bookworm*)    OS_ID="debian12" ;;
            13*|trixie*)      OS_ID="debian13" ;;
            *)                OS_ID="debian13" ;;
        esac
        OS_VER="$dver"
        OS_PRETTY="${pretty:-Debian} ($dver)"
    fi

    case "$OS_ID" in
        debian12|debian13|astra) PKG_FMT="deb"; PM="apt" ;;
        alt)                     PKG_FMT="rpm"; PM="apt-rpm" ;;
        redos|rosa)
            PKG_FMT="rpm"; PM="dnf"
            command -v dnf >/dev/null 2>&1 || PM="yum"
            ;;
        *)
            if command -v dnf >/dev/null 2>&1; then
                OS_ID="redos"; PKG_FMT="rpm"; PM="dnf"
            elif command -v rpm >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
                OS_ID="alt"; PKG_FMT="rpm"; PM="apt-rpm"
            elif command -v dpkg >/dev/null 2>&1; then
                OS_ID="debian13"; PKG_FMT="deb"; PM="apt"
            fi
            [ -n "$pretty" ] && OS_PRETTY="$pretty (профиль подобран автоматически: $OS_ID)"
            ;;
    esac

    case "$OS_ID" in
        redos)             FEAT_RDP=true ;;
        debian12|debian13) FEAT_GCONF_BACKPORT=true ;;
    esac

    if [ -z "$PKG_FMT" ]; then
        echo "Не удалось определить ОС и пакетный менеджер."
        echo "Укажите профиль вручную: $SCRIPT_NAME --os debian13|debian12|astra|alt|redos|rosa"
        exit 1
    fi

    log "ОС: $OS_ID ($OS_PRETTY), формат: $PKG_FMT, менеджер: $PM"
}

# Предупреждение, если версия ОС ниже поддерживаемой (не блокирует работу)
check_os_version() {
    local minver="" name=""
    case "$OS_ID" in
        astra)    minver="1.7"; name="Astra Linux" ;;
        alt)      minver="10";  name="Альт Linux" ;;
        redos)    minver="7.3"; name="РЕД ОС" ;;
        rosa)     minver="12.4"; name="РОСА «Хром»" ;;
        debian12) minver="12";  name="Debian" ;;
        debian13) minver="13";  name="Debian" ;;
    esac
    [ -z "$minver" ] && return 0
    [ -z "$OS_VER" ] && return 0
    local cur
    cur="$(echo "$OS_VER" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)"
    [ -z "$cur" ] && return 0
    if ! ver_ge "$cur" "$minver"; then
        warn "$name $cur старее поддерживаемой ($minver+). Скрипт продолжит, но возможны сбои."
        log "Предупреждение: версия ОС $cur ниже $minver"
    fi
}

# ============================================================================
#  АБСТРАКЦИЯ ПАКЕТНОГО МЕНЕДЖЕРА
#  Единый интерфейс поверх apt (Debian/Astra), apt-rpm (Альт), dnf (РЕД ОС)
# ============================================================================

PM_UPDATED=false

# Обновить индексы репозиториев (один раз за запуск)
pm_update() {
    [ "$PM_UPDATED" = true ] && return 0
    step "Обновление списка пакетов ($PM)..."
    case "$PM" in
        apt|apt-rpm) run apt-get update ;;
        dnf)         run dnf -q makecache ;;
        yum)         run yum -q makecache ;;
    esac
    PM_UPDATED=true
    return 0
}

# Установлен ли пакет
pkg_installed() {
    local p="$1"
    case "$PKG_FMT" in
        deb) dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed" ;;
        rpm) rpm -q "$p" >/dev/null 2>&1 ;;
    esac
}

# Доступен ли пакет в репозиториях (или уже установлен)
pkg_available() {
    local p="$1"
    pkg_installed "$p" && return 0
    case "$PM" in
        apt|apt-rpm)
            local cand
            cand="$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')"
            [ -n "$cand" ] && [ "$cand" != "(none)" ]
            ;;
        dnf) dnf -q info "$p" >/dev/null 2>&1 ;;
        yum) yum -q info "$p" >/dev/null 2>&1 ;;
        *)   return 1 ;;
    esac
}

# Из списка альтернатив вернуть первое реально существующее имя пакета.
# Пример: pkg_pick "libgtk-3-0t64 libgtk-3-0 gtk3 libgtk+3"
pkg_pick() {
    local candidate
    for candidate in $1; do
        if pkg_available "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Установить пакеты из репозитория
pm_install() {
    [ $# -eq 0 ] && return 0
    case "$PM" in
        apt)     run_v env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        apt-rpm) run_v apt-get install -y "$@" ;;
        dnf)     run_v dnf install -y "$@" ;;
        yum)     run_v yum install -y "$@" ;;
    esac
}

# Установить локальный файл пакета вместе с его зависимостями
pm_install_local() {
    local file="$1"
    case "$PM" in
        apt)
            # apt сам подтягивает зависимости из репозитория
            if run_v env DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "$file"; then
                return 0
            fi
            warn "apt не справился, пробуем dpkg + починку зависимостей..."
            run_v dpkg -i "$file"
            run_v env DEBIAN_FRONTEND=noninteractive apt-get install -f -y
            pkg_installed "$PKG_NAME"
            ;;
        apt-rpm)
            if run_v apt-get install -y "$file"; then
                return 0
            fi
            warn "apt-get не справился, ставим через rpm и добираем зависимости..."
            local reqs
            reqs="$(rpm_missing_requires "$file")"
            if [ -n "$reqs" ]; then
                step "Недостающие зависимости: $reqs"
                run_v apt-get install -y $reqs
            fi
            run_v rpm -Uvh --replacepkgs "$file"
            ;;
        dnf)
            run_v dnf install -y --allowerasing "$file"
            ;;
        yum)
            run_v yum install -y "$file"
            ;;
    esac
}

# Удалить пакет
pm_remove() {
    local p="$1"
    case "$PM" in
        apt)     run_v env DEBIAN_FRONTEND=noninteractive apt-get remove -y "$p"
                 run_v env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y ;;
        apt-rpm) run_v apt-get remove -y "$p" ;;
        dnf)     run_v dnf remove -y "$p" ;;
        yum)     run_v yum remove -y "$p" ;;
    esac
}

# Версия установленного Р7
installed_version() {
    case "$PKG_FMT" in
        deb) dpkg-query -W -f='${Version}' "$PKG_NAME" 2>/dev/null ;;
        rpm) rpm -q --qf '%{VERSION}-%{RELEASE}' "$PKG_NAME" 2>/dev/null ;;
    esac
}

# Список неудовлетворённых зависимостей rpm-файла (для Альт)
rpm_missing_requires() {
    local file="$1" line out=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            rpmlib*|rtld*|/*) continue ;;
        esac
        line="$(echo "$line" | awk '{print $1}')"
        if ! rpm -q --whatprovides "$line" >/dev/null 2>&1; then
            out="$out $line"
        fi
    done < <(rpm -qpR "$file" 2>/dev/null)
    echo "$out"
}

# ============================================================================
#  ЗАВИСИМОСТИ ПО ОС
#
#  Формат строки:  req|альт1 альт2 альт3   — обязательная зависимость
#                  opt|альт1 альт2         — желательная (нет — не беда)
#  Альтернативы перебираются по порядку, берётся первая существующая в репо.
#  Так один список работает и на Debian 12 (libgtk-3-0), и на Debian 13
#  (libgtk-3-0t64 после перехода на 64-битный time_t), и на Astra.
# ============================================================================

dep_spec() {
    case "$PKG_FMT" in
      deb)
        cat <<'SPEC'
req|libc6
req|libstdc++6
req|libgcc-s1 libgcc1
req|libcairo2
req|libgtk-3-0t64 libgtk-3-0
req|libx11-6
req|libxss1
req|libnss3
req|libnspr4
req|libdbus-glib-1-2
req|libasound2t64 libasound2
req|x11-common
req|xdg-utils
opt|libcurl4t64 libcurl4 libcurl3-gnutls
opt|libatk1.0-0t64 libatk1.0-0
opt|libgbm1
opt|libxkbcommon0
opt|libsecret-1-0
opt|libgconf-2-4
opt|gconf2-common
opt|fonts-liberation fonts-liberation2
opt|fonts-dejavu fonts-dejavu-core
opt|fonts-crosextra-carlito
opt|fonts-takao-gothic
opt|gstreamer1.0-plugins-base
opt|gstreamer1.0-plugins-good
opt|gstreamer1.0-plugins-ugly
opt|gstreamer1.0-libav
opt|zenity
SPEC
        ;;
      rpm)
        if [ "$OS_ID" = "alt" ]; then
            cat <<'SPEC'
req|glibc
req|libstdc++6 libstdc++
req|libgcc1 libgcc
req|libcairo cairo
req|libgtk+3 gtk+3
req|libX11
req|libXScrnSaver libXss
req|libnss nss
req|libnspr nspr
req|libdbus-glib dbus-glib
req|alsa-lib libalsa
req|xdg-utils
opt|libcurl curl
opt|libgbm mesa-libgbm
opt|libxkbcommon
opt|libsecret
opt|libGConf GConf
opt|fonts-ttf-liberation
opt|fonts-ttf-dejavu
opt|fonts-ttf-google-crosextra-carlito
opt|libgst-plugins1.0 gst-plugins1.0
opt|gst-plugins-good1.0
opt|gst-plugins-ugly1.0
opt|gst-libav1.0
opt|zenity
SPEC
        elif [ "$OS_ID" = "rosa" ]; then
            # РОСА «ХРОМ» — наследует именование пакетов Mandriva/ALT:
            # lib64<имя><soname>_<версия> вместо libимя.so.версия.
            cat <<'SPEC'
req|glibc
req|lib64stdc++6 libstdc++
req|lib64gcc1 lib64gcc libgcc
req|lib64cairo lib64cairo2 cairo
req|lib64gtk+2.0_0 lib64gtk+2_0 gtk2
req|lib64x11_6 libX11
req|lib64xscrnsaver1 libXScrnSaver
req|lib64nss3 nss
req|lib64nspr4 nspr
req|lib64dbus-glib-1_2 dbus-glib
req|lib64asound2 alsa-lib
req|xdg-utils
opt|lib64curl4 curl
opt|lib64atk1.0_0 atk
opt|lib64gbm1 mesa-libgbm
opt|lib64xkbcommon0 libxkbcommon
opt|lib64secret-1_0 libsecret
opt|lib64gconf-2_4 GConf2
opt|fonts-ttf-liberation
opt|fonts-ttf-dejavu
opt|fonts-ttf-google-crosextra-carlito
opt|gstreamer1-plugins-base
opt|gstreamer1-plugins-good
opt|gstreamer1-plugins-ugly-free gstreamer1-plugins-ugly
opt|gstreamer1-libav
opt|zenity
SPEC
        else
            cat <<'SPEC'
req|glibc
req|libstdc++
req|libgcc
req|cairo
req|gtk3
req|libX11
req|libXScrnSaver
req|nss
req|nspr
req|dbus-glib
req|alsa-lib
req|xdg-utils
opt|libcurl
opt|mesa-libgbm
opt|libxkbcommon
opt|libsecret
opt|GConf2
opt|liberation-fonts liberation-fonts-common
opt|dejavu-fonts dejavu-fonts-common dejavu-sans-fonts
opt|google-crosextra-carlito-fonts
opt|gstreamer1-plugins-base
opt|gstreamer1-plugins-good
opt|gstreamer1-plugins-ugly-free gstreamer1-plugins-ugly
opt|gstreamer1-libav
opt|zenity
SPEC
        fi
        ;;
    esac
}

deps_flag_file() { echo "$STATE_DIR/deps-$OS_ID.done"; }

# Показать таблицу зависимостей: что нужно, что уже стоит, что найдено в репо
list_dependencies() {
    header
    separator
    echo -e "${BOLD}${WHITE}  ЗАВИСИМОСТИ ДЛЯ: $OS_PRETTY${NC}"
    separator
    echo ""
    pm_update
    local line kind alts chosen
    while IFS='|' read -r kind alts; do
        [ -z "$kind" ] && continue
        chosen="$(pkg_pick "$alts")"
        if [ -n "$chosen" ]; then
            if pkg_installed "$chosen"; then
                echo -e "  ${GREEN}[установлен]${NC} $chosen"
            else
                echo -e "  ${YELLOW}[в репозитории]${NC} $chosen"
            fi
        else
            if [ "$kind" = "req" ]; then
                echo -e "  ${RED}[НЕ НАЙДЕН]${NC}   $alts"
            else
                echo -e "  ${CYAN}[нет, не критично]${NC} $alts"
            fi
        fi
    done < <(dep_spec)
    echo ""
    separator
    echo -e "${CYAN}Пакетный менеджер:${NC} $PM    ${CYAN}Формат:${NC} $PKG_FMT"
    separator
}

# ============================================================================
#  --check-deps: ДИАГНОСТИКА ВЕРСИЙ (НЕ авторезолвер)
#
#  В отличие от list_dependencies() (стоит/не стоит), здесь ещё и версии:
#  что установлено против того, что предлагает репозиторий. Никаких
#  сторонних репозиториев мы не подключаем и не предлагаем подключить —
#  РЕД ОС ФСТЭК и Astra ЗПС/МКЦ это сертифицированные конфигурации,
#  посторонний репозиторий может вывести систему из сертифицированного
#  состояния. Максимум — назвать пакет.
# ============================================================================

pkg_installed_version() {
    local p="$1"
    case "$PKG_FMT" in
        deb) dpkg-query -W -f='${Version}' "$p" 2>/dev/null ;;
        rpm) rpm -q --qf '%{VERSION}-%{RELEASE}' "$p" 2>/dev/null ;;
    esac
}

# Версия-кандидат из репозитория. Лучшая попытка — форматы вывода
# apt-cache/dnf/yum не так стабильны, как хотелось бы; при неопределённости
# честно возвращаем пусто, а не гадаем.
pkg_candidate_version() {
    local p="$1"
    case "$PM" in
        apt|apt-rpm)
            apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}'
            ;;
        dnf)
            dnf -q list available "$p" 2>/dev/null | awk 'NR==2{print $2}'
            ;;
        yum)
            yum -q list available "$p" 2>/dev/null | awk 'NR==2{print $2}'
            ;;
    esac
}

check_dependencies_versions() {
    header
    separator
    echo -e "${BOLD}${WHITE}  ПРОВЕРКА ВЕРСИЙ ЗАВИСИМОСТЕЙ — $OS_PRETTY${NC}"
    separator
    echo ""
    pm_update

    local kind alts chosen installed candidate cur cmp
    local n_ok=0 n_old=0 n_norepo=0 n_missing=0
    local html_rows=""

    while IFS='|' read -r kind alts; do
        [ -z "$kind" ] && continue
        chosen="$(pkg_pick "$alts")"

        if [ -z "$chosen" ]; then
            if [ "$kind" = "req" ]; then
                n_missing=$((n_missing + 1))
                echo -e "  ${RED}[НЕ НАЙДЕН]${NC}         $alts"
                html_rows="${html_rows}<tr><td>$(html_escape "$alts")</td><td>—</td><td>—</td><td class=\"miss\">не найден ни локально, ни в репо</td></tr>"
            else
                n_norepo=$((n_norepo + 1))
                echo -e "  ${CYAN}[нет, не критично]${NC}  $alts"
                html_rows="${html_rows}<tr><td>$(html_escape "$alts")</td><td>—</td><td>—</td><td>нет (необязательная)</td></tr>"
            fi
            continue
        fi

        installed="$(pkg_installed_version "$chosen")"
        candidate="$(pkg_candidate_version "$chosen")"

        if [ -z "$installed" ] && [ -z "$candidate" ]; then
            n_missing=$((n_missing + 1))
            echo -e "  ${RED}[НЕДОСТУПЕН]${NC}        $chosen"
            html_rows="${html_rows}<tr><td>$(html_escape "$chosen")</td><td>—</td><td>—</td><td class=\"miss\">недоступен</td></tr>"
        elif [ -z "$installed" ]; then
            n_missing=$((n_missing + 1))
            echo -e "  ${YELLOW}[НЕ УСТАНОВЛЕН]${NC}     $chosen  (в репозитории: $candidate)"
            html_rows="${html_rows}<tr><td>$(html_escape "$chosen")</td><td>—</td><td>$(html_escape "$candidate")</td><td class=\"miss\">не установлен</td></tr>"
        elif [ -z "$candidate" ]; then
            n_norepo=$((n_norepo + 1))
            echo -e "  ${CYAN}[БЕЗ ДАННЫХ О РЕПО]${NC} $chosen  (установлена: $installed)"
            html_rows="${html_rows}<tr><td>$(html_escape "$chosen")</td><td>$(html_escape "$installed")</td><td>—</td><td>без данных о репозитории</td></tr>"
        elif [ "$installed" = "$candidate" ]; then
            n_ok=$((n_ok + 1))
            echo -e "  ${GREEN}[АКТУАЛЬНА]${NC}         $chosen  $installed"
            html_rows="${html_rows}<tr><td>$(html_escape "$chosen")</td><td>$(html_escape "$installed")</td><td>$(html_escape "$candidate")</td><td class=\"ok\">актуальна</td></tr>"
        else
            cur="$(echo "$installed" | grep -oE '[0-9]+(\.[0-9]+)*' | head -1)"
            cmp="$(echo "$candidate" | grep -oE '[0-9]+(\.[0-9]+)*' | head -1)"
            if [ -n "$cur" ] && [ -n "$cmp" ] && ver_ge "$cur" "$cmp"; then
                n_ok=$((n_ok + 1))
                echo -e "  ${GREEN}[НОВЕЕ РЕПО]${NC}        $chosen  $installed (репо: $candidate)"
                html_rows="${html_rows}<tr><td>$(html_escape "$chosen")</td><td>$(html_escape "$installed")</td><td>$(html_escape "$candidate")</td><td class=\"ok\">новее репозитория</td></tr>"
            else
                n_old=$((n_old + 1))
                echo -e "  ${YELLOW}[УСТАРЕЛА]${NC}          $chosen  $installed → $candidate"
                html_rows="${html_rows}<tr><td>$(html_escape "$chosen")</td><td>$(html_escape "$installed")</td><td>$(html_escape "$candidate")</td><td class=\"miss\">устарела</td></tr>"
            fi
        fi
    done < <(dep_spec)

    echo ""
    separator
    echo -e "${CYAN}Актуальных:${NC} $n_ok   ${CYAN}Устаревших:${NC} $n_old   ${CYAN}Без данных о репо:${NC} $n_norepo   ${CYAN}Отсутствуют:${NC} $n_missing"
    separator
    log "Проверка версий зависимостей: актуально=$n_ok устарело=$n_old без-репо=$n_norepo нет=$n_missing"

    [ "$CFG_ENABLE_REPORT" = false ] && return 0
    local dir; dir="$(reports_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    local stamp; stamp="$(date '+%Y%m%d_%H%M%S')"
    local html_file="$dir/checkdeps-${stamp}.html"
    local ts; ts="$(date -Iseconds 2>/dev/null)"; [ -z "$ts" ] && ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"

    cat > "$html_file" <<HTMLEOF
<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<title>Р7-Офис — версии зависимостей ${stamp}</title>
<style>
  body{font-family:-apple-system,Segoe UI,Arial,sans-serif;background:#f5f7fa;color:#22252a;margin:0;padding:24px}
  .card{max-width:820px;margin:0 auto;background:#fff;border-radius:12px;padding:24px 28px;box-shadow:0 1px 4px rgba(0,0,0,.08)}
  h1{font-size:20px;margin:0 0 4px}
  table{width:100%;border-collapse:collapse;margin:8px 0 20px;font-size:14px}
  td,th{padding:5px 8px;border-bottom:1px solid #eee;text-align:left}
  td.ok{color:#2e7d32}
  td.miss{color:#c62828}
  .meta{color:#616161;font-size:13px}
</style></head>
<body><div class="card">
  <h1>Р7-Офис — версии зависимостей</h1>
  <p class="meta">${ts} · $(html_escape "$OS_PRETTY") · актуально: ${n_ok}, устарело: ${n_old}, без данных: ${n_norepo}, отсутствует: ${n_missing}</p>
  <table>
    <tr><th>Пакет</th><th>Установлена</th><th>В репозитории</th><th>Вердикт</th></tr>
    ${html_rows}
  </table>
</div></body></html>
HTMLEOF

    log "Отчёт сохранён: $html_file"
    echo -e "${CYAN}📊 Отчёт сохранён:${NC} $html_file"
}

# ---------------------------------------------------------------------------
#  Установка всех зависимостей
# ---------------------------------------------------------------------------
install_all_dependencies() {
    local force="${1:-false}"
    local flag; flag="$(deps_flag_file)"

    if [ "$force" != "force" ] && [ -f "$flag" ]; then
        ok "Зависимости уже установлены ранее (пропускаем)"
        return 0
    fi

    echo ""
    separator
    echo -e "${BOLD}${BLUE}  УСТАНОВКА ЗАВИСИМОСТЕЙ — $OS_PRETTY${NC}"
    separator
    echo ""

    pm_update

    local kind alts chosen
    local to_install=() missing_req=() missing_opt=()

    step "Проверка списка пакетов..."
    while IFS='|' read -r kind alts; do
        [ -z "$kind" ] && continue
        chosen="$(pkg_pick "$alts")"
        if [ -z "$chosen" ]; then
            if [ "$kind" = "req" ]; then missing_req+=("$alts"); else missing_opt+=("$alts"); fi
            continue
        fi
        if pkg_installed "$chosen"; then
            ok "$chosen"
        else
            echo -e "  ${YELLOW}⬜${NC} $chosen — будет установлен"
            to_install+=("$chosen")
        fi
    done < <(dep_spec)

    echo ""

    if [ ${#to_install[@]} -gt 0 ]; then
        step "Устанавливаем ${#to_install[@]} пакет(ов)..."
        if ! pm_install "${to_install[@]}"; then
            warn "Групповая установка не прошла — пробуем по одному"
            local p
            for p in "${to_install[@]}"; do
                pm_install "$p" || warn "Не удалось установить: $p"
            done
        fi
    else
        ok "Все доступные зависимости уже стоят"
    fi

    # libgconf-2-4 отсутствует в свежих Debian — при необходимости берём извне
    if [ "$FEAT_GCONF_BACKPORT" = true ] && ! pkg_installed libgconf-2-4; then
        install_gconf_backport
    fi

    # Wayland-сессия: доставляем XWayland
    if [ "$SESSION_TYPE" = "wayland" ]; then
        install_wayland_support
    fi

    echo ""
    if [ ${#missing_req[@]} -gt 0 ]; then
        warn "Не найдены в репозиториях (обязательные):"
        local m
        for m in "${missing_req[@]}"; do echo -e "     ${RED}•${NC} $m"; done
        echo -e "  ${CYAN}Это не всегда ошибка: пакетный менеджер может подтянуть их${NC}"
        echo -e "  ${CYAN}сам при установке Р7 — по зависимостям внутри пакета.${NC}"
        log "Не найдены обязательные пакеты: ${missing_req[*]}"
    fi
    if [ ${#missing_opt[@]} -gt 0 ]; then
        info "  Пропущены необязательные (нет в репо): ${#missing_opt[@]} шт."
        log "Пропущены необязательные: ${missing_opt[*]}"
    fi

    touch "$flag" 2>/dev/null
    echo ""
    ok "Зависимости обработаны"
    log "Зависимости установлены для $OS_ID"
    return 0
}

# ---------------------------------------------------------------------------
#  libgconf-2-4: в Debian 13 пакета уже нет в репозиториях.
#  Тянем .deb напрямую из архива Debian. Ошибка не критична.
# ---------------------------------------------------------------------------
install_gconf_backport() {
    local arch tmpdir
    arch="$(dpkg --print-architecture 2>/dev/null)"
    if [ "$arch" != "amd64" ]; then
        warn "libgconf-2-4: архитектура $arch не поддерживается бэкпортом, пропускаем"
        return 0
    fi

    step "libgconf-2-4 нет в репозитории — пробуем скачать из архива Debian"
    tmpdir="$(mktemp -d /tmp/r7-gconf.XXXXXX)" || return 0

    local base_urls=(
        "https://ftp.debian.org/debian/pool/main/g/gconf"
        "http://archive.debian.org/debian/pool/main/g/gconf"
        "https://snapshot.debian.org/archive/debian/20230101T000000Z/pool/main/g/gconf"
    )
    local files=("gconf2-common_3.2.6-8_all.deb" "libgconf-2-4_3.2.6-8_amd64.deb")
    local got_all=true f url downloaded=()

    for f in "${files[@]}"; do
        local success=false
        for url in "${base_urls[@]}"; do
            if download_file "$url/$f" "$tmpdir/$f"; then success=true; break; fi
        done
        if [ "$success" = true ]; then
            downloaded+=("$tmpdir/$f")
        else
            got_all=false
            break
        fi
    done

    if [ "$got_all" = true ] && [ ${#downloaded[@]} -eq 2 ]; then
        if run_v dpkg -i "${downloaded[@]}"; then
            ok "libgconf-2-4 установлен из архива Debian"
        else
            run_v env DEBIAN_FRONTEND=noninteractive apt-get install -f -y
            pkg_installed libgconf-2-4 && ok "libgconf-2-4 установлен" || warn "libgconf-2-4 установить не удалось"
        fi
    else
        warn "Скачать libgconf-2-4 не удалось (нет сети или файл убран из архива)"
        echo -e "  ${CYAN}Современные сборки Р7 обычно работают и без него.${NC}"
    fi

    rm -rf "$tmpdir" 2>/dev/null
    return 0
}

# Универсальная загрузка: wget или curl, что есть в системе
download_file() {
    local url="$1" dest="$2"
    if [ "$DRY_RUN" = true ]; then echo -e "  ${MAGENTA}[dry-run]${NC} download $url"; return 0; fi
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout=25 --tries=2 -O "$dest" "$url" 2>>"$LOG_FILE" && [ -s "$dest" ]
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 25 --retry 2 -o "$dest" "$url" 2>>"$LOG_FILE" && [ -s "$dest" ]
    else
        warn "Нет ни wget, ни curl — скачать не могу"
        return 1
    fi
}

# ============================================================================
#  ОКРУЖЕНИЕ: ПОЛЬЗОВАТЕЛЬ, ГРАФИКА, X11 / WAYLAND, ДИСК
# ============================================================================

REAL_USER=""; USER_HOME=""; REAL_UID=""
SESSION_TYPE="none"    # x11 | wayland | tty | none
FREE_SPACE_GB=0

# Определить пользователя, который реально работает за машиной
detect_real_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        REAL_USER="$SUDO_USER"
    else
        # Первый пользователь с графической сессией, иначе — владелец /home/*
        REAL_USER="$(who 2>/dev/null | awk '$2 ~ /^(:|tty|seat)/ {print $1; exit}')"
        [ -z "$REAL_USER" ] && REAL_USER="$(logname 2>/dev/null)"
        [ -z "$REAL_USER" ] && REAL_USER="$(ls -1 /home 2>/dev/null | head -1)"
        [ -z "$REAL_USER" ] && REAL_USER="root"
    fi
    USER_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
    [ -z "$USER_HOME" ] && USER_HOME="/home/$REAL_USER"
    [ -d "$USER_HOME" ] || USER_HOME="/root"
    REAL_UID="$(id -u "$REAL_USER" 2>/dev/null)"
    [ -z "$REAL_UID" ] && REAL_UID="0"
}

# Определить тип графической сессии — работает и из-под sudo
detect_session_type() {
    SESSION_TYPE="none"

    if [ -n "${XDG_SESSION_TYPE:-}" ] && [ "$XDG_SESSION_TYPE" != "unspecified" ]; then
        SESSION_TYPE="$XDG_SESSION_TYPE"
    elif command -v loginctl >/dev/null 2>&1; then
        local sid
        sid="$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$REAL_USER" '$3==u {print $1; exit}')"
        [ -z "$sid" ] && sid="$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NR==1{print $1}')"
        if [ -n "$sid" ]; then
            SESSION_TYPE="$(loginctl show-session "$sid" -p Type --value 2>/dev/null)"
        fi
    fi

    # Подстраховка по сокетам и процессам
    if [ "$SESSION_TYPE" = "none" ] || [ -z "$SESSION_TYPE" ]; then
        if [ -n "${WAYLAND_DISPLAY:-}" ] || ls /run/user/"$REAL_UID"/wayland-* >/dev/null 2>&1; then
            SESSION_TYPE="wayland"
        elif pgrep -x Xorg >/dev/null 2>&1 || pgrep -x X >/dev/null 2>&1; then
            SESSION_TYPE="x11"
        elif [ -n "${DISPLAY:-}" ]; then
            SESSION_TYPE="x11"
        else
            SESSION_TYPE="none"
        fi
    fi

    # Wayland без XWayland — отдельный случай, важен для Р7
    if [ "$SESSION_TYPE" = "wayland" ] && [ -z "${DISPLAY:-}" ]; then
        if pgrep -x Xwayland >/dev/null 2>&1; then
            export DISPLAY=":0"
        fi
    elif [ "$SESSION_TYPE" = "x11" ] && [ -z "${DISPLAY:-}" ]; then
        export DISPLAY=":0"
    fi
}

detect_environment() {
    detect_real_user
    detect_session_type

    [ "$CMD_GUI" = true ] && return 0

    info "Проверка окружения..."
    ok "ОС: $OS_PRETTY"
    ok "Пакетный менеджер: $PM (формат $PKG_FMT)"
    ok "Пользователь: $REAL_USER (домашняя папка: $USER_HOME)"

    case "$SESSION_TYPE" in
        wayland)
            warn "Сессия: Wayland"
            if pgrep -x Xwayland >/dev/null 2>&1; then
                ok "XWayland запущен — Р7 будет работать через него"
            else
                warn "XWayland не запущен. Пункт [W] в меню это исправит."
            fi
            ;;
        x11) ok "Сессия: X11 (DISPLAY=${DISPLAY:-не задан})" ;;
        tty) warn "Сессия: текстовая консоль, графики нет" ;;
        *)   warn "Графическая сессия не обнаружена (установка всё равно возможна)" ;;
    esac

    FREE_SPACE_GB="$(df -BG / 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')"
    [ -z "$FREE_SPACE_GB" ] && FREE_SPACE_GB=0
    if [ "$FREE_SPACE_GB" -lt 3 ] 2>/dev/null; then
        fail "Мало места на диске: ${FREE_SPACE_GB} ГБ (нужно хотя бы 3 ГБ)"
        return 1
    else
        ok "Свободно на диске: ${FREE_SPACE_GB} ГБ"
    fi
    echo ""
    return 0
}

# ============================================================================
#  ПРОСТОЙ ЭКРАНА: ОТКЛЮЧЕНИЕ НА ВРЕМЯ УСТАНОВКИ
#
#  Для ночных прогонов и soak-тестов под Jenkins: если экран гаснет и
#  блокируется, RDP/VNC-сессия может оборваться раньше, чем скрипт
#  закончит работу. Отключаем скринсейвер/DPMS/блокировку на время
#  работы скрипта и возвращаем исходные настройки при выходе — в том
#  числе по Ctrl+C и по обычному завершению (trap EXIT/INT/TERM).
#
#  Все меняющие команды идут через run() — значит, автоматически уважают
#  --dry-run и пишут себя в LOG_FILE, как и остальной скрипт.
#  Команды "прочитать текущее состояние" через run() не идут: run()
#  глотает stdout в лог, а нам нужно значение обратно в переменную.
# ============================================================================

IDLE_STATE_FILE=""
IDLE_CONTROL_ACTIVE=false

# XAUTHORITY реального пользователя — лучшая попытка, не гарантия.
# Скрипт и так строит похожие догадки для DISPLAY в detect_session_type().
find_xauthority() {
    if [ -n "${XAUTHORITY:-}" ] && [ -f "$XAUTHORITY" ]; then
        echo "$XAUTHORITY"; return 0
    fi
    local c
    for c in "$USER_HOME/.Xauthority" "/run/user/$REAL_UID/gdm/Xauthority"; do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    echo "$USER_HOME/.Xauthority"
}

# Выполнить команду от имени реального пользователя с его графическим
# окружением — xset/gsettings/xfconf-query от root в чужую X11/Wayland
# сессию обычно не достучатся без этого.
run_as_user() {
    if [ "$(id -u)" -eq 0 ] && [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        sudo -u "$REAL_USER" \
            DISPLAY="${DISPLAY:-:0}" \
            XAUTHORITY="$(find_xauthority)" \
            XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" \
            "$@"
    else
        "$@"
    fi
}

# --- X11 (xset): Debian, Astra, Альт/РЕД ОС/РОСА с X11-сессией ---------------

idle_x11_save() {
    command -v xset >/dev/null 2>&1 || return 1
    local q; q="$(run_as_user xset q 2>/dev/null)"
    [ -z "$q" ] && return 1
    local timeout cycle blanking dpms
    timeout="$(echo "$q" | awk '/^  timeout:/{print $2; exit}')"
    cycle="$(echo "$q" | awk '/^  timeout:/{print $4; exit}')"
    blanking="$(echo "$q" | awk '/prefer blanking:/{print $3; exit}')"
    dpms="off"; echo "$q" | grep -q "DPMS is Enabled" && dpms="on"
    printf 'X11_TIMEOUT=%s\nX11_CYCLE=%s\nX11_BLANKING=%s\nX11_DPMS=%s\n' \
        "${timeout:-0}" "${cycle:-0}" "${blanking:-yes}" "$dpms"
}

idle_x11_disable() {
    run run_as_user xset s off
    run run_as_user xset -dpms
    run run_as_user xset s noblank
}

idle_x11_restore() {
    local timeout="${1:-0}" cycle="${2:-0}" blanking="${3:-yes}" dpms="${4:-on}"
    run run_as_user xset s "$timeout" "$cycle"
    if [ "$blanking" = "yes" ]; then run run_as_user xset s blank; else run run_as_user xset s noblank; fi
    if [ "$dpms" = "on" ]; then run run_as_user xset +dpms; else run run_as_user xset -dpms; fi
}

# --- GNOME/Wayland (gsettings): Debian 13, РЕД ОС, РОСА ----------------------

idle_gsettings_save() {
    command -v gsettings >/dev/null 2>&1 || return 1
    local idle_delay lock_enabled idle_activation
    idle_delay="$(run_as_user gsettings get org.gnome.desktop.session idle-delay 2>/dev/null | sed -E 's/^uint32 //')"
    [ -z "$idle_delay" ] && return 1
    lock_enabled="$(run_as_user gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null)"
    idle_activation="$(run_as_user gsettings get org.gnome.desktop.screensaver idle-activation-enabled 2>/dev/null)"
    printf 'GS_IDLE_DELAY=%s\nGS_LOCK_ENABLED=%s\nGS_IDLE_ACTIVATION=%s\n' \
        "$idle_delay" "${lock_enabled:-true}" "${idle_activation:-true}"
}

idle_gsettings_disable() {
    run run_as_user gsettings set org.gnome.desktop.session idle-delay 0
    run run_as_user gsettings set org.gnome.desktop.screensaver lock-enabled false
    run run_as_user gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
}

idle_gsettings_restore() {
    local idle_delay="${1:-300}" lock_enabled="${2:-true}" idle_activation="${3:-true}"
    run run_as_user gsettings set org.gnome.desktop.session idle-delay "$idle_delay"
    run run_as_user gsettings set org.gnome.desktop.screensaver lock-enabled "$lock_enabled"
    run run_as_user gsettings set org.gnome.desktop.screensaver idle-activation-enabled "$idle_activation"
}

# --- Xfce (Альт бывает и с Xfce, и с GNOME) — проверяем независимо от SESSION_TYPE

idle_xfce_save() {
    command -v xfconf-query >/dev/null 2>&1 || return 1
    local dpms; dpms="$(run_as_user xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled 2>/dev/null)"
    [ -z "$dpms" ] && return 1
    printf 'XFCE_DPMS=%s\n' "$dpms"
}

idle_xfce_disable() {
    command -v xfconf-query >/dev/null 2>&1 || return 0
    run run_as_user xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false
}

idle_xfce_restore() {
    local dpms="${1:-true}"
    command -v xfconf-query >/dev/null 2>&1 || return 0
    run run_as_user xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s "$dpms"
}

# --- Текстовая консоль (без графики) -----------------------------------------
# setterm не умеет "спросить" текущие значения — восстанавливаем на
# консольные умолчания Дистрибутивов (10 минут), а не на неизвестный
# оригинал. Это единственное место, где восстановление не буквальное.

idle_console_save() {
    command -v setterm >/dev/null 2>&1 || return 1
    echo "CONSOLE_TOUCHED=yes"
}

idle_console_disable() {
    run setterm -blank 0 -powersave off -powerdown 0
}

idle_console_restore() {
    run setterm -blank 10 -powersave powerdown -powerdown 10
}

# --- Оркестрация --------------------------------------------------------------

idle_control_init() {
    if [ "$CMD_NO_IDLE" = true ]; then
        log "Управление простоем экрана отключено флагом --no-idle"
        return 0
    fi
    if [ "$CFG_ENABLE_IDLE_CONTROL" = false ]; then
        log "Управление простоем экрана отключено конфигом (ENABLE_IDLE_CONTROL=false)"
        return 0
    fi

    IDLE_STATE_FILE="$STATE_DIR/idle-saved.state"
    if ! : > "$IDLE_STATE_FILE" 2>/dev/null; then
        warn "Не удалось сохранить состояние экрана ($IDLE_STATE_FILE недоступен) — пропускаю"
        return 0
    fi

    {
        case "$SESSION_TYPE" in
            x11)      idle_x11_save ;;
            wayland)  idle_gsettings_save ;;
            tty|none) idle_console_save ;;
        esac
        idle_xfce_save
    } >> "$IDLE_STATE_FILE" 2>/dev/null

    case "$SESSION_TYPE" in
        x11)      idle_x11_disable ;;
        wayland)  idle_gsettings_disable ;;
        tty|none) idle_console_disable ;;
    esac
    idle_xfce_disable

    IDLE_CONTROL_ACTIVE=true
    log "Отключено засыпание/блокировка экрана (сессия: $SESSION_TYPE)"
    info "Экран не будет гаснуть на время работы скрипта (--no-idle — отключить)"
}

# Прочитать файл состояния и вызвать restore только там, где что-то
# реально сохранилось (пустая метка = "не пытаться восстанавливать").
idle_state_restore_from_file() {
    local file="$1"
    [ -f "$file" ] || return 0

    local X11_TIMEOUT="" X11_CYCLE="" X11_BLANKING="" X11_DPMS=""
    local GS_IDLE_DELAY="" GS_LOCK_ENABLED="" GS_IDLE_ACTIVATION=""
    local XFCE_DPMS="" CONSOLE_TOUCHED=""
    local key value
    while IFS='=' read -r key value; do
        [ -z "$key" ] && continue
        case "$key" in
            X11_TIMEOUT|X11_CYCLE|X11_BLANKING|X11_DPMS|\
            GS_IDLE_DELAY|GS_LOCK_ENABLED|GS_IDLE_ACTIVATION|\
            XFCE_DPMS|CONSOLE_TOUCHED)
                printf -v "$key" '%s' "$value" ;;
        esac
    done < "$file"

    [ -n "$X11_DPMS" ]       && idle_x11_restore "$X11_TIMEOUT" "$X11_CYCLE" "$X11_BLANKING" "$X11_DPMS"
    [ -n "$GS_IDLE_DELAY" ]  && idle_gsettings_restore "$GS_IDLE_DELAY" "$GS_LOCK_ENABLED" "$GS_IDLE_ACTIVATION"
    [ -n "$XFCE_DPMS" ]      && idle_xfce_restore "$XFCE_DPMS"
    [ "$CONSOLE_TOUCHED" = yes ] && idle_console_restore
}

idle_control_restore_now() {
    [ "$IDLE_CONTROL_ACTIVE" = true ] || return 0
    idle_state_restore_from_file "$IDLE_STATE_FILE"
    rm -f "$IDLE_STATE_FILE" 2>/dev/null
    IDLE_CONTROL_ACTIVE=false
    log "Настройки простоя экрана восстановлены"
}

# Единая точка выхода: сюда со временем может добраться и другая уборка,
# не только простой экрана — поэтому не привязываем trap к конкретной фиче.
on_script_exit() {
    spinner_stop 2>/dev/null
    idle_control_restore_now
}

# ============================================================================
#  WAYLAND: XWAYLAND + ЗАПУСК Р7 ЧЕРЕЗ X11-БЭКЕНД
#
#  Р7-Офис построен на Qt и CEF. Под Wayland он либо не стартует, либо
#  показывает пустое окно и ломает ввод. Надёжное решение — гнать его
#  через XWayland, принудительно задав X11-бэкенд в переменных окружения.
# ============================================================================

R7_WRAPPER="/usr/local/bin/r7-office-x11"

wayland_pkg_alts() {
    case "$OS_ID" in
        alt)        echo "xorg-server-xwayland xwayland xorg-xwayland" ;;
        redos)      echo "xorg-x11-server-Xwayland xwayland" ;;
        rosa)       echo "xorg-x11-server-Xwayland xwayland" ;;
        *)          echo "xwayland xwayland-run" ;;
    esac
}

install_wayland_support() {
    local pkg
    pkg="$(pkg_pick "$(wayland_pkg_alts)")"
    if [ -z "$pkg" ]; then
        warn "Пакет XWayland не найден в репозиториях этой ОС"
        return 1
    fi
    if pkg_installed "$pkg"; then
        ok "XWayland уже установлен ($pkg)"
    else
        step "Устанавливаем XWayland ($pkg)..."
        pm_install "$pkg" && ok "XWayland установлен" || { warn "Не удалось установить $pkg"; return 1; }
    fi
    return 0
}

# Найти исполняемый файл Р7-Офис
find_r7_binary() {
    local c
    for c in /usr/bin/r7-office /usr/bin/r7-office-desktopeditors \
             /opt/r7-office/desktopeditors/DesktopEditors \
             /opt/r7-office/editors/DesktopEditors \
             /opt/r7-office/DesktopEditors; do
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    c="$(command -v r7-office 2>/dev/null)"
    [ -n "$c" ] && { echo "$c"; return 0; }
    return 1
}

# Найти именно ELF-бинарник DesktopEditors (не обёртку /usr/bin/r7-office).
# Р7 построен на Qt/CEF и таскает свои .so рядом с самим бинарником —
# ldd на скрипте-обёртке бессмысленен, а без LD_LIBRARY_PATH на каталог
# бинарника даёт ложные "not found" на библиотеках, которые лежат тут же.
find_r7_elf() {
    local c
    for c in /opt/r7-office/desktopeditors/DesktopEditors \
             /opt/r7-office/editors/DesktopEditors \
             /opt/r7-office/DesktopEditors; do
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    find_r7_binary
}

# ============================================================================
#  SMOKE-ТЕСТ: РЕАЛЬНО ЛИ СОБЕРУТСЯ ЗАВИСИМОСТИ БИНАРНИКА
# ============================================================================

LDD_STATUS=""   # "" | passed | failed | skipped — читают история и отчёт

smoke_test_ldd() {
    local bin; bin="$(find_r7_elf)"
    if [ -z "$bin" ]; then
        LDD_STATUS="skipped"
        warn "Исполняемый файл Р7-Офис не найден — smoke-тест пропущен"
        return 1
    fi
    if ! command -v ldd >/dev/null 2>&1; then
        LDD_STATUS="skipped"
        info "  ldd не установлен — smoke-тест пропущен"
        return 0
    fi

    step "Smoke-тест: проверяем зависимости $(basename "$bin")..."
    local libdir out missing
    libdir="$(dirname "$bin")"
    out="$(LD_LIBRARY_PATH="$libdir:${LD_LIBRARY_PATH:-}" ldd "$bin" 2>&1)"
    missing="$(echo "$out" | grep "not found" || true)"

    if [ -z "$missing" ]; then
        LDD_STATUS="passed"
        ok "Smoke-тест пройден: все зависимости бинарника на месте"
        log "Smoke-тест (ldd) пройден: $bin"
        return 0
    fi

    LDD_STATUS="failed"
    fail "Smoke-тест: не хватает библиотек рядом с $(basename "$bin")"
    echo "$missing" | sed 's/^/     /'
    log "Smoke-тест (ldd) провален для $bin: $(echo "$missing" | tr '\n' ';' | sed 's/;/; /g')"
    return 1
}

# Найти .desktop файл Р7-Офис
find_r7_desktop() {
    local d
    for d in /usr/share/applications/r7-office-desktopeditors.desktop \
             /usr/share/applications/r7-office.desktop; do
        [ -f "$d" ] && { echo "$d"; return 0; }
    done
    d="$(ls -1 /usr/share/applications/*r7*.desktop 2>/dev/null | head -1)"
    [ -n "$d" ] && { echo "$d"; return 0; }
    return 1
}

# Создать обёртку, запускающую Р7 через XWayland
create_x11_wrapper() {
    local bin
    bin="$(find_r7_binary)"
    if [ -z "$bin" ]; then
        warn "Исполняемый файл Р7-Офис не найден — сначала установите Р7"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${MAGENTA}[dry-run]${NC} создать $R7_WRAPPER для $bin"
        return 0
    fi

    cat > "$R7_WRAPPER" <<WRAPEOF
#!/bin/sh
# Запуск Р7-Офис через XWayland.
# Создано автоматически: install-r7.sh --fix-wayland
export GDK_BACKEND=x11
export QT_QPA_PLATFORM=xcb
export CLUTTER_BACKEND=x11
export SDL_VIDEODRIVER=x11
export XDG_SESSION_TYPE=x11
unset WAYLAND_DISPLAY
[ -z "\$DISPLAY" ] && export DISPLAY=:0
exec "$bin" "\$@"
WRAPEOF
    chmod 755 "$R7_WRAPPER"
    ok "Создана обёртка: $R7_WRAPPER"
    log "Создан враппер $R7_WRAPPER -> $bin"
    return 0
}

# Переопределить ярлык в меню приложений пользователя
create_wayland_desktop_entry() {
    local src dest_dir dest
    src="$(find_r7_desktop)"
    dest_dir="$USER_HOME/.local/share/applications"
    dest="$dest_dir/r7-office-desktopeditors.desktop"

    if [ -z "$src" ]; then
        warn "Ярлык Р7-Офис не найден в /usr/share/applications"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${MAGENTA}[dry-run]${NC} создать ярлык $dest"
        return 0
    fi

    mkdir -p "$dest_dir"
    # Копируем системный ярлык и подменяем команду запуска на обёртку
    sed -E "s|^Exec=[^ ]*|Exec=$R7_WRAPPER|" "$src" > "$dest"
    chown "$REAL_USER":"$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")" "$dest" 2>/dev/null
    chmod 644 "$dest"
    ok "Ярлык для Wayland: $dest"

    if command -v update-desktop-database >/dev/null 2>&1; then
        run update-desktop-database "$dest_dir"
    fi
    log "Создан wayland-ярлык $dest"
    return 0
}

fix_wayland() {
    header
    separator
    echo -e "${BOLD}${BLUE}  ИСПРАВЛЕНИЕ ЗАПУСКА ПОД WAYLAND${NC}"
    separator
    echo ""

    if [ "$SESSION_TYPE" != "wayland" ]; then
        warn "Текущая сессия: $SESSION_TYPE (не Wayland)"
        echo -e "  ${CYAN}Настройку можно применить впрок — она не мешает работе под X11.${NC}"
        echo ""
        confirm "Продолжить?" "Y" || return 0
        echo ""
    fi

    pm_update
    install_wayland_support
    create_x11_wrapper
    create_wayland_desktop_entry

    echo ""
    separator
    ok "Готово. Запускайте Р7-Офис из меню приложений или командой:"
    echo -e "     ${BOLD}$R7_WRAPPER${NC}"
    echo ""
    info "Если окно всё равно пустое — перезайдите в сессию,"
    info "либо выберите на экране входа сессию 'X11 / Xorg'."
    separator
    log "Выполнен fix-wayland"
    return 0
}

# ============================================================================
#  ОПТИМИЗАЦИЯ RDP (только РЕД ОС, только при наличии xrdp)
# ============================================================================

rdp_flag_file() { echo "$STATE_DIR/rdp-optimized.done"; }

# Записать параметр в ini: заменить строку или дописать в конец
ini_set() {
    local file="$1" key="$2" value="$3"
    if grep -qE "^[#;[:space:]]*${key}=" "$file" 2>/dev/null; then
        sed -i -E "s|^[#;[:space:]]*${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

optimize_rdp() {
    [ "$FEAT_RDP" != true ] && return 0
    [ -f "$(rdp_flag_file)" ] && return 0

    local ini="/etc/xrdp/xrdp.ini"

    if ! command -v xrdp >/dev/null 2>&1 && [ ! -f "$ini" ]; then
        log "xrdp не установлен — оптимизация RDP пропущена"
        return 0
    fi
    if [ ! -f "$ini" ]; then
        warn "Файл $ini не найден — оптимизация RDP пропущена"
        return 0
    fi

    echo ""
    separator
    echo -e "${BOLD}${BLUE}  ОПТИМИЗАЦИЯ RDP-СОЕДИНЕНИЯ${NC}"
    separator
    echo ""
    echo -e "  Ускорим работу Р7-Офис в удалённом рабочем столе:"
    echo -e "    • tcp_send_buffer_bytes=33554432 — больше буфер, меньше рывков"
    echo -e "    • max_bpp=16 — меньше цветов, заметно быстрее отрисовка"
    echo -e "    • crypt_level=none — снимает шифрование канала"
    echo ""
    echo -e "  ${YELLOW}Внимание: crypt_level=none отключает шифрование RDP.${NC}"
    echo -e "  ${YELLOW}Применяйте только в доверенной локальной сети.${NC}"
    echo ""

    if ! confirm "Применить оптимизацию RDP?" "Y"; then
        info "  Пропущено. Вернуться к этому можно пунктом [P] в меню."
        touch "$(rdp_flag_file)" 2>/dev/null
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${MAGENTA}[dry-run]${NC} правка $ini"
        return 0
    fi

    # Резервная копия — только первая, чтобы не затереть исходник
    if [ ! -f "${ini}.r7-backup" ]; then
        cp "$ini" "${ini}.r7-backup" && ok "Резервная копия: ${ini}.r7-backup"
    else
        ok "Резервная копия уже есть: ${ini}.r7-backup"
    fi

    ini_set "$ini" "crypt_level" "none"
    ini_set "$ini" "tcp_send_buffer_bytes" "33554432"
    ini_set "$ini" "tcp_recv_buffer_bytes" "33554432"
    ini_set "$ini" "max_bpp" "16"
    ok "Параметры записаны в $ini"

    step "Перезапуск xrdp..."
    if run systemctl restart xrdp || run service xrdp restart; then
        ok "xrdp перезапущен"
    else
        warn "Перезапустить xrdp не удалось — сделайте это вручную"
    fi

    touch "$(rdp_flag_file)" 2>/dev/null
    log "Выполнена оптимизация RDP"
    echo ""
    ok "RDP оптимизирован"
    return 0
}

# Откатить настройки RDP из резервной копии
restore_rdp() {
    local ini="/etc/xrdp/xrdp.ini"
    if [ ! -f "${ini}.r7-backup" ]; then
        warn "Резервная копия ${ini}.r7-backup не найдена"
        return 1
    fi
    confirm "Восстановить исходный $ini из резервной копии?" "Y" || return 0
    cp "${ini}.r7-backup" "$ini" && ok "Настройки RDP восстановлены"
    rm -f "$(rdp_flag_file)"
    run systemctl restart xrdp || run service xrdp restart
    log "Настройки RDP восстановлены из резервной копии"
}

# ============================================================================
#  КОНТРОЛЬНАЯ СУММА
# ============================================================================

# Сравнить две суммы без учёта регистра
hash_equal() {
    local a b
    a="$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    b="$(echo "$2" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    [ "$a" = "$b" ]
}

check_checksum() {
    local file="$1" user_md5="$2"
    local md5_file="${file}.md5" sha_file="${file}.sha256"
    local computed expected

    # 1. Хэш передан аргументом или введён в меню
    if [ -n "$user_md5" ]; then
        step "Проверка MD5..."
        computed="$(md5sum "$file" | awk '{print $1}')"
        if hash_equal "$computed" "$user_md5"; then
            ok "MD5 совпадает"
            log "MD5 совпал для $file"
            return 0
        fi
        fail "MD5 НЕ совпадает!"
        echo -e "     ${YELLOW}Ожидалось: $user_md5${NC}"
        echo -e "     ${YELLOW}Получено:  $computed${NC}"
        log "MD5 не совпал для $file"
        return 1
    fi

    # 2. Рядом лежит файл с суммой
    if [ -f "$sha_file" ]; then
        step "Проверка SHA256 (из файла)..."
        computed="$(sha256sum "$file" | awk '{print $1}')"
        expected="$(awk '{print $1}' "$sha_file" | head -1)"
        hash_equal "$computed" "$expected" && { ok "SHA256 совпадает"; return 0; }
        fail "SHA256 НЕ совпадает!"
        echo -e "     ${YELLOW}Ожидалось: $expected${NC}"
        echo -e "     ${YELLOW}Получено:  $computed${NC}"
        return 1
    fi

    if [ -f "$md5_file" ]; then
        step "Проверка MD5 (из файла)..."
        computed="$(md5sum "$file" | awk '{print $1}')"
        expected="$(awk '{print $1}' "$md5_file" | head -1)"
        hash_equal "$computed" "$expected" && { ok "MD5 совпадает"; return 0; }
        fail "MD5 НЕ совпадает!"
        echo -e "     ${YELLOW}Ожидалось: $expected${NC}"
        echo -e "     ${YELLOW}Получено:  $computed${NC}"
        return 1
    fi

    # 3. Спросить у пользователя (MD5 из документа Word)
    if [ "$ASSUME_YES" = true ]; then
        warn "Файл с контрольной суммой не найден, проверка пропущена"
        return 0
    fi

    echo -e "${YELLOW}Файлы .md5 и .sha256 рядом с пакетом не найдены.${NC}"
    echo -e "${YELLOW}Если MD5 есть в документе Word — введите его сейчас.${NC}"
    echo -n -e "${BOLD}MD5 (Enter — пропустить проверку): ${NC}"
    read -r manual_md5
    if [ -z "$manual_md5" ]; then
        warn "Проверка пропущена"
        return 0
    fi
    computed="$(md5sum "$file" | awk '{print $1}')"
    if hash_equal "$computed" "$manual_md5"; then
        ok "MD5 совпадает"
        return 0
    fi
    fail "MD5 НЕ совпадает!"
    echo -e "     ${YELLOW}Ожидалось: $manual_md5${NC}"
    echo -e "     ${YELLOW}Получено:  $computed${NC}"
    return 1
}

# ============================================================================
#  ПОИСК ПАКЕТОВ
# ============================================================================

PKG_FILES=()

# Где искать пакеты: --dir, папка скрипта, Downloads пользователя, стандартные пути
resolve_download_dir() {
    if [ -n "$DOWNLOAD_DIR" ]; then
        [ -d "$DOWNLOAD_DIR" ] || { fail "Папка не найдена: $DOWNLOAD_DIR"; exit 1; }
        return 0
    fi
    local candidates=(
        "$SCRIPT_DIR"
        "$USER_HOME/Downloads"
        "$USER_HOME/Загрузки"
        "/home/administrator/Downloads"
        "/opt/r7-dist"
        "$PWD"
    )
    local d
    for d in "${candidates[@]}"; do
        [ -d "$d" ] || continue
        if ls "$d"/r7-*."$PKG_FMT" >/dev/null 2>&1; then
            DOWNLOAD_DIR="$d"
            return 0
        fi
    done
    # Пакетов нигде нет — берём первую существующую папку, сообщим позже
    for d in "${candidates[@]}"; do
        [ -d "$d" ] && { DOWNLOAD_DIR="$d"; return 0; }
    done
    DOWNLOAD_DIR="$PWD"
}

find_packages() {
    PKG_FILES=()
    resolve_download_dir
    mapfile -t PKG_FILES < <(ls -t "$DOWNLOAD_DIR"/r7-*."$PKG_FMT" 2>/dev/null)
    if [ ${#PKG_FILES[@]} -eq 0 ]; then
        return 1
    fi
    log "Найдено ${#PKG_FILES[@]} пакетов в $DOWNLOAD_DIR"
    return 0
}

require_packages() {
    if ! find_packages; then
        echo ""
        fail "В папке $DOWNLOAD_DIR не найдено файлов r7-*.$PKG_FMT"
        echo ""
        echo -e "  ${CYAN}Положите дистрибутив Р7-Офис в эту папку либо укажите свою:${NC}"
        echo -e "     ${BOLD}sudo $SCRIPT_NAME --dir /путь/к/папке${NC}"
        echo ""
        exit 1
    fi
}

# Версия из имени файла: r7-office_8.1.0-1234_amd64.deb -> 8.1.0-1234
extract_version() {
    local v
    v="$(basename "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[-.][0-9]+' | head -1)"
    [ -z "$v" ] && v="$(basename "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    echo "$v"
}

# Это дополнение (СБЕР IRM и подобные), а не основной пакет?
is_addon_package() {
    case "$(basename "$1")" in
        r7-office-sber-irm*|r7-office-*-plugin*|r7-*-addon*) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================================
#  ЗАПУЩЕННЫЙ Р7: НАЙТИ И ПРЕДЛОЖИТЬ ЗАКРЫТЬ
# ============================================================================

r7_running_pids() {
    pgrep -f 'r7-office|DesktopEditors|r7office' 2>/dev/null | tr '\n' ' '
}

ensure_r7_closed() {
    local pids
    pids="$(r7_running_pids)"
    [ -z "$pids" ] && return 0

    echo ""
    warn "Р7-Офис сейчас запущен (PID: $pids)"
    echo -e "  ${CYAN}Установка поверх работающей программы приводит к сбоям.${NC}"
    echo -e "  ${CYAN}Сохраните открытые документы перед закрытием.${NC}"
    echo ""

    if ! confirm "Закрыть Р7-Офис сейчас?" "Y"; then
        warn "Продолжаем с запущенным Р7 — возможны ошибки"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${MAGENTA}[dry-run]${NC} kill $pids"
        return 0
    fi

    step "Просим Р7 закрыться (SIGTERM)..."
    kill $pids 2>/dev/null

    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        [ -z "$(r7_running_pids)" ] && { ok "Р7-Офис закрыт"; log "Р7 закрыт по SIGTERM"; return 0; }
    done

    warn "Р7 не закрылся за 10 секунд"
    if confirm "Завершить принудительно (SIGKILL)? Несохранённое будет потеряно" "N"; then
        kill -9 $(r7_running_pids) 2>/dev/null
        sleep 1
        ok "Процессы завершены принудительно"
        log "Р7 завершён по SIGKILL"
    fi
    return 0
}

# ============================================================================
#  ИНФОРМАЦИЯ О ПАКЕТЕ
# ============================================================================

show_package_info() {
    local file="$1"
    echo ""
    separator
    echo -e "${BOLD}${WHITE}  ИНФОРМАЦИЯ О ПАКЕТЕ${NC}"
    separator
    echo -e "${CYAN}Файл:${NC}    $(basename "$file")"
    echo -e "${CYAN}Размер:${NC}  $(du -h "$file" 2>/dev/null | cut -f1)"
    echo -e "${CYAN}Изменён:${NC} $(stat -c '%y' "$file" 2>/dev/null | cut -d'.' -f1)"
    echo -e "${CYAN}MD5:${NC}     $(md5sum "$file" | awk '{print $1}')"
    echo ""
    case "$PKG_FMT" in
        deb)
            dpkg-deb -f "$file" Package Version Architecture Installed-Size 2>/dev/null | sed 's/^/  /'
            ;;
        rpm)
            rpm -qip "$file" 2>/dev/null | sed -n '1,8p' | sed 's/^/  /'
            ;;
    esac
    separator
    echo ""
}

# ============================================================================
#  СООТВЕТСТВИЕ СБОРКИ ПАКЕТА И ОС
#
#  Р7 собирает отдельные .rpm под каждую RPM-систему — имя пакета выглядит
#  одинаково (r7-office-ВЕРСИЯ.ТЕГ.x86_64.rpm), но ТЕГ выдаёт, под какую
#  систему собраны зависимости:
#    .p8 / .p9 / .p10 / .p11   — Альт Linux
#    .r8 / .r9                 — РОСА (имена библиотек как в Альте: lib64*)
#    .el7 / .el8                — РЕД ОС (обычные имена: glibc, gtk3, libX11)
#    ~astra[-signed]            — Astra Linux (.deb)
#  Если поставить "не свой" .rpm, пакетный менеджер упрётся в зависимости
#  вида "nothing provides lib64gtk+2.0_0" — это не сломанный репозиторий,
#  а просто пакет от другой ОС.
# ============================================================================

detect_build_tag() {
    local name; name="$(basename "$1")"
    case "$name" in
        *~astra*)                          echo "astra" ;;
        *.p[0-9]*.x86_64.rpm)              echo "alt" ;;
        *.r[0-9]*.x86_64.rpm)              echo "rosa" ;;
        *.el[0-9]*.x86_64.rpm)             echo "redos" ;;
        *~stretch*|*~bookworm*|*~trixie*)  echo "debian" ;;
        *)                                  echo "" ;;
    esac
}

check_package_os_match() {
    local file="$1" tag; tag="$(detect_build_tag "$file")"
    [ -z "$tag" ] && return 0

    local expect=""
    case "$OS_ID" in
        alt)                expect="alt" ;;
        rosa)               expect="rosa" ;;
        redos)              expect="redos" ;;
        astra)              expect="astra" ;;
        debian12|debian13)  expect="debian" ;;
    esac

    [ -z "$expect" ] || [ "$tag" = "$expect" ] && return 0

    echo ""
    warn "Похоже, пакет собран не под эту ОС."
    echo -e "  ${CYAN}Файл:${NC}            $(basename "$file")"
    echo -e "  ${CYAN}Сборка похожа на:${NC} $tag"
    echo -e "  ${CYAN}Текущая система:${NC}  $OS_ID ($OS_PRETTY)"
    echo -e "  ${CYAN}Установка чужой сборки обычно падает на зависимостях${NC}"
    echo -e "  ${CYAN}(\"nothing provides ...\"). Скачайте .rpm/.deb для этой ОС.${NC}"
    echo ""
    log "Несовпадение сборки пакета: файл похож на «$tag», ОС «$OS_ID» ($(basename "$file"))"
    confirm "Всё равно продолжить?" "N"
}

# ============================================================================
#  ПОДПИСЬ ПАКЕТА
#
#  MD5 из документа Word (check_checksum) защищает от битой закачки, но не
#  подтверждает, что пакет вообще пришёл от Р7. Где есть штатный
#  инструмент проверки подписи — используем его. Не блокируем установку
#  при отсутствии подписи: у .deb в этом проекте её просто обычно нет
#  (это не то же самое, что подпись Release-файла репозитория apt), а
#  среди тестовых сборок попадаются и неподписанные .rpm.
# ============================================================================

GPG_STATUS=""   # "" | passed | unsigned | failed | skipped — читают история и отчёт

check_package_signature() {
    local file="$1"
    case "$PKG_FMT" in
        rpm)
            if ! command -v rpm >/dev/null 2>&1; then
                GPG_STATUS="skipped"; return 0
            fi
            local out; out="$(rpm -K "$file" 2>&1)"
            case "$out" in
                *"signatures OK"*|*"pgp"*"OK"*|*"gpg"*"OK"*)
                    GPG_STATUS="passed"
                    ok "Подпись пакета: действительна"
                    ;;
                *"digests OK"*)
                    GPG_STATUS="unsigned"
                    info "  Подпись пакета: не подписан (контрольные суммы внутри пакета в порядке)"
                    ;;
                *)
                    GPG_STATUS="failed"
                    warn "Подпись пакета: не удалось подтвердить ($out)"
                    ;;
            esac
            log "Проверка подписи ($file): $out"
            ;;
        deb)
            if command -v dpkg-sig >/dev/null 2>&1; then
                local out; out="$(dpkg-sig --verify "$file" 2>&1)"
                if echo "$out" | grep -q "GOODSIG"; then
                    GPG_STATUS="passed"
                    ok "Подпись пакета: действительна"
                elif echo "$out" | grep -qi "no signature"; then
                    GPG_STATUS="unsigned"
                else
                    GPG_STATUS="failed"
                    warn "Подпись пакета: не удалось подтвердить ($out)"
                fi
                log "Проверка подписи ($file): $out"
            else
                # dpkg-sig почти нигде не стоит по умолчанию, а у .deb-пакетов
                # обычно и нет подписи на уровне отдельного файла — это
                # не ошибка проекта, честно помечаем как "не проверялось".
                GPG_STATUS="skipped"
            fi
            ;;
        *) GPG_STATUS="skipped" ;;
    esac
}

# ============================================================================
#  ИСТОРИЯ УСТАНОВОК (JSON Lines)
#
#  Одна строка — один JSON-объект. Специально не JSON-массив: чтобы
#  дописать запись в массив, пришлось бы перечитывать и переписывать
#  весь файл, а оборванная на середине запись сломала бы разбор целиком.
#  JSON Lines дописывается через >> и читается построчно — то, что нужно
#  для append-only лога.
#
#  Разбор — без jq/python (их может не быть в системе), свой парсер под
#  наш же формат: каждое строковое значение — "ключ":"значение" без
#  вложенных объектов, поэтому grep -oE + sed достаточно.
# ============================================================================

history_file() { echo "$STATE_DIR/history.log"; }

# Экранирование строки для встраивания в JSON-значение
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/}"
    printf '%s' "$s"
}

json_str_field() {
    echo "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -1 | sed -E "s/^\"$2\":\"//; s/\"\$//"
}

json_num_field() {
    echo "$1" | grep -oE "\"$2\":[0-9]+" | head -1 | sed -E "s/^\"$2\"://"
}

history_rotate() {
    local file="$1" max=1000 n
    n="$(wc -l < "$file" 2>/dev/null || echo 0)"
    if [ "$n" -gt "$max" ] 2>/dev/null; then
        tail -n "$max" "$file" > "${file}.tmp" 2>/dev/null && mv "${file}.tmp" "$file"
    fi
}

# history_write ACTION STATUS ПАКЕТ ВЕРСИЯ MD5 MD5_STATUS DURATION_SEC
# GPG_STATUS и LDD_STATUS берутся из глобальных переменных — их выставляют
# check_package_signature() и smoke_test_ldd(), вызванные в install_package().
history_write() {
    [ "$DRY_RUN" = true ] && return 0   # --dry-run ничего не делал — незачем и записывать
    [ "$CFG_ENABLE_HISTORY" = false ] && return 0
    local action="$1" status="$2" package="$3" version="$4" md5="$5" md5_status="$6" duration="${7:-0}"
    local file; file="$(history_file)"
    mkdir -p "$STATE_DIR" 2>/dev/null
    if ! : >> "$file" 2>/dev/null; then
        warn "Не удалось записать историю в $file"
        return 0
    fi

    local ts; ts="$(date -Iseconds 2>/dev/null)"
    [ -z "$ts" ] && ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"

    printf '{"ts":"%s","action":"%s","os_id":"%s","os_pretty":"%s","os_ver":"%s","pkg_fmt":"%s","pm":"%s","package":"%s","version":"%s","md5":"%s","md5_status":"%s","gpg_status":"%s","ldd_status":"%s","status":"%s","user":"%s","script_version":"%s","duration_sec":%s}\n' \
        "$(json_escape "$ts")" "$(json_escape "$action")" \
        "$(json_escape "$OS_ID")" "$(json_escape "$OS_PRETTY")" "$(json_escape "$OS_VER")" \
        "$(json_escape "$PKG_FMT")" "$(json_escape "$PM")" \
        "$(json_escape "$package")" "$(json_escape "$version")" \
        "$(json_escape "$md5")" "$(json_escape "$md5_status")" \
        "$(json_escape "${GPG_STATUS:-skipped}")" "$(json_escape "${LDD_STATUS:-skipped}")" \
        "$(json_escape "$status")" "$(json_escape "$REAL_USER")" \
        "$(json_escape "$SCRIPT_VERSION")" "${duration:-0}" >> "$file"

    history_rotate "$file"
    log "История ($action): $package -> $status"
}

history_print_entry() {
    local line="$1" ts action os_pretty version status duration user md5_status gpg_status ldd_status
    ts="$(json_str_field "$line" ts)"
    action="$(json_str_field "$line" action)"
    os_pretty="$(json_str_field "$line" os_pretty)"
    version="$(json_str_field "$line" version)"
    status="$(json_str_field "$line" status)"
    duration="$(json_num_field "$line" duration_sec)"
    user="$(json_str_field "$line" user)"
    md5_status="$(json_str_field "$line" md5_status)"
    gpg_status="$(json_str_field "$line" gpg_status)"
    ldd_status="$(json_str_field "$line" ldd_status)"

    local mark="${GREEN}✅${NC}"
    [ "$status" = "failed" ] && mark="${RED}❌${NC}"
    [ "$status" = "cancelled" ] && mark="${YELLOW}⚠️ ${NC}"

    echo -e "  $mark ${BOLD}$ts${NC}  $action  $version  ${CYAN}($status)${NC}"
    echo -e "     ОС: $os_pretty  |  пользователь: $user  |  ${duration:-0} сек"
    echo -e "     MD5: ${md5_status:-—}   GPG: ${gpg_status:-—}   ldd: ${ldd_status:-—}"
    echo ""
}

show_history() {
    local n="${1:-10}"
    local file; file="$(history_file)"
    header
    separator
    echo -e "${BOLD}${WHITE}  ИСТОРИЯ УСТАНОВОК (последние $n)${NC}"
    separator
    echo ""
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        info "  История пуста — установок ещё не было"
        separator
        return 0
    fi
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && history_print_entry "$line"
    done < <(tail -n "$n" "$file")
    separator
}

# ============================================================================
#  HTML/JSON-ОТЧЁТ ОБ УСТАНОВКЕ
#
#  Самодостаточный HTML (CSS инлайном, без внешних запросов — машины
#  бывают без интернета) плюс тот же результат в JSON рядом, для CI.
# ============================================================================

reports_dir() { echo "$STATE_DIR/reports"; }

html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

# generate_report KIND STATUS ПАКЕТ ВЕРСИЯ MD5_STATUS TOTAL_DUR DEPS_DUR PKG_DUR
# GPG_STATUS/LDD_STATUS — из глобальных переменных (их выставляют
# check_package_signature() и smoke_test_ldd() в install_package()).
generate_report() {
    [ "$DRY_RUN" = true ] && return 0   # --dry-run ничего не делал — незачем и записывать
    [ "$CFG_ENABLE_REPORT" = false ] && return 0

    local kind="$1" status="$2" package="$3" version="$4" md5_status="${5:-skipped}" \
          total_dur="${6:-0}" deps_dur="${7:-0}" pkg_dur="${8:-0}"

    local dir; dir="$(reports_dir)"
    if ! mkdir -p "$dir" 2>/dev/null; then
        warn "Не удалось создать $dir — отчёт не сохранён"
        return 0
    fi

    local stamp; stamp="$(date '+%Y%m%d_%H%M%S')"
    local base="$dir/${kind}-${stamp}"
    local html_file="${base}.html" json_file="${base}.json"
    local ts; ts="$(date -Iseconds 2>/dev/null)"; [ -z "$ts" ] && ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"

    # --- зависимости: что установлено, что пропущено ---
    local dep_rows="" dep_ok=0 dep_missing=0 dkind dalts dchosen dstate dcls
    while IFS='|' read -r dkind dalts; do
        [ -z "$dkind" ] && continue
        dchosen="$(pkg_pick "$dalts")"
        if [ -n "$dchosen" ] && pkg_installed "$dchosen"; then
            dep_ok=$((dep_ok + 1))
            dstate="установлен"; dcls="ok"
            dep_rows="${dep_rows}<tr><td>$(html_escape "$dchosen")</td><td class=\"$dcls\">$dstate</td></tr>"
        else
            dep_missing=$((dep_missing + 1))
            dcls="miss"
            [ "$dkind" = "req" ] && dstate="нет (обязательная)" || dstate="нет (необязательная)"
            dep_rows="${dep_rows}<tr><td>$(html_escape "${dchosen:-$dalts}")</td><td class=\"$dcls\">$dstate</td></tr>"
        fi
    done < <(dep_spec)

    local log_tail; log_tail="$(html_escape "$(tail -20 "$LOG_FILE" 2>/dev/null)")"

    local status_ru status_color
    case "$status" in
        success) status_ru="успешно"; status_color="#2e7d32" ;;
        failed)  status_ru="ошибка"; status_color="#c62828" ;;
        *)       status_ru="$status"; status_color="#616161" ;;
    esac

    cat > "$html_file" <<HTMLEOF
<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<title>Р7-Офис — отчёт ${kind} ${stamp}</title>
<style>
  body{font-family:-apple-system,Segoe UI,Arial,sans-serif;background:#f5f7fa;color:#22252a;margin:0;padding:24px}
  .card{max-width:820px;margin:0 auto;background:#fff;border-radius:12px;padding:24px 28px;box-shadow:0 1px 4px rgba(0,0,0,.08)}
  h1{font-size:20px;margin:0 0 4px}
  .status{display:inline-block;padding:2px 10px;border-radius:8px;color:#fff;background:${status_color};font-size:13px}
  table{width:100%;border-collapse:collapse;margin:8px 0 20px;font-size:14px}
  td,th{padding:5px 8px;border-bottom:1px solid #eee;text-align:left}
  td.ok{color:#2e7d32}
  td.miss{color:#c62828}
  pre{background:#22252a;color:#e6e6e6;padding:12px;border-radius:8px;overflow-x:auto;font-size:12px;line-height:1.5}
  .sec{margin-top:22px}
  .meta{color:#616161;font-size:13px}
</style></head>
<body><div class="card">
  <h1>Р7-Офис — отчёт: ${kind}</h1>
  <p class="meta">${ts} · <span class="status">${status_ru}</span></p>

  <div class="sec">
    <h3>Общая информация</h3>
    <table>
      <tr><th>ОС</th><td>$(html_escape "$OS_PRETTY")</td></tr>
      <tr><th>Профиль</th><td>$(html_escape "$OS_ID") / $(html_escape "$PM") / $(html_escape "$PKG_FMT")</td></tr>
      <tr><th>Пакет</th><td>$(html_escape "$package")</td></tr>
      <tr><th>Версия</th><td>$(html_escape "$version")</td></tr>
      <tr><th>Пользователь</th><td>$(html_escape "$REAL_USER")</td></tr>
      <tr><th>Скрипт</th><td>v$(html_escape "$SCRIPT_VERSION")</td></tr>
    </table>
  </div>

  <div class="sec">
    <h3>Проверка целостности</h3>
    <table>
      <tr><th>MD5</th><td>$(html_escape "$md5_status")</td></tr>
      <tr><th>Подпись пакета</th><td>$(html_escape "${GPG_STATUS:-skipped}")</td></tr>
      <tr><th>Smoke-тест (ldd)</th><td>$(html_escape "${LDD_STATUS:-skipped}")</td></tr>
    </table>
  </div>

  <div class="sec">
    <h3>Время</h3>
    <table>
      <tr><th>Всего</th><td>${total_dur} сек</td></tr>
      <tr><th>Зависимости</th><td>${deps_dur} сек</td></tr>
      <tr><th>Установка пакета</th><td>${pkg_dur} сек</td></tr>
    </table>
  </div>

  <div class="sec">
    <h3>Зависимости (${dep_ok} на месте, ${dep_missing} нет)</h3>
    <table>${dep_rows}</table>
  </div>

  <div class="sec">
    <h3>Лог установки (последние 20 строк)</h3>
    <pre>${log_tail}</pre>
  </div>
</div></body></html>
HTMLEOF

    printf '{"ts":"%s","kind":"%s","status":"%s","os_id":"%s","os_pretty":"%s","os_ver":"%s","package":"%s","version":"%s","md5_status":"%s","gpg_status":"%s","ldd_status":"%s","deps_ok":%s,"deps_missing":%s,"duration_sec":%s,"deps_duration_sec":%s,"package_duration_sec":%s,"user":"%s","script_version":"%s"}\n' \
        "$(json_escape "$ts")" "$(json_escape "$kind")" "$(json_escape "$status")" \
        "$(json_escape "$OS_ID")" "$(json_escape "$OS_PRETTY")" "$(json_escape "$OS_VER")" \
        "$(json_escape "$package")" "$(json_escape "$version")" \
        "$(json_escape "$md5_status")" "$(json_escape "${GPG_STATUS:-skipped}")" "$(json_escape "${LDD_STATUS:-skipped}")" \
        "$dep_ok" "$dep_missing" "$total_dur" "$deps_dur" "$pkg_dur" \
        "$(json_escape "$REAL_USER")" "$(json_escape "$SCRIPT_VERSION")" > "$json_file"

    log "Отчёт сохранён: $html_file"
    echo -e "${CYAN}📊 Отчёт сохранён:${NC} $html_file"
}

# Открыть последний отчёт — НЕ от root: браузер из-под sudo либо не
# запустится, либо наплодит root-овых конфигов в чужом профиле.
show_report() {
    local mode="${1:-open}"
    local dir; dir="$(reports_dir)"

    if [ "$mode" = "list" ]; then
        header
        separator
        echo -e "${BOLD}${WHITE}  ОТЧЁТЫ${NC}"
        separator
        if [ -d "$dir" ] && ls "$dir"/*.html >/dev/null 2>&1; then
            ls -t "$dir"/*.html | sed 's/^/  /'
        else
            info "  Отчётов ещё нет"
        fi
        separator
        return 0
    fi

    local last_html; last_html="$(ls -t "$dir"/*.html 2>/dev/null | head -1)"
    if [ -z "$last_html" ]; then
        info "Отчётов ещё нет — сначала выполните установку"
        return 0
    fi

    if [ "$mode" = "json" ]; then
        local last_json="${last_html%.html}.json"
        [ -f "$last_json" ] && cat "$last_json" || warn "JSON рядом с $last_html не найден"
        return 0
    fi

    ok "Последний отчёт: $last_html"
    if [ "$(id -u)" -eq 0 ] && [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ] && command -v xdg-open >/dev/null 2>&1; then
        run_as_user xdg-open "$last_html" >/dev/null 2>&1 &
    else
        info "  Откройте в браузере: $last_html"
    fi
}

# ============================================================================
#  УСТАНОВКА ПАКЕТА
# ============================================================================

install_package() {
    local file="$1" user_md5="${2:-}"
    case "$file" in
        /*) ;;
        *)  file="$PWD/$file" ;;
    esac
    local version; version="$(extract_version "$file")"
    [ -z "$version" ] && version="$(basename "$file")"
    local pkg_name; pkg_name="$(basename "$file")"
    local start_ts; start_ts="$(date +%s)"
    local deps_dur=0 pkg_dur=0
    GPG_STATUS=""; LDD_STATUS=""     # на каждую установку — заново

    if [ ! -f "$file" ]; then
        fail "Файл не найден: $file"
        return 1
    fi

    if ! check_package_os_match "$file"; then
        info "Отменено пользователем"
        local dur=$(( $(date +%s) - start_ts ))
        history_write install cancelled "$pkg_name" "$version" "" "skipped" "$dur"
        generate_report install cancelled "$pkg_name" "$version" "skipped" "$dur" 0 0
        return 1
    fi

    echo ""
    separator
    echo -e "${BOLD}${BLUE}  УСТАНОВКА: $version${NC}"
    separator

    check_package_signature "$file"

    # 1. Контрольная сумма
    local md5_status="skipped"
    if [ "$CMD_CHECK" = true ] || [ -n "$user_md5" ] || [ -f "${file}.md5" ] || [ -f "${file}.sha256" ]; then
        if check_checksum "$file" "$user_md5"; then
            md5_status="passed"
        else
            fail "Установка отменена: контрольная сумма не совпала"
            log "Установка отменена (MD5) для $file"
            local dur=$(( $(date +%s) - start_ts ))
            history_write install failed "$pkg_name" "$version" "$user_md5" "failed" "$dur"
            generate_report install failed "$pkg_name" "$version" "failed" "$dur" 0 0
            return 1
        fi
    fi

    # 2. Информация и подтверждение
    show_package_info "$file"
    if [ "$ASSUME_YES" != true ]; then
        if ! confirm "Продолжить установку?" "Y"; then
            info "Отменено пользователем"
            local dur=$(( $(date +%s) - start_ts ))
            history_write install cancelled "$pkg_name" "$version" "$user_md5" "$md5_status" "$dur"
            generate_report install cancelled "$pkg_name" "$version" "$md5_status" "$dur" 0 0
            return 1
        fi
    fi

    # 3. Зависимости
    local deps_start; deps_start="$(date +%s)"
    install_all_dependencies
    deps_dur=$(( $(date +%s) - deps_start ))

    # 4. Закрыть работающий Р7
    ensure_r7_closed

    # 5. Снести старую версию (дополнения ставим поверх, не трогая основной пакет)
    if ! is_addon_package "$file" && pkg_installed "$PKG_NAME"; then
        local old; old="$(installed_version)"
        step "Удаляем установленную версию ($old)..."
        pm_remove "$PKG_NAME"
    fi

    # 6. Установка
    step "Устанавливаем $version..."
    local pkg_start; pkg_start="$(date +%s)"
    if install_pkg_file "$file"; then
        pkg_dur=$(( $(date +%s) - pkg_start ))
        echo ""
        ok "УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО"
        log "Установлена версия $version из $(basename "$file")"
        post_install_actions   # тут же выставляет LDD_STATUS через smoke_test_ldd()
        local dur=$(( $(date +%s) - start_ts ))
        history_write install success "$pkg_name" "$version" "$user_md5" "$md5_status" "$dur"
        generate_report install success "$pkg_name" "$version" "$md5_status" "$dur" "$deps_dur" "$pkg_dur"
        return 0
    fi
    pkg_dur=$(( $(date +%s) - pkg_start ))

    echo ""
    fail "ОШИБКА ПРИ УСТАНОВКЕ"
    echo -e "  ${CYAN}Подробности в логе: $LOG_FILE${NC}"
    echo -e "  ${CYAN}Последние строки лога:${NC}"
    tail -15 "$LOG_FILE" 2>/dev/null | sed 's/^/     /'
    log "Ошибка установки $(basename "$file")"
    local dur=$(( $(date +%s) - start_ts ))
    history_write install failed "$pkg_name" "$version" "$user_md5" "$md5_status" "$dur"
    generate_report install failed "$pkg_name" "$version" "$md5_status" "$dur" "$deps_dur" "$pkg_dur"
    return 1
}

# Собственно вызов пакетного менеджера + проверка результата
install_pkg_file() {
    local file="$1"
    pm_install_local "$file" || true
    [ "$DRY_RUN" = true ] && return 0

    if is_addon_package "$file"; then
        # Для дополнения проверяем его собственное имя
        local name
        case "$PKG_FMT" in
            deb) name="$(dpkg-deb -f "$file" Package 2>/dev/null)" ;;
            rpm) name="$(rpm -qp --qf '%{NAME}' "$file" 2>/dev/null)" ;;
        esac
        [ -n "$name" ] && pkg_installed "$name"
        return $?
    fi

    pkg_installed "$PKG_NAME"
}

# Что делаем сразу после успешной установки
post_install_actions() {
    echo ""
    local ver; ver="$(installed_version)"
    [ -n "$ver" ] && info "Установленная версия: $ver"

    # Под Wayland сразу готовим запуск через XWayland
    if [ "$SESSION_TYPE" = "wayland" ]; then
        echo ""
        info "Обнаружена сессия Wayland — настраиваем запуск через XWayland"
        install_wayland_support
        create_x11_wrapper
        create_wayland_desktop_entry
    fi

    # RDP-оптимизация (РЕД ОС)
    optimize_rdp

    echo ""
    smoke_test_ldd

    echo ""
    local bin; bin="$(find_r7_binary)"
    if [ "$SESSION_TYPE" = "wayland" ] && [ -x "$R7_WRAPPER" ]; then
        ok "Запуск: ${BOLD}$R7_WRAPPER${NC} (или ярлык в меню приложений)"
    elif [ -n "$bin" ]; then
        ok "Запуск: ${BOLD}$bin${NC} (или ярлык в меню приложений)"
    else
        ok "Запуск: ярлык Р7-Офис в меню приложений"
    fi
}

# ============================================================================
#  КЭШ РЕДАКТОРА
# ============================================================================

cache_dirs() {
    echo "$USER_HOME/.local/share/r7-office/editors/recover"
    echo "$USER_HOME/.local/share/r7-office/editors/cache"
    echo "$USER_HOME/.cache/r7-office"
    echo "$USER_HOME/.cache/R7-Office"
}

clear_editor_cache() {
    header
    separator
    echo -e "${BOLD}${YELLOW}  ОЧИСТКА КЭША РЕДАКТОРА${NC}"
    separator
    echo ""

    local d found=false total=0
    while IFS= read -r d; do
        if [ -d "$d" ]; then
            found=true
            echo -e "  ${CYAN}$d${NC} — $(du -sh "$d" 2>/dev/null | cut -f1)"
        fi
    done < <(cache_dirs)

    if [ "$found" != true ]; then
        warn "Папки с кэшем не найдены (пользователь: $REAL_USER)"
        echo ""
        pause
        return 0
    fi

    echo ""
    echo -e "  ${YELLOW}Внимание: в папке recover лежат автосохранённые документы.${NC}"
    echo -e "  ${YELLOW}После очистки восстановить их не получится.${NC}"
    echo ""

    if ! confirm "Очистить кэш?" "N"; then
        info "Отменено"
        pause
        return 0
    fi

    while IFS= read -r d; do
        [ -d "$d" ] || continue
        if [ "$DRY_RUN" = true ]; then
            echo -e "  ${MAGENTA}[dry-run]${NC} rm -rf $d/*"
        else
            rm -rf "${d:?}"/* 2>/dev/null
            ok "Очищено: $d"
        fi
    done < <(cache_dirs)

    log "Очищен кэш редактора для $REAL_USER"
    echo ""
    ok "Кэш очищен"
    pause
}

# ============================================================================
#  УДАЛЕНИЕ Р7-ОФИС
# ============================================================================

remove_r7_office() {
    header
    separator
    echo -e "${BOLD}${RED}  УДАЛЕНИЕ Р7-ОФИС${NC}"
    separator
    echo ""

    if ! pkg_installed "$PKG_NAME"; then
        warn "Р7-Офис не установлен"
        echo ""
        pause
        return 0
    fi

    local removed_version; removed_version="$(installed_version)"
    info "Установленная версия: $removed_version"
    echo ""
    echo -e "  ${BLUE}[1]${NC} Удалить программу, ${GREEN}оставить${NC} кэш и настройки"
    echo -e "  ${BLUE}[2]${NC} Удалить программу и ${YELLOW}очистить кэш${NC}, настройки оставить"
    echo -e "  ${BLUE}[3]${NC} ${RED}Полное удаление${NC}: программа + кэш + настройки"
    echo -e "  ${BLUE}[4]${NC} Отмена"
    echo ""
    echo -n -e "${BOLD}Ваш выбор (1-4): ${NC}"
    read -r choice

    local start_ts; start_ts="$(date +%s)"
    GPG_STATUS="skipped"; LDD_STATUS="skipped"   # неприменимо к удалению

    case "$choice" in
        1)
            ensure_r7_closed
            pm_remove "$PKG_NAME"
            ok "Программа удалена, данные пользователя на месте"
            log "Удалён Р7 (вариант 1)"
            history_write remove success "$PKG_NAME" "$removed_version" "" "skipped" "$(( $(date +%s) - start_ts ))"
            ;;
        2)
            ensure_r7_closed
            pm_remove "$PKG_NAME"
            local d
            while IFS= read -r d; do
                [ -d "$d" ] && rm -rf "${d:?}"/* 2>/dev/null
            done < <(cache_dirs)
            ok "Программа удалена, кэш очищен"
            log "Удалён Р7 (вариант 2)"
            history_write remove success "$PKG_NAME" "$removed_version" "" "skipped" "$(( $(date +%s) - start_ts ))"
            ;;
        3)
            echo ""
            echo -e "  ${RED}Будут стёрты настройки и все автосохранённые документы.${NC}"
            echo -n -e "${BOLD}Для подтверждения введите YES: ${NC}"
            read -r confirm_word
            if [ "$confirm_word" != "YES" ]; then
                info "Отменено"
                pause
                return 0
            fi
            ensure_r7_closed
            pm_remove "$PKG_NAME"
            rm -rf "$USER_HOME/.local/share/r7-office" 2>/dev/null
            rm -rf "$USER_HOME/.config/r7-office" 2>/dev/null
            rm -rf "$USER_HOME/.cache/r7-office" 2>/dev/null
            rm -f  "$USER_HOME/.local/share/applications/r7-office-desktopeditors.desktop" 2>/dev/null
            rm -f  "$R7_WRAPPER" 2>/dev/null
            rm -f  "$(deps_flag_file)" 2>/dev/null
            ok "Полное удаление завершено"
            log "Удалён Р7 (вариант 3, полностью)"
            history_write remove success "$PKG_NAME" "$removed_version" "" "skipped" "$(( $(date +%s) - start_ts ))"
            ;;
        *)
            info "Отменено"
            ;;
    esac
    echo ""
    pause
}

# ============================================================================
#  ДИАГНОСТИКА (HEALTH-CHECK)
# ============================================================================

health_check() {
    header
    separator
    echo -e "${BOLD}${BLUE}  ДИАГНОСТИКА СИСТЕМЫ${NC}"
    separator
    echo ""

    echo -e "${BOLD}1. Операционная система${NC}"
    ok "$OS_PRETTY"
    ok "Профиль: $OS_ID | менеджер: $PM | формат: $PKG_FMT"
    check_os_version
    if [ -n "$CONFIG_LOADED" ]; then
        ok "Конфиг: $CONFIG_LOADED"
    else
        info "  Конфиг: не найден, используются умолчания"
    fi
    echo ""

    echo -e "${BOLD}2. Р7-Офис${NC}"
    if pkg_installed "$PKG_NAME"; then
        ok "Установлен, версия: $(installed_version)"
        local bin; bin="$(find_r7_binary)"
        [ -n "$bin" ] && ok "Исполняемый файл: $bin" || warn "Исполняемый файл не найден"
        local dsk; dsk="$(find_r7_desktop)"
        [ -n "$dsk" ] && ok "Ярлык: $dsk" || warn "Ярлык в меню приложений не найден"
        smoke_test_ldd
    else
        fail "Не установлен"
    fi
    local pids; pids="$(r7_running_pids)"
    [ -n "$pids" ] && ok "Сейчас запущен (PID: $pids)" || info "  Сейчас не запущен"
    echo ""

    echo -e "${BOLD}3. Графическая сессия${NC}"
    case "$SESSION_TYPE" in
        wayland)
            warn "Wayland"
            if pgrep -x Xwayland >/dev/null 2>&1; then ok "XWayland работает"; else fail "XWayland не запущен"; fi
            if [ -x "$R7_WRAPPER" ]; then ok "Обёртка настроена: $R7_WRAPPER"; else warn "Обёртка не создана — пункт [W] в меню"; fi
            ;;
        x11) ok "X11, DISPLAY=${DISPLAY:-не задан}" ;;
        *)   warn "Графическая сессия не обнаружена ($SESSION_TYPE)" ;;
    esac
    if [ "$IDLE_CONTROL_ACTIVE" = true ]; then
        ok "Простой экрана отключён на время работы скрипта"
    elif [ "$CMD_NO_IDLE" = true ]; then
        info "  Простой экрана: отключено флагом --no-idle"
    elif [ "$CFG_ENABLE_IDLE_CONTROL" = false ]; then
        info "  Простой экрана: отключено конфигом"
    else
        info "  Простой экрана: не менялся (нет xset/gsettings/xfconf-query или нет графической сессии)"
    fi
    echo ""

    echo -e "${BOLD}4. Зависимости${NC}"
    if [ -f "$(deps_flag_file)" ]; then ok "Устанавливались ранее"; else warn "Ещё не устанавливались"; fi
    local kind alts chosen miss=0
    while IFS='|' read -r kind alts; do
        [ "$kind" = "req" ] || continue
        chosen="$(pkg_pick "$alts")"
        if [ -z "$chosen" ] || ! pkg_installed "$chosen"; then
            miss=$((miss + 1))
            fail "нет: $alts"
        fi
    done < <(dep_spec)
    [ "$miss" -eq 0 ] && ok "Все обязательные библиотеки на месте"
    echo ""

    echo -e "${BOLD}5. Место на диске${NC}"
    df -h / /home 2>/dev/null | sed 's/^/     /' | sort -u
    echo ""

    echo -e "${BOLD}6. Кэш редактора${NC}"
    local d any=false
    while IFS= read -r d; do
        [ -d "$d" ] && { any=true; ok "$(du -sh "$d" 2>/dev/null)"; }
    done < <(cache_dirs)
    [ "$any" = true ] || info "  Кэш пуст или ещё не создан"
    echo ""

    if [ "$FEAT_RDP" = true ]; then
        echo -e "${BOLD}7. RDP${NC}"
        if [ -f /etc/xrdp/xrdp.ini ]; then
            ok "xrdp установлен"
            [ -f "$(rdp_flag_file)" ] && ok "Оптимизация применена" || warn "Оптимизация не применялась"
            grep -E '^(crypt_level|max_bpp|tcp_send_buffer_bytes)=' /etc/xrdp/xrdp.ini 2>/dev/null | sed 's/^/     /'
        else
            info "  xrdp не установлен"
        fi
        echo ""
    fi

    echo -e "${BOLD}8. Пакеты в папке${NC}"
    if find_packages; then
        ok "$DOWNLOAD_DIR — найдено ${#PKG_FILES[@]} шт."
    else
        warn "Пакеты r7-*.$PKG_FMT в $DOWNLOAD_DIR не найдены"
    fi
    echo ""

    echo -e "${BOLD}9. Журнал${NC}"
    ok "$LOG_FILE ($(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) строк)"
    separator
    log "Выполнена диагностика"
    pause
}

# ============================================================================
#  ИНТЕРАКТИВНОЕ МЕНЮ
# ============================================================================

show_menu() {
    header
    local cur; cur="$(installed_version)"
    [ -z "$cur" ] && cur="не установлен"

    echo -e "  ${BOLD}Текущая версия:${NC} ${GREEN}$cur${NC}"
    echo -e "  ${BOLD}Зависимости:${NC}    $([ -f "$(deps_flag_file)" ] && echo "${GREEN}установлены${NC}" || echo "${YELLOW}не установлены${NC}")"
    echo -e "  ${BOLD}Сессия:${NC}         $([ "$SESSION_TYPE" = "wayland" ] && echo "${YELLOW}Wayland${NC}" || echo "${GREEN}$SESSION_TYPE${NC}")"
    echo -e "  ${BOLD}Свободно:${NC}       $(df -h / 2>/dev/null | awk 'NR==2 {print $4}')"
    echo -e "  ${BOLD}Папка пакетов:${NC}  $DOWNLOAD_DIR"
    echo ""
    separator
    echo -e "${BOLD}${WHITE}  ДОСТУПНЫЕ ДИСТРИБУТИВЫ (${#PKG_FILES[@]}):${NC}"
    separator

    local i file version size mark tag
    # "Самая новая" относится к основному пакету: дополнение ставится поверх,
    # и пункт [L] тоже выбирает именно основной пакет.
    local newest_idx=0
    for i in "${!PKG_FILES[@]}"; do
        if ! is_addon_package "${PKG_FILES[$i]}"; then newest_idx=$i; break; fi
    done

    for i in "${!PKG_FILES[@]}"; do
        file="${PKG_FILES[$i]}"
        version="$(extract_version "$file")"
        size="$(du -h "$file" 2>/dev/null | cut -f1)"
        mark=""; tag=""
        [ "$cur" = "$version" ] && [ -n "$version" ] && mark="${GREEN} ✓ УСТАНОВЛЕНА${NC}"
        is_addon_package "$file" && tag="${MAGENTA}[дополнение]${NC} "
        if [ "$i" -eq "$newest_idx" ]; then
            echo -e "  ${GREEN}${BOLD}[$((i + 1))]${NC} $tag$(basename "$file")  ${size}  ${CYAN}(самая новая)${NC}$mark"
        else
            echo -e "  ${BLUE}[$((i + 1))]${NC} $tag$(basename "$file")  ${size}$mark"
        fi
    done

    echo ""
    separator
    echo -e "${BOLD}${WHITE}  ДЕЙСТВИЯ${NC}"
    echo ""
    echo -e "  ${GREEN}[1-${#PKG_FILES[@]}]${NC} Установить выбранную версию"
    echo -e "  ${YELLOW}[L]${NC}   Установить самую новую версию"
    echo -e "  ${BLUE}[F]${NC}   Переустановить текущую версию поверх"
    echo -e "  ${GREEN}[S]${NC}   Fast-lane — всё автоматически"
    echo -e "  ${MAGENTA}[D]${NC}   Переустановить зависимости"
    echo -e "  ${CYAN}[W]${NC}   Исправить запуск под Wayland"
    [ "$FEAT_RDP" = true ] && echo -e "  ${CYAN}[P]${NC}   Оптимизация RDP"
    echo -e "  ${CYAN}[H]${NC}   Диагностика системы"
    echo -e "  ${CYAN}[C]${NC}   Очистить кэш редактора"
    echo -e "  ${CYAN}[G]${NC}   Показать зависимости для этой ОС"
    echo -e "  ${RED}[R]${NC}   Удалить Р7-Офис"
    echo -e "  ${WHITE}[?]${NC}   Справка"
    echo -e "  ${RED}[Q]${NC}   Выход"
    echo ""
    separator
    echo -n -e "${BOLD}${WHITE}Ваш выбор: ${NC}"
}

show_inline_help() {
    header
    separator
    echo -e "${BOLD}${WHITE}  СПРАВКА${NC}"
    separator
    echo ""
    echo -e "${BOLD}Пункты меню${NC}"
    echo -e "  ${GREEN}1-N${NC}  Установить конкретный дистрибутив из списка."
    echo -e "       Скрипт спросит MD5 — его берут из документа Word к сборке."
    echo -e "       Можно нажать Enter и пропустить проверку."
    echo -e "  ${YELLOW}L${NC}    Поставить самый свежий файл из папки."
    echo -e "  ${BLUE}F${NC}    Переустановить версию, которая уже стоит. Помогает,"
    echo -e "       когда программа перестала запускаться."
    echo -e "  ${GREEN}S${NC}    Fast-lane: зависимости плюс самая новая версия, без вопросов."
    echo -e "  ${MAGENTA}D${NC}    Заново проверить и доставить библиотеки."
    echo -e "  ${CYAN}W${NC}    Настроить запуск через XWayland. Нужен, если под Wayland"
    echo -e "       окно Р7 пустое или программа вообще не открывается."
    [ "$FEAT_RDP" = true ] && \
    echo -e "  ${CYAN}P${NC}    Ускорить работу по RDP (буферы, глубина цвета, шифрование)."
    echo -e "  ${CYAN}H${NC}    Диагностика: что установлено, чего не хватает."
    echo -e "  ${CYAN}C${NC}    Очистить кэш редактора — лечит зависания и битые вкладки."
    echo -e "  ${CYAN}G${NC}    Список библиотек для вашей ОС и их состояние."
    echo -e "  ${RED}R${NC}    Удалить Р7-Офис. Три варианта: с сохранением данных или без."
    echo ""
    echo -e "${BOLD}Запуск из терминала${NC}"
    echo -e "  ${WHITE}sudo $SCRIPT_NAME -l --md5 ХЭШ${NC}   свежая версия с проверкой"
    echo -e "  ${WHITE}sudo $SCRIPT_NAME -v 8.1.0-1234${NC}  конкретная версия"
    echo -e "  ${WHITE}sudo $SCRIPT_NAME -f -y${NC}          полностью автоматически"
    echo -e "  ${WHITE}sudo $SCRIPT_NAME --health${NC}       диагностика"
    echo -e "  ${WHITE}sudo $SCRIPT_NAME --fix-wayland${NC}  починить Wayland"
    echo -e "  ${WHITE}sudo $SCRIPT_NAME --help${NC}         все опции"
    echo ""
    echo -e "${BOLD}Куда смотреть при ошибке${NC}"
    echo -e "  Журнал: ${WHITE}$LOG_FILE${NC}"
    echo -e "  Команда: ${WHITE}tail -50 $LOG_FILE${NC}"
    echo ""
    separator
    pause
}

# ============================================================================
#  FAST-LANE
# ============================================================================

fast_lane_install() {
    echo ""
    separator
    echo -e "${BOLD}${GREEN}  FAST-LANE — АВТОМАТИЧЕСКАЯ УСТАНОВКА${NC}"
    separator
    echo ""

    detect_environment || return 1
    install_all_dependencies
    require_packages

    # Берём самый свежий основной пакет, дополнения пропускаем
    local file="" f
    for f in "${PKG_FILES[@]}"; do
        if ! is_addon_package "$f"; then file="$f"; break; fi
    done
    [ -z "$file" ] && file="${PKG_FILES[0]}"

    info "Выбран пакет: $(basename "$file")"
    install_package "$file" "$CMD_MD5"
}

# ============================================================================
#  ГРАФИЧЕСКИЙ РЕЖИМ (zenity)
# ============================================================================

ensure_zenity() {
    command -v zenity >/dev/null 2>&1 && return 0
    warn "zenity не установлен — он нужен для графического режима"
    if confirm "Установить zenity?" "Y"; then
        pm_update
        pm_install zenity && return 0
    fi
    fail "Без zenity графический режим недоступен"
    return 1
}

gui_mode() {
    ensure_zenity || exit 1
    detect_environment >/dev/null 2>&1

    if ! find_packages; then
        zenity --error --width=420 --title="Р7-Офис" \
               --text="В папке $DOWNLOAD_DIR не найдено пакетов r7-*.$PKG_FMT" 2>/dev/null
        exit 1
    fi

    # Список версий
    local args=() f
    for f in "${PKG_FILES[@]}"; do
        args+=("$(basename "$f")")
    done

    local chosen
    chosen="$(zenity --list --title="Р7-Офис — выбор версии" \
                --text="ОС: $OS_PRETTY\nВыберите дистрибутив для установки:" \
                --column="Файл" "${args[@]}" --width=640 --height=420 2>/dev/null)"
    [ -z "$chosen" ] && exit 0

    local md5
    md5="$(zenity --entry --title="Проверка целостности" \
             --text="Введите MD5 из документа Word.\nОставьте пустым, чтобы пропустить проверку." \
             --width=460 2>/dev/null)"

    local target="$DOWNLOAD_DIR/$chosen"
    CMD_GUI=false   # дальше работаем обычным потоком, вывод пойдёт в терминал и лог
    ASSUME_YES=true

    # Файл с кодом возврата: mktemp вместо фиксированного пути в /tmp —
    # иначе локальный пользователь может подложить туда симлинк заранее.
    # Автоочистка по trap EXIT, даже если zenity закрыли до конца установки.
    local rc_file; rc_file="$(mktemp "${STATE_DIR:-/tmp}/r7-gui-rc.XXXXXX" 2>/dev/null || mktemp)"
    trap 'rm -f "$rc_file"' EXIT

    # В прогресс-бар пускаем только наши статусные строки (✅/⚠️/❌/→) —
    # иначе сырой вывод apt/dnf мелькает в подписи и ничего не разобрать.
    # Полный вывод в любом случае уходит в LOG_FILE через run()/run_v().
    (
        install_package "$target" "$md5"
        echo $? > "$rc_file"
    ) 2>&1 | grep --line-buffered -E '✅|⚠|❌|→' | sed -u 's/^/#/' \
      | zenity --progress --pulsate --auto-close --no-cancel \
               --title="Установка Р7-Офис" --text="Идёт установка, подождите..." \
               --width=460 2>/dev/null

    local rc; rc="$(cat "$rc_file" 2>/dev/null)"
    rm -f "$rc_file"
    trap - EXIT
    if [ "$rc" = "0" ]; then
        zenity --info --width=420 --title="Готово" \
               --text="Р7-Офис установлен.\nВерсия: $(installed_version)" 2>/dev/null
    else
        zenity --error --width=460 --title="Ошибка" \
               --text="Установка не завершилась.\nПодробности в журнале:\n$LOG_FILE" 2>/dev/null
    fi
    exit 0
}

# ============================================================================
#  РЕЖИМЫ КОМАНДНОЙ СТРОКИ
# ============================================================================

# Скачать пакет по ссылке и установить
install_from_url() {
    local url="$1"
    local name; name="$(basename "${url%%\?*}")"
    case "$name" in
        *.deb|*.rpm) ;;
        *) name="r7-office-downloaded.$PKG_FMT" ;;
    esac

    resolve_download_dir
    local dest="$DOWNLOAD_DIR/$name"

    step "Скачиваем $url"
    if ! download_file "$url" "$dest"; then
        fail "Не удалось скачать файл"
        return 1
    fi
    ok "Скачано: $dest ($(du -h "$dest" 2>/dev/null | cut -f1))"

    # Формат скачанного файла должен подходить этой ОС
    case "$dest" in
        *.deb) [ "$PKG_FMT" = "deb" ] || { fail "Скачан .deb, а системе нужен .$PKG_FMT"; return 1; } ;;
        *.rpm) [ "$PKG_FMT" = "rpm" ] || { fail "Скачан .rpm, а системе нужен .$PKG_FMT"; return 1; } ;;
    esac

    install_package "$dest" "$CMD_MD5"
}

# Найти пакет по номеру/версии: "2815" или "8.1.0-1234"
find_by_version() {
    local want="$1" f
    for f in "${PKG_FILES[@]}"; do
        case "$(basename "$f")" in
            *"$want"*) echo "$f"; return 0 ;;
        esac
    done
    return 1
}

run_cli_mode() {
    # Справка и списки — до проверки root не доходят, они безобидны
    if [ -n "$CMD_URL" ]; then
        detect_environment || exit 1
        install_all_dependencies
        install_from_url "$CMD_URL"
        exit $?
    fi

    if [ -n "$CMD_VERSION" ]; then
        detect_environment || exit 1
        require_packages
        local file
        file="$(find_by_version "$CMD_VERSION")"
        if [ -z "$file" ]; then
            fail "Пакет с версией '$CMD_VERSION' не найден в $DOWNLOAD_DIR"
            echo -e "  ${CYAN}Что есть в папке:${NC}"
            local f
            for f in "${PKG_FILES[@]}"; do echo "     $(basename "$f")"; done
            exit 1
        fi
        install_package "$file" "$CMD_MD5"
        exit $?
    fi

    if [ "$CMD_LATEST" = true ]; then
        detect_environment || exit 1
        require_packages
        local file="" f
        for f in "${PKG_FILES[@]}"; do
            if ! is_addon_package "$f"; then file="$f"; break; fi
        done
        [ -z "$file" ] && file="${PKG_FILES[0]}"
        install_package "$file" "$CMD_MD5"
        exit $?
    fi

    if [ "$CMD_FAST" = true ]; then
        ASSUME_YES=true
        fast_lane_install
        exit $?
    fi

    return 1   # режим командной строки не задан — идём в меню
}

# ============================================================================
#  ГЛАВНЫЙ ЦИКЛ
# ============================================================================

interactive_loop() {
    require_packages

    while true; do
        find_packages
        if [ ${#PKG_FILES[@]} -eq 0 ]; then
            fail "Пакеты r7-*.$PKG_FMT в папке $DOWNLOAD_DIR пропали"
            echo -e "  ${CYAN}Положите дистрибутив обратно или запустите с --dir ПУТЬ${NC}"
            pause
            exit 1
        fi
        show_menu
        read -r choice

        case "$choice" in
            [0-9]*)
                if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#PKG_FILES[@]}" ] 2>/dev/null; then
                    local selected="${PKG_FILES[$((choice - 1))]}"
                    echo ""
                    echo -n -e "${YELLOW}MD5 из документа (Enter — пропустить): ${NC}"
                    read -r manual_md5
                    install_package "$selected" "$manual_md5"
                    echo ""
                    pause
                else
                    fail "Нет пункта с номером $choice"
                    sleep 1
                fi
                ;;
            [Ll])
                local latest="" f
                for f in "${PKG_FILES[@]}"; do
                    if ! is_addon_package "$f"; then latest="$f"; break; fi
                done
                [ -z "$latest" ] && latest="${PKG_FILES[0]}"
                local latest_ver cur_ver
                latest_ver="$(extract_version "$latest")"
                cur_ver="$(installed_version)"
                if [ -n "$cur_ver" ] && [ "$cur_ver" = "$latest_ver" ]; then
                    warn "Версия $latest_ver уже установлена"
                    confirm "Всё равно переустановить?" "N" || { sleep 1; continue; }
                fi
                echo -n -e "${YELLOW}MD5 (Enter — пропустить): ${NC}"
                read -r manual_md5
                install_package "$latest" "$manual_md5"
                pause
                ;;
            [Ff])
                local cur_ver; cur_ver="$(installed_version)"
                if [ -z "$cur_ver" ]; then
                    fail "Р7-Офис не установлен — переустанавливать нечего"
                    sleep 2; continue
                fi
                local found="" f
                for f in "${PKG_FILES[@]}"; do
                    [ "$(extract_version "$f")" = "$cur_ver" ] && { found="$f"; break; }
                done
                if [ -z "$found" ]; then
                    fail "Файл версии $cur_ver в папке не найден"
                    echo -e "  ${CYAN}Выберите версию из списка вручную.${NC}"
                    sleep 3; continue
                fi
                warn "Переустановка версии $cur_ver поверх"
                confirm "Продолжить?" "Y" || continue
                echo -n -e "${YELLOW}MD5 (Enter — пропустить): ${NC}"
                read -r manual_md5
                install_package "$found" "$manual_md5"
                pause
                ;;
            [Ss]) fast_lane_install; pause ;;
            [Dd]) install_all_dependencies force; pause ;;
            [Ww]) fix_wayland; pause ;;
            [Pp])
                if [ "$FEAT_RDP" != true ]; then
                    fail "Оптимизация RDP предусмотрена только для РЕД ОС"
                    sleep 2
                    continue
                fi
                echo ""
                echo -e "  ${BLUE}[1]${NC} Применить оптимизацию RDP"
                echo -e "  ${BLUE}[2]${NC} Откатить настройки из резервной копии"
                echo -e "  ${BLUE}[3]${NC} Отмена"
                echo -n -e "${BOLD}Ваш выбор (1-3): ${NC}"
                read -r rdp_choice
                case "$rdp_choice" in
                    1) rm -f "$(rdp_flag_file)"; optimize_rdp; pause ;;
                    2) restore_rdp; pause ;;
                    *) info "Отменено"; sleep 1 ;;
                esac
                ;;
            [Hh]) health_check ;;
            [Cc]) clear_editor_cache ;;
            [Gg]) list_dependencies; pause ;;
            [Rr]) remove_r7_office ;;
            [Qq]) echo -e "${GREEN}Готово. До свидания!${NC}"; log "Выход из меню"; exit 0 ;;
            "?"|help|HELP|помощь|Помощь) show_inline_help ;;
            "") ;;
            *) fail "Не понял выбор: $choice"; sleep 1 ;;
        esac
    done
}

main() {
    parse_args "$@"
    setup_colors

    if [ "$CMD_HELP" = true ]; then
        show_help
        exit 0
    fi

    check_root "$@"
    # Единая точка восстановления (пока — только простой экрана) на любой
    # выход, включая Ctrl+C: без переисполнения EXIT-ветки после INT/TERM
    # выход по сигналу не срабатывал бы через обычный trap EXIT.
    trap 'on_script_exit; exit 130' INT
    trap 'on_script_exit; exit 143' TERM
    trap on_script_exit EXIT

    load_config
    init_log
    detect_os
    [ "$CFG_SKIP_RDP" = true ] && FEAT_RDP=false
    detect_real_user
    detect_session_type

    [ "$DRY_RUN" = true ] && { echo ""; warn "Режим --dry-run: команды показываются, но не выполняются"; echo ""; }

    if [ "$CMD_RESTORE_IDLE" = true ]; then
        local f="$STATE_DIR/idle-saved.state"
        if [ ! -f "$f" ]; then
            info "Сохранённых настроек экрана не найдено — восстанавливать нечего"
            exit 0
        fi
        idle_state_restore_from_file "$f"
        rm -f "$f"
        ok "Настройки простоя/блокировки экрана восстановлены"
        log "Ручное восстановление простоя экрана (--restore-idle)"
        exit 0
    fi

    idle_control_init

    # Одиночные операции
    if [ "$CMD_LIST_DEPS" = true ];   then list_dependencies; exit 0; fi
    if [ "$CMD_CHECK_DEPS" = true ];  then check_dependencies_versions; exit 0; fi
    if [ "$CMD_HEALTH" = true ];      then detect_environment >/dev/null; health_check; exit 0; fi
    if [ "$CMD_VERIFY" = true ]; then
        if ! pkg_installed "$PKG_NAME"; then
            fail "Р7-Офис не установлен — проверять нечего"
            exit 1
        fi
        smoke_test_ldd
        exit $?
    fi
    if [ "$CMD_HISTORY" = true ]; then show_history "$CMD_HISTORY_N"; exit 0; fi
    if [ "$CMD_REPORT" = true ]; then show_report "$CMD_REPORT_MODE"; exit 0; fi
    if [ "$CMD_FIX_WAYLAND" = true ]; then fix_wayland; exit $?; fi
    if [ "$CMD_REMOVE" = true ];      then remove_r7_office; exit 0; fi
    if [ "$CMD_INSTALL_DEPS" = true ]; then
        detect_environment || exit 1
        install_all_dependencies force
        exit $?
    fi
    if [ "$CMD_GUI" = true ]; then gui_mode; fi

    # Режимы установки без меню
    run_cli_mode

    # Интерактивное меню
    header
    check_os_version
    detect_environment || { pause; }
    install_all_dependencies
    interactive_loop
}

main "$@"
