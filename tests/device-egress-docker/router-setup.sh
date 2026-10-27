#!/bin/sh
set -eu
mkdir -p /etc/openclash/config /etc/openclash/history /etc/crontabs /var/lock
touch /etc/crontabs/root
cat > /harness/entrypoint.sh <<'EOF'
#!/bin/sh
# Management bridge exists solely for the loopback-published LuCI port. It must
# never become a path from this test stack to the host LAN or public Internet.
ip route del default 2>/dev/null || true
ip -6 route del default 2>/dev/null || true
ip route replace blackhole 192.168.50.1/32
# Upstream ucode modules use the newer ubus path; QWRT procd uses the old one.
if [ -f /harness/qwrt ]; then
 mkdir -p /var/run/ubus
 ln -sf ../ubus.sock /var/run/ubus/ubus.sock
fi
exec "$@"
EOF
chmod +x /harness/entrypoint.sh
if [ -f /harness/qwrt ]; then
 cat > /etc/init.d/harness_ubus <<'EOF'
#!/bin/sh /etc/rc.common
START=11
start() {
 mkdir -p /var/run/ubus
 ln -sf ../ubus.sock /var/run/ubus/ubus.sock
}
EOF
 chmod +x /etc/init.d/harness_ubus
 /etc/init.d/harness_ubus enable
fi
cat > /etc/init.d/harness_observe <<'EOF'
#!/bin/sh /etc/rc.common
START=19
start() {
 guard=no; core=no
 nft list table inet openclash_guard >/dev/null 2>&1 && guard=yes
 pidof clash >/dev/null && core=yes
 echo "guard=$guard core=$core" > /tmp/harness-guard-boot
}
EOF
cat > /etc/init.d/zz_harness_ready <<'EOF'
#!/bin/sh /etc/rc.common
START=99
start() { touch /tmp/harness-boot-ready; }
EOF
chmod +x /etc/init.d/harness_observe /etc/init.d/zz_harness_ready
/etc/init.d/harness_observe enable
/etc/init.d/zz_harness_ready enable
cat > /etc/config/network <<'EOF'
config interface 'loopback'
 option device 'lo'
 option proto 'static'
 option ipaddr '127.0.0.1'
 option netmask '255.0.0.0'
config interface 'lan'
 option device 'eth0'
 option proto 'static'
 option ipaddr '10.231.0.2'
 option netmask '255.255.255.0'
 option ip6addr 'fd42:231::2/64'
config interface 'wan'
 option device 'eth1'
 option proto 'static'
 option ipaddr '203.0.113.2'
 option netmask '255.255.255.0'
 option ip6addr 'fd42:232::2/64'
EOF
cat > /etc/config/firewall <<'EOF'
config defaults
 option input 'ACCEPT'
 option output 'ACCEPT'
 option forward 'REJECT'
 option flow_offloading '0'
config zone
 option name 'lan'
 list network 'lan'
 option input 'ACCEPT'
 option output 'ACCEPT'
 option forward 'ACCEPT'
config zone
 option name 'wan'
 list network 'wan'
 option input 'ACCEPT'
 option output 'ACCEPT'
 option forward 'REJECT'
 option masq '1'
config forwarding
 option src 'lan'
 option dest 'wan'
EOF
cat > /etc/openclash/config/harness.yaml <<'EOF'
mode: rule
log-level: info
allow-lan: true
external-controller: 0.0.0.0:9090
secret: harness
dns:
  enable: true
  listen: 0.0.0.0:7874
  enhanced-mode: redir-host
  nameserver: [203.0.113.10]
proxies:
  - name: node-a
    type: ss
    server: 203.0.113.10
    port: 8388
    cipher: aes-128-gcm
    password: docker-only
    udp: true
proxy-groups:
  - name: safe-auto
    type: url-test
    proxies: [node-a]
    url: http://203.0.113.10:8080/
    interval: 3600
  - name: unsafe-select
    type: select
    proxies: [DIRECT, node-a]
rules:
  - MATCH,DIRECT
EOF
cp /etc/openclash/config/harness.yaml /harness/original.yaml
uci batch <<'EOF'
set openclash.config.enable='0'
set openclash.config.config_path='/etc/openclash/config/harness.yaml'
set openclash.config.dashboard_password='harness'
set openclash.config.en_mode='redir-host'
set openclash.config.operation_mode='redir-host'
set openclash.config.enable_redirect_dns='0'
set openclash.config.disable_udp_quic='0'
set openclash.config.china_ip_route='1'
set openclash.config.china_ip6_route='0'
set openclash.config.router_self_proxy='0'
set openclash.config.intranet_allowed='0'
set openclash.config.log_level='info'
set luci.main.lang='zh_cn'
commit
EOF
# Local replacement for the downloaded china bypass data: the endpoint must be
# bypassed by ordinary OpenClash chains, but never by the device listener.
cat > /etc/openclash/china_ip_route.ipset <<'EOF'
define china_ip_route = { 203.0.113.10/32 }
add set inet fw4 china_ip_route { type ipv4_addr; flags interval; auto-merge; }
add element inet fw4 china_ip_route $china_ip_route
EOF
cat > /etc/openclash/china_ip6_route.ipset <<'EOF'
define china_ip6_route = { fd42:232::10/128 }
add set inet fw4 china_ip6_route { type ipv6_addr; flags interval; auto-merge; }
add element inet fw4 china_ip6_route $china_ip6_route
EOF
# No geo rules are used, so no external geo assets are needed.
rm -f /etc/uci-defaults/luci-openclash
sed -i 's/@OPENCLASH_VERSION@/docker-test/g' /usr/lib/lua/luci/view/openclash/*.htm /usr/lib/lua/luci/openclash.lua
/etc/init.d/openclash enable
[ ! -f /etc/init.d/openclash_guard ] || /etc/init.d/openclash_guard enable
/etc/init.d/uhttpd enable
/etc/init.d/rpcd enable
cp /etc/config/openclash /harness/clean-uci
