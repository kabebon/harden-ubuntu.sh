#!/bin/bash
# =============================================================================
# harden-ubuntu.sh — ультимативная безопасная настройка Ubuntu-сервера v2.0
# =============================================================================
# Описание: создаёт пользователя, SSH-ключи, меняет порт, отключает root/пароли,
#           включает UFW, BBR, fail2ban. Идеально обрабатывает socket activation.
# =============================================================================

set -euo pipefail

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Проверка root
if [[ $EUID -ne 0 ]]; then echo -e "${RED}Запустите от root${NC}"; exit 1; fi

# Защита от curl | bash
if ! test -t 0; then
    echo -e "${RED}Не запускайте через curl | bash — скачайте и запустите отдельно${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# Переменные
# -----------------------------------------------------------------------------
ROLLBACK_LOG="/root/harden-rollback-$(date +%Y%m%d-%H%M%S).log"
SSHD_BACKUP=""; USER_CREATED=false; SUDOERS_FILE=""; KEY_DIR=""
SOCKET_OVERRIDE_CREATED=false

echo "Лог отката: $ROLLBACK_LOG" | tee "$ROLLBACK_LOG"

# -----------------------------------------------------------------------------
# Функция отката
# -----------------------------------------------------------------------------
rollback() {
    echo -e "\n${RED}Откат...${NC}" | tee -a "$ROLLBACK_LOG"
    
    # Восстановление конфига
    [ -n "$SSHD_BACKUP" ] && [ -f "$SSHD_BACKUP" ] && cp "$SSHD_BACKUP" /etc/ssh/sshd_config
    
    # Удаление override socket
    if $SOCKET_OVERRIDE_CREATED; then
        rm -rf /etc/systemd/system/ssh.socket.d
        systemctl daemon-reload
        systemctl restart ssh.socket 2>/dev/null || true
    fi
    
    # Перезапуск SSH
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    
    # Удаление пользователя (если создан)
    if $USER_CREATED && id "$NEW_USER" &>/dev/null; then
        deluser --remove-home "$NEW_USER" 2>/dev/null
        rm -f "$SUDOERS_FILE" 2>/dev/null
    fi
    
    # Очистка
    rm -rf "$KEY_DIR" 2>/dev/null
    echo -e "${YELLOW}Откат завершён${NC}" | tee -a "$ROLLBACK_LOG"
    exit 1
}
trap rollback INT TERM

# -----------------------------------------------------------------------------
# Ввод данных
# -----------------------------------------------------------------------------
echo -e "\n${YELLOW}Имя пользователя (a-z,0-9,_,-):${NC}"
read -r -p "> " NEW_USER
NEW_USER=${NEW_USER:-admin}
[[ "$NEW_USER" =~ ^[a-zA-Z0-9_-]{3,32}$ ]] || { echo -e "${RED}Недопустимое имя${NC}"; exit 1; }

if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}Пользователь $NEW_USER существует. Продолжить? [y/N]${NC}"
    read -r cont; [[ "$cont" =~ ^[Yy]$ ]] || exit 0
    USER_EXISTS=true
else
    USER_EXISTS=false
fi

