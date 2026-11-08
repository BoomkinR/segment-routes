uci set "${IPSET_SECTION}.family=ipv4"
uci -q delete "${IPSET_SECTION}.match" || true
uci add_list "${IPSET_SECTION}.match=dest_ip"
uci set "${IPSET_SECTION}.maxelem=65536"

# Mark packets from LAN whose IPv4 destination was resolved from ru-routes.
MARK_RULE="$(uci -q show firewall | sed -n "/\\.name='awg_mark_ru_routes'$/s/\\.name=.*//p" | grep '^firewall\.@rule\[' | head -n 1 || true)"
if [ -z "$MARK_RULE" ]; then
    uci add firewall rule >/dev/null
    MARK_RULE="firewall.@rule[-1]"
fi
uci set "${MARK_RULE}.name=awg_mark_ru_routes"
uci set "${MARK_RULE}.src=lan"
uci set "${MARK_RULE}.dest=*"
uci set "${MARK_RULE}.proto=all"
uci set "${MARK_RULE}.ipset=vpn_domains"
uci set "${MARK_RULE}.set_mark=${AWG_MARK}"
uci set "${MARK_RULE}.target=MARK"
uci set "${MARK_RULE}.family=ipv4"

# Dedicated IPv4 policy routing table and fwmark rule.
mkdir -p /etc/iproute2
grep -qE "^[[:space:]]*${AWG_TABLE}[[:space:]]+vpn_awg$" /etc/iproute2/rt_tables 2>/dev/null ||
    echo "${AWG_TABLE} vpn_awg" >> /etc/iproute2/rt_tables

ROUTE_RULE="$(uci -q show network | sed -n "/\\.name='awg_vpn_mark'$/s/\\.name=.*//p" | grep '^network\.@rule\[' | head -n 1 || true)"
if [ -z "$ROUTE_RULE" ]; then
    uci add network rule >/dev/null
    ROUTE_RULE="network.@rule[-1]"
fi
uci set "${ROUTE_RULE}.name=awg_vpn_mark"
uci set "${ROUTE_RULE}.family=ipv4"
uci set "${ROUTE_RULE}.mark=${AWG_MARK}"
uci set "${ROUTE_RULE}.priority=100"
uci set "${ROUTE_RULE}.lookup=vpn_awg"

# The route is installed only while awg0 is up.
cat > "$AWG_HOTPLUG" <<'EOF_HOTPLUG'
#!/bin/sh
[ "${INTERFACE:-}" = "awg0" ] || exit 0
case "${ACTION:-}" in
    ifup)
        ip -4 route replace default dev awg0 table 100
        ;;
    ifdown)
        ip -4 route del default dev awg0 table 100 2>/dev/null || true
        ;;
esac
EOF_HOTPLUG
chmod 755 "$AWG_HOTPLUG"

# Store the updater on flash. It always downloads from the one fixed URL,
# validates every line, and only replaces the active file after validation.
cat > "$AWG_UPDATE" <<'EOF_UPDATE'
#!/bin/sh
set -eu

URL="https://raw.githubusercontent.com/BoomkinR/segment-routes/refs/heads/main/ru-routes"
DIR="/tmp/dnsmasq.d"
TARGET="${DIR}/90-ru-routes.conf"
TMP="${DIR}/.ru-routes.conf.$$"

mkdir -p "$DIR"
trap 'rm -f "$TMP"' EXIT HUP INT TERM

wget -q -O "$TMP" "$URL" || {
    echo "[awg-routing] Download failed; keeping previous routes." >&2
    exit 1
}

[ -s "$TMP" ] || {
    echo "[awg-routing] Downloaded list is empty; keeping previous routes." >&2
    exit 1
}

# Accept only the exact dnsmasq nftset format for this one IPv4 fw4 set.
BAD_LINES="$(grep -Ev '^nftset=/[^/]+/4#inet#fw4#vpn_domains$' "$TMP" || true)"
[ -z "$BAD_LINES" ] || {
    echo "[awg-routing] Unexpected line(s) in ru-routes; keeping previous routes." >&2
    exit 1
}

LINE_COUNT="$(wc -l < "$TMP" | tr -d ' ')"
[ "$LINE_COUNT" -ge 1 ] || {
    echo "[awg-routing] No route entries; keeping previous routes." >&2
    exit 1
}

dnsmasq --test --conf-file="$TMP" >/dev/null 2>&1 || {
    echo "[awg-routing] dnsmasq rejected the downloaded list; keeping previous routes." >&2
    exit 1
}

mv "$TMP" "$TARGET"
trap - EXIT HUP INT TERM
/etc/init.d/dnsmasq restart
echo "[awg-routing] Installed ${LINE_COUNT} ru-routes entries."
EOF_UPDATE
chmod 755 "$AWG_UPDATE"

# dnsmasq-full reads this runtime directory. The init service below downloads
# the file again on boot, so the list survives the /tmp cleanup at reboot.
uci set dhcp.@dnsmasq[0].confdir="$AWG_DNSMASQ_DIR"

uci commit network
uci commit firewall
uci commit dhcp

# Install a boot-time updater and an 8-hour refresh job.
cat > /etc/init.d/awg-routing <<'EOF_INIT'
#!/bin/sh /etc/rc.common
START=99
STOP=10

start() {
    /usr/sbin/awg-routing-update
}
EOF_INIT
chmod 755 /etc/init.d/awg-routing
/etc/init.d/awg-routing enable

CRON_LINE="0 */8 * * * /usr/sbin/awg-routing-update"
( crontab -l 2>/dev/null | grep -Fv '/usr/sbin/awg-routing-update' || true
  echo "$CRON_LINE" ) | crontab -
/etc/init.d/cron enable 2>/dev/null || true
/etc/init.d/cron restart 2>/dev/null || true

log "Reloading firewall and network."
/etc/init.d/firewall restart
/etc/init.d/network restart

# If the interface is already up, install its table default route now.
if ip link show "$AWG_IF" >/dev/null 2>&1; then
    ip -4 route replace default dev "$AWG_IF" table "$AWG_TABLE" || true
fi

log "Downloading the fixed ru-routes list."
"$AWG_UPDATE" || die "Не удалось установить ru-routes. Предыдущий файл, если он был, сохранён."

log "Готово."
log "AWG interface: ${AWG_IF}"
log "IPv4 policy table: ${AWG_TABLE} (vpn_awg)"
log "IPv4 fwmark: ${AWG_MARK}"
log "Routes source: ${AWG_ROUTES_URL}"
log "Проверь handshake: awg show ${AWG_IF}"
log "Проверь таблицу: ip -4 route show table ${AWG_TABLE}"
log "Проверь set: nft list set inet fw4 vpn_domains"
log "Примечание: AWG kernel module может потребовать перезагрузку после первой установки/обновления."
