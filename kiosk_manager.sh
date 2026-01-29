#!/bin/bash
# kiosk_manager.sh — Интерактивный установщик Kiosk Mode на базе Firefox ESR
# Специальная версия для поддержки старых SSL/TLS протоколов.

# --- НАСТРОЙКИ ---
RPI_USER="pi"
USER_HOME="/home/$RPI_USER"
CONFIG_FILE="$USER_HOME/kiosk.conf"
BACKUP_CONFIG="/boot/kiosk.conf"
FIREFOX_PROFILE_DIR="$USER_HOME/.mozilla/firefox/kiosk.default"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт с sudo: sudo ./kiosk_manager.sh"
  exit
fi

# --- ФУНКЦИИ ---

# 1. Функция перезапуска (убиваем firefox, цикл в .xinitrc поднимет его снова)
reload_browser() {
    echo "Перезагружаю интерфейс..."
    pkill -f firefox-esr
}

# 2. Функция обновления конфига (URL и разрешение)
update_config() {
    local url=$1
    local width=$2
    local height=$3

    cat <<EOF > "$CONFIG_FILE"
URL="$url"
WIDTH=$width
HEIGHT=$height
EOF
    chown $RPI_USER:$RPI_USER "$CONFIG_FILE"
    cp "$CONFIG_FILE" "$BACKUP_CONFIG"
}

# 3. Настройка профиля Firefox (Самая важная часть для SSL)
setup_firefox_profile() {
    echo ">>> Настройка профиля Firefox (разрешение старых SSL)..."
    
    # Создаем папку для профиля, если нет
    mkdir -p "$FIREFOX_PROFILE_DIR"
    chown -R $RPI_USER:$RPI_USER "$USER_HOME/.mozilla"

    # Создаем файл user.js с настройками безопасности и киоска
    # Здесь security.tls.version.min = 1 разрешает TLS 1.0
    cat <<EOF > "$FIREFOX_PROFILE_DIR/user.js"
// --- БЕЗОПАСНОСТЬ И SSL (Для старых серверов) ---
user_pref("security.tls.version.min", 1);
user_pref("security.tls.version.fallback-limit", 1);
user_pref("security.insecure_connection_text.enabled", false);
user_pref("security.insecure_connection_icon.enabled", false);

// --- НАСТРОЙКИ КИОСКА ---
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.max_resumed_crashes", 0);
user_pref("toolkit.cosmeticAnimations.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.rights.3.shown", true);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("browser.fullscreen.autohide", true);
user_pref("browser.link.open_newwindow", 1); // Открывать ссылки в том же окне

// --- КЭШ (ВКЛЮЧАЕМ ДЛЯ ОФЛАЙН-РЕЖИМА) ---
// Разрешаем кеш на диске, чтобы видео работало без сети
user_pref("browser.cache.disk.enable", true); 
// Ставим лимит 1 ГБ (значение в килобайтах: 1048576 КБ = 1 ГБ)
user_pref("browser.cache.disk.capacity", 1048576);
// Разрешаем "умное" управление размером (можно поставить false, если хотите жесткий лимит)
user_pref("browser.cache.disk.smart_size.enabled", false);

// Очищать кеш при закрытии? НЕТ, иначе после перезагрузки RPi контент пропадет
user_pref("privacy.clearOnShutdown.cache", false);
user_pref("privacy.sanitize.sanitizeOnShutdown", false);
EOF

    chown $RPI_USER:$RPI_USER "$FIREFOX_PROFILE_DIR/user.js"
}

