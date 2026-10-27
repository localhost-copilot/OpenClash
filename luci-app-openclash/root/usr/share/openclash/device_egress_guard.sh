#!/bin/sh
# Only device-list mutations and boot regenerate this table. OpenClash's own
# stop/start_fail/revert paths must never call this script or remove the cache.
command -v nft >/dev/null 2>&1 && command -v fw4 >/dev/null 2>&1 || exit 1
mkdir -p /etc/openclash /var/lock || exit 1
exec 8>/var/lock/openclash-device-guard.lock
flock -x 8 || exit 1
candidate=$(mktemp /etc/openclash/.device-guard.XXXXXX) || exit 1
snapshot=$(mktemp /etc/openclash/.device-guard-json.XXXXXX) || exit 1
trap 'rm -f "$candidate" "$snapshot"' EXIT HUP INT TERM
valid=1
cache_loaded=0

emergency() {
	# Keep this fallback independent of the Lua renderer and its dependencies.
	cat > "$candidate" <<'EOF'
add table inet openclash_guard
delete table inet openclash_guard
table inet openclash_guard {
 chain prerouting {
  type filter hook prerouting priority -300; policy drop;
  iifname "lo" accept
  fib daddr type local accept
  fib daddr oifname "br-lan" accept
 }
 chain forward {
  type filter hook forward priority -10; policy drop;
  iifname "br-lan" oifname "br-lan" accept
 }
 chain output {
  type filter hook output priority -10; policy drop;
  oifname { "lo", "br-lan" } accept
 }
}
EOF
	valid=0
}

case "$1" in
	load)
		if lua /usr/share/openclash/device_egress.lua check-cache 2>/dev/null; then
			cp /etc/openclash/device-guard.nft "$candidate" && cache_loaded=1 || emergency
		else
			lua /usr/share/openclash/device_egress.lua render > "$candidate" || emergency
		fi
		;;
	install) cp "$2" "$candidate" || emergency ;;
	emergency) emergency ;;
	*) lua /usr/share/openclash/device_egress.lua render > "$candidate" || emergency ;;
esac
[ -s "$candidate" ] || emergency
if ! nft -c -f "$candidate" || ! nft -f "$candidate"; then
	emergency
	nft -c -f "$candidate" && nft -f "$candidate" || {
		logger -t openclash "Cannot install even the emergency device guard"
		exit 1
	}
fi
# Replaying a valid cache at boot/postinst must leave that file untouched.
if [ "$cache_loaded" != 1 ] || [ "$valid" != 1 ]; then
	mv -f "$candidate" /etc/openclash/device-guard.nft || exit 1
fi
if nft -j list table inet openclash_guard > "$snapshot" 2>/dev/null; then
	mv -f "$snapshot" /etc/openclash/device-guard.json || exit 1
else
	rm -f /etc/openclash/device-guard.json
fi
# Enabling protection must also evict accelerated established flows.
nft flush flowtable inet fw4 ft 2>/dev/null || true
[ "$valid" = 1 ]
