# Local Device Egress integration harness

From the repository root:

```sh
tests/device-egress-docker/run.sh
tests/device-egress-docker/run.sh ui
tests/device-egress-docker/run.sh down
ROUTER_IMAGE=qwrt UI_PORT=18082 tests/device-egress-docker/run.sh
ROUTER_IMAGE=qwrt UI_PORT=18082 tests/device-egress-docker/run.sh upgrade
ROUTER_IMAGE=openwrt UI_PORT=18082 tests/device-egress-docker/run.sh upgrade
ROUTER_IMAGE=qwrt UI_PORT=18082 tests/device-egress-docker/run.sh ui
```

Requires Docker with Compose v2.36+ (interface naming), Linux arm64 privileged
containers with nft TPROXY support, Python 3 and Make on the host, a C compiler
(unless po2lmo is already installed), and a local mihomo
checkout beside this repository. Tested with OrbStack on Apple Silicon.
Override the checkout with `MIHOMO_SOURCE=/absolute/path/to/mihomo`.
`ROUTER_IMAGE` accepts `openwrt` (default) or `qwrt`. The latter uses the locally
pulled `coolsnowwolf/qwrt:arm64-latest` image: its base stage selects
`linux/amd64` to match the incorrect manifest; its AArch64 binaries execute
natively and every run asserts `uname -m` is `aarch64`. Derived images use
`linux/arm64` metadata.
The Go builder runs in Docker with `CGO_ENABLED=0`, targeting linux/arm64.
OpenWrt packages and builder dependencies are downloaded during image builds;
test destinations and proxy traffic are entirely local.

The test command builds feature, peer, and master images, creates fresh
containers, runs every scenario, prints a PASS/FAIL table, and tears down with an
EXIT/INT/TERM trap. A failed scenario does not prevent later scenarios from
running. Failures return a nonzero exit code. `down` also removes an interrupted
UI session. Images and build caches are retained for quick reruns.

`ui` creates three rows: 走节点, 已阻断 (missing target), and 已暂停. It verifies
their backend states and the authenticated LuCI HTML, then leaves the stack up.
Open the page at:

<http://127.0.0.1:18080/cgi-bin/luci/admin/services/openclash/device-egress>

Login: **root / test**. Bootstrap, LuCI compatibility libraries, uhttpd, and the
package's compiled Simplified Chinese translations are installed. If another local service owns port 18080, use
`UI_PORT=18081 tests/device-egress-docker/run.sh ui`; the harness never stops
unrelated containers. Use the same override for `down` if desired.

For repeatable mobile layout checks, run `ui-geometry.js` against that preview
with `playwright-core` available to Node and a local Chromium executable:

```sh
NODE_PATH=/path/to/node_modules CHROMIUM_PATH=/path/to/chromium \
  ROUTER_IMAGE=qwrt UI_PORT=18082 node tests/device-egress-docker/ui-geometry.js
```

It checks add/edit and pause/delete dialogs at 390×844: header/body separation,
visible footer buttons with successful `elementFromPoint` hits, and the final
page card/note scrolling above a fixed bottom navbar. All page requests are
restricted to the preview's loopback origin. No screenshots are taken.

## Topology and isolation

```text
client  10.231.0.20, fd42:231::20, 00:16:3e:00:00:20 ─┐
                                                     ├─ lan ─ router ─ wan ─ internet/node
client2 10.231.0.21, fd42:231::21, 00:16:3e:00:00:21 ─┘        .2               .10
```

* LAN: `10.231.0.0/24`, `fd42:231::/64`; router `.2` / `::2`.
* WAN: `203.0.113.0/24`, `fd42:232::/64`; router `.2`, WAN peer `.10`.
* Both data networks are Docker `internal` networks. There is no host networking.
  Clients have a default route through the OpenWrt container, never the Docker
  gateway. The WAN peer routes LAN IPv6 back through OpenWrt.
  Peer interfaces disable IPv6 RA/autoconfiguration, and client IPv6 default
  routes have metric 1, so SLAAC addresses or learned gateways cannot replace
  the fixed identities and routes under test.
* Docker cannot publish a port on an internal-only container. A third management
  bridge exists solely to publish LuCI on host loopback. Before `/sbin/init`, the
  router entrypoint deletes both default routes and installs a blackhole route
  to `192.168.50.1/32`. No test probes that address or any other real router.
