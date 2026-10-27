# Device Egress implementation and verification

The authoritative UI and behavior contract remains [device-egress-spec.md](device-egress-spec.md). This document records the implementation, local checks and remaining device acceptance work. No router was contacted or deployment performed.

## Files

| Area | Files under `luci-app-openclash/` |
| --- | --- |
| LuCI navigation and authenticated JSON | `luasrc/controller/openclash.lua` |
| Pure validation and nft rendering | `luasrc/device_egress.lua` |
| Discovery, state, transactions, core reload and runtime routing | `luasrc/device_egress_service.lua` |
| Page | `luasrc/view/openclash/device_egress.htm`, `root/www/luci-static/resources/openclash/js/device_egress.js`, `root/www/luci-static/resources/openclash/css/oc-device-egress.css` |
| Chinese copy | `po/zh-cn/openclash.zh-cn.po` |
| Final YAML listener pass and command adapter | `root/usr/share/openclash/device_egress.rb`, `root/usr/share/openclash/device_egress.lua` |
| Persistent guard | `root/usr/share/openclash/device_egress_guard.sh`, `root/etc/init.d/openclash_guard`, `root/usr/share/nftables.d/ruleset-post/92-openclash-guard.nft`, `root/lib/upgrade/keep.d/openclash-device-egress`; runtime cache `/etc/openclash/device-guard.nft` |
| OpenClash startup/runtime cleanup | `root/etc/init.d/openclash` |
| Permissions, boot link, conffile and uninstall/upgrade lifecycle | `Makefile` |

Tests: `tests/device-egress.lua`, `tests/device-egress-service.lua`, `tests/device-egress-ui.js`, `tests/test_device_egress.py`. Docker integration and package evidence are documented in [the harness report](../tests/device-egress-docker/REPORT.md). The user-supplied specification was left unchanged.

## Section 10 invariants

| Spec | Implementation |
| --- | --- |
| A: one pinned TPROXY listener per enabled device | The final Ruby pass runs after normal YAML processing, custom overwrites and provider path normalization, including quick starts. Listeners have `udp: true`, `proxy: <target>`, and ports `7900 + section ordinal` (7901–7932). Paused sections retain their ordinal. Existing OpenClash UCI ports, YAML ports, controller/DNS ports and custom listener ranges are checked before save and at startup. Missing or unsafe targets receive no usable inbound, leaving the device blocked. |
| A: MAC **and** IPv4 match; TCP and UDP outside localnetwork | A dedicated fw4 prerouting hook at -151 checks both identities, returns localnetwork destinations, and TPROXYs both transports. Mark `0x40000`, rule priority 1886 and route table 789 select `local default dev lo`. Conflicting routing entries are refused; runtime route cleanup requires this feature's ownership marker. |
| A: precedence over ordinary interception | Bound MAC exemptions are installed immediately after ordinary redirect/TPROXY/TUN chain creation. Source access-control insertions explicitly exclude the bound set. The final atomic runtime batch puts exemptions first again after custom firewall processing. All cleanup is scoped to `inet fw4`. |
| A: DNS behavior | With DNS hijacking enabled, bound DNS gets the appropriate dnsmasq/core redirect ahead of ordinary access-control exclusions. With it disabled, external port 53 receives the same device TPROXY treatment as other TCP/UDP. |
| A: hot reload first | A successful local `PUT /configs?force=true` loads the regenerated runtime YAML. Failure takes the isolated normal-init restart path. Config snapshots and sockets owned by the current core must agree before the UI reports “走节点”. |
| B: persistent guard and IPv6 blocking | `inet openclash_guard` has a forward filter at -10, actual LAN destination sets, a bound MAC set, and source-IPv4 mismatch drops at -160. IPv6 outside connected LAN/link-local destinations is blocked. The default forward rule matches Ethernet source; the isolated conntrack-mark fallback is described below. |
| B: safe ordering during mutations/rebuilds | An additional persistent prerouting check at -149 drops external bound traffic that did not pass the dedicated -151 hook. This closes the interval before runtime exemptions exist and prevents ordinary TUN/redirect interception from admitting newly bound traffic. DHCP broadcasts to the LAN DHCP service remain possible. |
| B: boot, firewall reload, upgrade persistence | START=18 and an installed S18 boot link load the cached nft program. Boot checks binding comments against UCI, regenerating when bindings changed. Before netifd is ready, LAN IPv4 discovery falls back to `network.lan`. A ruleset-post include replays the cache in the fw4 transaction. The cache is generated at runtime and excluded from the package payload so opkg never overwrites it with an empty seed. UCI is a conffile; UCI, nft cache and health snapshot are in keep.d. |
| B: independence from the OpenClash process | OpenClash stop, restart, start_fail and revert_firewall remove only fw4 runtime rules and the owned policy route. They never regenerate, flush or delete the guard table. Guard changes happen through binding mutations/reapplication or boot recovery of changed bindings. Disabling/deleting the last enabled binding emits an idempotent delete-table program. |
| B: generation/install failure and rollback | Guard writes are checked with `nft -c`, then applied atomically. An independent shell fallback installs an emergency LAN-only policy, caches it, returns failure and exposes nft stderr to an expandable plain-text error. Failed guard installation occurs before UCI mutation. Failed UCI commit reverts UCI and restores the previous guard. |
| B: flowtable and uninstall | Guard changes and runtime replacements flush `inet fw4 ft`. A complete package removal deletes the guard and owned route. **Uninstalling removes protection and permits ordinary direct routing.** A version upgrade preserves the guard and its files. QWRT same-version `--force-reinstall` invokes ordinary removal hooks with `PKG_UPGRADE=0`, so it removes protection during replacement; it is not a fail-closed upgrade. |
| C: UCI | Only `device_egress` sections hold bindings (`enabled`, `name`, `mac`, `ip`, `target`). Server validation normalizes MAC case, rejects duplicates/router/out-of-LAN IPs and direct targets, checks occupied IPs and enforces the 32-section limit, including paused entries. DHCP reservations are independent transactions followed by dnsmasq reload. |
| D: physical acceptance | Remains unrun, as requested. The full matrix is below. |

