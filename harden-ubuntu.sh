#!/bin/bash
# --- НАСТРОЙКИ ---
NEW_USER="admin_user"
SSH_KEY="ssh-rsa AAAAB3Nza... ваш_публичный_ключ ...user@host"
SSH_PORT="2222"

echo "=== Настройка безопасного доступа (порт $SSH_PORT) ==="

# 0. Проверка на root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт нужно запускать от root (sudo)"
   exit 1
fi

# ────────────────────────────────────────────────
#     ПРОВЕРКА — уже настроен или нет
# ────────────────────────────────────────────────

SKIP_SETUP=false

# Проверяем наличие пользователя
if id "$NEW_USER" &>/dev/null; then
    # Проверяем наличие ключа в authorized_keys
    if [[ -f "/home/$NEW_USER/.ssh/authorized_keys" ]] && grep -qF "${SSH_KEY%% *}" "/home/$NEW_USER/.ssh/authorized_keys" 2>/dev/null; then
        # Проверяем, отключён ли парольный вход
        if grep -qE "^PasswordAuthentication no" /etc/ssh/sshd_config; then
            echo "→ Похоже, сервер уже настроен (пользователь + ключ + пароли отключены)"
            SKIP_SETUP=true
        fi
    fi
fi

if $SKIP_SETUP; then
    echo "Ничего не делаем, чтобы случайно не сломать уже работающую конфигурацию."
    echo "Если нужно перезапустить настройку — запусти скрипт с аргументом --force"
    if [[ "$1" != "--force" ]]; then
        exit 0
    else
        echo "Запущен с --force → продолжаем принудительно"
    fi
fi

# ────────────────────────────────────────────────
#     ОСНОВНАЯ НАСТРОЙКА
# ────────────────────────────────────────────────

echo "--- Начинаем настройку сервера (Порт SSH: $SSH_PORT) ---"

# 1. Обновление системы
apt update && apt upgrade -y

# 2. Включение BBR
echo "Настройка TCP BBR..."
if lsmod | grep -q bbr; then
    echo "BBR уже включен."
else
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo "BBR успешно активирован."
fi

# 3. Создание пользователя (если ещё нет)
if id "$NEW_USER" &>/dev/null; then
    echo "Пользователь $NEW_USER уже существует."
else
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$NEW_USER"
    chmod 0440 "/etc/sudoers.d/90-$NEW_USER"
    echo "Пользователь $NEW_USER создан."
fi

# 4. Настройка SSH ключей
mkdir -p "/home/$NEW_USER/.ssh"
# Добавляем ключ, если его там ещё нет
if ! grep -qF "${SSH_KEY%% *}" "/home/$NEW_USER/.ssh/authorized_keys" 2>/dev/null; then
    echo "$SSH_KEY" >> "/home/$NEW_USER/.ssh/authorized_keys"
    echo "Ключ добавлен в authorized_keys"
fi

chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
chmod 700 "/home/$NEW_USER/.ssh"
chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"

# 5. Настройка SSH Daemon
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak-$(date +%Y%m%d-%H%M%S)

sed -i "s/^#*Port.*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# 6. Настройка файрвола (UFW)
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Перезапуск SSH
SSH_SERVICE="ssh"
systemctl is-active --quiet ssh || SSH_SERVICE="sshd"
systemctl restart "$SSH_SERVICE" && echo "SSH перезапущен ($SSH_SERVICE)"

# 7. Установка защитного ПО + fail2ban
apt install -y fail2ban curl git htop

cat <<EOT > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $SSH_PORT
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
bantime = 1h
EOT

systemctl restart fail2ban
fail2ban-client reload

# ────────────────────────────────────────────────
#     ФИНАЛЬНЫЙ ВЫВОД
# ────────────────────────────────────────────────

echo ""
echo "=== Настройка завершена! ==="
echo ""

echo "Проверка BBR:"
sysctl net.ipv4.tcp_congestion_control

echo ""
echo "Рекомендуемая команда для подключения:"
IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com)
echo "   ssh -p $SSH_PORT $NEW_USER@$IP"
echo ""
echo "Перед закрытием текущей сессии — обязательно проверьте, что подключаетесь!"
echo "Если что-то пошло не так — оставайтесь в текущей сессии root."
echo ""
