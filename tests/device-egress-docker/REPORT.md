# Local Docker integration — 2026-10-27

Work stayed on `feat/device-egress`; nothing was committed or pushed. No real
router or other LAN host was contacted. No screenshots were taken.

This follow-up reruns the package lifecycle suites on both images, Python/UI
tests, and browser DOM geometry at 390×844. The broad scenario tables and
standalone release/version/download checks are retained from the prior report;
they were not repeated for this focused change.

Commands from the repository root:

```sh
tests/device-egress-docker/build-ipk.sh
ROUTER_IMAGE=qwrt UI_PORT=18082 tests/device-egress-docker/run.sh
ROUTER_IMAGE=qwrt UI_PORT=18082 tests/device-egress-docker/run.sh upgrade
ROUTER_IMAGE=openwrt UI_PORT=18082 tests/device-egress-docker/run.sh upgrade
ROUTER_IMAGE=openwrt UI_PORT=18082 tests/device-egress-docker/run.sh ui
UI_PORT=18082 tests/device-egress-docker/run.sh
ROUTER_IMAGE=qwrt UI_PORT=18082 tests/device-egress-docker/run.sh ui
python3 -m unittest discover -s tests -v
node tests/device-egress-ui.js
# After the matching run.sh ui; repeated for openwrt and qwrt:
NODE_PATH=/tmp/oc-shots/node_modules \
  CHROMIUM_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  ROUTER_IMAGE=qwrt UI_PORT=18082 node tests/device-egress-docker/ui-geometry.js
# Existing standalone checks, using the locally installed LuaJIT:
luajit tests/releases.lua
luajit tests/version-fetch.lua
node tests/download-urls.js
```

LuaJIT was resolved from `/opt/homebrew/Cellar/luajit/*/bin/luajit` by Python
because it was absent from PATH; the scripts above were passed to that binary.

The runner defaults to `ROUTER_IMAGE=openwrt`. Logs, snapshots and packet
observations are in ignored `results/qwrt/` and `results/openwrt/`.
Earlier failed probes are retained, including `upgrade-before-fix.txt`,
`cache-before-fix.txt`, `ipv6-before-readiness.txt` and `earlier-failures/`.

## Image and isolation evidence

The locally pulled `coolsnowwolf/qwrt:arm64-latest` has amd64 metadata but AArch64
binaries. This command returned **aarch64**, matching the OrbStack host:

```sh
docker run --rm --network none --platform linux/amd64 --entrypoint /bin/sh \
  coolsnowwolf/qwrt:arm64-latest -c 'uname -m'
```

The Dockerfile uses that platform for the QWRT base and arm64 for the derived
images. Every scenario run also asserts `uname -m = aarch64`. The raw image ID
was `sha256:b6197c0bb344959641101cd68e64d263d3c807d5c1ddad60b4eab53d1143e0e7`.

QWRT reports OpenWrt **24.10.3 r6954-1270397e47**, Ruby **3.3.6**, nft **1.1.3**,
preinstalled luci-app-openclash **0.47.028**, and luci-theme-design **5.7.6**.
Its original procd, netifd, LuCI and Ruby runtime remain in use.

**This QWRT image ships fw3, not fw4.** The feature requires fw4, so the harness
removes fw3 and extracts the SHA256-verified official fw4
`2024.12.18~18fc0ead-r1` userspace package. It adds upstream ucode modules,
missing Ruby JSON/tempfile and LuCI helper dependencies. It retains QWRT nft
1.1.3. QWRT opkg cannot resolve the upstream fw4 kmods against its 5.4 package
database; those modules are not installed. The container uses host modules.
This is evidence for **QWRT with fw4 added**, not its stock iptables path.

QWRT first-boot defaults which rewrite networking and start unrelated modem or
proxy services are removed. Design is explicitly selected. An early init script
aliases `/var/run/ubus/ubus.sock` to QWRT procd's `/var/run/ubus.sock`, after boot
has cleared `/var/run`; upstream ucode otherwise cannot discover interface
devices. The default OpenWrt 24.10.8 base installs dnsmasq-full in place of
minimal dnsmasq so master and feature share package dependencies.