* The WAN peer serves caller-IP HTTP on 8080 and UDP echo on 9000, for both IP
  families. Its mihomo Shadowsocks listener is on 8388. DIRECT traffic is
  masqueraded to `203.0.113.2`. Traffic relayed by node-a originates from
  `203.0.113.10`, including UDP. An unbound IPv6 request observes its own LAN
  IPv6 address because IPv6 is routed without NAT.

## What is exercised

The default router uses `openwrt/rootfs:armsr-armv8-24.10.8`,
real netifd, fw4/nftables, and **the unmodified service entrypoints under procd**
(`/sbin/init` as PID 1). The upstream base's image metadata incorrectly says
`aarch64_generic`; its FROM explicitly selects that platform. The resulting
images and Go binary are linux/arm64.

QWRT uses OpenWrt 24.10.3 userspace with its shipped LuCI, Ruby 3.3.6, procd,
nft 1.1.3 and luci-theme-design 5.7.6. **This image ships fw3**, so the harness
replaces fw3 with official OpenWrt fw4 2024.12.18 and its ucode dependencies.
Missing Ruby JSON/tempfile and LuCI runtime packages are also installed.
Upstream package signatures use keys copied from the official OpenWrt rootfs;
the separately downloaded fw4 IPK is SHA256 checked and its userspace data
extracted directly. QWRT opkg cannot resolve its upstream kernel dependencies;
the container uses OrbStack's kernel/modules.
QWRT's unrelated first-boot defaults and enabled services are cleared before
the harness configures its isolated interfaces; Design is explicitly selected.
This is a QWRT base with fw4 added, not a test of its stock fw3 firewall path.

The package's root tree and LuCI files are installed directly, including its
real init scripts, guard renderer/installer, Ruby listener generator, and JSON
backend. The harness calls `/etc/init.d/openclash` for lifecycle actions and the
same `luci.device_egress_service.mutate` backend used by the UI for save, pause,
resume, rejection, and deletion. It does not recreate firewall or listener
generation logic. A START=19 observer records whether the START=18 guard is
present before OpenClash starts; a six-second service boot delay makes the
blocked interval observable after container restart.

The Clash fixture ends in `MATCH,DIRECT` and uses a local china-bypass set
containing the test endpoint. It includes node-a, safe-auto (url-test without
DIRECT), and unsafe-select (select containing DIRECT). This makes a lost binding
visibly leak the router's DIRECT source IP. No geo databases, public test URLs,
DNS servers, provider downloads, or real router are needed for the assertions.
OpenClash's generated background NTP lookup cannot leave the isolated topology.

Each numbered scenario tests fresh TCP HTTP and UDP echo sockets from both
clients. Restart, crash, and reboot also have independent continuous TCP and UDP
pollers on both clients (up to 200 requests/second/protocol; blocked requests time
out after 350ms). They record every observed source and reject any unexpected
egress. This samples the transition; it is not a proof about every packet or
every possible scheduling interleaving. SIGKILL checks the failure interval
before procd's normal five-second respawn. A port collision forces the real
listener-generation `start_fail` path. IPv4 address changes retain a valid route
so a missing route cannot masquerade as protection.

Scenario 12 builds and installs an IPK from `git archive master` on the same
selected router base, with the same
dependencies, network, UCI, raw YAML and a custom firewall script returning 23.
It compares generated YAML as parsed JSON and actual `inet fw4` rules after
start, firewall restart/reload, and stop. Only handles, counters and nft metadata
are removed; rules, expressions and ordering are retained. The baseline image
has no Device Egress modules or guard include. The master revision is recorded.

The group-hardening case checks the actual generated `empty-fallback: REJECT`
and `exclude-type: Direct|Compatible`. It routes the unbound control's TCP and
UDP through the same group via the ordinary SOCKS inbound. It then injects a
late Direct adapter into that generated group and reloads it through the core
API: the adapter is excluded, the resulting empty group rejects, and both
bound and shared ordinary traffic fail. The unrelated select group is checked
for absence of these additions. This models a late provider membership change;
it does not exercise a remote provider downloader.

**Shared-group consequence:** hardening changes the selected group and its
selected child graph globally. Unbound devices that use those groups also lose
Direct/Compatible members and receive REJECT when no allowed member remains.
They do not retain mihomo's default COMPATIBLE/direct empty fallback. Unbound
traffic using other groups or the fixture's ordinary MATCH,DIRECT remains
unchanged. Removing the last binding restores the saved original group fields.

