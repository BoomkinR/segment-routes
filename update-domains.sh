#!/bin/sh

# URL вашего файла со списком доменов на GitHub (RAW-ссылка!)
URL="https://raw.githubusercontent.com/BoomkinR/segment-routes/refs/heads/main/ru-routes"

# Временный файл и итоговый конфиг для dnsmasq
TMP_FILE="/tmp/github_domains.txt"
CONF_FILE="/tmp/dnsmasq.d/awg_domains.conf"

# Создаем папку для кастомных конфигов dnsmasq, если её нет
mkdir -p /tmp/dnsmasq.d

# Скачиваем список доменов
wget -4 -qO "$TMP_FILE" "$URL"

if [ -s "$TMP_FILE" ]; then
    # Очищаем старый конфиг
    echo "# Auto-generated from GitHub" > "$CONF_FILE"

    # Формируем строки вида: nftset=/://domain.com
    # Это заставит dnsmasq при резолве домена автоматически добавлять его IP в nftables-сет 'awg_set'
    awk '/^[a-zA-Z0-9]/ {print "nftset=/"$1"/4#inet#fw4#awg_set"}' "$TMP_FILE" >> "$CONF_FILE"

    # Перезапускаем dnsmasq, чтобы применить изменения
    /etc/init.d/dnsmasq restart
    echo "Domains updated successfully."
else
    echo "Failed to download or empty list."
fi
