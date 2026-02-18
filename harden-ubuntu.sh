#!/bin/bash
# =============================================================================
# harden-ubuntu.sh — безопасная начальная настройка Ubuntu-сервера (исправленная версия)
# =============================================================================
# Описание: создаёт пользователя, настраивает SSH-ключи, меняет порт SSH,
#           отключает root-логин и пароли, включает UFW, BBR, fail2ban,
#           корректно обрабатывает systemd socket activation.
# Использование: скачать и запустить от root, следуя инструкциям.
# =============================================================================

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Безопасная настройка сервера (SSH-ключ, BBR, fail2ban) ===${NC}"

# -----------------------------------------------------------------------------
# Проверка запуска от root
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите от root (sudo)${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# Защита от curl | bash (скрипт не должен запускаться из пайпа)
# -----------------------------------------------------------------------------
if ! test -t 0; then
    echo -e "${RED}Не запускайте через curl | bash — скачайте и запустите отдельно${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# Переменные для отката
# -----------------------------------------------------------------------------
ROLLBACK_LOG="/root/harden-rollback-$(date +%Y%m%d-%H%M%S).log"
SSHD_BACKUP=""
USER_CREATED=false          # true, если пользователь был создан скриптом
SUDOERS_FILE=""
UFW_WAS_ENABLED=false       # true, если UFW был включен (и мы его включаем)
KEY_DIR=""                  # временная папка с ключами
SOCKET_OVERRIDE_CREATED=false

echo "Лог отката будет сохранён в: $ROLLBACK_LOG" | tee -a "$ROLLBACK_LOG"

# -----------------------------------------------------------------------------
# Функция отката (вызывается при ошибке или по Ctrl+C)
# -----------------------------------------------------------------------------
rollback() {
    echo -e "\n${RED}Откат изменений...${NC}" | tee -a "$ROLLBACK_LOG"

    # Удаление временной папки с ключами
    if [ -n "$KEY_DIR" ] && [ -d "$KEY_DIR" ]; then
        rm -rf "$KEY_DIR"
        echo "→ Временные ключи удалены" | tee -a "$ROLLBACK_LOG"
    fi

    # Восстановление sshd_config из бэкапа
    if [ -n "$SSHD_BACKUP" ] && [ -f "$SSHD_BACKUP" ]; then
        cp "$SSHD_BACKUP" /etc/ssh/sshd_config
        echo "→ sshd_config восстановлен из бэкапа" | tee -a "$ROLLBACK_LOG"
        # Перезапуск SSH в исходном состоянии
        systemctl daemon-reload 2>/dev/null || true
        if systemctl is-active ssh.socket >/dev/null 2>&1; then
            rm -rf /etc/systemd/system/ssh.socket.d 2>/dev/null || true
            systemctl daemon-reload
            systemctl restart ssh.socket
        else
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        fi
        echo "→ SSH перезапущен" | tee -a "$ROLLBACK_LOG"
    fi

    # Удаление созданного пользователя (только если он был создан скриптом)
    if $USER_CREATED && id "$NEW_USER" &>/dev/null; then
        deluser --remove-home "$NEW_USER" 2>/dev/null
        [ -n "$SUDOERS_FILE" ] && rm -f "$SUDOERS_FILE" 2>/dev/null
        echo "→ Пользователь $NEW_USER удалён" | tee -a "$ROLLBACK_LOG"
    fi

    # Отключение UFW, если он был включен скриптом
    if $UFW_WAS_ENABLED; then
        ufw --force disable 2>/dev/null && echo "→ UFW отключён" | tee -a "$ROLLBACK_LOG"
    fi

    # Удаление override для ssh.socket, если он был создан
    if $SOCKET_OVERRIDE_CREATED; then
        rm -rf /etc/systemd/system/ssh.socket.d 2>/dev/null
        systemctl daemon-reload
        systemctl restart ssh.socket 2>/dev/null || true
        echo "→ override ssh.socket удалён" | tee -a "$ROLLBACK_LOG"
    fi

    echo -e "${YELLOW}Откат завершён. Проверьте систему!${NC}" | tee -a "$ROLLBACK_LOG"
    exit 1
}

# Перехват Ctrl+C и ошибок (через set -e откат не сработает, поэтому используем trap)
trap rollback INT TERM

# -----------------------------------------------------------------------------
# Запрос имени нового пользователя
# -----------------------------------------------------------------------------
echo -e "\n${YELLOW}Введите имя нового пользователя (только a-z, 0-9, _, -, от 3 до 32 символов)${NC}"
read -r -p "Имя пользователя: " NEW_USER
NEW_USER=${NEW_USER:-admin}

if [[ ! "$NEW_USER" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
    echo -e "${RED}Недопустимое имя${NC}"
    exit 1
fi

# Проверка существования пользователя
if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}Пользователь $NEW_USER уже существует. Ключ будет добавлен к существующему пользователю.${NC}"
    read -r -p "Продолжить? [y/N]: " cont
    [[ "$cont" =~ ^[Yy]$ ]] || exit 0
    USER_EXISTS=true
else
    USER_EXISTS=false
fi

# -----------------------------------------------------------------------------
# Запрос нового порта SSH
# -----------------------------------------------------------------------------
echo -e "\n${YELLOW}Новый порт SSH (рекомендуется >1024, не 22)${NC}"
read -r -p "Новый порт SSH: " NEW_PORT
NEW_PORT=${NEW_PORT:-2222}

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1024 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo -e "${RED}Неверный порт (должен быть от 1024 до 65535)${NC}"
    exit 1
fi

# Проверка, не занят ли порт другим процессом
if ss -tuln | grep -q ":$NEW_PORT "; then
    echo -e "${RED}Порт $NEW_PORT уже используется другим процессом.${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# Генерация SSH-ключей
# -----------------------------------------------------------------------------
echo -e "\n${GREEN}Генерируем пару ed25519 ключей...${NC}\n"

KEY_DIR="/root/temp-ssh-key-$(date +%s)"
mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"

ssh-keygen -t ed25519 -f "$KEY_DIR/id_ed25519" -N "" -C "$NEW_USER@$(hostname)-$(date +%Y%m%d)" >/dev/null 2>&1

PUB_KEY=$(cat "$KEY_DIR/id_ed25519.pub")
PRIV_KEY=$(cat "$KEY_DIR/id_ed25519")

# Вывод предупреждения и приватного ключа
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

# -----------------------------------------------------------------------------
# Применение изменений (опасная часть)
# -----------------------------------------------------------------------------

# 1. Бэкап оригинального sshd_config
SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$SSHD_BACKUP" 2>/dev/null || {
    echo -e "${RED}Не удалось создать бэкап sshd_config${NC}"
    rollback
}

# 2. Создание пользователя (если не существовал)
if ! $USER_EXISTS; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    SUDOERS_FILE="/etc/sudoers.d/90-$NEW_USER"
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
    USER_CREATED=true
    echo "→ Пользователь $NEW_USER создан и добавлен в группу sudo" | tee -a "$ROLLBACK_LOG"
fi

# 3. Установка ключа для пользователя
mkdir -p "/home/$NEW_USER/.ssh"
echo "$PUB_KEY" > "/home/$NEW_USER/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
chmod 700 "/home/$NEW_USER/.ssh"
chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
echo "→ Публичный ключ добавлен пользователю $NEW_USER" | tee -a "$ROLLBACK_LOG"

# 4. Редактирование sshd_config
sed -i "s/^#*Port.*/Port $NEW_PORT/" /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Проверка синтаксиса sshd_config
if ! sshd -t; then
    echo -e "${RED}Ошибка в sshd_config. Откат...${NC}" | tee -a "$ROLLBACK_LOG"
    rollback
fi
echo "→ sshd_config обновлён, синтаксис корректен" | tee -a "$ROLLBACK_LOG"

# 5. Настройка UFW
if ! command -v ufw &>/dev/null; then
    echo "Устанавливаем ufw..." | tee -a "$ROLLBACK_LOG"
    apt update -qq && apt install -y ufw
fi

# Запоминаем исходное состояние UFW
if ufw status | grep -q "Status: inactive"; then
    UFW_WAS_ENABLED=false
else
    UFW_WAS_ENABLED=true   # был включён, после скрипта не отключаем при откате
fi

# Открываем нужные порты
ufw allow "$NEW_PORT"/tcp 2>/dev/null || true
ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true

# Включаем UFW (если был выключен)
if ! ufw status | grep -q "Status: active"; then
    echo "y" | ufw enable 2>/dev/null || true
    UFW_WAS_ENABLED=true
fi

# Проверяем, что правило для нового порта добавлено
if ! ufw status | grep -q "$NEW_PORT/tcp"; then
    echo -e "${RED}Не удалось добавить правило UFW для порта $NEW_PORT${NC}" | tee -a "$ROLLBACK_LOG"
    rollback
fi
echo "→ UFW настроен, порты открыты" | tee -a "$ROLLBACK_LOG"

# 6. Настройка BBR
echo -e "\n${YELLOW}Настройка BBR...${NC}" | tee -a "$ROLLBACK_LOG"
if sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr; then
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo "BBR включён" | tee -a "$ROLLBACK_LOG"
    else
        echo "BBR уже активен" | tee -a "$ROLLBACK_LOG"
    fi
else
    echo "BBR недоступен в ядре" | tee -a "$ROLLBACK_LOG"
fi

# 7. Установка и настройка fail2ban
echo -e "\n${YELLOW}Установка fail2ban...${NC}" | tee -a "$ROLLBACK_LOG"
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
echo "→ fail2ban настроен" | tee -a "$ROLLBACK_LOG"

# -----------------------------------------------------------------------------
# Перезапуск SSH (с учётом socket activation)
# -----------------------------------------------------------------------------
echo -e "\n${YELLOW}Перезапускаем SSH-сервис...${NC}" | tee -a "$ROLLBACK_LOG"

# Определяем, используется ли socket activation
if systemctl is-active ssh.socket >/dev/null 2>&1; then
    echo "Обнаружен systemd socket activation (ssh.socket)" | tee -a "$ROLLBACK_LOG"
    # Создаём override для изменения порта
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat <<EOT > /etc/systemd/system/ssh.socket.d/port.conf
[Socket]
ListenStream=
ListenStream=$NEW_PORT
EOT
    SOCKET_OVERRIDE_CREATED=true
    systemctl daemon-reload

    # Останавливаем ssh.service, чтобы он не конфликтовал
    systemctl stop ssh.service 2>/dev/null || true

    # Перезапускаем socket
    systemctl restart ssh.socket
    sleep 2

    # Проверяем, что socket слушает нужный порт
    if ss -tuln | grep -q ":$NEW_PORT "; then
        echo -e "${GREEN}✓ ssh.socket слушает порт $NEW_PORT${NC}" | tee -a "$ROLLBACK_LOG"
    else
        echo -e "${RED}✗ ssh.socket не слушает порт $NEW_PORT${NC}" | tee -a "$ROLLBACK_LOG"
        rollback
    fi
else
    echo "Классический режим — перезапускаем ssh/sshd" | tee -a "$ROLLBACK_LOG"
    if systemctl is-active ssh >/dev/null 2>&1; then
        systemctl restart ssh
    elif systemctl is-active sshd >/dev/null 2>&1; then
        systemctl restart sshd
    else
        echo -e "${RED}Не найдена служба ssh или sshd${NC}" | tee -a "$ROLLBACK_LOG"
        rollback
    fi
    sleep 2

    # Проверяем, что порт открылся
    if ! ss -tuln | grep -q ":$NEW_PORT "; then
        echo -e "${RED}✗ Порт $NEW_PORT не открылся после перезапуска${NC}" | tee -a "$ROLLBACK_LOG"
        rollback
    else
        echo -e "${GREEN}✓ Порт $NEW_PORT успешно открыт${NC}" | tee -a "$ROLLBACK_LOG"
    fi
fi

# -----------------------------------------------------------------------------
# Финальные сообщения
# -----------------------------------------------------------------------------
# Определяем IP-адрес сервера (первый не-loopback)
SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "\n${GREEN}============================================================${NC}"
echo -e "               Настройка завершена${NC}"
echo ""
echo -e "Пользователь:    ${YELLOW}$NEW_USER${NC}"
echo -e "Порт SSH:        ${YELLOW}$NEW_PORT${NC}"
echo -e "BBR:             ${YELLOW}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'недоступен')${NC}"
echo -e "fail2ban:        ${GREEN}активен${NC}"
echo ""
echo -e "Команда подключения:"
echo -e "  ${YELLOW}ssh -p $NEW_PORT $NEW_USER@$SERVER_IP${NC}"
echo ""
echo -e "${YELLOW}Проверьте вход в НОВОМ окне терминала перед закрытием сессии!${NC}"
echo -e "${GREEN}============================================================${NC}"

# Удаляем временную папку с ключами
rm -rf "$KEY_DIR"
echo -e "\nУдачи и безопасной работы!${NC}"

# Отключаем trap (успешное завершение)
trap - INT TERM
exit 0