Both data networks are internal Docker bridges. Management publishes only on
127.0.0.1. The router entrypoint removes default routes and installs a blackhole
for `192.168.50.1/32` before init. Peers disable IPv6 RA/autoconfiguration through
Docker endpoint sysctls, and client IPv6 defaults explicitly select the test
router with metric 1. All traffic destinations are local fixtures.

## QWRT scenarios — previous full run (retained)

```text
SCENARIO                         RESULT  DETAIL
01 running                       PASS    TCP+UDP and control verified
02 modes                         PASS    global/direct/rule: bound via node; control DIRECT
03 stop                          PASS    TCP+UDP and control verified
04 restart                       PASS    fresh TCP+UDP sockets throughout restart: no DIRECT samples
05 kill-9                        PASS    SIGKILL: both blocked before procd respawn; no DIRECT samples
06 start_fail                    PASS    listener port collision invoked real start_fail; both blocked
07 fw4 reload/restart            PASS    fw4 reload + firewall restart retain guard while stopped
08 container reboot              PASS    container reboot: START=19 observed guard=yes/core=no; then node
09 missing/unsafe target         PASS    missing target blocked; UI backend rejects select containing DIRECT
10 changed IPv4/IPv6             PASS    IPv4 change and IPv6 TCP+UDP blocked; unbound IPv6 succeeds
G group hardening                PASS    shared group TCP+UDP: late Direct excluded, empty REJECT; unrelated group unchanged
11 pause/remove                  PASS    real LuCI backend pause/resume/delete; empty guard removed
12 no bindings vs master         PASS    master: start/reload/stop nft + YAML identical; failing custom script does not abort
```

## OpenWrt scenarios — previous full run (retained)

```text
SCENARIO                         RESULT  DETAIL
01 running                       PASS    TCP+UDP and control verified
02 modes                         PASS    global/direct/rule: bound via node; control DIRECT
03 stop                          PASS    TCP+UDP and control verified
04 restart                       PASS    fresh TCP+UDP sockets throughout restart: no DIRECT samples
05 kill-9                        PASS    SIGKILL: both blocked before procd respawn; no DIRECT samples
06 start_fail                    PASS    listener port collision invoked real start_fail; both blocked
07 fw4 reload/restart            PASS    fw4 reload + firewall restart retain guard while stopped
08 container reboot              PASS    container reboot: START=19 observed guard=yes/core=no; then node
09 missing/unsafe target         PASS    missing target blocked; UI backend rejects select containing DIRECT
10 changed IPv4/IPv6             PASS    IPv4 change and IPv6 TCP+UDP blocked; unbound IPv6 succeeds
G group hardening                PASS    shared group TCP+UDP: late Direct excluded, empty REJECT; unrelated group unchanged
11 pause/remove                  PASS    real LuCI backend pause/resume/delete; empty guard removed
12 no bindings vs master         PASS    master: start/reload/stop nft + YAML identical; failing custom script does not abort
```

Scenario 12 installs a real IPK assembled from `git archive master` on the same
selected base. It copies the feature's exact clean UCI input to master, uses
identical YAML and custom firewall hook returning 23, and compares parsed YAML
and ordered fw4 JSON after start, reload and stop. Only handles, counters and
nft metadata are removed. Master is
`d83fd7c3a0ed4628bb27ecf0d4feb2e30831677a`; its image has no Device Egress modules
or guard init script. Evidence includes `master-package.txt`, both YAML files
and the six nft snapshots in each results directory.

The group case tests ordinary unbound SOCKS TCP/UDP through the shared safe
group, then injects a late Direct adapter through a local core reload. The
generated exclusion removes it and the empty group rejects both consumers.
The unrelated select group remains unchanged. Hardening therefore affects all
consumers of selected groups and their child graph; ordinary unbound
MATCH,DIRECT traffic remains direct. Remote provider downloads are not tested.

## QWRT package lifecycle — actual final table

