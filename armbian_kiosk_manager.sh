#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Запустите скрипт с правами суперпользователя: sudo ./armbian_kiosk_manager.sh"
  exit 1
fi

# Определяем пользователя (если запущен через sudo обычным пользователем, используем его, иначе root)
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    APP_USER="$SUDO_USER"
else
    APP_USER="root"
fi

USER_HOME=$(getent passwd "$APP_USER" | cut -d: -f6)
USER_ID=$(id -u "$APP_USER")

CONFIG_FILE="$USER_HOME/kiosk.conf"

reload_browser() {
    echo "Перезагружаю киоск..."
    systemctl restart kiosk.service
}

update_config() {
    cat <<EOF > "$CONFIG_FILE"
URL="$1"
WIDTH=$2
HEIGHT=$3
EOF
    chown $APP_USER:$APP_USER "$CONFIG_FILE"
}

do_install() {
    echo "=========================================="
    echo " УСТАНОВКА KIOSK MODE (Weston + Chromium) "
    echo " Пользователь: $APP_USER"
    echo " Платформа: Armbian (RK3318 / Mali-450)"
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

    echo ">>> Обновление списков пакетов и установка зависимостей..."
    apt-get update -qq
    apt-get install --no-install-recommends -y \
        weston \
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

    echo ">>> Настройка прав пользователя..."
    usermod -aG video,render,tty,input $APP_USER

    echo ">>> Настройка конфигурации Weston..."
    mkdir -p "$USER_HOME/.config"
    cat <<EOF > "$USER_HOME/.config/weston.ini"
[core]
shell=kiosk-shell.so

[autolaunch]
path=/usr/local/bin/kiosk-launch.sh
EOF
    chown -R $APP_USER:$APP_USER "$USER_HOME/.config"

    echo ">>> Настройка udev (скрытие курсора мыши для киоска)..."
    cat <<'UDEV' > /etc/udev/rules.d/99-hide-mouse.rules
SUBSYSTEM=="input", ATTRS{name}=="*Mouse*", ENV{LIBINPUT_IGNORE_DEVICE}="1"
UDEV
    udevadm control --reload-rules
    udevadm trigger

    echo ">>> Создание скрипта запуска Chromium..."
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

if [[ "$URL" == http://* ]]; then
    REMOTE_HOST_PORT=$(echo "$URL" | sed -E 's|^http://([^/]+).*|\1|')
    REMOTE_HOST=$(echo "$REMOTE_HOST_PORT" | cut -d: -f1)
    LOCAL_PORT=$(echo "$REMOTE_HOST_PORT" | grep -oP ':\K[0-9]+' || echo "80")
    URL_PATH=$(echo "$URL" | sed -E 's|^http://[^/]+(/.*)?|\1|')

    socat TCP-LISTEN:${LOCAL_PORT},fork,reuseaddr TCP:${REMOTE_HOST}:${LOCAL_PORT} &
    SOCAT_PID=$!
    sleep 1

    LOCAL_URL="http://localhost:${LOCAL_PORT}${URL_PATH}"
    trap "kill $SOCAT_PID 2>/dev/null" EXIT
else
    LOCAL_URL="$URL"
fi

sync

rm -f "$XDG_CONFIG_HOME/chromium/SingletonLock"
rm -f "$XDG_CONFIG_HOME/chromium/SingletonSocket"

# Запуск Chromium с жестко отключенным GPU для стабильности Mali-450
exec chromium \
    --no-sandbox \
    --kiosk \
    --enable-features=UseOzonePlatform \
    --ozone-platform=wayland \
    --disable-es3-gl-context \
    --disable-gpu \
    --disable-gpu-compositing \
    --no-first-run \
    --disable-first-run-ui \
    --noerrdialogs \
    --disable-hang-monitor \
    --disable-dev-shm-usage \
    --no-default-browser-check \
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
    --allow-insecure-localhost \
    --allow-running-insecure-content \
    --ignore-certificate-errors \
    --password-store=basic \
	--disk-cache-dir="$XDG_CACHE_HOME/chromium" \
    --disk-cache-size=104857600 \
    --disable-features=Translate,TranslateUI,MediaRouter,GlobalMediaControls \
    --js-flags="--max-old-space-size=384 --initial-old-space-size=128" \
    "$LOCAL_URL"
SCRIPT
    chmod +x /usr/local/bin/kiosk-launch.sh

    echo ">>> Создание systemd-сервиса (Weston)..."
    cat <<EOF > /etc/systemd/system/kiosk.service
[Unit]
Description=Weston Kiosk Mode
After=systemd-user-sessions.service network-online.target
Wants=network-online.target

[Service]
User=$APP_USER
Group=$APP_USER
SupplementaryGroups=video render input tty
Environment=HOME=$USER_HOME
Environment=XDG_CONFIG_HOME=$USER_HOME/.config
Environment=XDG_RUNTIME_DIR=/run/user/$USER_ID
Environment=WLR_RENDERER=pixman
Environment=WESTON_LAUNCHER_DIRECT=1
TTYPath=/dev/tty7
PAMName=login
StandardInput=tty
StandardOutput=tty
TimeoutStopSec=10
ExecStartPre=/bin/bash -c 'mkdir -p /run/user/$USER_ID && chown $APP_USER:$APP_USER /run/user/$USER_ID && chmod 700 /run/user/$USER_ID'
ExecStartPre=/bin/bash -c 'mkdir -p $USER_HOME/.cache/chromium $USER_HOME/.config/chromium && chown -R $APP_USER:$APP_USER $USER_HOME/.cache $USER_HOME/.config'
ExecStartPre=-/bin/bash -c 'rm -f $USER_HOME/.config/chromium/Singleton*'
ExecStartPre=-/bin/bash -c 'rm -f /run/user/$USER_ID/wayland-*'
ExecStartPre=-/usr/bin/killall -9 chromium weston 2>/dev/null
ExecStart=/usr/bin/dbus-run-session /usr/bin/weston --tty=7 --seat=seat0 --backend=drm-backend.so
ExecStop=/bin/bash -c 'killall -TERM chromium || true'
ExecStopPost=/bin/sleep 1
Restart=always
RestartSec=3
MemoryMax=750M
MemorySwapMax=512M
OOMScoreAdj=500

[Install]
WantedBy=graphical.target
EOF

    echo ">>> Настройка защиты от зависания при OOM..."
    cat <<'SYSCTL' > /etc/sysctl.d/99-kiosk-oom.conf
vm.panic_on_oom=1
kernel.panic=10
vm.swappiness=80
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
    chown -R $APP_USER:$APP_USER "$USER_HOME/.cache" "$USER_HOME/.config"

    echo ">>> Создание watchdog для восстановления после краша таба..."
    cat <<'WATCHDOG' > /usr/local/bin/kiosk-watchdog.sh
#!/bin/bash
CHECK_INTERVAL=10
STARTUP_DELAY=30
DEAD_THRESHOLD=3

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

    echo ">>> Отключение графических менеджеров входа (lightdm/gdm3)..."
    systemctl disable lightdm 2>/dev/null || true
    systemctl disable gdm3 2>/dev/null || true

    echo ">>> Активация сервисов..."
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
        echo "Параметры сохранены."
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
    read -p "Очистить? (y/N): " CLEAN_DATA
    if [[ "$CLEAN_DATA" =~ ^[Yy]$ ]]; then
        rm -rf "$USER_HOME/.config/chromium"
        echo ">>> Данные сайтов очищены."
    fi

    echo ">>> Перезапуск браузера..."
    systemctl start kiosk.service
}

show_logs() {
    echo "=== Логи Kiosk (Weston) ==="
    journalctl -u kiosk.service --no-pager -n 30
    echo ""
    read -p "Нажмите Enter..."
}

show_info() {
    echo "=========================================="
    echo " ИНФОРМАЦИЯ О СИСТЕМЕ"
    echo "=========================================="
    echo "Пользователь: $APP_USER (UID=$USER_ID)"
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
    echo "   ARMBIAN KIOSK MANAGER (Weston+Chromium)"
    echo "           [User: $APP_USER]              "
    echo "=========================================="
    echo "1. Установить Kiosk Mode (с нуля)"
    echo "2. Сменить ссылку на сайт"
    echo "3. Изменить параметры экрана"
    echo "4. Перезапустить браузер"
    echo "5. Перезагрузить приставку"
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
