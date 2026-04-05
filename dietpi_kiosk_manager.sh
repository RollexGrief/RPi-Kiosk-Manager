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
    echo " УСТАНОВКА KIOSK MODE (Cage + Chromium)"
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

    echo ">>> Установка Cage, Chromium и зависимостей..."
    apt-get update -qq
    apt-get install --no-install-recommends -y \
        cage \
        chromium \
        dbus \
        dbus-user-session \
        socat \
        curl \
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

mkdir -p "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

# Проверяем протокол: используем socat только для HTTP
if [[ "$URL" == http://* ]]; then
    # Извлекаем host, port и путь
    REMOTE_HOST_PORT=$(echo "$URL" | sed -E 's|^http://([^/]+).*|\1|')
    REMOTE_HOST=$(echo "$REMOTE_HOST_PORT" | cut -d: -f1)
    LOCAL_PORT=$(echo "$REMOTE_HOST_PORT" | grep -oP ':\K[0-9]+' || echo "80")
    URL_PATH=$(echo "$URL" | sed -E 's|^http://[^/]+(/.*)?|\1|')

    # Запускаем socat: localhost:LOCAL_PORT -> REMOTE_HOST:LOCAL_PORT
    socat TCP-LISTEN:${LOCAL_PORT},fork,reuseaddr TCP:${REMOTE_HOST}:${LOCAL_PORT} &
    SOCAT_PID=$!
    sleep 1

    LOCAL_URL="http://localhost:${LOCAL_PORT}${URL_PATH}"
    trap "kill $SOCAT_PID 2>/dev/null" EXIT
else
    LOCAL_URL="$URL"
fi

sync

exec dbus-run-session cage -d -m last -- chromium \
    --kiosk \
    --no-sandbox \
    --no-first-run \
    --disable-first-run-ui \
    --noerrdialogs \
    --disable-hang-monitor \
    --disable-dev-shm-usage \
    --no-default-browser-check \
    --no-memcheck \
    --disable-remote-playback-api \
    --disable-notifications \
    --disable-default-apps \
    --disable-background-networking \
    --disable-component-update \
    --disable-domain-reliability \
    --disable-breakpad \
    --disable-sync \
    --disable-client-side-phishing-detection \
    --disable-extensions \
    --no-pings \
    --deny-permission-prompts \
    --disable-background-timer-throttling \
    --disable-renderer-backgrounding \
    --disable-prompt-on-repost \
    --disable-pinch \
    --hide-scrollbars \
    --autoplay-policy=no-user-gesture-required \
    --ozone-platform=wayland \
    --allow-insecure-localhost \
    --allow-running-insecure-content \
    --ignore-certificate-errors \
    --password-store=basic \
    --use-gl=egl \
    --disk-cache-size=52428800 \
    --enable-features=VaapiVideoDecoder \
    --disable-features=Translate,TranslateUI,MediaRouter,GlobalMediaControls,MediaRemoting,OptimizationHints,UseChromeOSDirectVideoDecoder \
    --js-flags="--max-old-space-size=384 --initial-old-space-size=128" \
    --remote-debugging-port=9222 \
    --remote-debugging-address=127.0.0.1 \
    "$LOCAL_URL"
SCRIPT
    chmod +x /usr/local/bin/kiosk-launch.sh

    echo ">>> Создание systemd-сервиса..."
    cat <<EOF > /etc/systemd/system/kiosk.service
[Unit]
Description=Kiosk Browser (Cage + Chromium)
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
#ExecStartPre=-/bin/bash -c 'rm -rf $USER_HOME/.cache/chromium/Default/Cache $USER_HOME/.cache/chromium/Default/Code\ Cache $USER_HOME/.cache/chromium/Default/GPUCache'

ExecStart=/usr/local/bin/kiosk-launch.sh
Environment=XDG_RUNTIME_DIR=/run/user/$USER_ID
Environment=WLR_LIBINPUT_NO_DEVICES=1

ExecStop=/bin/bash -c 'killall -TERM chromium || true'
ExecStopPost=/bin/sleep 1

Restart=always
RestartSec=3

MemoryMax=700M
MemorySwapMax=512M
OOMScoreAdj=500

[Install]
WantedBy=multi-user.target
EOF

    echo ">>> Настройка swap (защита от OOM при тяжёлых видео)..."
    # DietPi по умолчанию отключает swap. Включаем zram-swap как компромисс
    # (не изнашивает SD-карту, работает в RAM со сжатием)
    if command -v dietpi-config &>/dev/null; then
        # zram-swap через DietPi dietpi.txt или вручную
        if ! swapon --show | grep -q zram; then
            apt-get install --no-install-recommends -y zram-tools 2>/dev/null || true
            if command -v zramswap &>/dev/null; then
                echo "ALGO=lz4" > /etc/default/zramswap
                echo "PERCENT=50" >> /etc/default/zramswap
                systemctl enable zramswap
                systemctl start zramswap
                echo ">>> zram-swap включён (25% RAM, сжатие lz4)"
            fi
        else
            echo ">>> swap уже активен, пропускаем"
        fi
    fi

    echo ">>> Настройка защиты от зависания при OOM..."
    cat <<'SYSCTL' > /etc/sysctl.d/99-kiosk-oom.conf
# При нехватке памяти — перезагрузка вместо зависания
vm.panic_on_oom=1
kernel.panic=10

# Агрессивный swap: начинать использовать zram раньше
vm.swappiness=80

# Уменьшить кеш файловой системы в пользу приложений
vm.vfs_cache_pressure=200
SYSCTL
    sysctl -p /etc/sysctl.d/99-kiosk-oom.conf

    echo ">>> Настройка политик Chromium..."
    mkdir -p /etc/chromium/policies/managed
    cat <<'POLICY' > /etc/chromium/policies/managed/kiosk.json
{
    "TranslateEnabled": false,
    "CommandLineFlagSecurityWarningsEnabled": false,
    "DefaultNotificationsSetting": 2,
    "BrowserSignin": 0,
    "SyncDisabled": true,
    "MetricsReportingEnabled": false,
    "EnableMediaRouter": false,
    "AutofillAddressEnabled": false,
    "AutofillCreditCardEnabled": false,
    "PasswordManagerEnabled": false
}
POLICY

    echo ">>> Настройка директорий кеша..."
    mkdir -p "$USER_HOME/.cache/chromium" "$USER_HOME/.config/chromium"
    chown -R $RPI_USER:$RPI_USER "$USER_HOME/.cache" "$USER_HOME/.config"

    echo ">>> Создание watchdog для восстановления после краша таба..."
    cat <<'WATCHDOG' > /usr/local/bin/kiosk-watchdog.sh
#!/bin/bash
# Детектирует OOM-краш renderer по отсутствию процесса --type=renderer
# Когда renderer убит OOM — браузер жив, но renderer-процесса нет

CHECK_INTERVAL=10
STARTUP_DELAY=30
DEAD_THRESHOLD=3  # 3 проверки × 10с = 30с без renderer → рестарт

sleep $STARTUP_DELAY

while true; do
    sleep $CHECK_INTERVAL

    if ! systemctl is-active --quiet kiosk.service; then
        sleep $STARTUP_DELAY
        continue
    fi

    BROWSER=$(pgrep -f '/usr/lib/chromium/chromium' 2>/dev/null | wc -l)
    RENDERER=$(pgrep -f 'chromium.*--type=renderer' 2>/dev/null | wc -l)

    if [ "${BROWSER}" -gt 0 ] && [ "${RENDERER}" -eq 0 ]; then
        DEAD_COUNT=$((DEAD_COUNT + 1))
        logger -t kiosk-watchdog "Нет renderer (${DEAD_COUNT}/${DEAD_THRESHOLD}), RAM: $(free -m | awk '/Mem:/{print $3}')MB used"
    else
        DEAD_COUNT=0
    fi

    if [ "${DEAD_COUNT:-0}" -ge "$DEAD_THRESHOLD" ]; then
        logger -t kiosk-watchdog "Renderer мёртв — перезапускаю kiosk.service"
        systemctl restart kiosk.service
        DEAD_COUNT=0
        sleep $STARTUP_DELAY
    fi
done
WATCHDOG
    chmod +x /usr/local/bin/kiosk-watchdog.sh

    cat <<'WSERVICE' > /etc/systemd/system/kiosk-watchdog.service
[Unit]
Description=Kiosk Watchdog (auto-restart on renderer crash)
After=kiosk.service
BindsTo=kiosk.service

[Service]
Type=simple
ExecStart=/usr/local/bin/kiosk-watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
WSERVICE

    echo ">>> Создание таймера ночного перезапуска..."
    cat <<'TIMER' > /etc/systemd/system/kiosk-restart.timer
[Unit]
Description=Ночной перезапуск Kiosk для освобождения памяти

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    cat <<'TSERVICE' > /etc/systemd/system/kiosk-restart.service
[Unit]
Description=Перезапуск Kiosk

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart kiosk.service
TSERVICE

    echo ">>> Активация сервиса..."
    systemctl daemon-reload
    systemctl enable kiosk.service
    systemctl enable kiosk-watchdog.service
    systemctl enable kiosk-restart.timer
    systemctl start kiosk-restart.timer

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
    rm -rf "$USER_HOME/.cache/chromium"

    echo "Очистить данные сайтов (LocalStorage, IndexedDB, Service Workers)?"
    echo "ВНИМАНИЕ: Офлайн-данные плеера будут удалены!"
    read -p "Очистить? (y/N): " CLEAN_DATA
    if [[ "$CLEAN_DATA" =~ ^[Yy]$ ]]; then
        rm -rf "$USER_HOME/.config/chromium"
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
    echo "  DIETPI KIOSK MANAGER (Cage + Chromium)  "
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