```text
SCENARIO                         RESULT  DETAIL
U1 preinstalled upgrade          PASS    0.47.028 -> working tree IPK; existing UCI/YAML preserved; S18 enabled; page loads
U2 add binding                   PASS    binding saved through LuCI backend; active; TCP+UDP node and DIRECT control verified
U3 repeat upgrade                PASS    identical IPK, earlier installed-version fixture; 585 guard/cache polls unchanged; binding retained
U5 equal-version force-reinstall PASS    4094 guard/cache polls unchanged; TCP 3763/12/0; UDP 3757/12/0 node/blocked/DIRECT; through reinstall + 30s after opkg
U4 package removal               PASS    opkg exited with guard/cache intact; released 20.3s later; links/cache/pref 1886 gone; TCP+UDP DIRECT restored
```

`build-ipk.sh` and `build_ipk.py` create `.cache/feature.ipk`, version
**0.48.002.2**, without an SDK. Make evaluates the real define blocks, including
`$$` expansion, and executes Build/Prepare and the install recipe. Metadata and
hooks come from those definitions. OpenWrt's default postinst/prerm wrappers
run UCI defaults and init actions. Host cc builds the shipped po2lmo sources
when po2lmo is absent; compiled Chinese LMO is included, with no translation
fallback. The IPK is an opkg-accepted gzip tar containing debian-binary,
control.tar.gz and data.tar.gz. Its S18 symlink, executable hooks, conffiles and
LMO were inspected as well as exercised by opkg.

U1 upgrades the untouched preinstalled 0.47.028 with
`opkg install --force-reinstall /harness/feature.ipk`. An existing UCI marker,
config path and byte-identical YAML survive. The real authenticated Design
page loads and S18 is enabled. U2 saves a binding through the LuCI backend,
verifies active state and policy rule 1886, and checks bound/control TCP+UDP.

U3 keeps the IPK byte-identical. To simulate a **future version upgrade**,
only the installed opkg version metadata is changed to
`0.48.002.2~harness-previous`; installed payload/configuration are unchanged.
Normal `opkg install /harness/feature.ipk` then logs an actual upgrade. All
**585** guard polls found the table present and the cached nft hash unchanged.
Independent bound-client observations are recorded in `upgrade-client-*.jsonl`.
Config/binding, S18, page and node traffic still work afterward. U5's TCP/UDP
counts in the actual table use **node / blocked / DIRECT** order; all 4,094
table/cache polls passed. U4 executes real opkg removal, verifies protection
remains after opkg returns, and waits for deferred cleanup of the table, cache,
S18/K99 links and owned routing rule, followed by direct traffic.

## OpenWrt package lifecycle — actual final table

```text
SCENARIO                         RESULT  DETAIL
U1 preinstalled upgrade          PASS    0.48.002.2~harness-previous -> working tree IPK; existing UCI/YAML preserved; S18 enabled; page loads
U2 add binding                   PASS    binding saved through LuCI backend; active; TCP+UDP node and DIRECT control verified
U3 repeat upgrade                PASS    identical IPK, earlier installed-version fixture; 1223 guard/cache polls unchanged; binding retained
U5 equal-version force-reinstall PASS    4443 guard/cache polls unchanged; TCP 3412/28/0; UDP 3414/28/0 node/blocked/DIRECT; through reinstall + 30s after opkg
U4 package removal               PASS    opkg exited with guard/cache intact; released 20.2s later; links/cache/pref 1886 gone; TCP+UDP DIRECT restored
```

Upstream OpenWrt has no preinstalled OpenClash, so its upgrade image first
installs the master IPK. U1 lowers only that installed version's metadata before
installing the feature IPK; U3 uses the same earlier-version fixture as QWRT.
U5 uses the actual equal installed/IPK version on both images, with no version
metadata fixture. Both U3 and U5 also require unchanged cache inode and mtime.
The final lifecycle runs use the cache-preserving replay implementation.

### Historical same-version forced reinstall failure — now fixed

This failure is not relabeled as an upgrade pass. QWRT
`opkg install --force-reinstall` on an **equal version** performs removal then
installation. Instrumented hooks received:

```text
prerm: args=[remove] PKG_UPGRADE=[0]
postrm: args=[remove] PKG_UPGRADE=[0]
```

