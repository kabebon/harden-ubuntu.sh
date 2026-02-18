#!/bin/bash

# =============================================================================
# harden-ubuntu.sh — безопасная настройка БЕЗ разрыва сессии v3.1
# =============================================================================
# КЛЮЧЕВАЯ ИДЕЯ: не перезапускаем SSH, а добавляем новый порт рядом со старым
# Текущая сессия НЕ ПРЕРЫВАЕТСЯ!
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
OLD_PORT=$(ss -tulpn | grep sshd | head -1 | grep -oP ':\K\d+' || echo "22")
echo "Лог отката: $ROLLBACK_LOG" | tee "$ROLLBACK_LOG"
echo "Текущий порт SSH: $OLD_PORT" | tee -a "$ROLLBACK_LOG"
# -----------------------------------------------------------------------------
# Функция отката
# -----------------------------------------------------------------------------
rollback() {
    echo -e "\n${RED}Откат...${NC}" | tee -a "$ROLLBACK_LOG"
    # Восстановление конфига
    [ -n "$SSHD_BACKUP" ] && [ -f "$SSHD_BACKUP" ] && cp "$SSHD_BACKUP" /etc/ssh/sshd_config
    # Удаление новых портов из socket override
    rm -rf /etc/systemd/system/ssh.socket.d 2>/dev/null
    systemctl daemon-reload
    # Перезапуск socket (только если был изменён)
    if systemctl is-active ssh.socket >/dev/null 2>&1; then
        systemctl restart ssh.socket
    fi
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
# Улучшенная проверка порта (попытка bind для точности)
if ! (bash -c "exec 3<>/dev/tcp/0.0.0.0/$NEW_PORT" 2>/dev/null); then
    echo -e "${RED}Порт $NEW_PORT уже занят или недоступен${NC}"; exit 1
fi
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
echo -e "${RED}!!! СКОПИРУЙТЕ ПРИВАТНЫЙ КЛЮЧ СЕЙЧАС И СОХРАНИТЕ ЕГО В БЕЗОПАСНОМ МЕСТЕ !!!${NC}"
echo -e "${RED}После этого введите 'yes' и нажмите Enter для продолжения.${NC}"
read -r -p "Введите yes для подтверждения: " confirm
[[ "$confirm" == "yes" ]] || { rm -rf "$KEY_DIR"; exit 1; }
# -----------------------------------------------------------------------------
# Применение изменений (БЕЗ ПЕРЕЗАПУСКА SSH)
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
# -----------------------------------------------------------------------------
# ⭐ КЛЮЧЕВОЕ ИЗМЕНЕНИЕ: добавляем НОВЫЙ порт, НО НЕ УБИРАЕМ СТАРЫЙ
# -----------------------------------------------------------------------------
echo -e "\n${YELLOW}🔧 Добавляем новый порт $NEW_PORT рядом со старым $OLD_PORT...${NC}"
# Редактирование sshd_config - добавляем новый порт, сохраняя старый
if grep -q "^Port" /etc/ssh/sshd_config; then
    # Если есть строка Port, комментируем её и добавляем оба порта
    sed -i 's/^Port/#Port/g' /etc/ssh/sshd_config
fi
echo "Port $OLD_PORT" >> /etc/ssh/sshd_config
echo "Port $NEW_PORT" >> /etc/ssh/sshd_config
# Отключаем root и пароли (это безопасно делать сразу)
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
# Добавляем ListenAddress для надёжности
if ! grep -q "^ListenAddress" /etc/ssh/sshd_config; then
    echo "ListenAddress 0.0.0.0" >> /etc/ssh/sshd_config
    echo "ListenAddress ::" >> /etc/ssh/sshd_config
fi
# Проверка синтаксиса
sshd -t || { echo -e "${RED}Ошибка конфига${NC}"; rollback; }
# -----------------------------------------------------------------------------
# Настройка socket activation (ДОБАВЛЯЕМ порт, НЕ ПЕРЕЗАПУСКАЯ)
# -----------------------------------------------------------------------------
if systemctl is-active ssh.socket >/dev/null 2>&1; then
    echo "🔧 Обнаружен socket activation - добавляем порт $NEW_PORT к существующему..." | tee -a "$ROLLBACK_LOG"
    # Создаём директорию, если нет
    mkdir -p /etc/systemd/system/ssh.socket.d
    # Создаём override, который ДОБАВЛЯЕТ новый порт к существующим
    cat > /etc/systemd/system/ssh.socket.d/port.conf <<EOT
[Socket]
ListenStream=0.0.0.0:$NEW_PORT
EOT
    # Добавляем IPv6 только если включён
    IPV6_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6)
    if [ "$IPV6_DISABLED" = "0" ]; then
        echo "ListenStream=[::]:$NEW_PORT" >> /etc/systemd/system/ssh.socket.d/port.conf
    fi
    echo "FreeBind=true" >> /etc/systemd/system/ssh.socket.d/port.conf
    SOCKET_OVERRIDE_CREATED=true
    # Просто перезагружаем конфигурацию, НО НЕ ПЕРЕЗАПУСКАЕМ САМ СЕРВИС!
    systemctl daemon-reload
    # Говорим systemd перечитать конфигурацию socket-а на лету
    if ! systemctl try-reload-or-restart ssh.socket; then
        echo -e "${RED}Ошибка при обновлении ssh.socket — откат!${NC}"
        rollback
    fi
    echo -e "${GREEN}✓ Новый порт $NEW_PORT добавлен к socket. Старый порт $OLD_PORT продолжает работать.${NC}" | tee -a "$ROLLBACK_LOG"
    echo "⚠️ Перезапуска socket НЕ ПРОИСХОДИЛО, ваша сессия СОХРАНЕНА!" | tee -a "$ROLLBACK_LOG"
