include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-openclash
PKG_VERSION:=0.48.002.2
PKG_MAINTAINER:=vernesong <https://github.com/vernesong/OpenClash>

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)/config
	config PACKAGE_kmod-inet-diag
	default y if PACKAGE_$(PKG_NAME)

	config PACKAGE_luci-compat
	default y if PACKAGE_$(PKG_NAME)

	config PACKAGE_kmod-nft-tproxy
	default y if PACKAGE_firewall4

	config PACKAGE_kmod-ipt-nat
	default y if ! PACKAGE_firewall4

	config PACKAGE_iptables-mod-tproxy
	default y if ! PACKAGE_firewall4

	config PACKAGE_iptables-mod-extra
	default y if ! PACKAGE_firewall4

	config PACKAGE_dnsmasq_full_ipset
	default y if ! PACKAGE_firewall4

	config PACKAGE_dnsmasq_full_nftset
	default y if PACKAGE_firewall4

	config PACKAGE_ipset
	default y if ! PACKAGE_firewall4
endef

define Package/$(PKG_NAME)
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=LuCI support for clash
	PKGARCH:=all
	DEPENDS:=+dnsmasq-full +bash +curl +ca-bundle +ip-full \
	+ruby +ruby-yaml +ruby-json +ruby-tempfile +flock +kmod-tun +unzip
	MAINTAINER:=vernesong
endef

define Package/$(PKG_NAME)/description
	A LuCI support for clash
endef