It removed protection during replacement. The bound client observed **122 TCP
and 129 UDP DIRECT samples** in the recorded failed probe. A true version
upgrade instead supplied `upgrade <version>` and `PKG_UPGRADE=1`, retaining the
guard. Ordinary removal must release protection, and its hook arguments and
environment are indistinguishable from this forced reinstall. No production
guess based on parent command lines or opkg temporary directory names was
added. The fix keeps removal asynchronous instead: postrm schedules a detached
20-second release. At that time both `/etc/init.d/openclash_guard` and
`/usr/share/openclash/device_egress_guard.sh` must be absent, and a successful
`opkg status luci-app-openclash` must return no package, before cleanup proceeds.
Any remaining payload/status or failed status inspection retains protection.
The worker uses setsid/nohup when available, or BusyBox start-stop-daemon's
detached session when both applets are absent (as on the tested QWRT image).
All stdio is disconnected, so the worker survives opkg/LuCI exiting.

Both final U5 hook traces contain `prerm` and `postrm` with
`args=[remove] PKG_UPGRADE=[0]`; this is the actual equal-version path.

Postinst enables S18/K99 and loads the retained cache immediately. Successful
cache replay preserves its inode and mtime as well as its contents. An invalid
cache still falls back to a newly persisted emergency policy. The ordinary
removal hook no longer deletes `/etc/openclash`; only confirmed deferred removal
does so. Backup restoration excludes `device-guard.nft` so its copy cannot
truncate or replace the live file. The cache remains absent from the IPK.
The `upgrade` argument and `PKG_UPGRADE=1` bypass deferred release.

U5 now exercises the exact equal-version `--force-reinstall` action, starting
with OpenClash stopped. It records the real removal-hook arguments, continuously
polls the table and cache hash, and samples fresh TCP/UDP on both clients through
reinstall and for 30 seconds after opkg returns. It requires zero bound DIRECT
samples. U4 runs afterward, verifies protection remains after opkg exits, then
waits for release and TCP/UDP DIRECT recovery within 25 seconds of opkg returning.
The original failing probe remains historical evidence rather than a pass.

The original forced-reinstall failure was recorded before removing the empty
cache seed and before this deferred-release fix. Opkg also printed nonfatal
`sh: out of range` and lock-unlink warnings. Exit status was zero and the
explicit lifecycle/traffic checks passed. The existing history helper deletes
the opkg lock when reading package metadata; that unrelated behavior remains.

Harness bring-up failures were not counted as passes. The first new U5 compared
the entire opkg status record and failed on the legitimate installation-time
change; it now compares the version and separately verifies config/bindings.
A QWRT U4 observed one TCP timeout immediately after release; recovery now uses
a bounded wait for both protocols/clients within the deferred deadline. The
first OpenWrt U4 started that deadline before opkg's stop hooks; it now starts
at opkg return, matching the release contract. Earlier results/diagnostics are
retained under `earlier-failures/reinstall-status-assertion`,
`earlier-failures/removal-tcp-transition` and
`earlier-failures/removal-deadline` in their respective image directories.

## Bugs and fixes in this extension

1. QWRT iproute2 6.17 reports `Dump terminated` for an absent table 789. The
   backend previously recognized only `FIB table does not exist` and rejected
   the first binding. It now dumps all numeric tables, checks only table 789,
   recognizes numeric local-route type 2, and still rejects occupied tables or
   failed inspection. A service-boundary regression test covers those cases.
2. Make consumed unescaped shell expressions/variables in package hooks:
   `$(pidof clash)`, awk `$0`/`$2`, and DNSMASQ shell variables. They now use the
   required dollar escaping and survive actual Make expansion into scripts.
3. Shipping an empty `device-guard.nft` conffile let opkg briefly replace the
   generated cache before restoring it. The empty seed is removed from the
   source payload. The guard generates the cache on first startup; package
   upgrades never unpack over it. `/etc/config/openclash` is now the conffile,
   while keep.d continues to retain UCI, nft cache and health snapshot.
4. Equal-version force-reinstall uses ordinary removal hooks. Deferred cleanup
   now checks actual package absence before releasing protection; cache replay
   and backup restore leave the live cache untouched.
5. Design's global header/footer styles overlapped mobile dialog content and
   hid its action buttons. Dialogs now use `div.de-dialog-header` and
   `div.de-dialog-footer`, with explicit layout/visibility/background/height
   rules for header/body/footer. Mobile page padding leaves 88px plus the safe
   area below the final note so it can scroll above Design's fixed navbar.

