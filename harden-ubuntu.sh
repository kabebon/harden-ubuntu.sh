#!/bin/bash
# =============================================================================
# harden-ubuntu.sh — безопасная начальная настройка Ubuntu-сервера
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Безопасная настройка сервера (SSH-ключ, BBR, fail2ban) ===${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите от root (sudo)${NC}"
    exit 1
fi

if ! test -t 0; then
    echo -e "${RED}Не запускайте через curl | bash — скачайте и запустите отдельно${NC}"
    exit 1
fi

ROLLBACK_LOG="/root/harden-rollback-$(date +%Y%m%d-%H%M%S).log"
SSHD_BACKUP=""
USER_CREATED=false
SUDOERS_FILE=""
UFW_WAS_ENABLED=false
KEY_DIR=""
SOCKET_OVERRIDE_CREATED=false

echo "Лог отката → $ROLLBACK_LOG" | tee -a "$ROLLBACK_LOG"

rollback() {
    echo -e "\n${RED}Откат изменений...${NC}" | tee -a "$ROLLBACK_LOG"

    [ -n "$KEY_DIR" ] && [ -d "$KEY_DIR" ] && rm -rf "$KEY_DIR" && echo "→ Ключи удалены"

    [ -n "$SSHD_BACKUP" ] && [ -f "$SSHD_BACKUP" ] && cp "$SSHD_BACKUP" /etc/ssh/sshd_config && \
        systemctl daemon-reload && systemctl restart ssh.socket 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null && \
        echo "→ sshd_config восстановлен"

    if $USER_CREATED && id "$NEW_USER" &>/dev/null; then
        deluser --remove-home "$NEW_USER" 2>/dev/null
        [ -n "$SUDOERS_FILE" ] && rm -f "$SUDOERS_FILE"
        echo "→ Пользователь $NEW_USER удалён"
    fi

    if $UFW_WAS_ENABLED; then
        ufw --force disable 2>/dev/null && echo "→ UFW отключён"
    fi

    if $SOCKET_OVERRIDE_CREATED; then
        rm -rf /etc/systemd/system/ssh.socket.d 2>/dev/null
        systemctl daemon-reload
        echo "→ ssh.socket override удалён"
    fi

    echo -e "${YELLOW}Откат завершён (частично). Проверьте систему!${NC}"
    exit 1
}

trap rollback INT ERR

# ────────────────────────────────────────────────
# Запросы
# ────────────────────────────────────────────────

echo -e "\n${YELLOW}Имя пользователя:${NC}"
read -r NEW_USER
NEW_USER=${NEW_USER:-admin}

if [[ ! "$NEW_USER" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
    echo -e "${RED}Недопустимое имя${NC}"
    exit 1
fi

if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}$NEW_USER уже существует — ключ перезапишется${NC}"
    read -r -p "Продолжить? [y/N]: " cont
    [[ "$cont" =~ ^[Yy]$ ]] || exit 0
else
    USER_CREATED=true
fi

echo -e "\n${YELLOW}Новый порт SSH:${NC}"
read -r NEW_PORT
NEW_PORT=${NEW_PORT:-2222}

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1024 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo -e "${RED}Неверный порт${NC}"
    exit 1
fi

# ────────────────────────────────────────────────
# Ключи + подтверждение
# ────────────────────────────────────────────────

echo -e "\n${GREEN}Генерируем ключи...${NC}"

KEY_DIR="/root/temp-ssh-key-$(date +%s)"
mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"

ssh-keygen -t ed25519 -f "$KEY_DIR/id_ed25519" -N "" -C "$NEW_USER@$(hostname)" >/dev/null 2>&1

PUB_KEY=$(cat "$KEY_DIR/id_ed25519.pub")
PRIV_KEY=$(cat "$KEY_DIR/id_ed25519")

echo -e "${YELLOW}┌───────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│                     ВАЖНО! СДЕЛАЙТЕ ЭТО СЕЙЧАС                 │${NC}"
echo -e "${YELLOW}│  Скопируйте приватный ключ ниже — он исчезнет после выполнения!  │${NC}"
echo -e "${YELLOW}└───────────────────────────────────────────────────────────────┘${NC}\n"

echo "$PRIV_KEY"

echo -e "\n${GREEN}Публичный ключ:${NC}"
echo "$PUB_KEY"

echo -e "\n${RED}Скопировали приватный ключ?${NC}"
read -r -p "Напишите yes для продолжения: " confirm
[[ "$confirm" == "yes" ]] || { echo "Не подтверждено"; rm -rf "$KEY_DIR"; exit 1; }

# ────────────────────────────────────────────────
# Настройка SSH
# ────────────────────────────────────────────────

SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$SSHD_BACKUP" 2>/dev/null

if $USER_CREATED; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    SUDOERS_FILE="/etc/sudoers.d/90-$NEW_USER"
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
fi

mkdir -p "/home/$NEW_USER/.ssh"
echo "$PUB_KEY" > "/home/$NEW_USER/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
chmod 700 "/home/$NEW_USER/.ssh"
chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"

sed -i "s/^#*Port.*/Port $NEW_PORT/" /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# ────────────────────────────────────────────────
# Обработка systemd socket activation (самое важное)
# ────────────────────────────────────────────────
echo -e "\n${YELLOW}Настраиваем прослушку порта $NEW_PORT...${NC}"

if systemctl is-active ssh.socket >/dev/null 2>&1; then
    echo "Обнаружен systemd socket activation (ssh.socket)"

    mkdir -p /etc/systemd/system/ssh.socket.d
    cat <<EOT > /etc/systemd/system/ssh.socket.d/port.conf
[Socket]
ListenStream=
ListenStream=$NEW_PORT
EOT

    SOCKET_OVERRIDE_CREATED=true
    systemctl daemon-reload
    systemctl restart ssh.socket
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

    echo -e "${GREEN}✓ ssh.socket переконфигурирован на порт $NEW_PORT${NC}"
else
    echo "Классический режим (без socket) — просто меняем sshd_config"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    echo -e "${GREEN}✓ sshd перезапущен${NC}"
fi

# Проверка, слушает ли нужный порт
sleep 3
if ss -tulnp | grep -q ":$NEW_PORT"; then
    echo -e "${GREEN}✓ Порт $NEW_PORT успешно прослушивается${NC}"
else
    echo -e "${RED}✗ Порт $NEW_PORT НЕ прослушивается!${NC}"
    echo "Проверьте вручную: ss -tulnp | grep ssh"
    echo "Возможно, нужна перезагрузка сервера или ручная правка ssh.socket"
fi

# ────────────────────────────────────────────────
# Остальное (UFW, BBR, fail2ban)
# ────────────────────────────────────────────────

if ufw status | grep -q "Status: inactive"; then
    UFW_WAS_ENABLED=true
fi

ufw allow "$NEW_PORT"/tcp 2>/dev/null || true
ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
ufw --force enable 2>/dev/null || true

echo -e "\n${YELLOW}BBR...${NC}"
if sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr; then
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
    echo "BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"
else
    echo "BBR недоступен"
fi

echo -e "\n${YELLOW}fail2ban...${NC}"
apt update -qq && apt install -y fail2ban

cat <<EOT > /etc/fail2ban/jail.local
[sshd]
enabled   = true
port      = $NEW_PORT
logpath   = %(sshd_log)s
backend   = %(sshd_backend)s
maxretry  = 5
bantime   = 3600
findtime  = 600
EOT

systemctl restart fail2ban 2>/dev/null
fail2ban-client reload 2>/dev/null

# ────────────────────────────────────────────────
# Финал
# ────────────────────────────────────────────────

echo -e "\n${GREEN}============================================================${NC}"
echo "Настройка завершена!"
echo ""
echo "Пользователь: $NEW_USER"
echo "Порт:        $NEW_PORT"
echo "Подключение: ssh -p $NEW_PORT $NEW_USER@$(curl -s ifconfig.me || echo 'ваш_IP')"
echo ""
echo -e "${YELLOW}ОБЯЗАТЕЛЬНО проверьте новый вход в отдельном терминале!${NC}"
echo -e "${GREEN}============================================================${NC}"

rm -rf "$KEY_DIR"