Groups are checked recursively through explicit members, include-all options, cached/inline provider expansion, and the running core's group/provider graph. DIRECT and COMPATIBLE are unsafe; REJECT is allowed. Unknown providers, unknown members and cycles fail closed. Filters are checked conservatively as a superset because Ruby and Mihomo use different regex engines.

Mihomo can substitute COMPATIBLE when a provider/group becomes empty. For selected safe group graphs, the processed YAML therefore sets `empty-fallback: REJECT` and excludes Direct/Compatible adapter types. Original values are recorded in the private `x-openclash-device-egress` YAML field and restored before regeneration or when bindings are removed. Unrelated groups and the source YAML are untouched. This also means another device sharing that selected graph will reject an empty graph rather than fall back to direct. With no device sections and no previously generated feature data, YAML is never parsed or rewritten by this pass.

Guard health requires both an exact regenerated-cache match and a structural comparison of the complete live nft table against the installed JSON snapshot. Handles and counter values are ignored; missing/changed rules are not. Neither an existing table name nor a running PID is sufficient evidence of protection.

## Isolated fallback hooks

1. **Forward Ethernet source matching:** primary is `ether saddr @bound`. If device tracing shows that this does not match, set `openclash.config.device_egress_ct_mark='1'`, commit, then use **重新应用保护**. The alternative sets bit `0x40000000` in the prerouting ct mark and drops original-direction forwarded packets carrying that bit, preserving other bits. No automatic silent fallback is enabled.
2. **Listener evidence:** primary is the recorded successful core configuration plus matching TCP and UDP socket inodes in `/proc/<pid>/fd` and `/proc/net/{tcp,udp}`. An optional executable `/etc/openclash/custom/device_egress_listener_probe` receives `pid mac port target`; exit 0 must mean the pinned inbound is verified. Without proof, the UI stays blocked. No hook is installed by default.
3. **Reload:** primary is the authenticated loopback core API; fallback is ordinary OpenClash restart. Both retain the independent guard.
4. **Discovery:** primary is JSON `ip neigh`; an isolated plain-text parser handles older ip-full. Boot uses cached guard data and falls back from netifd LAN discovery to static `network.lan` when regeneration is necessary.
5. **Guard generation:** the shell emergency renderer does not require Lua, UCI or Ruby. It allows local/router and br-lan communication, blocks forwarded external traffic before interception, and blocks router external output. On nonstandard LAN device names this deliberately favors blocking over granting broader access.

