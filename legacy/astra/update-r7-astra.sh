cat > /usr/local/bin/update-r7-astra.sh << 'EOF'
#!/bin/bash

# ============================================================
#  🚀 Р7 Офис Установщик - СПЕЦИАЛЬНАЯ ВЕРСИЯ ДЛЯ ASTRA LINUX
#  Версия: 1.0 - использует apt, dpkg
# ============================================================

# ------------------- НАСТРОЙКИ -------------------
DOWNLOAD_DIR="/home/administrator/Downloads"
LOG_FILE="/var/log/r7-update-astra.log"
DEPENDENCIES_FLAG="/var/lib/r7-dependencies-astra-installed"

# ------------------- ЦВЕТА -------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------- ПЕРЕМЕННЫЕ ДЛЯ АРГУМЕНТОВ -------------------
CMD_VERSION=""
CMD_LATEST=false
CMD_FAST=false
CMD_URL=""
CMD_CHECK=false
CMD_MD5=""
CMD_GUI=false
CMD_HELP=false

# ------------------- ФУНКЦИИ -------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

separator() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

header() {
    clear
    separator
    echo -e "${BOLD}${WHITE}  🚀  Р7 ОФИС - УСТАНОВЩИК ДЛЯ ASTRA LINUX  ${NC}"
    echo -e "${BOLD}${WHITE}  🔧  РАБОТАЕТ ЧЕРЕЗ APT / DPKG  ${NC}"
    separator
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Этот скрипт должен запускаться от root!${NC}"
        echo -e "${YELLOW}   Используйте: sudo update-r7-astra.sh${NC}"
        exit 1
    fi
}

# ============================================================
#  🎛️  РАЗБОР АРГУМЕНТОВ
# ============================================================

show_help() {
    cat << EOF
Использование: update-r7-astra.sh [ОПЦИИ]

ОПЦИИ:
  -v, --version VERSION   Установить конкретную версию
  -l, --latest            Установить самую новую версию
  -f, --fast              Fast-lane режим (всё автоматически)
  -u, --url URL           Скачать .deb по ссылке и установить
  --check                 Проверить контрольную сумму (MD5)
  --md5 HASH              Задать MD5-хэш для проверки
  --gui                   Использовать графический интерфейс (zenity)
  -h, --help              Показать эту справку

Примеры:
  update-r7-astra.sh -v 2815 --md5 a1b2c3...   # установить с проверкой
  update-r7-astra.sh -l                        # установить самую новую
  update-r7-astra.sh -f                        # fast-lane
  update-r7-astra.sh -h                        # справка
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--version) CMD_VERSION="$2"; shift 2 ;;
            -l|--latest) CMD_LATEST=true; shift ;;
            -f|--fast) CMD_FAST=true; shift ;;
            -u|--url) CMD_URL="$2"; shift 2 ;;
            --check) CMD_CHECK=true; shift ;;
            --md5) CMD_MD5="$2"; shift 2 ;;
            --gui) CMD_GUI=true; shift ;;
            -h|--help) CMD_HELP=true; shift ;;
            *) echo -e "${RED}❌ Неизвестная опция: $1${NC}"; show_help ;;
        esac
    done
    [ "$CMD_HELP" = true ] && show_help
}

# ============================================================
#  📦  АВТОУСТАНОВКА ZENITY
# ============================================================

ensure_zenity() {
    if ! command -v zenity &> /dev/null; then
        echo -e "${YELLOW}⚠️  zenity не установлен. Он нужен для графического режима.${NC}"
        echo -n -e "${BOLD}Установить zenity? [y/N]: ${NC}"
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            apt update && apt install -y zenity
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ zenity установлен${NC}"
            else
                echo -e "${RED}❌ Не удалось установить zenity. Выход.${NC}"
                exit 1
            fi
        else
            echo -e "${RED}❌ zenity обязателен для --gui. Выход.${NC}"
            exit 1
        fi
    fi
}

# ============================================================
#  🧠  АВТОДЕТЕКТ ОКРУЖЕНИЯ
# ============================================================

