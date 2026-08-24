cat > /usr/local/bin/update-r7-redos.sh << 'EOF'
#!/bin/bash

# ============================================================
#  🚀 Р7 Офис Установщик - СПЕЦИАЛЬНАЯ ВЕРСИЯ ДЛЯ РЕД ОС
#  Версия: 1.1 - с оптимизацией RDP
# ============================================================

# ------------------- НАСТРОЙКИ -------------------
DOWNLOAD_DIR="/home/administrator/Downloads"
LOG_FILE="/var/log/r7-update.log"
DEPENDENCIES_FLAG="/var/lib/r7-dependencies-installed"
RDP_OPTIMIZED_FLAG="/var/lib/rdp-optimized"

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
    echo -e "${BOLD}${WHITE}  🚀  Р7 ОФИС - УСТАНОВЩИК ДЛЯ РЕД ОС  ${NC}"
    echo -e "${BOLD}${WHITE}  🔧  РАБОТАЕТ ЧЕРЕЗ DNF / RPM  ${NC}"
    separator
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Этот скрипт должен запускаться от root!${NC}"
        echo -e "${YELLOW}   Используйте: sudo update-r7-redos.sh${NC}"
        exit 1
    fi
}

# ============================================================
#  ⚡  ОПТИМИЗАЦИЯ RDP-СОЕДИНЕНИЯ (при первом запуске)
# ============================================================

optimize_rdp() {
    # Проверяем, выполнялась ли оптимизация ранее
    if [ -f "$RDP_OPTIMIZED_FLAG" ]; then
        echo -e "${GREEN}✅ RDP уже оптимизирован (пропускаем)${NC}"
        return 0
    fi

    echo ""
    separator
    echo -e "${BOLD}${BLUE}  ⚡  ОПТИМИЗАЦИЯ RDP-СОЕДИНЕНИЯ  ${NC}"
    separator
    echo ""

    # Проверяем, установлен ли xrdp
    if ! command -v xrdp &> /dev/null; then
        echo -e "${YELLOW}⚠️  xrdp не установлен. Пропускаем оптимизацию.${NC}"
        echo -e "${YELLOW}   Если используете RDP, установите xrdp:${NC}"
        echo -e "${CYAN}   dnf install -y xrdp${NC}"
        return 0
    fi

    # Проверяем, существует ли файл
    if [ ! -f "/etc/xrdp/xrdp.ini" ]; then
        echo -e "${YELLOW}⚠️  Файл /etc/xrdp/xrdp.ini не найден. Пропускаем.${NC}"
        return 0
    fi

    echo -e "${BLUE}📝 Настройка /etc/xrdp/xrdp.ini...${NC}"

    # Создаём резервную копию
    cp /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.backup
    echo -e "  ${GREEN}✅${NC} Создана резервная копия: /etc/xrdp/xrdp.ini.backup"

    # Проверяем и добавляем параметры, если их нет
    local needs_restart=false

    # crypt_level
    if ! grep -q "^crypt_level=" /etc/xrdp/xrdp.ini; then
        echo -e "  ${BLUE}→${NC} Добавляем crypt_level=none"
        echo "crypt_level=none" >> /etc/xrdp/xrdp.ini
        needs_restart=true
    else
        sed -i 's/^crypt_level=.*/crypt_level=none/' /etc/xrdp/xrdp.ini
        echo -e "  ${BLUE}→${NC} Обновляем crypt_level=none"
        needs_restart=true
    fi

    # tcp_send_buffer_bytes
    if ! grep -q "^tcp_send_buffer_bytes=" /etc/xrdp/xrdp.ini; then
        echo -e "  ${BLUE}→${NC} Добавляем tcp_send_buffer_bytes=33554432"
        echo "tcp_send_buffer_bytes=33554432" >> /etc/xrdp/xrdp.ini
        needs_restart=true
    else
        sed -i 's/^tcp_send_buffer_bytes=.*/tcp_send_buffer_bytes=33554432/' /etc/xrdp/xrdp.ini
        echo -e "  ${BLUE}→${NC} Обновляем tcp_send_buffer_bytes=33554432"
        needs_restart=true
    fi

    # max_bpp
    if ! grep -q "^max_bpp=" /etc/xrdp/xrdp.ini; then
        echo -e "  ${BLUE}→${NC} Добавляем max_bpp=16"
        echo "max_bpp=16" >> /etc/xrdp/xrdp.ini
        needs_restart=true
    else
        sed -i 's/^max_bpp=.*/max_bpp=16/' /etc/xrdp/xrdp.ini
        echo -e "  ${BLUE}→${NC} Обновляем max_bpp=16"
        needs_restart=true
    fi

    if [ "$needs_restart" = true ]; then
        echo -e "  ${BLUE}→${NC} Перезапуск xrdp..."
        systemctl restart xrdp 2>/dev/null || service xrdp restart 2>/dev/null
        echo -e "  ${GREEN}✅${NC} xrdp перезапущен"
    fi

    # Создаём флаг, что оптимизация выполнена
    touch "$RDP_OPTIMIZED_FLAG"
    echo ""
    echo -e "${GREEN}✅ RDP-СОЕДИНЕНИЕ ОПТИМИЗИРОВАНО!${NC}"
    echo -e "${CYAN}   Параметры применены:${NC}"
    echo -e "     • crypt_level=none"
    echo -e "     • tcp_send_buffer_bytes=33554432"
    echo -e "     • max_bpp=16"
    echo -e "${YELLOW}   ВАЖНО: crypt_level=none отключает шифрование.${NC}"
    echo -e "${YELLOW}   Используйте только в надёжных сетях!${NC}"
    echo ""
    log "Выполнена оптимизация RDP"

    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read -r
}