Manual UCI binding edits must be followed by protection reapplication; the page reports a configuration/cache mismatch as unprotected. Boot also detects changed binding identities.

## Local validation

Run from the repository root:

```sh
python3 -m unittest discover -s tests -v
luajit tests/releases.lua
luajit tests/version-fetch.lua
node tests/download-urls.js
```

The Python suite also executes the feature Lua and JavaScript harnesses. Feature coverage includes guard enabled/disabled/invalid/emergency cases, conntrack fallback, UCI validation and rollback, status precedence and stale health, socket ownership, recursive DIRECT/provider checks, YAML generation/port conflicts/removal, independent DHCP pin UI behavior, exact confirmation copy, text-only names, polling/visibility behavior, menu preservation, busy-state protection and latency timeouts.

Results: **43 Python tests passed**, including the feature harnesses (**15 policy, 15 service and 14 UI scenarios**). The existing release-selection Lua, large-response Lua and download-URL JavaScript checks also passed.

Additional checks: `sh -n` on all changed shell/init scripts; LuaJIT bytecode compilation of all changed Lua (luac is unavailable); `ruby -c`; `node --check`; and the repository's own po2lmo compiler against the complete Chinese catalog. GNU msgfmt rejects the catalog's pre-existing header, which starts with header continuation strings without msgid/msgstr; that unrelated header was left unchanged.

No OpenWrt SDK/toolchain is installed here. The Docker harness now assembles real IPKs without the SDK and exercises nft parsing/loading and opkg lifecycle on isolated containers. See its report for results and firmware differences. JavaScript interactions use the deterministic DOM harness; no browser layout or screenshot verification is claimed.

## Remaining on-device verification

All of these require an explicitly authorized device session and were not attempted:

- Install/build packaging, LuCI authentication/CSRF compatibility, menus/translations and atomic UCI/dnsmasq behavior on the target firmware.
- Validate generated nft input with the target nft/kernel, required TPROXY module availability in every OpenClash mode, policy route priority/namespace, and independent guard persistence through fw4 ruleset-post includes.
- Trace forward `ether saddr` matching. Exercise the ct-mark fallback separately if needed, checking original/reply direction and coexistence with other marks.
- Verify TCP **HTTPS** and UDP **STUN** exit IPs for a bound device. Repeat across stop, restart, core kill/respawn, start_fail, fw4 reload and full reboot; observe no direct exit at any point.
- Switch global/direct modes; switch to a configuration missing the selected target; test direct-containing nested/provider groups, provider empty/failure cases, device IP changes and IPv6 blocking. Check devices sharing a selected group and unrelated devices, including users with no device sections.
- Exercise DNS hijacking on/off, dnsmasq custom DNS ports, access-control exclusions, mainland bypass, common-port-only rules and TUN/TPROXY/redirect modes.
- Confirm hot reload preserves the listener pin; force API failure to exercise restart fallback. Check `/proc` listener evidence and only install the optional probe hook if the target's socket reporting requires it.
- Check software/hardware flow offloading warnings and whether flushing fw4's flowtable evicts established flows on the actual hardware.
- Force guard generation/nft-check failures; confirm emergency LAN/router access, external blocking, unchanged UCI, persistent cached emergency policy and recovery through protection reapplication.
- Verify upgrade/sysupgrade retention and full-uninstall removal of protection.
- Capture the page and edit/confirmation sheets at **1440px and 390px**, in **light and dark themes**. Verify no horizontal scrolling, hidden mobile MACs, 44px targets, fixed sheet footer, special-character/emoji names, and viewport keyboard behavior.
