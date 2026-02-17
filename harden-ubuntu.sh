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

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите от root (sudo)${NC}"
    exit 1
fi

# Защита от curl | bash
if ! test -t 0; then
    echo -e "${RED}Не запускайте через curl | bash — скачайте и запустите отдельно${NC}"
    exit 1
fi

# Переменные для отката
ROLLBACK_LOG="/root/harden-rollback-$(date +%Y%m%d-%H%M%S).log"
SSHD_BACKUP=""
USER_CREATED=false
SUDOERS_FILE=""
UFW_WAS_ENABLED=false
KEY_DIR=""
SOCKET_OVERRIDE_CREATED=false

echo "Лог отката будет сохранён в: $ROLLBACK_LOG" | tee -a "$ROLLBACK_LOG"

rollback() {
    echo -e "\n${RED}Откат изменений...${NC}" | tee -a "$ROLLBACK_LOG"

    [ -n "$KEY_DIR" ] && [ -d "$KEY_DIR" ] && rm -rf "$KEY_DIR" && echo "→ Ключи удалены" | tee -a "$ROLLBACK_LOG"

    [ -n "$SSHD_BACKUP" ] && [ -f "$SSHD_BACKUP" ] && \
        cp "$SSHD_BACKUP" /etc/ssh/sshd_config && \
        systemctl daemon-reload && \
        systemctl restart ssh.socket 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null && \
        echo "→ sshd_config восстановлен" | tee -a "$ROLLBACK_LOG"

    if $USER_CREATED && id "$NEW_USER" &>/dev/null; then
        deluser --remove-home "$NEW_USER" 2>/dev/null
        [ -n "$SUDOERS_FILE" ] && rm -f "$SUDOERS_FILE" 2>/dev/null
        echo "→ Пользователь $NEW_USER удалён" | tee -a "$ROLLBACK_LOG"
    fi

    if $UFW_WAS_ENABLED; then
        ufw --force disable 2>/dev/null && echo "→ UFW отключён" | tee -a "$ROLLBACK_LOG"
    fi

    if $SOCKET_OVERRIDE_CREATED; then
        rm -rf /etc/systemd/system/ssh.socket.d 2>/dev/null
        systemctl daemon-reload
        echo "→ ssh.socket override удалён" | tee -a "$ROLLBACK_LOG"
    fi

    echo -e "${YELLOW}Откат завершён (частично). Проверьте систему!${NC}" | tee -a "$ROLLBACK_LOG"
    exit 1
}

trap rollback INT

# ────────────────────────────────────────────────
# Запросы
# ────────────────────────────────────────────────

echo -e "\n${YELLOW}Введите имя нового пользователя (только a-z, 0-9, _, -)${NC}"
read -r -p "Имя пользователя: " NEW_USER
NEW_USER=${NEW_USER:-admin}

