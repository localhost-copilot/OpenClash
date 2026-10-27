# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=openwrt/rootfs:armsr-armv8-24.10.8
ARG BASE_PLATFORM=linux/aarch64_generic
FROM --platform=linux/aarch64_generic openwrt/rootfs:armsr-armv8-24.10.8 AS openwrt-keys
FROM --platform=linux/arm64 golang:1.25-alpine AS core
WORKDIR /src
COPY --from=mihomo . .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -tags with_gvisor -o /clash .

FROM --platform=linux/arm64 alpine:3.20 AS peer
RUN apk add --no-cache python3 iproute2 curl
COPY --from=core /clash /usr/bin/clash
COPY tests/device-egress-docker/peer.py /harness/peer.py
ENTRYPOINT ["python3", "/harness/peer.py"]

FROM --platform=linux/arm64 alpine:3.20 AS translations
RUN apk add --no-cache build-base
COPY luci-app-openclash/tools/po2lmo/src/ /src/
COPY luci-app-openclash/po/zh-cn/openclash.zh-cn.po /src/openclash.po
RUN cc -o /po2lmo /src/po2lmo.c /src/template_lmo.c && /po2lmo /src/openclash.po /openclash.zh-cn.lmo

# This upstream tag is mislabeled aarch64_generic, despite containing AArch64 ELF.
FROM --platform=${BASE_PLATFORM} ${BASE_IMAGE} AS router-deps
ARG ROUTER_FLAVOR=openwrt
COPY --from=openwrt-keys /etc/opkg/keys/ /etc/opkg/keys/
COPY tests/device-egress-docker/qwrt-prepare.sh /harness/qwrt-prepare.sh
RUN if [ "$ROUTER_FLAVOR" = qwrt ]; then /bin/sh /harness/qwrt-prepare.sh; else \
    mkdir -p /var/lock && opkg update && opkg remove dnsmasq && \
    opkg install --force-overwrite dnsmasq-full unzip kmod-tun bash curl ca-bundle ip-full ruby ruby-yaml ruby-json \
      ruby-bigdecimal ruby-tempfile flock firewall4 luci-base luci-compat \
      luci-theme-bootstrap luci-i18n-base-zh-cn uhttpd uhttpd-mod-ubus rpcd-mod-luci \
      liblucihttp-lua lua luci-lib-ip luci-lib-jsonc rpcd-mod-file luci-i18n-firewall-zh-cn && \
    opkg install nftables-json; fi && \
    rm -f /etc/rc.d/*dropbear /etc/rc.d/*odhcpd /etc/rc.d/*sysntpd /etc/rc.d/*urngd
FROM router-deps AS router
COPY luci-app-openclash/root/ /
COPY luci-app-openclash/luasrc/ /usr/lib/lua/luci/
COPY --from=translations /openclash.zh-cn.lmo /usr/lib/lua/luci/i18n/openclash.zh-cn.lmo
COPY --from=core /clash /etc/openclash/core/clash_meta
COPY tests/device-egress-docker/router-setup.sh /harness/setup.sh
COPY tests/device-egress-docker/backend.lua /harness/backend.lua
RUN chmod +x /etc/init.d/openclash* /usr/share/openclash/* /harness/setup.sh && \
    /harness/setup.sh && printf 'test\ntest\n' | passwd root
ENTRYPOINT ["/harness/entrypoint.sh"]
CMD ["/sbin/init"]

FROM router-deps AS master
COPY tests/device-egress-docker/.cache/master.ipk /tmp/master.ipk
RUN opkg install --force-reinstall /tmp/master.ipk && rm -f /tmp/master.ipk
COPY --from=core /clash /etc/openclash/core/clash_meta
COPY tests/device-egress-docker/router-setup.sh /harness/setup.sh
RUN chmod +x /etc/init.d/openclash /usr/share/openclash/* /harness/setup.sh && \
    /harness/setup.sh && printf 'test\ntest\n' | passwd root
ENTRYPOINT ["/harness/entrypoint.sh"]
CMD ["/sbin/init"]

# QWRT keeps its preinstalled package; upstream starts with the master IPK.
FROM router-deps AS upgrade
ARG ROUTER_FLAVOR=openwrt
COPY tests/device-egress-docker/.cache/master.ipk /harness/previous.ipk
RUN if [ "$ROUTER_FLAVOR" = openwrt ]; then opkg install /harness/previous.ipk; fi
COPY --from=core /clash /etc/openclash/core/clash_meta
COPY tests/device-egress-docker/router-setup.sh /harness/setup.sh
COPY tests/device-egress-docker/backend.lua /harness/backend.lua
COPY tests/device-egress-docker/.cache/feature.ipk /harness/feature.ipk
RUN chmod +x /harness/setup.sh && /harness/setup.sh && printf 'test\ntest\n' | passwd root
ENTRYPOINT ["/harness/entrypoint.sh"]
CMD ["/sbin/init"]