detect_environment() {
    if [ "$CMD_GUI" = false ]; then
        echo -e "${BLUE}🔍 Детект окружения...${NC}"
    fi
    
    if [ -n "$SUDO_USER" ]; then
        REAL_USER="$SUDO_USER"
    else
        REAL_USER="$(whoami)"
    fi
    USER_HOME=$(eval echo ~$REAL_USER)
    [ "$CMD_GUI" = false ] && echo -e "  ${GREEN}✅${NC} Пользователь: $REAL_USER"

    if [ -z "$DISPLAY" ]; then
        if pgrep -x "Xorg" > /dev/null || pgrep -x "Xwayland" > /dev/null; then
            export DISPLAY=":0"
            [ "$CMD_GUI" = false ] && echo -e "  ${GREEN}✅${NC} Графика обнаружена, DISPLAY=:0"
        else
            [ "$CMD_GUI" = false ] && echo -e "  ${YELLOW}⚠️${NC} Графика не обнаружена"
        fi
    else
        [ "$CMD_GUI" = false ] && echo -e "  ${GREEN}✅${NC} DISPLAY: $DISPLAY"
    fi

    if [ -f /etc/astra_version ]; then
        [ "$CMD_GUI" = false ] && echo -e "  ${GREEN}✅${NC} Astra Linux: $(cat /etc/astra_version | head -1)"
    elif [ -f /etc/os-release ]; then
        [ "$CMD_GUI" = false ] && echo -e "  ${GREEN}✅${NC} ОС: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
    fi

    FREE_SPACE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$FREE_SPACE" -lt 5 ]; then
        if [ "$CMD_GUI" = true ]; then
            zenity --error --title="Ошибка" --text="Мало места: ${FREE_SPACE}G (нужно >5G)" --width=400
        else
            echo -e "  ${RED}❌${NC} Мало места: ${FREE_SPACE}G (нужно >5G)"
        fi
        return 1
    else
        [ "$CMD_GUI" = false ] && echo -e "  ${GREEN}✅${NC} Свободно: ${FREE_SPACE}G"
    fi
    
    [ "$CMD_GUI" = false ] && echo ""
    return 0
}

# ============================================================
#  🔐  ПРОВЕРКА КОНТРОЛЬНОЙ СУММЫ (MD5 / РУЧНОЙ ВВОД)
# ============================================================

check_checksum() {
    local file="$1"
    local md5_file="${file}.md5"
    local user_md5="$2"

    if [ -n "$user_md5" ]; then
        echo -e "${BLUE}🔍 Проверка MD5...${NC}"
        local computed=$(md5sum "$file" | awk '{print $1}')
        if [ "$computed" = "$user_md5" ]; then
            echo -e "${GREEN}✅ MD5 совпадает${NC}"
            return 0
        else
            echo -e "${RED}❌ MD5 НЕ совпадает!${NC}"
            echo -e "${YELLOW}   Ожидалось: $user_md5${NC}"
            echo -e "${YELLOW}   Получено:  $computed${NC}"
            return 1
        fi
    elif [ -f "$md5_file" ]; then
        echo -e "${BLUE}🔍 Проверка MD5 (из файла)...${NC}"
        local computed=$(md5sum "$file" | awk '{print $1}')
        local expected=$(cat "$md5_file" | awk '{print $1}')
        if [ "$computed" = "$expected" ]; then
            echo -e "${GREEN}✅ MD5 совпадает${NC}"
            return 0
        else
            echo -e "${RED}❌ MD5 НЕ совпадает!${NC}"
            echo -e "${YELLOW}   Ожидалось: $expected${NC}"
            echo -e "${YELLOW}   Получено:  $computed${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}⚠️  Файл .md5 не найден.${NC}"
        echo -n -e "${BOLD}Введите MD5 (или Enter для пропуска): ${NC}"
        read -r manual_md5
        if [ -n "$manual_md5" ]; then
            local computed=$(md5sum "$file" | awk '{print $1}')
            if [ "$computed" = "$manual_md5" ]; then
                echo -e "${GREEN}✅ MD5 совпадает${NC}"
                return 0
            else
                echo -e "${RED}❌ MD5 НЕ совпадает!${NC}"
                echo -e "${YELLOW}   Ожидалось: $manual_md5${NC}"
                echo -e "${YELLOW}   Получено:  $computed${NC}"
                return 1
            fi
        else
            echo -e "${YELLOW}⚠️  Проверка пропущена${NC}"
            return 0
        fi
    fi
}

# ============================================================
#  📋  ДЕТАЛЬНАЯ ИНФОРМАЦИЯ О ПАКЕТЕ
# ============================================================