define Build/Prepare
	$(CP) $(CURDIR)/root $(PKG_BUILD_DIR)
	$(CP) $(CURDIR)/luasrc $(PKG_BUILD_DIR)
	# Replace the @OPENCLASH_VERSION@ token with the package version (browser asset cache keys).
	sed -i 's|@OPENCLASH_VERSION@|$(PKG_VERSION)|g' $(PKG_BUILD_DIR)/luasrc/openclash.lua $(PKG_BUILD_DIR)/luasrc/view/openclash/*.htm
	$(foreach po,$(wildcard ${CURDIR}/po/zh-cn/*.po), \
		po2lmo $(po) $(PKG_BUILD_DIR)/$(patsubst %.po,%.lmo,$(notdir $(po)));)
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/init.d/openclash
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/init.d/openclash_guard
	chmod -R 0755 $(PKG_BUILD_DIR)/root/usr/share/openclash/
	exit 0
endef

define Build/Configure
endef

define Build/Compile
endef

# The nft cache is runtime state, absent from the payload: opkg briefly unpacks
# even modified conffiles before restoring them, so an empty seed is unsafe.
define Package/$(PKG_NAME)/conffiles
/etc/config/openclash
endef

define Package/$(PKG_NAME)/preinst
#!/bin/sh
	if [ -f "/etc/config/openclash" ] && [ ! -f "/tmp/openclash.bak" ]; then
		cp -f "/etc/config/openclash" "/tmp/openclash.bak" >/dev/null 2>&1
		cp -rf "/etc/openclash" "/tmp/openclash" >/dev/null 2>&1
		cp -rf "/usr/share/openclash/ui" "/tmp/openclash_ui" >/dev/null 2>&1
		cp -rf "/www/luci-static/resources/openclash/pac" "/tmp/pac" >/dev/null 2>&1
	fi
	exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
	if [ -z "$${IPKG_INSTROOT}" ]; then
		/etc/init.d/openclash_guard enable
		/etc/init.d/openclash_guard start
	fi
	exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
	[ -n "$$(pidof clash)" ] && /etc/init.d/openclash stop 2>/dev/null
	if [ -f "/etc/config/openclash" ] && [ ! -f "/tmp/openclash.bak" ]; then
		cp -f "/etc/config/openclash" "/tmp/openclash.bak" >/dev/null 2>&1
		cp -rf "/etc/openclash" "/tmp/openclash" >/dev/null 2>&1
		cp -rf "/usr/share/openclash/ui" "/tmp/openclash_ui" >/dev/null 2>&1
		cp -rf "/www/luci-static/resources/openclash/pac" "/tmp/pac" >/dev/null 2>&1
	fi
	exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
	# Version upgrades pass "upgrade"; same-version forced reinstalls pass "remove".
	if [ "$$1" != "upgrade" ] && [ "$${PKG_UPGRADE}" != "1" ] && [ -z "$${IPKG_INSTROOT}" ]; then
		# Detach with closed stdio so cleanup survives opkg (and LuCI) exiting.
		if command -v setsid >/dev/null 2>&1; then
			GUARD_DETACH="setsid /bin/sh"
		elif command -v nohup >/dev/null 2>&1; then
			GUARD_DETACH="nohup /bin/sh"
		else
			# OpenWrt/QWRT BusyBox may omit both applets; -b creates a new session.
			GUARD_DETACH="start-stop-daemon -S -b -n oc-guard-release -x /bin/sh --"
		fi
		$$GUARD_DETACH -c '
			sleep 20
			[ ! -e /etc/init.d/openclash_guard ] || exit 0
			[ ! -e /usr/share/openclash/device_egress_guard.sh ] || exit 0
			status="$$(opkg status luci-app-openclash 2>/dev/null)" || exit 0
			[ -z "$$status" ] || exit 0
			nft delete table inet openclash_guard 2>/dev/null || true
			if [ -f /var/run/openclash-device-route ]; then
				ip rule del pref 1886 fwmark 0x40000 lookup 789 2>/dev/null || true
				ip route del local default dev lo table 789 2>/dev/null || true
				rm -f /var/run/openclash-device-route
			fi
			rm -f /etc/rc.d/S18openclash_guard /etc/rc.d/K99openclash_guard
			rm -rf /etc/openclash
		' </dev/null >/dev/null 2>&1 &
	fi
	DEFAULT_DNSMASQ_CFGID="$$(uci -q show "dhcp.@dnsmasq[0]" | awk 'NR==1 {split($$0, conf, /[.=]/); print conf[2]}' 2>/dev/null)"
	if [ -f "/tmp/etc/dnsmasq.conf.$$DEFAULT_DNSMASQ_CFGID" ]; then
	   DNSMASQ_CONF_DIR="$$(awk -F '=' '/^conf-dir=/ {print $$2}' "/tmp/etc/dnsmasq.conf.$$DEFAULT_DNSMASQ_CFGID" 2>/dev/null)"
	else
	   DNSMASQ_CONF_DIR="/tmp/dnsmasq.d"
	fi
	DNSMASQ_CONF_DIR=$${DNSMASQ_CONF_DIR%*/}
	if [ "$$1" != "upgrade" ]; then
		rm -rf /etc/config/openclash >/dev/null 2>&1
	fi
	rm -rf /tmp/openclash.log >/dev/null 2>&1
	rm -rf /tmp/openclash_start.log >/dev/null 2>&1
	rm -rf /tmp/openclash.change >/dev/null 2>&1
	rm -rf /usr/share/openclash >/dev/null 2>&1
	rm -rf /tmp/openclash_version_history.json >/dev/null 2>&1
	rm -rf /tmp/openclash_cdn_info.json >/dev/null 2>&1
	rm -rf /tmp/openclash_tpl_cache >/dev/null 2>&1
	rm -rf $${DNSMASQ_CONF_DIR}/dnsmasq_openclash_custom_domain.conf >/dev/null 2>&1
	rm -rf $${DNSMASQ_CONF_DIR}/dnsmasq_openclash_chnroute_pass.conf >/dev/null 2>&1
	rm -rf $${DNSMASQ_CONF_DIR}/dnsmasq_openclash_chnroute6_pass.conf >/dev/null 2>&1
	rm -rf /tmp/etc/openclash >/dev/null 2>&1
	rm -rf /tmp/openclash_announcement >/dev/null 2>&1
	rm -rf /www/luci-static/resources/openclash >/dev/null 2>&1
	rm -rf /tmp/oix* >/dev/null 2>&1
	rm -f /etc/nginx/conf.d/openclash.conf >/dev/null 2>&1
	rm -f /etc/nginx/conf.d/openclash.locations >/dev/null 2>&1
	[ -x /etc/init.d/nginx ] && /etc/init.d/nginx reload >/dev/null 2>&1
	uci -q delete firewall.openclash
	uci -q commit firewall
	[ -f "/etc/config/ucitrack" ] && {
	uci -q delete ucitrack.@openclash[-1]
	uci -q commit ucitrack
	}
	rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* /var/luci-indexcache /var/luci-indexcache.* >/dev/null 2>&1
	rm -rf /tmp/luci-modulecache /var/luci-modulecache >/dev/null 2>&1
	exit 0
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/*.*.lmo $(1)/usr/lib/lua/luci/i18n/
	$(CP) $(PKG_BUILD_DIR)/root/* $(1)/
	$(CP) $(PKG_BUILD_DIR)/luasrc/* $(1)/usr/lib/lua/luci/
	$(INSTALL_DIR) $(1)/etc/rc.d
	$(LN) ../init.d/openclash_guard $(1)/etc/rc.d/S18openclash_guard
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