if [[ ! "$NEW_USER" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
    echo -e "${RED}Недопустимое имя${NC}"
    exit 1
fi

if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}Пользователь $NEW_USER уже существует — ключ перезапишется${NC}"
    read -r -p "Продолжить? [y/N]: " cont
    [[ "$cont" =~ ^[Yy]$ ]] || exit 0
else
    USER_CREATED=true
fi

echo -e "\n${YELLOW}Новый порт SSH (рекомендуется >1024, не 22)${NC}"
read -r -p "Новый порт SSH: " NEW_PORT
NEW_PORT=${NEW_PORT:-2222}

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1024 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo -e "${RED}Неверный порт${NC}"
    exit 1
fi

# ────────────────────────────────────────────────
# Генерация ключей
# ────────────────────────────────────────────────

echo -e "\n${GREEN}Генерируем пару ed25519 ключей...${NC}\n"

KEY_DIR="/root/temp-ssh-key-$(date +%s)"
mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"

ssh-keygen -t ed25519 -f "$KEY_DIR/id_ed25519" -N "" -C "$NEW_USER@$(hostname)-$(date +%Y%m%d)" >/dev/null 2>&1

PUB_KEY=$(cat "$KEY_DIR/id_ed25519.pub")
PRIV_KEY=$(cat "$KEY_DIR/id_ed25519")

echo -e "${YELLOW}┌───────────────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│                     ВАЖНО! СДЕЛАЙТЕ ЭТО СЕЙЧАС                 │${NC}"
echo -e "${YELLOW}│  Скопируйте приватный ключ ниже — он исчезнет после выполнения!  │${NC}"
echo -e "${YELLOW}└───────────────────────────────────────────────────────────────┘${NC}\n"

echo "$PRIV_KEY"
echo ""

echo -e "${GREEN}Публичный ключ (будет добавлен):${NC}"
echo "$PUB_KEY"
echo ""

echo -e "${RED}Скопировали приватный ключ в безопасное место?${NC}"
read -r -p "Напишите yes и нажмите Enter для продолжения: " confirm

if [[ "$confirm" != "yes" ]]; then
    echo -e "${RED}Копирование не подтверждено. Выход без изменений.${NC}"
    rm -rf "$KEY_DIR"
    exit 1
fi

echo -e "${GREEN}Подтверждение получено. Продолжаем...${NC}\n"

# ────────────────────────────────────────────────
# Опасная часть
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
# UFW
# ────────────────────────────────────────────────
if ufw status | grep -q "Status: inactive"; then
    UFW_WAS_ENABLED=true
fi

ufw allow "$NEW_PORT"/tcp 2>/dev/null || true
ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
ufw --force enable 2>/dev/null || true

# ────────────────────────────────────────────────
# BBR
# ────────────────────────────────────────────────
echo -e "\n${YELLOW}Настройка BBR...${NC}"
if sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr; then
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo "BBR включён"
    else
        echo "BBR уже активен"
    fi
else
    echo "BBR недоступен в ядре"
fi

# ────────────────────────────────────────────────
# fail2ban
# ────────────────────────────────────────────────
echo -e "\n${YELLOW}Установка fail2ban...${NC}"
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
fail2ban-client reload 2>/dev/null || true

# ────────────────────────────────────────────────
# Перезапуск SSH + обработка socket activation
# ────────────────────────────────────────────────
echo -e "\n${YELLOW}Перезапускаем SSH-сервис...${NC}"

set +e  # отключаем -e, чтобы ошибки restart не прерывали скрипт

SSH_SOCKET_ACTIVE=false
SSH_SERVICE=""

if systemctl is-active ssh.socket >/dev/null 2>&1; then
    SSH_SOCKET_ACTIVE=true
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
else
    echo "Классический режим — перезапускаем ssh/sshd"
    if systemctl is-active ssh >/dev/null 2>&1; then
        SSH_SERVICE="ssh"
        systemctl restart ssh
    elif systemctl is-active sshd >/dev/null 2>&1; then
        SSH_SERVICE="sshd"
        systemctl restart sshd
    else
        echo -e "${RED}Не найдена ни ssh, ни sshd служба${NC}"
    fi
fi

sleep 3

# Проверка реального порта
if ss -tulnp 2>/dev/null | grep -q ":$NEW_PORT .*sshd"; then
    echo -e "${GREEN}✓ Порт успешно изменён на $NEW_PORT${NC}"
else
    echo -e "${RED}✗ Порт НЕ изменился! Остался старый.${NC}"
    echo "Текущие прослушиваемые порты sshd:"
    ss -tulnp | grep sshd || echo "sshd не слушает ничего"
    echo ""
    echo -e "${YELLOW}Возможные причины:${NC}"
    echo "1. systemd socket activation — проверьте /etc/systemd/system/ssh.socket.d/port.conf"
    echo "2. Ошибка в sshd_config — проверьте синтаксис: sshd -t"
    echo "3. Нужно перезагрузить сервер полностью: reboot"
    echo ""
    echo -e "${YELLOW}Хотите откатить изменения? [y/N]${NC}"
    read -r rollback_confirm
    if [[ "$rollback_confirm" =~ ^[Yy]$ ]]; then
        rollback
    else
        echo -e "${YELLOW}Откат отменён. Продолжайте на свой страх и риск.${NC}"
    fi
fi

set -e  # возвращаем обратно

# ────────────────────────────────────────────────
# Финал
# ────────────────────────────────────────────────

echo -e "\n${GREEN}============================================================${NC}"
echo -e "               Настройка завершена${NC}"
echo ""
echo -e "Пользователь:    ${YELLOW}$NEW_USER${NC}"
echo -e "Порт SSH:        ${YELLOW}$NEW_PORT${NC}"
echo -e "BBR:             ${YELLOW}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'недоступен')${NC}"
echo -e "fail2ban:        ${GREEN}активен${NC}"
echo ""
echo -e "Команда подключения:"
echo -e "  ${YELLOW}ssh -p $NEW_PORT $NEW_USER@$(curl -s ifconfig.me 2>/dev/null || echo 'ваш_IP')${NC}"
echo ""
echo -e "${YELLOW}Проверьте вход в НОВОМ окне терминала перед закрытием сессии!${NC}"
echo -e "${GREEN}============================================================${NC}"

rm -rf "$KEY_DIR"

echo -e "\nУдачи и безопасной работы!${NC}"