show_detailed_info() {
    local file="$1"
    echo -e "${BOLD}${WHITE}📄 ДЕТАЛЬНАЯ ИНФОРМАЦИЯ О ПАКЕТЕ${NC}"
    separator
    echo ""
    dpkg --info "$file" 2>/dev/null | while read -r line; do
        echo -e "  ${CYAN}$line${NC}"
    done
    echo ""
    echo -e "${CYAN}Размер файла:${NC} $(du -h "$file" | cut -f1)"
    echo -e "${CYAN}Дата изменения:${NC} $(stat -c "%y" "$file" | cut -d'.' -f1)"
    echo -e "${CYAN}MD5:${NC} $(md5sum "$file" | awk '{print $1}')"
    echo ""
}

# ============================================================
#  🔧 УСТАНОВКА ВСЕХ ЗАВИСИМОСТЕЙ (для Astra Linux)
# ============================================================

install_all_dependencies() {
    if [ "$CMD_GUI" = false ]; then
        echo ""
        separator
        echo -e "${BOLD}${BLUE}🔧 ПРОВЕРКА И УСТАНОВКА ЗАВИСИМОСТЕЙ${NC}"
        separator
        echo ""
    fi

    if [ -f "$DEPENDENCIES_FLAG" ]; then
        [ "$CMD_GUI" = false ] && echo -e "${GREEN}✅ Зависимости уже установлены (пропускаем)${NC}"
        return 0
    fi

    local deps_to_install=()
    local deps_already_installed=()

    # Список всех необходимых зависимостей для Р7 Офис на Astra Linux
    declare -A DEPENDENCIES=(
        # Базовые системные библиотеки
        ["libc6"]="libc6"
        ["libstdc++6"]="libstdc++6"
        ["libgcc-s1"]="libgcc-s1"
        
        # Графические библиотеки
        ["libcairo2"]="libcairo2"
        ["libgtk-3-0"]="libgtk-3-0"
        ["libx11-6"]="libx11-6"
        ["libxss1"]="libxss1"
        ["x11-common"]="x11-common"
        ["xdg-utils"]="xdg-utils"
        
        # Мультимедиа и звук
        ["gstreamer1.0-libav"]="gstreamer1.0-libav"
        ["gstreamer1.0-plugins-ugly"]="gstreamer1.0-plugins-ugly"
        ["gstreamer1.0-plugins-good"]="gstreamer1.0-plugins-good"
        ["libasound2"]="libasound2"
        
        # Шрифты
        ["fonts-liberation"]="fonts-liberation"
        ["fonts-dejavu"]="fonts-dejavu"
        ["fonts-crosextra-carlito"]="fonts-crosextra-carlito"
        ["fonts-takao-gothic"]="fonts-takao-gothic"
        
        # Дополнительные библиотеки
        ["libdbus-glib-1-2"]="libdbus-glib-1-2"
        ["libnss3"]="libnss3"
        ["libnspr4"]="libnspr4"
        ["libsecret-1-0"]="libsecret-1-0"
    )

    [ "$CMD_GUI" = false ] && echo -e "${BLUE}📋 Проверка зависимостей...${NC}"
    echo ""

    for dep in "${!DEPENDENCIES[@]}"; do
        if dpkg -l 2>/dev/null | grep -q "^ii.*$dep"; then
            [ "$CMD_GUI" = false ] && echo -e "  ${GREEN}✅${NC} $dep - уже установлен"
            deps_already_installed+=("$dep")
        else
            [ "$CMD_GUI" = false ] && echo -e "  ${YELLOW}⬜${NC} $dep - будет установлен"
            deps_to_install+=("$dep")
        fi
    done

    echo ""

    if [ ${#deps_to_install[@]} -eq 0 ]; then
        [ "$CMD_GUI" = false ] && echo -e "${GREEN}✅ Все зависимости уже установлены!${NC}"
        touch "$DEPENDENCIES_FLAG"
        echo ""
        return 0
    fi

    echo -e "${YELLOW}📦 Будет установлено ${#deps_to_install[@]} пакетов${NC}"
    echo ""

    # Установка зависимостей через apt
    if [ ${#deps_to_install[@]} -gt 0 ]; then
        echo -e "${BLUE}→ Установка зависимостей через APT...${NC}"
        apt update 2>&1 | tee -a "$LOG_FILE"
        apt install -y "${deps_to_install[@]}" 2>&1 | tee -a "$LOG_FILE"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Все зависимости успешно установлены!${NC}"
            touch "$DEPENDENCIES_FLAG"
            log "Все зависимости успешно установлены"
        else
            echo -e "${RED}❌ Ошибка при установке некоторых зависимостей${NC}"
            log "Ошибка при установке зависимостей"
            
            # Пробуем установить по отдельности проблемные пакеты
            echo -e "${YELLOW}→ Пробуем установить пакеты по отдельности...${NC}"
            for dep in "${deps_to_install[@]}"; do
                echo -e "  ${BLUE}Установка $dep...${NC}"
                apt install -y "$dep" 2>&1 | tee -a "$LOG_FILE"
            done
        fi
    fi

    echo ""
    echo -e "${GREEN}✅ ВСЕ ЗАВИСИМОСТИ УСПЕШНО УСТАНОВЛЕНЫ!${NC}"
    touch "$DEPENDENCIES_FLAG"
    echo ""
    return 0
}

# ============================================================
#  📋 ПОИСК ФАЙЛОВ И ВЕРСИЙ
# ============================================================

find_deb_files() {
    cd "$DOWNLOAD_DIR" || {
        echo -e "${RED}❌ Папка $DOWNLOAD_DIR не найдена!${NC}"
        exit 1
    }
    mapfile -t DEB_FILES < <(ls -t r7-office_*.deb 2>/dev/null)
    if [ ${#DEB_FILES[@]} -eq 0 ]; then
        echo -e "${RED}❌ Файлы r7-office_*.deb не найдены в $DOWNLOAD_DIR${NC}"
        echo -e "${YELLOW}   Поместите .deb файл в папку и попробуйте снова${NC}"
        exit 1
    fi
    log "Найдено ${#DEB_FILES[@]} файлов"
}

extract_version() {
    echo "$1" | grep -oP '\d+\.\d+\.\d+-\d+' | head -1
}

# ============================================================
#  📥 УСТАНОВКА ЧЕРЕЗ dpkg
# ============================================================

install_r7_with_dpkg() {
    local file="$1"
    local version=$(extract_version "$file")
    local user_md5="$2"

    if [ "$CMD_GUI" = true ]; then
        zenity --progress --title="Р7 Офис" --text="Начинаем установку $version" --pulsate --auto-close --width=400
    fi

    # Проверка MD5
    if [ "$CMD_CHECK" = true ] || [ "$CMD_GUI" = true ] || [ -n "$user_md5" ]; then
        check_checksum "$file" "$user_md5" || {
            if [ "$CMD_GUI" = true ]; then
                zenity --error --title="Ошибка" --text="Контрольная сумма не совпадает!\nУстановка отменена." --width=400
            else
                echo -e "${RED}❌ Установка отменена из-за несовпадения суммы${NC}"
            fi
            return 1
        }
    fi

    # Показать детальную информацию
    if [ "$CMD_GUI" = true ]; then
        local info=$(dpkg --info "$file" 2>/dev/null | head -20)
        echo "$info" | zenity --text-info --title="Информация о пакете" --width=600 --height=400 2>/dev/null
    else
        show_detailed_info "$file"
        echo -n -e "${BOLD}Продолжить установку? [Y/n]: ${NC}"
        read -r confirm
        [[ "$confirm" =~ ^[Nn]$ ]] && return 1
    fi

    cd "$DOWNLOAD_DIR" || return 1

    # Удаляем старую версию
    if dpkg -l | grep -q r7-office; then
        [ "$CMD_GUI" = false ] && echo -e "${BLUE}⏳ Удаление старой версии...${NC}"
        apt remove -y r7-office 2>&1 | tee -a "$LOG_FILE"
        apt autoremove -y 2>&1 | tee -a "$LOG_FILE"
    fi

    # Установка через dpkg
    [ "$CMD_GUI" = false ] && echo -e "${BLUE}⏳ Установка $version через dpkg...${NC}"
    dpkg -i "$file" 2>&1 | tee -a "$LOG_FILE"
    local dpkg_exit=$?

    if [ $dpkg_exit -eq 0 ]; then
        [ "$CMD_GUI" = false ] && echo -e "${GREEN}✅ УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!${NC}"
        log "Установлена версия $version через dpkg"
        
        # Исправляем возможные проблемы с зависимостями
        echo -e "${BLUE}→ Проверка зависимостей...${NC}"
        apt install -f -y 2>&1 | tee -a "$LOG_FILE"

        if [ "$CMD_GUI" = true ]; then
            zenity --info --title="Успех" --text="Версия $version успешно установлена!" --width=400
        fi

        echo ""
        dpkg -l | grep r7-office
        echo ""
        echo -e "${GREEN}🎯 Запустите Р7 Офис командой: r7-office${NC}"
        return 0
    else
        [ "$CMD_GUI" = false ] && echo -e "${RED}❌ ОШИБКА ПРИ УСТАНОВКЕ (код: $dpkg_exit)${NC}"
        log "Ошибка при установке версии $version (код: $dpkg_exit)"
        if [ "$CMD_GUI" = true ]; then
            zenity --error --title="Ошибка" --text="Ошибка при установке (код $dpkg_exit)" --width=400
        fi
        return 1
    fi
}

# ============================================================
#  🏎️  FAST-LANE
# ============================================================

fast_lane_install() {
    if [ "$CMD_GUI" = false ]; then
        echo ""
        separator
        echo -e "${BOLD}${GREEN}  🏎️  FAST-LANE РЕЖИМ${NC}"
        separator
        echo ""
    fi
    detect_environment || exit 1
    install_all_dependencies

    cd "$DOWNLOAD_DIR" || exit 1
    local latest_file=$(ls -t r7-office_*.deb 2>/dev/null | head -1)
    if [ -z "$latest_file" ]; then
        [ "$CMD_GUI" = false ] && echo -e "${RED}❌ Не найден .deb файл${NC}"
        exit 1
    fi
    install_r7_with_dpkg "$latest_file" "$CMD_MD5"
    
    if [ $? -eq 0 ] && [ -n "$DISPLAY" ] && [ "$CMD_GUI" = false ]; then
        echo -n -e "${YELLOW}Запустить Р7? [Y/n]: ${NC}"
        read -r run_r7
        if [[ "$run_r7" =~ ^[Yy]$ ]] || [ -z "$run_r7" ]; then
            r7-office &
        fi
    fi
}

# ============================================================
#  🏥  HEALTH-CHECK
# ============================================================

health_check() {
    echo ""
    separator
    echo -e "${BOLD}${BLUE}  🏥  ДИАГНОСТИКА Р7-ОФИС${NC}"
    separator
    echo ""
    
    echo -e "${CYAN}1. Проверка установленного пакета...${NC}"
    if dpkg -l | grep -q r7-office; then
        echo -e "   ${GREEN}✅ Р7 установлен (версия: $(dpkg -l | grep r7-office | awk '{print $3}'))${NC}"
    else
        echo -e "   ${RED}❌ Р7 не установлен${NC}"
    fi
    
    echo -e "${CYAN}2. Проверка зависимостей...${NC}"
    if [ -f "$DEPENDENCIES_FLAG" ]; then
        echo -e "   ${GREEN}✅ Зависимости установлены${NC}"
    else
        echo -e "   ${YELLOW}⚠️  Зависимости не установлены${NC}"
    fi
    
    echo -e "${CYAN}3. Проверка запуска...${NC}"
    if pgrep -f "r7-office" > /dev/null; then
        echo -e "   ${GREEN}✅ Р7 запущен (PID: $(pgrep -f r7-office))${NC}"
    else
        echo -e "   ${YELLOW}⚠️  Р7 не запущен${NC}"
    fi
    
    echo -e "${CYAN}4. Проверка места на диске...${NC}"
    echo -e "   ${GREEN}✅ Свободно: $(df -h / | awk 'NR==2 {print $4}')${NC}"
    
    echo -e "${CYAN}5. Проверка кэша...${NC}"
    CACHE_DIR="$USER_HOME/.local/share/r7-office/editors/recover"
    if [ -d "$CACHE_DIR" ]; then
        echo -e "   ${GREEN}✅ Кэш: $(du -sh "$CACHE_DIR" | cut -f1)${NC}"
    else
        echo -e "   ${YELLOW}⚠️  Кэш не найден${NC}"
    fi
    
    separator
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read -r
}

# ============================================================
#  🗑️  ОЧИСТКА КЭША
# ============================================================

clear_editor_cache() {
    echo ""
    separator
    echo -e "${BOLD}${YELLOW}  🗑️  ОЧИСТКА КЭША РЕДАКТОРА Р7-ОФИС${NC}"
    separator
    echo ""
    CACHE_DIR="$USER_HOME/.local/share/r7-office/editors/recover"
    if [ ! -d "$CACHE_DIR" ]; then
        echo -e "${YELLOW}⚠️  Папка с кэшем не найдена${NC}"
        echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
        read -r
        return 0
    fi
    CACHE_SIZE=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)
    echo -e "${CYAN}📍 Путь: $CACHE_DIR (размер: $CACHE_SIZE)${NC}"
    echo ""
    echo -n -e "${BOLD}Очистить кэш? [y/N]: ${NC}"
    read -r choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        rm -rf "$CACHE_DIR"/*
        echo -e "${GREEN}✅ Кэш очищен${NC}"
        log "Очищен кэш редактора"
    else
        echo -e "${YELLOW}❌ Отмена${NC}"
    fi
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read -r
}

# ============================================================
#  🧹  ПОЛНОЕ УДАЛЕНИЕ
# ============================================================

remove_r7_office() {
    echo ""
    separator
    echo -e "${BOLD}${RED}  🧹  ПОЛНОЕ УДАЛЕНИЕ Р7-ОФИС${NC}"
    separator
    echo ""
    echo -e "${RED}⚠️  ВНИМАНИЕ! Будет выполнено полное удаление Р7-Офис.${NC}"
    echo ""
    echo -e "${BOLD}Выберите вариант удаления:${NC}"
    echo ""
    echo -e "  ${BLUE}[1]${NC} Удалить приложение, ${GREEN}ОСТАВИТЬ${NC} кэш и настройки"
    echo -e "  ${BLUE}[2]${NC} Удалить приложение, ${YELLOW}ОЧИСТИТЬ${NC} кэш, ${GREEN}ОСТАВИТЬ${NC} настройки"
    echo -e "  ${BLUE}[3]${NC} ${RED}Полное удаление${NC} (приложение + кэш + настройки)"
    echo -e "  ${BLUE}[4]${NC} Отмена"
    echo ""
    echo -n -e "${BOLD}Ваш выбор (1-4): ${NC}"
    read -r choice
    case "$choice" in
        1) 
            apt remove -y r7-office
            apt autoremove -y
            echo -e "${GREEN}✅ Приложение удалено.${NC}" 
            ;;
        2) 
            apt remove -y r7-office
            apt autoremove -y
            CACHE_DIR="$USER_HOME/.local/share/r7-office/editors/recover"
            [ -d "$CACHE_DIR" ] && rm -rf "$CACHE_DIR"/*
            echo -e "${GREEN}✅ Приложение удалено, кэш очищен.${NC}" 
            ;;
        3) 
            echo -n -e "${BOLD}Подтвердите полное удаление (введите YES): ${NC}"
            read -r confirm
            if [ "$confirm" != "YES" ]; then
                echo -e "${YELLOW}❌ Отмена${NC}"
                return 0
            fi
            apt remove -y r7-office
            apt autoremove -y
            rm -rf "$USER_HOME/.local/share/r7-office"
            rm -rf "$USER_HOME/.config/r7-office"
            rm -f "$DEPENDENCIES_FLAG"
            echo -e "${GREEN}✅ Полное удаление завершено.${NC}" 
            ;;
        4|*) 
            echo -e "${YELLOW}❌ Отмена${NC}" 
            ;;
    esac
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read -r
}

# ============================================================
#  ❓  СПРАВКА (инлайн)
# ============================================================

show_inline_help() {
    echo ""
    separator
    echo -e "${BOLD}${WHITE}  ❓  СПРАВКА ПО КОМАНДАМ  ${NC}"
    separator
    echo ""
    echo -e "${CYAN}В интерактивном меню:${NC}"
    echo -e "  ${GREEN}[1-${#DEB_FILES[@]}]${NC}  - Установить выбранную версию (спросит MD5)"
    echo -e "  ${BLUE}[F]${NC}           - Переустановить текущую версию"
    echo -e "  ${YELLOW}[L]${NC}           - Установить самую новую"
    echo -e "  ${GREEN}[S]${NC}           - Fast-lane (всё автоматически)"
    echo -e "  ${MAGENTA}[D]${NC}           - Переустановить зависимости"
    echo -e "  ${CYAN}[H]${NC}           - Диагностика"
    echo -e "  ${CYAN}[C]${NC}           - Очистить кэш"
    echo -e "  ${RED}[R]${NC}           - Полное удаление"
    echo -e "  ${RED}[Q]${NC}           - Выйти"
    echo -e "  ${WHITE}?${NC} / help / Помощь - эта справка"
    echo ""
    echo -e "${CYAN}Аргументы командной строки:${NC}"
    echo -e "  ${WHITE}-v ВЕРСИЯ${NC}      - установить конкретную версию"
    echo -e "  ${WHITE}-l${NC}              - установить самую новую"
    echo -e "  ${WHITE}-f${NC}              - fast-lane"
    echo -e "  ${WHITE}-u URL${NC}          - скачать и установить по ссылке"
    echo -e "  ${WHITE}--check${NC}          - проверять контрольную сумму"
    echo -e "  ${WHITE}--md5 ХЭШ${NC}        - указать MD5 для проверки"
    echo -e "  ${WHITE}--gui${NC}            - графический режим"
    echo -e "  ${WHITE}-h${NC}              - полная справка"
    echo ""
    separator
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read -r
}

# ============================================================
#  📊  МЕНЮ
# ============================================================

show_menu() {
    header
    CURRENT_VERSION=$(dpkg -l 2>/dev/null | grep r7-office | awk '{print $3}')
    [ -z "$CURRENT_VERSION" ] && CURRENT_VERSION="не установлен"
    
    echo -e "  ${BOLD}Текущая версия:${NC} ${GREEN}$CURRENT_VERSION${NC}"
    echo -e "  ${BOLD}🔒 Зависимости:${NC} $([ -f "$DEPENDENCIES_FLAG" ] && echo "${GREEN}установлены${NC}" || echo "${YELLOW}не установлены${NC}")"
    echo -e "  ${BOLD}💾 Свободно:${NC} $(df -h / | awk 'NR==2 {print $4}')"
    echo ""
    separator
    echo ""

    find_deb_files

    echo -e "${BOLD}${WHITE}📋 Доступные дистрибутивы (всего: ${#DEB_FILES[@]}):${NC}"
    separator
    for i in "${!DEB_FILES[@]}"; do
        file="${DEB_FILES[$i]}"
        version=$(extract_version "$file")
        size=$(du -h "$file" | cut -f1)
        installed=""
        [ "$CURRENT_VERSION" = "$version" ] && installed="${GREEN} ✓ УСТАНОВЛЕНА${NC}"
        display_num=$((i + 1))
        if [ $i -eq 0 ]; then
            echo -e "${GREEN}${BOLD}[$display_num]${NC} ${file}  ${CYAN}(самая новая)${NC} $installed"
        else
            echo -e "${BLUE}[$display_num]${NC} ${file}  ${size} $installed"
        fi
    done

    echo ""
    separator
    echo -e "${BOLD}${WHITE}📌 Выберите действие:${NC}"
    echo ""
    echo -e "  ${GREEN}[1-${#DEB_FILES[@]}]${NC} - Установить выбранную версию"
    echo -e "  ${BLUE}[F]${NC}   - Принудительно переустановить текущую версию"
    echo -e "  ${YELLOW}[L]${NC}   - Установить самую новую версию"
    echo -e "  ${GREEN}[S]${NC}   - 🏎️  Fast-lane"
    echo -e "  ${MAGENTA}[D]${NC}   - Переустановить зависимости"
    echo -e "  ${CYAN}[H]${NC}   - 🏥  Диагностика"
    echo -e "  ${CYAN}[C]${NC}   - 🗑️  Очистить кэш"
    echo -e "  ${RED}[R]${NC}   - 🧹 Полное удаление"
    echo -e "  ${WHITE}[?]${NC}   - ❓  Помощь"
    echo -e "  ${RED}[Q]${NC}   - Выйти"
    echo ""
    separator
    echo -n -e "${BOLD}${WHITE}Ваш выбор: ${NC}"
}

# ============================================================
#  🏁  ЗАПУСК
# ============================================================

main() {
    check_root

    # Разбор аргументов командной строки
    if [ $# -gt 0 ]; then
        parse_args "$@"
        if [ "$CMD_GUI" = true ]; then
            ensure_zenity
        fi
        if [ -n "$CMD_URL" ]; then
            local tmp_file="$DOWNLOAD_DIR/r7-office_downloaded.deb"
            wget -O "$tmp_file" "$CMD_URL" || exit 1
            install_r7_with_dpkg "$tmp_file" "$CMD_MD5"
            exit $?
        elif [ -n "$CMD_VERSION" ]; then
            local found=""
            for f in "$DOWNLOAD_DIR"/r7-office_*"$CMD_VERSION"*.deb; do
                [ -f "$f" ] && found="$f" && break
            done
            if [ -z "$found" ]; then
                echo -e "${RED}❌ Файл с версией $CMD_VERSION не найден${NC}"
                exit 1
            fi
            install_r7_with_dpkg "$found" "$CMD_MD5"
            exit $?
        elif [ "$CMD_LATEST" = true ]; then
            local latest_file=$(ls -t "$DOWNLOAD_DIR"/r7-office_*.deb 2>/dev/null | head -1)
            if [ -z "$latest_file" ]; then
                echo -e "${RED}❌ Не найден .deb файл${NC}"
                exit 1
            fi
            install_r7_with_dpkg "$latest_file" "$CMD_MD5"
            exit $?
        elif [ "$CMD_FAST" = true ]; then
            fast_lane_install
            exit $?
        else
            echo -e "${RED}❌ Неизвестная комбинация аргументов${NC}"
            show_help
        fi
    fi

    # Интерактивный режим
    header
    detect_environment
    install_all_dependencies
    find_deb_files

    while true; do
        show_menu
        read -r choice

        case "$choice" in
            [0-9]*)
                if [ "$choice" -ge 1 ] && [ "$choice" -le "${#DEB_FILES[@]}" ]; then
                    idx=$((choice - 1))
                    selected="${DEB_FILES[$idx]}"
                    echo -n -e "${YELLOW}Введите MD5 (или Enter для пропуска): ${NC}"
                    read -r manual_md5
                    install_r7_with_dpkg "$selected" "$manual_md5"
                    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
                    read -r
                else
                    echo -e "${RED}❌ Неверный номер!${NC}"
                    sleep 1
                fi
                ;;
            [Ff])
                CURRENT_VERSION=$(dpkg -l 2>/dev/null | grep r7-office | awk '{print $3}')
                if [ -z "$CURRENT_VERSION" ]; then
                    echo -e "${RED}❌ Нет установленной версии${NC}"
                    sleep 2
                    continue
                fi
                found=""
                for f in "${DEB_FILES[@]}"; do
                    [ "$(extract_version "$f")" = "$CURRENT_VERSION" ] && found="$f" && break
                done
                if [ -z "$found" ]; then
                    echo -e "${RED}❌ Файл с версией $CURRENT_VERSION не найден${NC}"
                    sleep 3
                    continue
                fi
                echo -e "${YELLOW}⚠️  Принудительная переустановка $CURRENT_VERSION${NC}"
                echo -n -e "${BOLD}Продолжить? [Y/n]: ${NC}"
                read -r confirm
                [[ "$confirm" =~ ^[Nn]$ ]] && continue
                echo -n -e "${YELLOW}Введите MD5 (или Enter): ${NC}"
                read -r manual_md5
                install_r7_with_dpkg "$found" "$manual_md5"
                ;;
            [Ll])
                latest="${DEB_FILES[0]}"
                latest_ver=$(extract_version "$latest")
                CURRENT_VERSION=$(dpkg -l 2>/dev/null | grep r7-office | awk '{print $3}')
                if [ "$CURRENT_VERSION" = "$latest_ver" ]; then
                    echo -e "${YELLOW}⚠️  Версия $latest_ver уже установлена${NC}"
                    sleep 2
                    continue
                fi
                echo -n -e "${YELLOW}Введите MD5 (или Enter): ${NC}"
                read -r manual_md5
                install_r7_with_dpkg "$latest" "$manual_md5"
                ;;
            [Ss])
                fast_lane_install
                ;;
            [Dd])
                rm -f "$DEPENDENCIES_FLAG"
                echo -e "${GREEN}✅ Флаг удалён${NC}"
                install_all_dependencies
                ;;
            [Hh])
                health_check
                ;;
            [Cc])
                clear_editor_cache
                ;;
            [Rr])
                remove_r7_office
                ;;
            [Qq])
                echo -e "${GREEN}👋 До свидания!${NC}"
                exit 0
                ;;
            "?"|"help"|"HELP"|"Помощь")
                show_inline_help
                ;;
            *)
                echo -e "${RED}❌ Неверный выбор!${NC}"
                sleep 1
                ;;
        esac
    done
}

main "$@"
EOF