#!/bin/sh
set -eu
touch /harness/qwrt
mkdir -p /var/lock
# This QWRT image ships fw3 despite its nft 1.1.3 binary. Exercise the feature's
# fw4 path using official OpenWrt userspace; kernel modules come from OrbStack.
cat > /etc/opkg/distfeeds.conf <<'EOF'
src/gz openwrt_base https://downloads.openwrt.org/releases/24.10.3/packages/aarch64_generic/base
src/gz openwrt_luci https://downloads.openwrt.org/releases/24.10.3/packages/aarch64_generic/luci
src/gz openwrt_packages https://downloads.openwrt.org/releases/24.10.3/packages/aarch64_generic/packages
EOF
opkg remove --force-depends firewall
opkg update
# Do not replace QWRT's installed Ruby, LuCI, procd or nft 1.1.3 with upstream
# versions. Only fill missing runtime dependencies.
opkg install --force-overwrite ruby-json ruby-tempfile flock rpcd-mod-luci \
    liblucihttp-lua rpcd-mod-file ucode ucode-mod-fs ucode-mod-ubus ucode-mod-uci
# fw4's declared kmods target another kernel. Use host modules and the existing
# JSON-capable QWRT nft binary, rather than installing/downgrading either.
cd /tmp
fw4_package=firewall4_2024.12.18~18fc0ead-r1_aarch64_generic.ipk
curl -fL "https://downloads.openwrt.org/releases/24.10.3/packages/aarch64_generic/base/$fw4_package" -o /tmp/firewall4.ipk
echo '50fcfbf67c62d1e87546622516c00e2eba77eeddabad57a2a02ed5f289611e0e  /tmp/firewall4.ipk' | sha256sum -c -
mkdir -p /tmp/fw4-package
tar -xzf /tmp/firewall4.ipk -C /tmp/fw4-package
tar -xzf /tmp/fw4-package/data.tar.gz -C /
rm -rf /tmp/fw4-package
rm -f /tmp/firewall4.ipk
# QWRT's unrelated first-boot defaults change LAN to DHCP and start modem/proxy
# daemons. Keep the isolated fixture deterministic, including the Design theme.
rm -f /etc/uci-defaults/* /etc/rc.d/*
for service in boot system sysctl log rpcd firewall network cron done uhttpd; do
    [ ! -x "/etc/init.d/$service" ] || "/etc/init.d/$service" enable
done
uci set luci.main.mediaurlbase=/luci-static/design
uci set luci.themes.Design=/luci-static/design
uci commit luci
