#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Запустите скрипт с sudo: sudo ./dietpi_kiosk_manager.sh"
  exit 1
fi

if id "dietpi" &>/dev/null; then
    RPI_USER="dietpi"
else
    RPI_USER="root"
fi

USER_HOME=$(eval echo "~$RPI_USER")
USER_ID=$(id -u "$RPI_USER")

CONFIG_FILE="$USER_HOME/kiosk.conf"

reload_browser() {
    echo "Перезагружаю браузер..."
    systemctl restart kiosk.service
}

update_config() {
    cat <<EOF > "$CONFIG_FILE"
URL="$1"
WIDTH=$2
HEIGHT=$3
EOF
    chown $RPI_USER:$RPI_USER "$CONFIG_FILE"
}

setup_autologin() {
    echo ">>> Настройка автологина..."

    if command -v dietpi-autostart &>/dev/null; then
        echo 14 > /boot/dietpi/.dietpi-autostart_index 2>/dev/null || dietpi-autostart 14
        mkdir -p /var/lib/dietpi/dietpi-autostart
        cat <<'AUTOSTART' > /var/lib/dietpi/dietpi-autostart/custom.sh
#!/bin/bash
exit 0
AUTOSTART
        chmod +x /var/lib/dietpi/dietpi-autostart/custom.sh
    fi

    mkdir -p /etc/systemd/system/getty@tty1.service.d
    cat <<GETTY > /etc/systemd/system/getty@tty1.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $RPI_USER --noclear %I \$TERM
GETTY
}

