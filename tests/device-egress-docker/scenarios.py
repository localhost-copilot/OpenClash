#!/usr/bin/env python3
"""Black-box lifecycle tests. Policy/rendering always comes from the package."""
import contextlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import traceback

HERE = Path(__file__).resolve().parent
RESULTS = Path(os.environ.get("HARNESS_RESULTS", HERE / "results"))
COMPOSE = ["docker", "compose", "-f", str(HERE / "compose.yaml")]
DIRECT, NODE, BLOCKED = "203.0.113.2", "203.0.113.10", "BLOCKED"
MAC = "00:16:3e:00:00:20"
ROWS = []


def command(args, *, data=None, check=True, timeout=90, env=None):
    result = subprocess.run(args, input=data, text=True, capture_output=True, timeout=timeout, env=env)
    if check and result.returncode:
        raise AssertionError(f"{args}: {result.stdout[-1500:]} {result.stderr[-1500:]}")
    return result


def compose(*args, **kwargs):
    return command(COMPOSE + list(args), **kwargs)


def execute(service, *args, **kwargs):
    return compose("exec", "-T", service, *args, **kwargs)


def router(script, **kwargs):
    return execute("router", "sh", "-c", script, **kwargs).stdout.strip()


def wait_for(check, description, timeout=60):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = check()
            if last:
                return last
        except (AssertionError, ValueError) as error:
            last = str(error)
        time.sleep(0.2)
    raise AssertionError(f"Timed out waiting for {description}; last={last}")


def boot_ready():
    wait_for(lambda: router("ubus call network.interface.lan status | jsonfilter -e '@.up'") == "true", "netifd")
    wait_for(lambda: router("test -e /tmp/harness-boot-ready && echo yes") == "yes", "procd boot complete")


def status():
    return json.loads(execute("router", "lua", "-e", 'print(require("luci.jsonc").stringify(require("luci.device_egress_service").status()))').stdout)


def mutate(operation, **fields):
    return json.loads(execute("router", "lua", "/harness/backend.lua", data=json.dumps(dict(operation=operation, **fields))).stdout)


def bind(target="safe-auto"):
    rows = status()["rows"]
    fields = {"device": {"name": "测试笔记本", "mac": MAC, "ip": "10.231.0.20", "target": target}}
    if rows:
        fields["id"] = rows[0]["id"]
    return mutate("save", **fields)


def start():
    router("uci set openclash.config.enable=1; uci commit openclash; rm -f /tmp/openclash.change; /etc/init.d/openclash start")
    core_ready()


def core_ready():
    wait_for(lambda: router("pidof clash >/dev/null && test -e /tmp/openclash.change && echo ready") == "ready", "real OpenClash startup")


def stop():
    router("/etc/init.d/openclash stop")
    wait_for(lambda: router("pidof clash || true") == "", "core stop")


def pair(expected, control=DIRECT, host=NODE):
    observed = {}
    for name, want in (("client", expected), ("client2", control)):
        value = json.loads(execute(name, "python3", "/harness/peer.py", "probe", host).stdout)
        observed[name] = value
        assert value == {"tcp": want, "udp": want}, f"{name}: wanted {want}, observed {value}"
    return observed


def guard_present():
    assert router("nft list table inet openclash_guard >/dev/null && echo yes") == "yes"