fi
# -----------------------------------------------------------------------------
# UFW - открываем новый порт, но НЕ ЗАКРЫВАЕМ старый
# -----------------------------------------------------------------------------
if ! command -v ufw &>/dev/null; then apt update -qq && apt install -y ufw; fi
ufw allow "$NEW_PORT"/tcp
ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
if ! ufw status | grep -q "Status: active"; then
    echo "y" | ufw enable
fi
# -----------------------------------------------------------------------------
# BBR и fail2ban (безопасно, не влияют на сессию)
# -----------------------------------------------------------------------------
if sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr; then
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
fi
apt update -qq && apt install -y fail2ban
cat > /etc/fail2ban/jail.local <<EOT
[sshd]
enabled = true
port = $NEW_PORT
logpath = %(sshd_log)s
maxretry = 5
bantime = 3600
findtime = 600
EOT
systemctl restart fail2ban
# -----------------------------------------------------------------------------
# ФИНАЛ: просим пользователя проверить новый порт
# -----------------------------------------------------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e " 🎉 БАЗОВАЯ НАСТРОЙКА ЗАВЕРШЕНА 🎉"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}\n"
echo -e "${YELLOW}✅ ТЕКУЩАЯ SSH-СЕССИЯ НЕ ПРЕРЫВАЛАСЬ!${NC}"
echo -e "${YELLOW}✅ СТАРЫЙ ПОРТ $OLD_PORT ВСЁ ЕЩЁ РАБОТАЕТ!${NC}"
echo -e "${GREEN}✅ НОВЫЙ ПОРТ $NEW_PORT ДОБАВЛЕН!${NC}\n"
echo -e "Пользователь: ${YELLOW}$NEW_USER${NC}"
echo -e "Команда для проверки:"
echo -e " ${YELLOW}ssh -p $NEW_PORT $NEW_USER@$SERVER_IP${NC}\n"
echo -e "${RED}⚠️ ВАЖНО:${NC}"
echo "1. ОТКРОЙТЕ НОВОЕ ОКНО ТЕРМИНАЛА (не закрывая это!)"
echo "2. Проверьте подключение по НОВОМУ порту:"
echo " ${YELLOW}ssh -p $NEW_PORT $NEW_USER@$SERVER_IP${NC}"
echo "3. Если подключились успешно - МОЖЕТЕ закрыть старый порт:"
echo " - Отредактируйте /etc/ssh/sshd_config (удалите 'Port $OLD_PORT')"
echo " - Закройте порт в UFW: ufw delete allow $OLD_PORT/tcp"
echo " - Если используется socket: удалите старый порт из override"
echo "4. Если НЕ подключились - нажмите Ctrl+C для отката"
echo -e "\n${YELLOW}Ожидание проверки... (нажмите Enter если всё работает, Ctrl+C для отката)${NC}"
read -r
# -----------------------------------------------------------------------------
# Опционально: помощь в закрытии старого порта
# -----------------------------------------------------------------------------
echo -e "\n${GREEN}Хотите, чтобы скрипт автоматически закрыл старый порт $OLD_PORT?${NC}"
echo "Это БЕЗОПАСНО, только если вы УЖЕ подключились по новому порту в другом окне."
read -r -p "Закрыть старый порт? (y/N): " close_old
if [[ "$close_old" =~ ^[Yy]$ ]]; then
    echo "Закрываем старый порт $OLD_PORT..." | tee -a "$ROLLBACK_LOG"
    # Удаляем старый порт из sshd_config
    sed -i "/Port $OLD_PORT/d" /etc/ssh/sshd_config
    # Если есть socket activation - удаляем старый порт из override
    if systemctl is-active ssh.socket >/dev/null 2>&1; then
        # Просто перезаписываем override только с новым портом
        cat > /etc/systemd/system/ssh.socket.d/port.conf <<EOT
[Socket]
ListenStream=
ListenStream=0.0.0.0:$NEW_PORT
EOT
        if [ "$IPV6_DISABLED" = "0" ]; then
            echo "ListenStream=[::]:$NEW_PORT" >> /etc/systemd/system/ssh.socket.d/port.conf
        fi
        echo "FreeBind=true" >> /etc/systemd/system/ssh.socket.d/port.conf
        systemctl daemon-reload
        systemctl try-reload-or-restart ssh.socket
    fi
    # Закрываем в UFW
    ufw delete allow "$OLD_PORT"/tcp 2>/dev/null || true
    echo -e "${GREEN}✓ Старый порт $OLD_PORT закрыт${NC}" | tee -a "$ROLLBACK_LOG"
fi
# -----------------------------------------------------------------------------
# Завершение
# -----------------------------------------------------------------------------
rm -rf "$KEY_DIR"
echo -e "\n${GREEN}✅ Скрипт успешно завершён! Сессия сохранена.${NC}"
trap - INT TERM
exit 0