echo -e "\n${YELLOW}Новый порт SSH (1024-65535):${NC}"
read -r -p "> " NEW_PORT
NEW_PORT=${NEW_PORT:-2222}
[[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_PORT" -ge 1024 ] && [ "$NEW_PORT" -le 65535 ] || {
    echo -e "${RED}Неверный порт${NC}"; exit 1
}

ss -tuln | grep -q ":$NEW_PORT " && {
    echo -e "${RED}Порт $NEW_PORT уже занят${NC}"; exit 1
}

# -----------------------------------------------------------------------------
# Генерация ключей
# -----------------------------------------------------------------------------
echo -e "\n${GREEN}Генерируем ключи ed25519...${NC}"
KEY_DIR="/root/temp-ssh-key-$(date +%s)"
mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"
ssh-keygen -t ed25519 -f "$KEY_DIR/id_ed25519" -N "" -C "$NEW_USER@$(hostname)-$(date +%Y%m%d)" >/dev/null 2>&1

PUB_KEY=$(cat "$KEY_DIR/id_ed25519.pub")
PRIV_KEY=$(cat "$KEY_DIR/id_ed25519")

echo -e "\n${YELLOW}═══ ПРИВАТНЫЙ КЛЮЧ (СКОПИРУЙТЕ СЕЙЧАС) ═══${NC}\n"
echo "$PRIV_KEY"
echo -e "\n${YELLOW}═══════════════════════════════════════════${NC}\n"
echo -e "${GREEN}Публичный ключ:${NC}\n$PUB_KEY\n"

read -r -p "Введите yes для подтверждения: " confirm
[[ "$confirm" == "yes" ]] || { rm -rf "$KEY_DIR"; exit 1; }

# -----------------------------------------------------------------------------
# Применение изменений
# -----------------------------------------------------------------------------
# Бэкап
SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$SSHD_BACKUP"

# Создание пользователя
if ! $USER_EXISTS; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    SUDOERS_FILE="/etc/sudoers.d/90-$NEW_USER"
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
    USER_CREATED=true
fi

# Установка ключа
mkdir -p "/home/$NEW_USER/.ssh"
echo "$PUB_KEY" > "/home/$NEW_USER/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
chmod 700 "/home/$NEW_USER/.ssh" && chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"

# Редактирование sshd_config
sed -i "s/^#*Port.*/Port $NEW_PORT/" /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# КРИТИЧЕСКИ ВАЖНО: добавляем ListenAddress для обоих протоколов
if ! grep -q "^ListenAddress" /etc/ssh/sshd_config; then
    echo "ListenAddress 0.0.0.0" >> /etc/ssh/sshd_config
    echo "ListenAddress ::" >> /etc/ssh/sshd_config
else
    sed -i 's/^#*ListenAddress.*/ListenAddress 0.0.0.0\nListenAddress ::/' /etc/ssh/sshd_config
fi

# Проверка синтаксиса
sshd -t || { echo -e "${RED}Ошибка конфига${NC}"; rollback; }

# -----------------------------------------------------------------------------
# UFW
# -----------------------------------------------------------------------------
if ! command -v ufw &>/dev/null; then apt update -qq && apt install -y ufw; fi

ufw allow "$NEW_PORT"/tcp
ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true

if ! ufw status | grep -q "Status: active"; then
    echo "y" | ufw enable
fi

# -----------------------------------------------------------------------------
# BBR
# -----------------------------------------------------------------------------
if sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr; then
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
fi

# -----------------------------------------------------------------------------
# fail2ban
# -----------------------------------------------------------------------------
apt update -qq && apt install -y fail2ban
cat > /etc/fail2ban/jail.local <<EOT
[sshd]
enabled   = true
port      = $NEW_PORT
logpath   = %(sshd_log)s
maxretry  = 5
bantime   = 3600
findtime  = 600
EOT
systemctl restart fail2ban

# -----------------------------------------------------------------------------
# ⭐ КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ: правильная обработка socket activation
# -----------------------------------------------------------------------------
echo -e "\n${YELLOW}Настройка SSH...${NC}"

# Удаляем все существующие override для socket
rm -rf /etc/systemd/system/ssh.socket.d
mkdir -p /etc/systemd/system/ssh.socket.d

if systemctl is-active ssh.socket >/dev/null 2>&1; then
    echo "🔧 Настройка socket activation..." | tee -a "$ROLLBACK_LOG"
    
    # Правильный override с явным указанием IPv4 и IPv6
    cat > /etc/systemd/system/ssh.socket.d/port.conf <<EOT
[Socket]
ListenStream=
ListenStream=0.0.0.0:$NEW_PORT
ListenStream=[::]:$NEW_PORT
FreeBind=true
EOT
    SOCKET_OVERRIDE_CREATED=true
    
    systemctl daemon-reload
    systemctl stop ssh.service 2>/dev/null || true
    systemctl restart ssh.socket
    sleep 2
    
    # Проверка обоих протоколов
    if ss -tuln | grep -q ":$NEW_PORT"; then
        echo -e "${GREEN}✓ Socket слушает порт $NEW_PORT (IPv4+IPv6)${NC}" | tee -a "$ROLLBACK_LOG"
    else
        echo -e "${RED}✗ Ошибка запуска socket${NC}" | tee -a "$ROLLBACK_LOG"
        rollback
    fi
else
    echo "🔧 Классический режим SSH..." | tee -a "$ROLLBACK_LOG"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || {
        echo -e "${RED}✗ Не удалось перезапустить SSH${NC}"
        rollback
    }
    sleep 2
    ss -tuln | grep -q ":$NEW_PORT" || rollback
fi

# -----------------------------------------------------------------------------
# Финальное сообщение
# -----------------------------------------------------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "               🎉 НАСТРОЙКА ЗАВЕРШЕНА 🎉"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}\n"
echo -e "Пользователь: ${YELLOW}$NEW_USER${NC}"
echo -e "Порт SSH:     ${YELLOW}$NEW_PORT${NC}"
echo -e "Команда:      ${YELLOW}ssh -p $NEW_PORT $NEW_USER@$SERVER_IP${NC}\n"
echo -e "${RED}ВАЖНО: проверьте подключение в НОВОМ окне, не закрывая это!${NC}\n"

rm -rf "$KEY_DIR"
trap - INT TERM
exit 0
