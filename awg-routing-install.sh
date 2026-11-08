#!/bin/sh
# OpenWrt 25.12 + AmneziaWG 3.1 selective IPv4 routing.
# Routes domains from the fixed BoomkinR/segment-routes ru-routes list.

set -eu

AWG_IF="awg0"
AWG_TABLE="100"
AWG_MARK="0x1"
AWG_ROUTES_URL="https://raw.githubusercontent.com/BoomkinR/segment-routes/refs/heads/main/ru-routes"
AWG_INSTALLER_URL="https://raw.githubusercontent.com/2Grey/awg-openwrt/refs/heads/master/amneziawg-install.sh"
AWG_CONF="${1:-}"
AWG_TMP="/tmp/awg-routing"
AWG_DNSMASQ_DIR="/tmp/dnsmasq.d"
AWG_DNSMASQ_FILE="${AWG_DNSMASQ_DIR}/90-ru-routes.conf"
AWG_UPDATE="/usr/sbin/awg-routing-update"
AWG_HOTPLUG="/etc/hotplug.d/iface/90-awg-routing"

log() { printf '[awg-routing] %s\n' "$*"; }
die() { printf '[awg-routing] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "Запусти скрипт от root."
[ -n "$AWG_CONF" ] || die "Использование: $0 /path/to/client.conf"
[ -r "$AWG_CONF" ] || die "Не могу прочитать конфигурацию: $AWG_CONF"

. /etc/openwrt_release
case "${DISTRIB_RELEASE:-}" in
    25.12*) ;;
    *) die "Поддерживается только OpenWrt 25.12.x; обнаружено: ${DISTRIB_RELEASE:-unknown}" ;;
esac

command -v apk >/dev/null 2>&1 || die "Не найден apk: ожидается OpenWrt 25.12."
command -v ubus >/dev/null 2>&1 || die "Не найден ubus."
command -v uci >/dev/null 2>&1 || die "Не найден uci."
command -v wget >/dev/null 2>&1 || die "Не найден wget."

# This importer supports one [Peer], as does the upstream AWG importer.
PEER_COUNT="$(grep -Eic '^[[:space:]]*\[[Pp][Ee][Ee][Rr][[:space:]]*\][[:space:]]*$' "$AWG_CONF" || true)"
[ "$PEER_COUNT" = "1" ] || die "В .conf должна быть ровно одна секция [Peer]; найдено: ${PEER_COUNT:-0}"

# The tunnel address must be IPv4. IPv6 AllowedIPs/DNS are ignored below.
ADDRESS_VALUE="$(awk '
    BEGIN { sec="" }
    /^[[:space:]]*[#;]/ { next }
    /^[[:space:]]*\[/ {
        sec=tolower($0); gsub(/[[:space:]\[\]]/, "", sec); next
    }
    sec=="interface" {
        p=index($0,"=")
        if (p>0) {
            k=tolower($0); sub(/[[:space:]]*=.*/, "", k)
            if (k=="address") { v=substr($0,p+1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit }
        }
    }
' "$AWG_CONF")"
[ -n "$ADDRESS_VALUE" ] || die "В [Interface] отсутствует Address."
case "$ADDRESS_VALUE" in
    *:*) die "В Address обнаружен IPv6. Этот установщик работает только с IPv4; оставь IPv4-адрес(а) в .conf." ;;
esac

mkdir -p "$AWG_TMP"
chmod 700 "$AWG_TMP"

log "Проверка и установка пакетов AmneziaWG 3.1."
wget -q -O "$AWG_TMP/amneziawg-install.sh" "$AWG_INSTALLER_URL" ||
    die "Не удалось скачать установщик AWG."
[ -s "$AWG_TMP/amneziawg-install.sh" ] || die "Скачанный установщик AWG пуст."
grep -q 'prepare_awg_packages' "$AWG_TMP/amneziawg-install.sh" ||
    die "Скачанный файл не похож на ожидаемый установщик AWG."

# The upstream installer detects the exact target/subtarget and kernel package,
# installs the signed 2Grey feed packages, then imports every supported AWG 3.1
# field from the supplied .conf file.
sh "$AWG_TMP/amneziawg-install.sh" -a 3.1 -c "$AWG_CONF" -i "$AWG_IF" -e ||
    die "Установщик AmneziaWG завершился с ошибкой."

log "Установка dnsmasq-full."
apk add dnsmasq-full || die "Не удалось установить dnsmasq-full."

# Force the imported peer to carry IPv4 only and prevent AllowedIPs from
# installing a default route into the main routing table.
PEER_SECTION="network.@amneziawg_${AWG_IF}[0]"
uci -q get "$PEER_SECTION" >/dev/null 2>&1 ||
    die "Не найдена peer-секция network.amneziawg_${AWG_IF} после импорта .conf."

uci -q delete "${PEER_SECTION}.allowed_ips" || true
uci add_list "${PEER_SECTION}.allowed_ips=0.0.0.0/0"
uci set "${PEER_SECTION}.route_allowed_ips=0"

# DNS from the tunnel profile is not used; LAN clients resolve through router
# dnsmasq, which fills the nftables set from the fixed domain list.
uci -q delete "network.${AWG_IF}.dns" || true

# Keep the tunnel firewall zone IPv4-only.
ZONE_SECTION="$(uci -q show firewall | sed -n "/\\.name='${AWG_IF}'$/s/\\.name=.*//p" | grep '^firewall\.@zone\[' | head -n 1 || true)"
if [ -z "$ZONE_SECTION" ]; then
    uci add firewall zone >/dev/null
    ZONE_SECTION="firewall.@zone[-1]"
fi
uci set "${ZONE_SECTION}.name=${AWG_IF}"
uci set "${ZONE_SECTION}.network=${AWG_IF}"
uci set "${ZONE_SECTION}.input=REJECT"
uci set "${ZONE_SECTION}.output=ACCEPT"
uci set "${ZONE_SECTION}.forward=REJECT"
uci set "${ZONE_SECTION}.masq=1"
uci set "${ZONE_SECTION}.mtu_fix=1"
uci set "${ZONE_SECTION}.family=ipv4"
uci -q delete "${ZONE_SECTION}.masq6" || true

# Add/refresh LAN -> AWG forwarding (IPv4 only).
FWD_SECTION="$(uci -q show firewall | sed -n "/\\.name='${AWG_IF}-lan'$/s/\\.name=.*//p" | grep '^firewall\.@forwarding\[' | head -n 1 || true)"
if [ -z "$FWD_SECTION" ]; then
    uci add firewall forwarding >/dev/null
    FWD_SECTION="firewall.@forwarding[-1]"
fi
uci set "${FWD_SECTION}.name=${AWG_IF}-lan"
uci set "${FWD_SECTION}.src=lan"
uci set "${FWD_SECTION}.dest=${AWG_IF}"
uci set "${FWD_SECTION}.family=ipv4"

# dnsmasq nftset target declared by the fixed ru-routes file:
# 4#inet#fw4#vpn_domains
IPSET_SECTION="$(uci -q show firewall | sed -n "/\\.name='vpn_domains'$/s/\\.name=.*//p" | grep '^firewall\.@ipset\[' | head -n 1 || true)"
if [ -z "$IPSET_SECTION" ]; then
    uci add firewall ipset >/dev/null
    IPSET_SECTION="firewall.@ipset[-1]"
fi
uci set "${IPSET_SECTION}.name=vpn_domains"
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