## Evidence and limits

Ignored `results/` contains the last table, per-transition packet observations,
master/feature YAML and ruleset snapshots, group fixture, image build logs,
failure diagnostics, and container logs. `.cache/master/` contains the archived
baseline. New runs store evidence separately in `results/openwrt/` and
`results/qwrt/`. Failures never get relabeled as skipped or passed. To run existing
repository unit tests separately (requires local Ruby, Lua/LuaJIT, Node, Python):

```sh
python3 -m unittest discover -s tests -v
```

This harness does not test physical boot, hardware/software flow offload,
Wi-Fi/MAC rotation, DHCP discovery, DNS hijacking modes, HTTPS/STUN, TUN modes,
iptables firmware, UI layouts beyond the separate mobile geometry checks, or
real subscription/provider downloads. HTTP and UDP echo make egress observable
without external infrastructure. The UI command renders the real page for
manual inspection.

The real router's **kernel 5.4 is not reproduced**.
OrbStack uses kernel 7.x, including when QWRT is selected. Results
are local integration evidence, not a substitute for compatibility validation
on the router kernel, physical interfaces and offload implementation.

## SDK-free package and upgrade test

```sh
tests/device-egress-docker/build-ipk.sh
ROUTER_IMAGE=qwrt UI_PORT=18082 tests/device-egress-docker/run.sh upgrade
```

The builder writes `.cache/feature.ipk`. Override `PACKAGE_SOURCE` and
`PACKAGE_OUTPUT` to build another tree. It requires host Make, Python 3, and a C
compiler when `po2lmo` is absent. It evaluates the actual Makefile definitions
with Make, including `$$` expansion, runs Build/Prepare and the install recipe,
and assembles `control.tar.gz`, `data.tar.gz` and `debian-binary` in an opkg
compatible outer gzip tar. Scripts use OpenWrt's default postinst/prerm wrappers
to execute UCI defaults, package hooks and init actions. Translations are compiled
using installed po2lmo or the shipped C sources; there is no untranslated fallback.
The artifact is for local validation and is not an SDK/release-build replacement.
The UCI config is a conffile. The generated nft cache is deliberately absent
from the payload; first guard startup creates it, and upgrades leave it alone.

`upgrade` starts from the original preinstalled 0.47.028 on QWRT, with an existing
UCI config and local YAML. It uses real `opkg install --force-reinstall`, checks
config preservation, S18 enablement and authenticated Design HTML, saves a live
binding, upgrades using the same package while polling both the guard table and
cached file hash. OpenWrt starts with an installed master IPK and an earlier
installed-version fixture. U5 performs an equal-version `--force-reinstall`
while OpenClash is stopped and continuously samples bound/control TCP+UDP,
the guard table and cache hash through replacement and for 30 seconds after
opkg exits. It requires zero bound DIRECT samples. U4 then removes the package,
checks that protection survives opkg exiting, and waits up to 25 seconds afterward for
the detached 20-second cleanup to remove the guard/cache/links/rule and restore
DIRECT traffic. U5 precedes U4 so it can reuse the installed package and binding.
Evidence is in `results/{qwrt,openwrt}/upgrade-*`, `reinstall-*`,
`initial-upgrade-opkg.log`, `repeat-upgrade-opkg.log`,
`equal-version-reinstall-opkg.log` and `remove-opkg.log`.
Polling samples transitions; it cannot prove the absence
of a gap shorter than the sampling interval.

For that future-upgrade simulation, only the **installed opkg version metadata**
is lowered to `0.48.002.2~harness-previous`; the IPK and installed payload remain
unchanged. Normal `opkg install` then takes its real upgrade path. This matters:
QWRT's same-version `--force-reinstall` instead calls `prerm remove` and
`postrm remove` with `PKG_UPGRADE=0`, then installs afresh. The package therefore
defers removal cleanup in a detached session. After 20 seconds it releases
protection only if both guard payload files are absent and `opkg status` reports
no package. Reinstallation enables the guard and immediately loads its retained
cache; backup restoration also excludes that live cache. See REPORT.md for the
actual lifecycle and traffic evidence, including the earlier failing probe.
