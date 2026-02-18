#!/bin/bash
# harden-ubuntu.sh — v3.6 (2026) — с fail2ban, BBR и открытием 80/443 в UFW

set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите от root${NC}"
    exit 1
fi

# Защита от curl | bash
if ! test -t 0; then
    echo -e "${RED}Не запускайте через curl | bash — скачайте и запустите отдельно${NC}"
    exit 1
fi

# Лог отката
ROLLBACK_LOG="/root/harden-rollback-$(date +%Y%m%d-%H%M%S).log"
SSHD_BACKUP=""
USER_CREATED=false
SUDOERS_FILE=""
KEY_DIR=""

OLD_PORT=$(ss -tulpn | grep -E 'ssh|sshd' | head -1 | grep -oP ':\K\d+' || echo "22")
echo "Лог отката: $ROLLBACK_LOG" | tee "$ROLLBACK_LOG"
echo "Текущий порт SSH: $OLD_PORT" | tee -a "$ROLLBACK_LOG"

# Функция отката
rollback() {
    echo -e "\n${RED}Откат...${NC}" | tee -a "$ROLLBACK_LOG"
    if [ -n "$SSHD_BACKUP" ] && [ -f "$SSHD_BACKUP" ]; then
        cp "$SSHD_BACKUP" /etc/ssh/sshd_config
    fi
    rm -rf /etc/systemd/system/ssh.socket.d 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    systemctl restart ssh 2>/dev/null || true
    if $USER_CREATED && id "$NEW_USER" &>/dev/null; then
        deluser --remove-home "$NEW_USER" 2>/dev/null
        rm -f "$SUDOERS_FILE" 2>/dev/null
    fi
    rm -rf "$KEY_DIR" 2>/dev/null
    echo -e "${YELLOW}Откат завершён${NC}" | tee -a "$ROLLBACK_LOG"
    exit 1
}
trap rollback INT TERM

# Ввод данных
echo -e "\n${YELLOW}Имя пользователя (a-z,0-9,_,-):${NC}"
read -r NEW_USER
NEW_USER=${NEW_USER:-kabeba}
[[ "$NEW_USER" =~ ^[a-zA-Z0-9_-]{3,32}$ ]] || { echo -e "${RED}Недопустимое имя${NC}"; exit 1; }

if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}Пользователь $NEW_USER существует. Продолжить? [y/N]${NC}"
    read -r cont
    [[ "$cont" =~ ^[Yy]$ ]] || exit 0
fi

echo -e "\n${YELLOW}Новый порт SSH (рекомендую 2222, 2200, 8022, 10022):${NC}"
read -r NEW_PORT
NEW_PORT=${NEW_PORT:-2222}
[[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_PORT" -ge 1024 ] && [ "$NEW_PORT" -le 65535 ] || {
    echo -e "${RED}Неверный порт${NC}"
    exit 1
}

# Простая проверка (только если явно занят)
if ss -tuln | grep -q ":$NEW_PORT "; then
    echo -e "${RED}Порт $NEW_PORT уже занят (по ss)${NC}"
    echo "Попробуйте другой порт или подождите 2–3 минуты."
    exit 1
fi

# Генерация ключей
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

echo -e "${RED}!!! СКОПИРУЙТЕ ПРИВАТНЫЙ КЛЮЧ СЕЙЧАС И СОХРАНИТЕ ЕГО В БЕЗОПАСНОМ МЕСТЕ !!!${NC}"
echo -e "${RED}После копирования введите 'yes' и нажмите Enter${NC}"
read -r confirm
[[ "$confirm" == "yes" ]] || { rm -rf "$KEY_DIR"; exit 1; }

# Бэкап конфига
SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$SSHD_BACKUP"

# Создание пользователя (если не существует)
if ! id "$NEW_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    SUDOERS_FILE="/etc/sudoers.d/90-$NEW_USER"
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
    USER_CREATED=true
fi

# Установка публичного ключа
mkdir -p "/home/$NEW_USER/.ssh"
echo "$PUB_KEY" > "/home/$NEW_USER/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
chmod 700 "/home/$NEW_USER/.ssh"
chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"

# Настройка sshd_config
if grep -q "^Port" /etc/ssh/sshd_config; then
    sed -i 's/^Port/#Port/g' /etc/ssh/sshd_config
fi
echo "Port $OLD_PORT" >> /etc/ssh/sshd_config
echo "Port $NEW_PORT" >> /etc/ssh/sshd_config

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

if ! grep -q "^ListenAddress" /etc/ssh/sshd_config; then
    echo "ListenAddress 0.0.0.0" >> /etc/ssh/sshd_config
    echo "ListenAddress ::" >> /etc/ssh/sshd_config
fi

# Проверка конфига
sshd -t || { echo -e "${RED}Ошибка в конфигурации sshd${NC}"; rollback; }

# Отключаем socket activation (если ещё активна)
systemctl stop ssh.socket 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
systemctl mask ssh.socket 2>/dev/null || true
systemctl unmask ssh.service 2>/dev/null || true
systemctl enable ssh.service 2>/dev/null || true

# Перезапуск sshd
systemctl restart ssh

# UFW — открываем новый SSH порт + 80 и 443
if command -v ufw &>/dev/null; then
    ufw allow "$NEW_PORT"/tcp 2>/dev/null || true
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable
    fi
    echo -e "${GREEN}UFW: открыт порты $NEW_PORT/tcp, 80/tcp, 443/tcp${NC}"
fi

# Установка и настройка fail2ban
echo -e "\n${GREEN}Устанавливаем fail2ban...${NC}"
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
echo -e "${GREEN}fail2ban установлен и настроен на защиту порта $NEW_PORT${NC}"

# Включение BBR (если доступен)
# Включение BBR
echo -e "\n${GREEN}Проверяем и включаем BBR...${NC}"
if modprobe tcp_bbr 2>/dev/null; then
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo -e "${GREEN}BBR включён (tcp_congestion_control = bbr)${NC}"
    else
        echo -e "${YELLOW}BBR уже включён${NC}"
    fi
    # Автозагрузка модуля
    echo "tcp_bbr" >> /etc/modules 2>/dev/null || true
else
    echo -e "${YELLOW}BBR недоступен — модуль tcp_bbr не найден в ядре${NC}"
fi

# Финальное сообщение и проверка
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e " 🎉 НАСТРОЙКА ЗАВЕРШЕНА 🎉"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}\n"