do_install() {
    echo "=========================================="
    echo " УСТАНОВКА KIOSK MODE (Cage + Cog)"
    echo " Пользователь: $RPI_USER"
    echo "=========================================="

    CURRENT_HOSTNAME=$(hostname)
    read -p "Имя устройства / hostname (текущее: $CURRENT_HOSTNAME): " INPUT_HOSTNAME
    INPUT_HOSTNAME=${INPUT_HOSTNAME:-$CURRENT_HOSTNAME}

    read -p "URL сайта (по умолчанию https://google.com): " INPUT_URL
    INPUT_URL=${INPUT_URL:-"https://google.com"}

    read -p "Ширина экрана (по умолчанию 1920): " INPUT_W
    INPUT_W=${INPUT_W:-1920}

    read -p "Высота экрана (по умолчанию 1080): " INPUT_H
    INPUT_H=${INPUT_H:-1080}

    update_config "$INPUT_URL" "$INPUT_W" "$INPUT_H"

    echo ">>> Установка Cage, Cog и зависимостей..."
    apt-get update -qq
    apt-get install --no-install-recommends -y \
        cage \
        cog \
        dbus \
        dbus-user-session \
        sqlite3 \
        glib-networking \
        libwpewebkit-2.0-1 \
        libwpebackend-fdo-1.0-1 \
        gstreamer1.0-libav \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-ugly \
        socat \
        avahi-daemon

    echo ">>> Настройка hostname: ${INPUT_HOSTNAME}.local ..."
    hostnamectl set-hostname "$INPUT_HOSTNAME"
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$INPUT_HOSTNAME/" /etc/hosts
    grep -q "127.0.1.1" /etc/hosts || echo "127.0.1.1	$INPUT_HOSTNAME" >> /etc/hosts
    systemctl enable avahi-daemon
    systemctl restart avahi-daemon
    echo ">>> Устройство доступно как: ${INPUT_HOSTNAME}.local"

    echo ">>> Настройка прав пользователя..."
    usermod -aG video,render,tty,input $RPI_USER

    setup_autologin

    echo ">>> Настройка udev (скрытие курсора)..."
    cat <<'UDEV' > /etc/udev/rules.d/99-hide-hdmi-input.rules
SUBSYSTEM=="input", ATTRS{name}=="vc4-hdmi-0", ENV{LIBINPUT_IGNORE_DEVICE}="1"
SUBSYSTEM=="input", ATTRS{name}=="vc4-hdmi-1", ENV{LIBINPUT_IGNORE_DEVICE}="1"
UDEV
    udevadm control --reload-rules
    udevadm trigger

    echo ">>> Создание скрипта запуска..."
    cat <<'SCRIPT' > /usr/local/bin/kiosk-launch.sh
#!/bin/bash
if [ -f "$HOME/kiosk.conf" ]; then
    source "$HOME/kiosk.conf"
else
    URL="https://google.com"
fi

export XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CONFIG_HOME="$HOME/.config"

# Создаём директории для persistent storage WPE WebKit
mkdir -p "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

# Извлекаем host:port из URL для локального проксирования
REMOTE_HOST=$(echo "$URL" | sed -E 's|^https?://([^/]+).*|\1|')
LOCAL_PORT=$(echo "$REMOTE_HOST" | grep -oP ':\K[0-9]+' || echo "80")
URL_PATH=$(echo "$URL" | sed -E 's|^https?://[^/]+(/.*)|\1|')

# Запускаем socat: localhost:LOCAL_PORT -> REMOTE_HOST
# Service Workers работают на localhost без HTTPS
socat TCP-LISTEN:${LOCAL_PORT},fork,reuseaddr TCP:${REMOTE_HOST} &
SOCAT_PID=$!
sleep 1

# Подменяем URL на localhost
LOCAL_URL="http://localhost:${LOCAL_PORT}${URL_PATH}"

# Ждём готовность файловой системы после загрузки
sync

# Убиваем socat при завершении
trap "kill $SOCAT_PID 2>/dev/null" EXIT

exec dbus-run-session cage -d -m last -- cog \
    --platform=wl \
    --cookie-jar=sqlite:"$XDG_DATA_HOME/cog-cookies.db" \
    --enable-page-cache=true \
    --enable-offline-web-application-cache=true \
    --enable-html5-local-storage=true \
    --enable-html5-database=true \
    --features="+StorageAPI,+StorageAPIEstimate,+CacheAPI,+ServiceWorkers" \
    "$LOCAL_URL"
SCRIPT
    chmod +x /usr/local/bin/kiosk-launch.sh

    echo ">>> Создание systemd-сервиса..."
    cat <<EOF > /etc/systemd/system/kiosk.service
[Unit]
Description=Kiosk Browser (Cage + Cog)
After=systemd-logind.service

[Service]
User=$RPI_USER
Group=$RPI_USER
SupplementaryGroups=video render input tty
PAMName=login
Type=simple

TimeoutStopSec=10

ExecStartPre=/bin/bash -c 'mkdir -p /run/user/$USER_ID && chown $RPI_USER:$RPI_USER /run/user/$USER_ID && chmod 700 /run/user/$USER_ID'
ExecStartPre=-/bin/bash -c 'rm -f /run/user/$USER_ID/wayland-*'

ExecStart=/usr/local/bin/kiosk-launch.sh
Environment=XDG_RUNTIME_DIR=/run/user/$USER_ID
Environment=WLR_LIBINPUT_NO_DEVICES=1

ExecStop=/bin/bash -c 'killall -TERM cog || true'
ExecStopPost=/bin/sleep 1

Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    echo ">>> Настройка директорий кеша..."
    mkdir -p "$USER_HOME/.cache/cog" "$USER_HOME/.local/share/cog"
    mkdir -p "$USER_HOME/.cache/com.igalia.Cog" "$USER_HOME/.local/share/com.igalia.Cog"
    mkdir -p "$USER_HOME/.cache/wpe" "$USER_HOME/.local/share/wpe"
    chown -R $RPI_USER:$RPI_USER "$USER_HOME/.cache" "$USER_HOME/.local/share"

    echo ">>> Активация сервиса..."
    systemctl daemon-reload
    systemctl enable kiosk.service

    echo ""
    echo "==============================================================="
    echo " УСТАНОВКА ЗАВЕРШЕНА!"
    echo "==============================================================="
    echo " Kiosk запустится автоматически после перезагрузки."
    echo ""
    echo " ВАЖНО: Убедитесь что в /boot/config.txt есть:"
    echo "   dtoverlay=vc4-kms-v3d"
    echo "   gpu_mem=128 (или 256 для тяжелых видео)"
    echo "==============================================================="
    read -p "Перезагрузить сейчас? (y/N): " DO_REBOOT
    if [[ "$DO_REBOOT" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

change_site() {
    if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi
    echo "Текущий сайт: $URL"
    read -p "Новый URL: " NEW_URL
    if [ ! -z "$NEW_URL" ]; then
        update_config "$NEW_URL" "$WIDTH" "$HEIGHT"
        echo "URL обновлён."
        reload_browser
    fi
    read -p "Нажмите Enter..."
}

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

clean_cache() {
    echo ">>> Остановка браузера..."
    systemctl stop kiosk.service

    echo ">>> Очистка кеша..."
    rm -rf "$USER_HOME/.cache/cog" "$USER_HOME/.cache/com.igalia.Cog" "$USER_HOME/.cache/wpe"

    echo "Очистить данные сайтов (LocalStorage, IndexedDB, Service Workers)?"
    echo "ВНИМАНИЕ: Офлайн-данные плеера будут удалены!"
    read -p "Очистить? (y/N): " CLEAN_DATA
    if [[ "$CLEAN_DATA" =~ ^[Yy]$ ]]; then
        rm -rf "$USER_HOME/.local/share/cog" "$USER_HOME/.local/share/com.igalia.Cog" "$USER_HOME/.local/share/wpe"
        echo ">>> Данные сайтов очищены."
    fi

    echo ">>> Перезапуск браузера..."
    systemctl start kiosk.service
}

show_logs() {
    echo "=== Логи Kiosk ==="
    journalctl -u kiosk.service --no-pager -n 30
    echo ""
    read -p "Нажмите Enter..."
}

show_info() {
    echo "=========================================="
    echo " ИНФОРМАЦИЯ О СИСТЕМЕ"
    echo "=========================================="
    echo "Пользователь: $RPI_USER (UID=$USER_ID)"
    echo ""
    systemctl is-active --quiet kiosk.service && echo "Kiosk: РАБОТАЕТ" || echo "Kiosk: ОСТАНОВЛЕН"
    echo ""
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo "URL: $URL"
        echo "Разрешение: ${WIDTH}x${HEIGHT}"
    fi
    echo ""
    free -h | head -2
    echo ""
    df -h / | tail -1
    echo ""
    read -p "Нажмите Enter..."
}

while true; do
    clear
    echo "=========================================="
    echo "    DIETPI KIOSK MANAGER (Cage + Cog)     "
    echo "           [User: $RPI_USER]              "
    echo "=========================================="
    echo "1. Установить Kiosk Mode (с нуля)"
    echo "2. Сменить ссылку на сайт"
    echo "3. Сменить разрешение экрана"
    echo "4. Перезагрузить браузер"
    echo "5. Перезагрузить Raspberry Pi"
    echo "6. Очистить кеш браузера"
    echo "7. Показать логи"
    echo "8. Информация о системе"
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
        7) show_logs ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo "Неверный выбор"; sleep 1 ;;
    esac
done