# 4. Полная установка
do_install() {
    echo "=========================================="
    echo " НАЧАЛО УСТАНОВКИ KIOSK MODE (FIREFOX)"
    echo "=========================================="
    
    read -p "Введите URL сайта: " INPUT_URL
    INPUT_URL=${INPUT_URL:-"https://google.com"}
    
    read -p "Введите ширину (1920): " INPUT_W
    INPUT_W=${INPUT_W:-1920}
    
    read -p "Введите высоту (1080): " INPUT_H
    INPUT_H=${INPUT_H:-1080}

    # Сохраняем конфиг
    update_config "$INPUT_URL" "$INPUT_W" "$INPUT_H"

    # Установка пакетов
    echo ">>> Обновление системы и установка Firefox ESR..."
    apt-get update -qq
    # Удаляем chromium, чтобы не мешал, ставим firefox
    apt-get install --no-install-recommends -y xserver-xorg-video-all xserver-xorg-input-all xserver-xorg-core xinit x11-xserver-utils unclutter firefox-esr ffmpeg libavcodec-extra

    # Настраиваем профиль Firefox
    setup_firefox_profile

    # Настройка автологина
    echo ">>> Настройка автологина..."
    raspi-config nonint do_boot_behaviour B2

    # Настройка .bash_profile
    BASH_PROFILE="$USER_HOME/.bash_profile"
    if [ ! -f "$BASH_PROFILE" ]; then touch "$BASH_PROFILE"; fi
    
    if ! grep -q "startx" "$BASH_PROFILE"; then
        echo ">>> Настройка автостарта X11..."
        cat <<EOF >> "$BASH_PROFILE"
# Kiosk autostart
if [ -z \$DISPLAY ] && [ \$(tty) = /dev/tty1 ]; then
    startx
fi
EOF
        chown $RPI_USER:$RPI_USER "$BASH_PROFILE"
    fi

    # Настройка .xinitrc (цикл запуска Firefox)
    XINITRC="$USER_HOME/.xinitrc"
    echo ">>> Создание скрипта запуска..."
    
    cat <<EOF > "$XINITRC"
#!/usr/bin/env sh
xset -dpms
xset s off
xset s noblank
unclutter &

# Регистрируем профиль в profiles.ini, если его там нет (костыль для первого запуска)
if [ ! -f "$USER_HOME/.mozilla/firefox/profiles.ini" ]; then
    mkdir -p "$USER_HOME/.mozilla/firefox"
    echo "[General]" > "$USER_HOME/.mozilla/firefox/profiles.ini"
    echo "StartWithLastProfile=1" >> "$USER_HOME/.mozilla/firefox/profiles.ini"
    echo "" >> "$USER_HOME/.mozilla/firefox/profiles.ini"
    echo "[Profile0]" >> "$USER_HOME/.mozilla/firefox/profiles.ini"
    echo "Name=kiosk" >> "$USER_HOME/.mozilla/firefox/profiles.ini"
    echo "IsRelative=1" >> "$USER_HOME/.mozilla/firefox/profiles.ini"
    echo "Path=kiosk.default" >> "$USER_HOME/.mozilla/firefox/profiles.ini"
    echo "Default=1" >> "$USER_HOME/.mozilla/firefox/profiles.ini"
fi

while true; do
    # Читаем конфиг
    if [ -f $CONFIG_FILE ]; then
        . $CONFIG_FILE
    else
        URL="https://google.com"
        WIDTH=1920
        HEIGHT=1080
    fi
    
    # Запуск Firefox
    # --kiosk: режим киоска
    # --width/height: размер окна (важно для старых мониторов)
    # -P kiosk: используем наш настроенный профиль с user.js
    
    /usr/bin/firefox-esr --kiosk \$URL \\
        --width \$WIDTH \\
        --height \$HEIGHT \\
        -P kiosk

    sleep 2
done
EOF
    chown $RPI_USER:$RPI_USER "$XINITRC"
    chmod +x "$XINITRC"

    # Настройка config.txt
    CONFIG_TXT="/boot/config.txt"
    [ ! -f "$CONFIG_TXT" ] && CONFIG_TXT="/boot/firmware/config.txt"
    
    if [ -f "$CONFIG_TXT" ]; then
        echo ">>> Проверка настроек HDMI..."
        if ! grep -q "disable_overscan=1" "$CONFIG_TXT"; then
             echo "disable_overscan=1" >> "$CONFIG_TXT"
        fi
        if ! grep -q "hdmi_force_hotplug=1" "$CONFIG_TXT"; then
             echo "hdmi_force_hotplug=1" >> "$CONFIG_TXT"
        fi
    fi

    echo ">>> Установка завершена!"
    read -p "Нажмите Enter чтобы вернуться в меню..."
}

# 4. Меню смены сайта
change_site() {
    if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi
    echo "Текущий сайт: $URL"
    read -p "Введите новый URL: " NEW_URL
    if [ ! -z "$NEW_URL" ]; then
        update_config "$NEW_URL" "$WIDTH" "$HEIGHT"
        echo "URL обновлен."
        reload_browser
    fi
    read -p "Нажмите Enter..."
}

# 5. Меню смены разрешения
change_res() {
    if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi
    echo "Текущее разрешение: ${WIDTH}x${HEIGHT}"
    read -p "Новая ширина: " NEW_W
    read -p "Новая высота: " NEW_H
    if [ ! -z "$NEW_W" ] && [ ! -z "$NEW_H" ]; then
        update_config "$URL" "$NEW_W" "$NEW_H"
        echo "Разрешение обновлено."
        reload_browser
    fi
    read -p "Нажмите Enter..."
}

# 6. Функция полной очистки кеша
clean_cache() {
    echo ">>> Остановка браузера..."
    pkill -f firefox-esr
    
    echo ">>> Очистка кеша..."
    # 1. Удаляем дисковый кеш (сами видео и картинки)
    # Используем wildcard (*), так как имя папки профиля может содержать случайные символы
    rm -rf "$USER_HOME/.cache/mozilla/firefox/"*kiosk.default*/cache2
    rm -rf "$USER_HOME/.cache/mozilla/firefox/"*kiosk.default*/startupCache
    rm -rf "$USER_HOME/.cache/mozilla/firefox/"*kiosk.default*/jumpListCache
    
    # 2. ВАЖНО: Мы НЕ удаляем LocalStorage ($USER_HOME/.mozilla/.../storage),
    # чтобы плеер не забыл последний плейлист, если сервер недоступен.
    
    echo ">>> Кеш успешно очищен!"
    sleep 1
    
    # Браузер сам перезапустится циклом в .xinitrc, но можно подтолкнуть
    # reload_browser # (эта функция у вас уже есть, можно вызвать её)
}

# --- ГЛАВНОЕ МЕНЮ ---
while true; do
    clear
    echo "=========================================="
    echo "           RPI KIOSK MANAGER              "
    echo "=========================================="
    echo "1. Установить Kiosk Mode (с нуля)"
    echo "2. Сменить ссылку на сайт"
    echo "3. Сменить разрешение экрана"
    echo "4. Принудительно перезагрузить браузер"
    echo "5. Перезагрузить Raspberry Pi"
    echo "6. Очистить кеш браузера"
    echo "0. Выход"
    echo "=========================================="
    read -p "Ваш выбор: " choice

    case $choice in
        1) do_install ;;
        2) change_site ;;
        3) change_res ;;
        4) reload_browser ;;
        5) reboot ;;
        6) clean_cache ;;
        0) exit 0 ;;
        *) echo "Неверный выбор"; sleep 1 ;;
    esac
done