Harness fixes include QWRT's ubus socket alias, common dnsmasq-full dependencies,
and disabling learned IPv6 addresses/routes. The OpenWrt IPv6 control failure
persisted through a readiness wait until those peer network settings were
fixed. The control now proves connectivity before a blocking assertion. The
upgrade harness also avoids clearing an already-running service's completion
marker when default_postinst has started it.

## Mobile DOM geometry — actual final results

`ui-geometry.js` ran in local headless Chrome against each image's real
authenticated page, at **390×844**. All page requests were restricted to the
preview's `http://127.0.0.1:18082` origin. OpenWrt selected
`/luci-static/bootstrap`; QWRT selected `/luci-static/design`. Values below are
CSS pixels, rounded to two decimals; all four dialogs have the same geometry
within each theme.

| Theme | Dialogs | Header top–bottom | Body top–bottom | Footer top–bottom | Button top–bottom | Visible / centre hits |
| --- | --- | --- | --- | --- | --- | --- |
| QWRT Design | add/edit/pause/delete | 0–77 | 77–767 | 767–844 | 784–828 | 8/8 visible, 8/8 button hits |
| OpenWrt Bootstrap | add/edit/pause/delete | 0–77.39 | 77.39–766.61 | 766.61–844 | 783.61–828 | 8/8 visible, 8/8 button hits |

For add/edit, Design's device heading is at **77–91.89** and its search input
at **94.89–138.89**; Bootstrap's heading is at **77.39–113.39** and search at
**113.39–160.98**. Neither is covered by the dialog header. Every dialog has
zero bare header/footer elements. Each footer's two buttons passed visibility
and `document.elementFromPoint` equality at the button centre, including
取消 / 保存并应用, 暂停 and 删除.

| Theme | Last card top–bottom after scrolling | Footnote top–bottom | Bottom viewport/navbar limit | Result |
| --- | --- | --- | --- | --- |
| QWRT Design | 423.97–600.91 | 612.91–656.25 | 794 (fixed navbar top) | PASS |
| OpenWrt Bootstrap | 456.75–627.53 | 639.53–675.53 | 844 (viewport bottom) | PASS |

Raw rectangles, visibility flags and hit results are in each image's
`results/<image>/ui-geometry.json`. The check waits for the dialog close handler
to remove the sheet/unlock page scrolling before scrolling the footnote into
view; it uses no timing sleeps or screenshots. The final QWRT UI run is left up.

## Unit checks, preview and limits

* Python discovery: **44 tests passed**, including unchanged-cache replay and
  rejected-cache emergency recovery in test_device_egress.py.
* Embedded Lua harnesses: **15 policy / 15 service** cases passed.
* Explicit device-egress-ui.js: **15 tests passed**, including theme-safe dialog
  structure for add/edit and pause/delete confirmations.
* Existing releases.lua, version-fetch.lua and download-urls.js: passed.
* Shell/Python/JavaScript syntax and git diff --check: passed.

The QWRT preview is left running at
<http://127.0.0.1:18082/cgi-bin/luci/admin/services/openclash/device-egress>,
login **root / test**. Host-side authentication returned HTTP 200. The HTML
uses `/luci-static/design/` and contains compiled translations **走节点 / 已阻断 /
已暂停**; backend fixtures are **active / missing / paused**. Evidence is in
`ui-state.json`, `ui-host.html` and `ui-host-check.txt`. Those original HTML checks
verify rendering/backend state; the new browser geometry checks below exercise
real add/edit and confirmation dialogs without screenshots.
Unrelated containers on port 18080 remain untouched. Stop the preview with
`ROUTER_IMAGE=qwrt tests/device-egress-docker/run.sh down`.

**The container kernel is the host's
7.2.12-orbstack-00394-gbecdd6130068, not the router's 5.4 kernel.** Results do
not establish compatibility with that kernel, stock QWRT fw3/iptables, hardware
or software flow offload, physical boot, Wi-Fi/MAC rotation, DHCP discovery,
DNS hijacking modes, HTTPS/STUN, TUN modes, remote provider download failures,
sysupgrade/power-loss recovery, or browser layouts beyond the tested mobile
geometry. Polling
samples transitions and cannot prove protection for every packet or scheduling
interleaving. No failures are converted into skips.