# ============================================================
#  🧠  АВТОДЕТЕКТ ОКРУЖЕНИЯ
# ============================================================

detect_environment() {
    echo -e "${BLUE}🔍 Детект окружения...${NC}"
    
    if [ -n "$SUDO_USER" ]; then
        REAL_USER="$SUDO_USER"
    else
        REAL_USER="$(whoami)"
    fi
    USER_HOME=$(eval echo ~$REAL_USER)
    echo -e "  ${GREEN}✅${NC} Пользователь: $REAL_USER"

    if [ -z "$DISPLAY" ]; then
        if pgrep -x "Xorg" > /dev/null || pgrep -x "Xwayland" > /dev/null; then
            export DISPLAY=":0"
            echo -e "  ${GREEN}✅${NC} Графика обнаружена, DISPLAY=:0"
        else
            echo -e "  ${YELLOW}⚠️${NC} Графика не обнаружена"
        fi
    else
        echo -e "  ${GREEN}✅${NC} DISPLAY: $DISPLAY"
    fi

    if [ -f /etc/redos-release ]; then
        echo -e "  ${GREEN}✅${NC} РЕД ОС: $(cat /etc/redos-release | head -1)"
    elif [ -f /etc/os-release ]; then
        echo -e "  ${GREEN}✅${NC} ОС: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
    fi

    FREE_SPACE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$FREE_SPACE" -lt 5 ]; then
        echo -e "  ${RED}❌${NC} Мало места: ${FREE_SPACE}G (нужно >5G)"
        return 1
    else
        echo -e "  ${GREEN}✅${NC} Свободно: ${FREE_SPACE}G"
    fi
    
    echo ""
    return 0
}

# ============================================================
#  🔐  ПРОВЕРКА КОНТРОЛЬНОЙ СУММЫ (MD5)
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
#  📋  ПОИСК ФАЙЛОВ И ВЕРСИЙ (.rpm)
# ============================================================