@contextlib.contextmanager
def polling(label, allowed=(NODE, BLOCKED), require_block=False):
    processes = {}
    for name in ("client", "client2"):
        execute(name, "rm", "-f", "/tmp/poll-stop")
        processes[name] = subprocess.Popen(COMPOSE + ["exec", "-T", name, "python3", "/harness/peer.py", "poll", "/tmp/poll", "/tmp/poll-stop"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        # Wait for actual samples before triggering the transition.
        for name in processes:
            wait_for(lambda: execute(name, "sh", "-c", "test -s /tmp/poll.tcp && test -s /tmp/poll.udp").returncode == 0, "pollers")
        yield
    finally:
        failures = []
        for name, process in processes.items():
            execute(name, "touch", "/tmp/poll-stop")
            out, err = process.communicate(timeout=10)
            (RESULTS / f"{label}-{name}-counts.json").write_text(out)
            for proto in ("tcp", "udp"):
                data = execute(name, "cat", "/tmp/poll." + proto).stdout
                (RESULTS / f"{label}-{name}-{proto}.jsonl").write_text(data)
            if process.returncode:
                failures.append(err)
                continue
            counts = json.loads(out)
            for proto, values in counts.items():
                if not values or not set(values).issubset(set(allowed if name == "client" else (DIRECT, BLOCKED))):
                    failures.append(f"{label} {name}/{proto}: {values}")
                if name == "client" and require_block and not values.get(BLOCKED):
                    failures.append(f"{label} {proto}: no blocked sample: {values}")
        assert not failures, "; ".join(failures)


def record(name, function):
    print(f"Running {name}...", flush=True)
    try:
        detail = function() or "TCP+UDP and control verified"
        ROWS.append((name, "PASS", str(detail)))
    except Exception as error:
        ROWS.append((name, "FAIL", str(error).replace("\n", " ")[:350]))
        (RESULTS / (name.split()[0] + "-error.txt")).write_text(traceback.format_exc())
        diagnostics(name.split()[0])
    print(f"{ROWS[-1][1]} {name}: {ROWS[-1][2]}", flush=True)


def diagnostics(label):
    for filename, script in {
        "openclash.log": "cat /tmp/openclash.log",
        "rules.nft": "nft list ruleset",
        "state.txt": "ps; ip rule; ip route show table all; uci show openclash",
        "runtime.yaml": "cat /etc/openclash/harness.yaml",
        "boot.log": "logread",
    }.items():
        with contextlib.suppress(Exception):
            (RESULTS / f"{label}-{filename}").write_text(router(script, check=False))


def running():
    bind()
    start()
    pair(NODE)
    assert status()["rows"][0]["state"] == "active", status()


def modes():
    for mode in ("global", "direct", "rule"):
        router("curl -fsS --noproxy '*' -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' -X PATCH http://127.0.0.1:9090/configs -d " + "'{\"mode\":\"" + mode + "\"}'")
        pair(NODE)
    return "global/direct/rule: bound via node; control DIRECT"


def stopped():
    stop()
    guard_present()
    pair(BLOCKED)


def restart():
    start()
    with polling("restart", require_block=True):
        router("rm -f /tmp/openclash.change; /etc/init.d/openclash restart")
        core_ready()
        pair(NODE)
    pair(NODE)
    return "fresh TCP+UDP sockets throughout restart: no DIRECT samples"


def crash():
    with polling("kill9", require_block=True):
        router("kill -9 $(pidof clash)")
        pair(BLOCKED)
        # procd deliberately respawns after five seconds; recovery is allowed.
        time.sleep(1)
    pair(BLOCKED)
    return "SIGKILL: both blocked before procd respawn; no DIRECT samples"


def start_failure():
    stop()
    router("printf '\nlisteners: [{name: collision, type: socks, port: 7901}]\n' >> /etc/openclash/config/harness.yaml")
    router("uci set openclash.config.enable=1; uci commit openclash; rm -f /tmp/openclash.change; /etc/init.d/openclash start")
    wait_for(lambda: router("uci get openclash.config.enable") == "0", "start_fail disables service")
    assert "Device Egress Listener Generation Failed" in router("cat /tmp/openclash.log")
    guard_present()
    pair(BLOCKED)
    router("cp /harness/original.yaml /etc/openclash/config/harness.yaml")
    return "listener port collision invoked real start_fail; both blocked"


def firewall():
    stop()
    for action in ("fw4 reload", "/etc/init.d/firewall restart"):
        router(action)
        guard_present()
        pair(BLOCKED)
    return "fw4 reload + firewall restart retain guard while stopped"


def reboot():
    # A real boot delay makes the guard-before-core interval observable.
    router("uci set openclash.config.enable=1; uci set openclash.config.delay_start=6; uci commit openclash")
    with polling("reboot", require_block=True):
        compose("restart", "router")
        wait_for(lambda: router("test -f /tmp/harness-guard-boot && echo yes") == "yes", "START=19 boot observation")
        observation = router("cat /tmp/harness-guard-boot")
        assert "guard=yes" in observation and "core=no" in observation, observation
        pair(BLOCKED)
        core_ready()
        pair(NODE)
    router("uci set openclash.config.delay_start=0; uci commit openclash")
    return "container reboot: START=19 observed guard=yes/core=no; then node"


def missing_and_validation():
    # A configuration switch can remove a previously valid target. Do not use
    # save to introduce an invalid target: the real backend must reject that.
    stop()
    router("sed -i 's/safe-auto/renamed-auto/g' /etc/openclash/config/harness.yaml")
    start()
    pair(BLOCKED)
    assert status()["rows"][0]["state"] == "missing", status()
    request = {"operation": "save", "id": status()["rows"][0]["id"], "device": {"name": "invalid", "mac": MAC, "ip": "10.231.0.20", "target": "unsafe-select"}}
    result = execute("router", "lua", "/harness/backend.lua", data=json.dumps(request), check=False)
    assert result.returncode and "contains DIRECT" in result.stdout, result.stdout
    stop()
    router("cp /harness/original.yaml /etc/openclash/config/harness.yaml")
    start()
    pair(NODE)
    return "missing target blocked; UI backend rejects select containing DIRECT"


def changed_ip_and_ipv6():
    execute("client", "ip", "addr", "del", "10.231.0.20/24", "dev", "eth0")
    execute("client", "ip", "addr", "add", "10.231.0.77/24", "dev", "eth0")
    execute("client", "ip", "route", "replace", "default", "via", "10.231.0.2")
    try:
        pair(BLOCKED)
    finally:
        execute("client", "ip", "addr", "del", "10.231.0.77/24", "dev", "eth0")
        execute("client", "ip", "addr", "add", "10.231.0.20/24", "dev", "eth0")
        execute("client", "ip", "route", "replace", "default", "via", "10.231.0.2")
    # IPv6 is first used here after router restart. Allow DAD/neighbor discovery
    # to settle, then require both control protocols before judging a block.
    wait_for(lambda: json.loads(execute("client2", "python3", "/harness/peer.py", "probe", "fd42:232::10").stdout)
             == {"tcp": "fd42:231::21", "udp": "fd42:231::21"}, "unbound IPv6 TCP+UDP reachability", timeout=15)
    pair(BLOCKED, control="fd42:231::21", host="fd42:232::10")
    pair(NODE)
    return "IPv4 change and IPv6 TCP+UDP blocked; unbound IPv6 succeeds"


def pause_remove():
    row = status()["rows"][0]
    mutate("pause", id=row["id"])
    pair(DIRECT)
    assert router("nft list table inet openclash_guard 2>/dev/null || true") == ""
    mutate("resume", id=row["id"])
    pair(NODE)
    mutate("delete", id=row["id"])
    pair(DIRECT)
    assert status()["rows"] == []
    assert router("nft list table inet openclash_guard 2>/dev/null || true") == ""
    return "real LuCI backend pause/resume/delete; empty guard removed"


def canonical_nft():
    document = json.loads(router("nft -j list table inet fw4"))
    def clean(value):
        if isinstance(value, dict):
            return {k: clean(v) for k, v in value.items() if k not in ("handle", "packets", "bytes", "metainfo")}
        if isinstance(value, list):
            return [clean(v) for v in value if not isinstance(v, dict) or "metainfo" not in v]
        return value
    return clean(document)


def baseline_lifecycle(label):
    boot_ready()
    stop()
    # Identical raw config/UCI/custom script for both images, no sections at all.
    router("cp /harness/clean-uci /etc/config/openclash; cp /harness/original.yaml /etc/openclash/config/harness.yaml; printf '#!/bin/sh\nexit 23\n' > /etc/openclash/custom/openclash_custom_firewall_rules.sh; chmod +x /etc/openclash/custom/openclash_custom_firewall_rules.sh")
    if label == "feature":
        assert status()["rows"] == []
    snapshots = {}
    start()
    pair(DIRECT)
    for phase in ("start", "reload", "stop"):
        if phase == "reload":
            router("rm -f /tmp/openclash.change; /etc/init.d/firewall restart")
            core_ready()
        elif phase == "stop":
            stop()
        pair(DIRECT)
        snapshots[phase] = canonical_nft()
        (RESULTS / f"{label}-{phase}-nft.json").write_text(json.dumps(snapshots[phase], indent=2))
    yaml = json.loads(router("ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_file(ARGV[0]))' /etc/openclash/harness.yaml"))
    (RESULTS / f"{label}-yaml.json").write_text(json.dumps(yaml, indent=2, ensure_ascii=False))
    if label == "feature":
        assert not any("openclash-device-" in str(item) for item in yaml.get("listeners", []))
        assert "x-openclash-device-egress" not in yaml
    return snapshots, yaml


def no_binding_master():
    feature, feature_yaml = baseline_lifecycle("feature")
    clean_uci = router("cat /harness/clean-uci") + "\n"
    diagnostics("feature-final")
    compose("stop", "router")
    compose("rm", "-f", "router")
    env = dict(os.environ, HARNESS_ROUTER_IMAGE=os.environ.get("HARNESS_MASTER_IMAGE", "device-egress-openwrt-master"))
    compose("up", "-d", "--no-deps", "router", env=env)
    boot_ready()
    # The stock QWRT package has older defaults which its upgrade hooks restore.
    # Compare both versions with the exact feature-side UCI input.
    execute("router", "sh", "-c", "cat > /harness/clean-uci", data=clean_uci)
    for client in ("client", "client2"):
        execute(client, "ip", "neigh", "flush", "all")
    master, master_yaml = baseline_lifecycle("master")
    router("test ! -e /usr/share/openclash/device_egress.lua; test ! -e /etc/init.d/openclash_guard")
    (RESULTS / "master-package.txt").write_text(router("opkg status luci-app-openclash"))
    diagnostics("master-final")
    assert feature_yaml == master_yaml, "generated YAML differs; see feature/master-yaml.json"
    for phase in feature:
        assert feature[phase] == master[phase], f"{phase} nft differs; see feature/master-{phase}-nft.json"
    return "master: start/reload/stop nft + YAML identical; failing custom script does not abort"


def group_hardening():
    # Record the actual generated group contracts, including shared unbound use.
    value = json.loads(router("ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_file(ARGV[0]))' /etc/openclash/harness.yaml"))
    groups = {g["name"]: g for g in value["proxy-groups"]}
    assert groups["safe-auto"]["empty-fallback"] == "REJECT"
    assert {"Direct", "Compatible"} <= set(groups["safe-auto"]["exclude-type"].split("|"))
    assert "empty-fallback" not in groups["unsafe-select"] and "exclude-type" not in groups["unsafe-select"]
    (RESULTS / "group-hardening.json").write_text(json.dumps(value["proxy-groups"], indent=2))
    # Send the control through the same group using GLOBAL selection. The bound
    # device still uses SpecialProxy. The ordinary MATCH,DIRECT config stays intact.
    router("curl -fsS --noproxy '*' -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' -X PUT http://127.0.0.1:9090/proxies/GLOBAL -d '{\"name\":\"safe-auto\"}'; curl -fsS --noproxy '*' -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' -X PATCH http://127.0.0.1:9090/configs -d '{\"mode\":\"global\"}'")
    # The china bypass intentionally keeps normal devices direct. An explicit
    # local SOCKS request tests the group's shared behavior without bypass.
    def shared(expected):
        observed = json.loads(execute("client2", "python3", "/harness/peer.py", "socks-probe").stdout)
        assert observed == {"tcp": expected, "udp": expected}, observed
    shared(NODE)
    router("cp /etc/openclash/harness.yaml /tmp/hardening-original.yaml")
    try:
        # Model a provider changing to a Direct adapter after generation. Keep
        # the feature-generated exclude-type/fallback exactly as installed.
        router("ruby -ryaml -e 'p=ARGV[0]; c=YAML.load_file(p); c[\"proxies\"] << {\"name\"=>\"late-direct\",\"type\"=>\"direct\"}; g=c[\"proxy-groups\"].find{|x|x[\"name\"]==\"safe-auto\"}; g[\"proxies\"]=[\"late-direct\"]; File.write(p,YAML.dump(c))' /etc/openclash/harness.yaml")
        router("curl -fsS --noproxy '*' -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' -X PUT 'http://127.0.0.1:9090/configs?force=true' -d '{\"path\":\"/etc/openclash/harness.yaml\"}'")
        # Full config reload restores the YAML's rule mode. Re-select the
        # ordinary shared group before checking its changed membership.
        router("curl -fsS --noproxy '*' -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' -X PUT http://127.0.0.1:9090/proxies/GLOBAL -d '{\"name\":\"safe-auto\"}'; curl -fsS --noproxy '*' -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' -X PATCH http://127.0.0.1:9090/configs -d '{\"mode\":\"global\"}'")
        shared(BLOCKED)
        pair(BLOCKED)
    finally:
        router("cp /tmp/hardening-original.yaml /etc/openclash/harness.yaml; curl -fsS --noproxy '*' -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' -X PUT 'http://127.0.0.1:9090/configs?force=true' -d '{\"path\":\"/etc/openclash/harness.yaml\"}'")
    router("curl -fsS --noproxy '*' -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' -X PUT http://127.0.0.1:9090/proxies/GLOBAL -d '{\"name\":\"DIRECT\"}'; curl -fsS --noproxy '*' -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' -X PATCH http://127.0.0.1:9090/configs -d '{\"mode\":\"rule\"}'")
    pair(NODE)
    return "shared group TCP+UDP: late Direct excluded, empty REJECT; unrelated group unchanged"


def ui():
    running()
    stop()
    # Invalid/missing entries arise from a config switch, so seed a formerly
    # valid second binding as persisted UCI, then boot with its target absent.
    router("uci set openclash.missing=device_egress; uci set openclash.missing.enabled=1; uci set openclash.missing.name='平板 · 出口已移除'; uci set openclash.missing.mac=00:16:3e:00:00:30; uci set openclash.missing.ip=10.231.0.30; uci set openclash.missing.target=removed-node; uci set openclash.paused=device_egress; uci set openclash.paused.enabled=0; uci set openclash.paused.name='客厅电视'; uci set openclash.paused.mac=00:16:3e:00:00:40; uci set openclash.paused.ip=10.231.0.40; uci set openclash.paused.target=node-a; uci commit openclash; /etc/init.d/openclash_guard start")
    start()
    states = [row["state"] for row in status()["rows"]]
    assert states == ["active", "missing", "paused"], states
    pair(NODE)
    page()
    (RESULTS / "ui-state.json").write_text(json.dumps(status(), ensure_ascii=False, indent=2))
    print("UI fixtures verified: active / missing target / paused", flush=True)


def page():
    # Verify the authenticated page is renderable, without browser automation.
    response = execute("router", "curl", "-sS", "-c", "/tmp/ui-cookie", "-d", "luci_username=root&luci_password=test", "http://127.0.0.1/cgi-bin/luci/admin/services/openclash/device-egress").stdout
    response = execute("router", "curl", "-fsS", "-b", "/tmp/ui-cookie", "http://127.0.0.1/cgi-bin/luci/admin/services/openclash/device-egress").stdout
    assert 'id="device-egress"' in response, response[-1000:]
    if os.environ.get("ROUTER_IMAGE") == "qwrt":
        assert router("uci get luci.main.mediaurlbase") == "/luci-static/design"
        assert "/luci-static/design/" in response, "Design theme missing from page"
    (RESULTS / "ui.html").write_text(response)


def install_ipk(label, force_reinstall=True):
    options = ["--force-reinstall"] if force_reinstall else []
    result = execute("router", "opkg", "install", *options, "/harness/feature.ipk", check=False)
    (RESULTS / f"{label}-opkg.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout + result.stderr


def upgrade_initial():
    if os.environ.get("ROUTER_IMAGE") == "qwrt":
        assert "Version: 0.47.028" in router("opkg status luci-app-openclash")
        previous = "0.47.028"
    else:
        # Upstream has no preinstalled OpenClash. Its image installs master;
        # lower only the installed version to exercise real upgrade hooks.
        previous = earlier_installed_version("initial")
    router("uci set openclash.config.upgrade_test='keep-existing-config'; uci commit openclash; cp /etc/openclash/config/harness.yaml /harness/before-upgrade.yaml")
    install_ipk("initial-upgrade")
    assert router("uci get openclash.config.upgrade_test") == "keep-existing-config"
    assert router("uci get openclash.config.config_path") == "/etc/openclash/config/harness.yaml"
    router("cmp /harness/before-upgrade.yaml /etc/openclash/config/harness.yaml; test -L /etc/rc.d/S18openclash_guard")
    page()
    return f"{previous} -> working tree IPK; existing UCI/YAML preserved; S18 enabled; page loads"


def upgrade_binding():
    running()
    guard_present()
    assert "1886:" in router("ip rule show"), "missing active policy route"
    return "binding saved through LuCI backend; active; TCP+UDP node and DIRECT control verified"


def earlier_installed_version(label):
    # QWRT --force-reinstall runs remove hooks with PKG_UPGRADE=0, rather than
    # upgrade hooks. Keep the IPK identical but mark only the installed version
    # as earlier, so this fixture exercises a genuine future opkg upgrade.
    version = router("opkg status luci-app-openclash").split("Version: ", 1)[1].splitlines()[0]
    earlier = version + "~harness-previous"
    execute("router", "opkg", "compare-versions", earlier, "<", version)
    execute("router", "sh", "-c", """
        awk -v version="$1" '/^Package: / { oc=($2=="luci-app-openclash") }
            oc && /^Version: / { $0="Version: " version } { print }' /usr/lib/opkg/status > /tmp/harness-opkg-status &&
        cat /tmp/harness-opkg-status > /usr/lib/opkg/status &&
        sed -i "s/^Version: .*/Version: $1/" /usr/lib/opkg/info/luci-app-openclash.control
    """, "sh", earlier)
    (RESULTS / f"{label}-version-fixture.txt").write_text(f"Installed metadata only: {version} -> {earlier}\nIPK unchanged\n")
    return earlier


@contextlib.contextmanager
def guard_polling(label):
    before = router("sha256sum /etc/openclash/device-guard.nft").split()[0]
    identity_script = '''lua -e 'local s=assert(require("nixio.fs").stat("/etc/openclash/device-guard.nft")); print(s.ino, s.mtime)' '''
    identity = router(identity_script)
    samples = []
    router("rm -f /tmp/upgrade-poll-stop /tmp/upgrade-poll")
    script = """while [ ! -e /tmp/upgrade-poll-stop ]; do
        if nft list table inet openclash_guard >/dev/null 2>&1; then printf 'present '; else printf 'ABSENT '; fi
        sha256sum /etc/openclash/device-guard.nft 2>/dev/null || echo CACHE_MISSING
        lua -e 'require("nixio").nanosleep(0, 5000000)'
    done > /tmp/upgrade-poll"""
    process = subprocess.Popen(COMPOSE + ["exec", "-T", "router", "sh", "-c", script],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        wait_for(lambda: router("test -s /tmp/upgrade-poll && echo yes") == "yes", "guard poller")
        yield samples
    finally:
        router("touch /tmp/upgrade-poll-stop")
        out, err = process.communicate(timeout=10)
        samples.extend(router("cat /tmp/upgrade-poll").splitlines())
        (RESULTS / f"{label}-guard-poll.txt").write_text("\n".join(samples) + "\n")
    assert process.returncode == 0, out + err
    assert samples and all(line.startswith("present " + before + " ") for line in samples), \
        f"guard/cache changed during {label}; {len(samples)} samples; see {label}-guard-poll.txt"
    assert router("sha256sum /etc/openclash/device-guard.nft").split()[0] == before
    assert router(identity_script) == identity, "cache file was replaced or rewritten during " + label


def upgrade_repeat():
    rows = status()["rows"]
    earlier_installed_version("upgrade")
    with guard_polling("upgrade") as samples, polling("upgrade"):
        output = install_ipk("repeat-upgrade", force_reinstall=False)
        assert "Upgrading luci-app-openclash" in output, output
    assert router("uci get openclash.config.upgrade_test") == "keep-existing-config"
    assert [r["id"] for r in status()["rows"]] == [r["id"] for r in rows]
    guard_present()
    router("test -L /etc/rc.d/S18openclash_guard")
    # default_postinst may already have started the enabled service. Calling
    # start() again would clear its completion marker before an init no-op.
    if router("pidof clash || true"):
        core_ready()
    else:
        start()
    pair(NODE)
    page()
    return f"identical IPK, earlier installed-version fixture; {len(samples)} guard/cache polls unchanged; binding retained"


def upgrade_reinstall():
    version = router("opkg status luci-app-openclash").split("Version: ", 1)[1].splitlines()[0]
    rows = status()["rows"]
    stop()
    pair(BLOCKED)
    # Record the real opkg removal arguments, without changing their behavior.
    router('''for hook in prerm postrm; do
        sed -i '2i echo "hook=$0 args=[$*] PKG_UPGRADE=[$PKG_UPGRADE]" >> /tmp/reinstall-hooks' /usr/lib/opkg/info/luci-app-openclash.$hook
    done''')
    with guard_polling("reinstall") as samples, polling("reinstall", require_block=True):
        install_ipk("equal-version-reinstall")
        deadline = time.monotonic() + 30
        core_ready()
        pair(NODE)
        time.sleep(max(0, deadline - time.monotonic()))
    hooks = router("cat /tmp/reinstall-hooks")
    (RESULTS / "reinstall-hooks.txt").write_text(hooks + "\n")
    assert "args=[remove] PKG_UPGRADE=[0]" in hooks, hooks
    assert router("opkg status luci-app-openclash").split("Version: ", 1)[1].splitlines()[0] == version
    assert [r["id"] for r in status()["rows"]] == [r["id"] for r in rows]
    assert router("uci get openclash.config.upgrade_test") == "keep-existing-config"
    router("test -L /etc/rc.d/S18openclash_guard")
    assert "1886:" in router("ip rule show")
    pair(NODE)
    page()
    counts = json.loads((RESULTS / "reinstall-client-counts.json").read_text())
    traffic = "; ".join(f"{proto.upper()} {counts[proto].get(NODE, 0)}/{counts[proto].get(BLOCKED, 0)}/{counts[proto].get(DIRECT, 0)}"
                        for proto in ("tcp", "udp"))
    return (f"{len(samples)} guard/cache polls unchanged; {traffic} node/blocked/DIRECT; "
            "through reinstall + 30s after opkg")


def upgrade_remove():
    guard_present()
    assert "1886:" in router("ip rule show")
    result = execute("router", "opkg", "remove", "luci-app-openclash", check=False)
    removed = time.monotonic()
    (RESULTS / "remove-opkg.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0, result.stdout + result.stderr
    guard_present()
    assert router("test -s /etc/openclash/device-guard.nft && echo yes") == "yes"
    pair(BLOCKED)
    wait_for(lambda: router("nft list table inet openclash_guard 2>/dev/null || true") == "",
             "detached guard release after opkg exited", timeout=max(1, removed + 25 - time.monotonic()))
    elapsed = time.monotonic() - removed
    assert "1886:" not in router("ip rule show")
    router("test ! -e /etc/rc.d/S18openclash_guard; test ! -L /etc/rc.d/S18openclash_guard; test ! -L /etc/rc.d/K99openclash_guard")
    router("test ! -e /etc/openclash/device-guard.nft; test ! -e /var/run/openclash-device-route")
    # Fresh probes may still time out during the routing transition; require
    # both clients/protocols to recover within the same deferred deadline.
    wait_for(lambda: pair(DIRECT), "TCP+UDP DIRECT after guard release",
             timeout=max(1, removed + 25 - time.monotonic()))
    return f"opkg exited with guard/cache intact; released {elapsed:.1f}s later; links/cache/pref 1886 gone; TCP+UDP DIRECT restored"


def main():
    RESULTS.mkdir(exist_ok=True)
    boot_ready()
    print("Kernel: " + router("uname -r"), flush=True)
    assert router("uname -m") == "aarch64", "Router must run natively on arm64"
    print("OpenWrt: " + router(". /etc/openwrt_release; echo $DISTRIB_DESCRIPTION"), flush=True)
    print("Core: " + router("/etc/openclash/core/clash_meta -v").splitlines()[0], flush=True)
    (RESULTS / "environment.txt").write_text(router("uname -a; cat /etc/openwrt_release; nft --version; ruby -v; opkg list-installed; ip route; ip -6 route"))
    if sys.argv[1] == "ui":
        ui()
        return
    scenarios = [
        ("01 running", running), ("02 modes", modes), ("03 stop", stopped),
        ("04 restart", restart), ("05 kill-9", crash), ("06 start_fail", start_failure),
        ("07 fw4 reload/restart", firewall), ("08 container reboot", reboot),
        ("09 missing/unsafe target", missing_and_validation),
        ("10 changed IPv4/IPv6", changed_ip_and_ipv6),
        ("G group hardening", group_hardening), ("11 pause/remove", pause_remove),
        ("12 no bindings vs master", no_binding_master),
    ]
    if sys.argv[1] == "upgrade":
        scenarios = [("U1 preinstalled upgrade", upgrade_initial), ("U2 add binding", upgrade_binding),
                     ("U3 repeat upgrade", upgrade_repeat), ("U5 equal-version force-reinstall", upgrade_reinstall),
                     ("U4 package removal", upgrade_remove)]
    for name, function in scenarios:
        record(name, function)
    print("\nSCENARIO                         RESULT  DETAIL")
    for name, outcome, detail in ROWS:
        print(f"{name:32} {outcome:6}  {detail}")
    (RESULTS / ("upgrade-summary.json" if sys.argv[1] == "upgrade" else "summary.json")).write_text(json.dumps(ROWS, indent=2))
    if any(outcome == "FAIL" for _, outcome, _ in ROWS):
        sys.exit(1)


if __name__ == "__main__":
    main()