echo -e "${YELLOW}ТЕКУЩАЯ СЕССИЯ НЕ ПРЕРЫВАЛАСЬ! Старый порт $OLD_PORT всё ещё работает.${NC}"
echo -e "${GREEN}Новый порт $NEW_PORT добавлен и SSH перезапущен.${NC}\n"

echo -e "Пользователь: ${YELLOW}$NEW_USER${NC}"
echo -e "Проверка в НОВОМ окне терминала (НЕ ЗАКРЫВАЙТЕ это!):"
echo -e "  ${YELLOW}ssh -p $NEW_PORT $NEW_USER@$SERVER_IP${NC}\n"

echo -e "${RED}⚠️ ВАЖНО:${NC}"
echo "1. Откройте новое окно терминала"
echo "2. Подключитесь по новому порту"
echo "3. Если успешно подключение работает — вернитесь сюда и нажмите Enter"
echo "   После этого скрипт предложит закрыть старый порт 22 автоматически"

echo -e "\n${YELLOW}Нажмите Enter после успешной проверки нового порта (или Ctrl+C для отката)${NC}"
read -r

# Предложение закрыть старый порт
echo -e "\n${YELLOW}Закрыть старый порт $OLD_PORT сейчас? [y/N]${NC}"
echo -e "   (это удалит Port $OLD_PORT из sshd_config, перезапустит ssh и удалит правило в ufw)${NC}"
read -r close_old

if [[ "$close_old" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Закрываем старый порт $OLD_PORT...${NC}"
    
    # Удаляем строку с Port $OLD_PORT
    sed -i "/^Port $OLD_PORT$/d" /etc/ssh/sshd_config
    
    # Проверка конфига
    sshd -t || {
        echo -e "${RED}Ошибка после удаления старого порта — откат изменений${NC}"
        cp "$SSHD_BACKUP" /etc/ssh/sshd_config
        systemctl restart ssh
        exit 1
    }
    
    # Перезапуск ssh
    systemctl restart ssh
    
    # Удаляем старое правило в ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw delete allow "$OLD_PORT"/tcp 2>/dev/null || true
    fi
    
    echo -e "${GREEN}✓ Старый порт $OLD_PORT успешно закрыт${NC}"
    echo -e "${YELLOW}Теперь SSH доступен только по порту $NEW_PORT${NC}"
else
    echo -e "${YELLOW}Старый порт $OLD_PORT оставлен открытым (можно закрыть позже вручную)${NC}"
fi

rm -rf "$KEY_DIR"
echo -e "\n${GREEN}Скрипт успешно завершён. Сессия сохранена.${NC}"
echo -e "${YELLOW}Дополнительно:${NC}"
echo " - fail2ban защищает порт $NEW_PORT"
echo " - BBR включён (если поддерживается ядром)"
echo " - UFW открыл порты $NEW_PORT, 80 и 443"

trap - INT TERM
exit 0