find_rpm_files() {
    cd "$DOWNLOAD_DIR" || {
        echo -e "${RED}❌ Папка $DOWNLOAD_DIR не найдена!${NC}"
        exit 1
    }
    mapfile -t RPM_FILES < <(ls -t r7-office_*.rpm 2>/dev/null)
    if [ ${#RPM_FILES[@]} -eq 0 ]; then
        echo -e "${RED}❌ Файлы r7-office_*.rpm не найдены в $DOWNLOAD_DIR${NC}"
        echo -e "${YELLOW}   Поместите .rpm файл в папку и попробуйте снова${NC}"
        exit 1
    fi
    log "Найдено ${#RPM_FILES[@]} файлов"
}

extract_version() {
    echo "$1" | grep -oP '\d+\.\d+\.\d+-\d+' | head -1
}

# ============================================================
#  📥  УСТАНОВКА ЧЕРЕЗ RPM
# ============================================================

install_r7_with_rpm() {
    local file="$1"
    local version=$(extract_version "$file")
    local user_md5="$2"

    echo ""
    separator
    echo -e "${BOLD}${BLUE}▶ УСТАНОВКА ВЕРСИИ $version${NC}"
    separator
    echo ""

    # Проверка MD5
    if [ -n "$user_md5" ] || [ "$CMD_CHECK" = true ]; then
        check_checksum "$file" "$user_md5" || {
            echo -e "${RED}❌ Установка отменена из-за несовпадения суммы${NC}"
            return 1
        }
    fi

    echo -e "${CYAN}📄 Информация о пакете:${NC}"
    rpm -qip "$file" 2>/dev/null | head -10
    echo ""

    cd "$DOWNLOAD_DIR" || return 1

    # Удаляем старую версию
    if rpm -qa | grep -q r7-office; then
        echo -e "${BLUE}⏳ Удаление старой версии...${NC}"
        dnf remove -y r7-office 2>&1 | tee -a "$LOG_FILE"
    fi

    # Установка через rpm
    echo -e "${BLUE}⏳ Установка $version через rpm...${NC}"
    rpm -ivh "$file" 2>&1 | tee -a "$LOG_FILE"
    local rpm_exit=$?

    if [ $rpm_exit -eq 0 ]; then
        echo -e "${GREEN}✅ УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!${NC}"
        log "Установлена версия $version через rpm"
        
        # Исправляем зависимости
        echo -e "${BLUE}→ Проверка зависимостей...${NC}"
        dnf install -y 2>&1 | tee -a "$LOG_FILE"
        
        echo ""
        rpm -qa | grep r7-office
        echo ""
        echo -e "${GREEN}🎯 Запустите Р7 Офис командой: r7-office${NC}"
        return 0
    else
        echo -e "${RED}❌ ОШИБКА ПРИ УСТАНОВКЕ (код: $rpm_exit)${NC}"
        log "Ошибка при установке версии $version (код: $rpm_exit)"
        return 1
    fi
}

# ============================================================
#  📊  МЕНЮ
# ============================================================

show_menu() {
    header

    CURRENT_VERSION=$(rpm -qa | grep r7-office | sed 's/.*-//')
    [ -z "$CURRENT_VERSION" ] && CURRENT_VERSION="не установлен"

    echo -e "  ${BOLD}Текущая версия:${NC} ${GREEN}$CURRENT_VERSION${NC}"
    echo -e "  ${BOLD}💾 Свободно:${NC} $(df -h / | awk 'NR==2 {print $4}')"
    echo ""
    separator
    echo ""

    find_rpm_files

    echo -e "${BOLD}${WHITE}📋 Доступные дистрибутивы (всего: ${#RPM_FILES[@]}):${NC}"
    separator
    for i in "${!RPM_FILES[@]}"; do
        file="${RPM_FILES[$i]}"
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
    echo -e "  ${GREEN}[1-${#RPM_FILES[@]}]${NC} - Установить выбранную версию"
    echo -e "  ${BLUE}[F]${NC}   - Переустановить текущую версию"
    echo -e "  ${YELLOW}[L]${NC}   - Установить самую новую версию"
    echo -e "  ${RED}[R]${NC}   - Удалить Р7-Офис"
    echo -e "  ${RED}[Q]${NC}   - Выйти"
    echo ""
    separator
    echo -n -e "${BOLD}${WHITE}Ваш выбор: ${NC}"
}

# ============================================================
#  🧹  УДАЛЕНИЕ Р7-ОФИС
# ============================================================

remove_r7_office() {
    echo ""
    separator
    echo -e "${BOLD}${RED}  🧹  УДАЛЕНИЕ Р7-ОФИС${NC}"
    separator
    echo ""
    
    if ! rpm -qa | grep -q r7-office; then
        echo -e "${YELLOW}⚠️  Р7-Офис не установлен${NC}"
        return 0
    fi
    
    echo -e "${BOLD}Выберите вариант удаления:${NC}"
    echo ""
    echo -e "  ${BLUE}[1]${NC} Удалить приложение (настройки сохраняются)"
    echo -e "  ${BLUE}[2]${NC} Полное удаление (приложение + настройки)"
    echo -e "  ${BLUE}[3]${NC} Отмена"
    echo ""
    echo -n -e "${BOLD}Ваш выбор (1-3): ${NC}"
    read -r choice
    
    case "$choice" in
        1)
            dnf remove -y r7-office
            echo -e "${GREEN}✅ Приложение удалено${NC}"
            ;;
        2)
            dnf remove -y r7-office
            rm -rf "$USER_HOME/.config/r7-office"
            rm -rf "$USER_HOME/.local/share/r7-office"
            echo -e "${GREEN}✅ Полное удаление завершено${NC}"
            ;;
        *)
            echo -e "${YELLOW}❌ Отмена${NC}"
            ;;
    esac
}

# ============================================================
#  🏁  ЗАПУСК
# ============================================================

main() {
    check_root
    header
    detect_environment
    
    # Оптимизация RDP при первом запуске (всегда, даже если нет R7)
    optimize_rdp

    while true; do
        show_menu
        read -r choice

        case "$choice" in
            [0-9]*)
                if [ "$choice" -ge 1 ] && [ "$choice" -le "${#RPM_FILES[@]}" ]; then
                    idx=$((choice - 1))
                    selected="${RPM_FILES[$idx]}"
                    echo -n -e "${YELLOW}Введите MD5 (или Enter): ${NC}"
                    read -r manual_md5
                    install_r7_with_rpm "$selected" "$manual_md5"
                    echo -n -e "${YELLOW}Нажмите Enter...${NC}"
                    read -r
                else
                    echo -e "${RED}❌ Неверный номер!${NC}"
                    sleep 1
                fi
                ;;
            [Ff])
                CURRENT_VERSION=$(rpm -qa | grep r7-office | sed 's/.*-//')
                if [ -z "$CURRENT_VERSION" ]; then
                    echo -e "${RED}❌ Нет установленной версии${NC}"
                    sleep 2
                    continue
                fi
                found=""
                for f in "${RPM_FILES[@]}"; do
                    [ "$(extract_version "$f")" = "$CURRENT_VERSION" ] && found="$f" && break
                done
                if [ -z "$found" ]; then
                    echo -e "${RED}❌ Файл с версией $CURRENT_VERSION не найден${NC}"
                    sleep 3
                    continue
                fi
                echo -n -e "${YELLOW}Введите MD5 (или Enter): ${NC}"
                read -r manual_md5
                install_r7_with_rpm "$found" "$manual_md5"
                ;;
            [Ll])
                latest="${RPM_FILES[0]}"
                latest_ver=$(extract_version "$latest")
                CURRENT_VERSION=$(rpm -qa | grep r7-office | sed 's/.*-//')
                if [ "$CURRENT_VERSION" = "$latest_ver" ]; then
                    echo -e "${YELLOW}⚠️  Версия $latest_ver уже установлена${NC}"
                    sleep 2
                    continue
                fi
                echo -n -e "${YELLOW}Введите MD5 (или Enter): ${NC}"
                read -r manual_md5
                install_r7_with_rpm "$latest" "$manual_md5"
                ;;
            [Rr])
                remove_r7_office
                ;;
            [Qq])
                echo -e "${GREEN}👋 До свидания!${NC}"
                exit 0
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