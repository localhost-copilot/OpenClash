import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
APP = REPO / "luci-app-openclash"
SHARE = APP / "root/usr/share/openclash"
LUA = shutil.which("lua") or shutil.which("luajit")
if not LUA:
    LUA = next(iter(Path("/opt/homebrew/Cellar/luajit").glob("*/bin/luajit")), None)


class DevicePolicyTest(unittest.TestCase):
    def test_lua_guard_and_uci_boundaries(self):
        self.assertIsNotNone(LUA, "Lua or LuaJIT is required for policy tests")
        result = subprocess.run([str(LUA), "tests/device-egress.lua"], cwd=REPO, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("15 tests passed", result.stdout)

    def test_service_save_rollback_and_startup_boundaries(self):
        self.assertIsNotNone(LUA, "Lua or LuaJIT is required for service tests")
        result = subprocess.run([str(LUA), "tests/device-egress-service.lua"], cwd=REPO, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("15 tests passed", result.stdout)

    def test_ui_state_and_mutation_behaviour(self):
        result = subprocess.run(["node", "tests/device-egress-ui.js"], cwd=REPO, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"Device egress UI: \d+ tests passed")


class DeviceYamlTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / "config.yaml"
        self.config = {"proxies": [{"name": "香港 <img>😀'\"", "type": "vmess"}], "proxy-groups": []}

    def invoke(self, operation, rows=None, live=None):
        self.path.write_text(json.dumps(self.config, ensure_ascii=False), encoding="utf-8")
        return subprocess.run(["ruby", str(SHARE / "device_egress.rb"), operation, str(self.path), str(self.root)],
                              input=json.dumps(rows if rows is not None else live or {}), text=True, capture_output=True)

    def catalogue(self, live=None):
        result = self.invoke("catalogue", live=live)
        self.assertEqual(result.returncode, 0, result.stderr)
        return {entry["name"]: entry for entry in json.loads(result.stdout)}

    def binding(self, **changes):
        return dict({"enabled": "1", "mac": "AA:BB:CC:DD:EE:01", "ip": "192.168.50.20", "target": self.config["proxies"][0]["name"]}, **changes)

    def listeners(self):
        result = subprocess.run(["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", str(self.path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_nested_direct_compatible_and_reject(self):
        self.config["proxy-groups"] = [
            {"name": "direct-child", "type": "select", "proxies": ["DIRECT"]},
            {"name": "parent", "type": "url-test", "proxies": ["direct-child"]},
            {"name": "compatible", "type": "fallback", "proxies": ["COMPATIBLE"]},
            {"name": "safe", "type": "select", "proxies": ["REJECT", self.binding()["target"]]},
        ]
        entries = self.catalogue()
        self.assertTrue(entries["parent"]["unsafe"])
        self.assertTrue(entries["compatible"]["unsafe"])
        self.assertFalse(entries["safe"]["unsafe"])

    def test_offline_catalogue_accepts_jsonc_empty_table(self):
        result = self.invoke("catalogue", rows=[])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)[0]["name"], self.binding()["target"])

    def test_cycles_and_missing_group_members_are_unsafe(self):
        self.config["proxy-groups"] = [{"name": "a", "proxies": ["b"]}, {"name": "b", "proxies": ["a"]}, {"name": "missing", "proxies": ["unknown"]}]
        self.assertTrue(all(item["unsafe"] for item in self.catalogue().values() if item["kind"] == "group"))

    def test_include_all_expands_direct_nodes(self):
        self.config["proxies"].append({"name": "local", "type": "direct"})
        self.config["proxy-groups"] = [{"name": "all", "type": "select", "include-all": True}]
        self.assertTrue(self.catalogue()["all"]["unsafe"])

    def test_provider_members_are_checked_even_with_filter(self):
        (self.root / "provider.yaml").write_text(json.dumps({"proxies": [{"name": "direct-from-provider", "type": "direct"}]}))
        self.config["proxy-providers"] = {"p": {"path": "./provider.yaml"}}
        self.config["proxy-groups"] = [{"name": "provider", "type": "select", "use": ["p"], "filter": "safe-only"}]
        self.assertTrue(self.catalogue()["provider"]["unsafe"])

    def test_include_all_providers_and_missing_cache_fail_closed(self):
        self.config["proxy-providers"] = {"p": {"path": "./missing.yaml"}}
        self.config["proxy-groups"] = [{"name": "provider", "include-all-providers": True}]
        self.assertTrue(self.catalogue()["provider"]["unsafe"])

    def test_safe_cached_provider_and_live_selection(self):
        (self.root / "provider.yaml").write_text(json.dumps({"proxies": [{"name": "provider-node", "type": "trojan"}]}))
        self.config["proxy-providers"] = {"p": {"path": "./provider.yaml"}}
        self.config["proxy-groups"] = [{"name": "provider", "type": "select", "use": ["p"]}]
        entry = self.catalogue({"proxies": {"provider": {"all": ["provider-node"], "now": "provider-node"}}})["provider"]
        self.assertFalse(entry["unsafe"])
        self.assertEqual(entry["current"], "provider-node")

    def test_live_direct_members_are_also_checked(self):
        self.config["proxy-groups"] = [{"name": "group", "proxies": [self.binding()["target"]]}]
        self.assertTrue(self.catalogue({"proxies": {"group": {"all": ["DIRECT"]}}})["group"]["unsafe"])

    def test_provider_api_resolves_overridden_names_and_direct_adapter_types(self):
        self.config["proxy-providers"] = {"p": {"type": "inline", "payload": [{"name": "a", "type": "vmess"}]}}
        self.config["proxy-groups"] = [{"name": "group", "use": ["p"]}]
        live = {"proxies": {"group": {"all": ["prefix-a"]}}, "providers": {"p": {"proxies": [{"name": "prefix-a", "type": "Vmess"}]}}}
        self.assertFalse(self.catalogue(live)["group"]["unsafe"])
        live["providers"]["p"]["proxies"][0]["type"] = "Direct"
        self.assertTrue(self.catalogue(live)["group"]["unsafe"])

    def test_direct_adapter_is_unsafe_but_direct_dialer_is_a_proxy(self):
        self.config["proxies"] = [{"name": "a", "type": "vmess", "dialer-proxy": "DIRECT"}, {"name": "b", "type": "direct"}]
        entries = self.catalogue()
        self.assertFalse(entries["a"]["unsafe"])
        self.assertTrue(entries["b"]["unsafe"])

    def test_inline_provider_and_empty_compatible_fallback(self):
        self.config["proxy-providers"] = {"p": {"type": "inline", "payload": []}}
        self.config["proxy-groups"] = [{"name": "empty", "use": ["p"]}, {"name": "reject-empty", "use": ["p"], "empty-fallback": "REJECT"}]
        entries = self.catalogue()
        self.assertTrue(entries["empty"]["unsafe"])
        self.assertFalse(entries["reject-empty"]["unsafe"])

    def test_selected_group_graph_cannot_acquire_direct_or_empty_fallback(self):
        self.config["proxy-groups"] = [
            {"name": "child", "type": "url-test", "proxies": [self.binding()["target"]]},
            {"name": "parent", "type": "select", "proxies": ["child"]},
            {"name": "unrelated", "type": "select", "proxies": ["DIRECT"]}]
        original = json.loads(json.dumps(self.config["proxy-groups"]))
        self.assertEqual(self.invoke("generate", [self.binding(target="parent")]).returncode, 0)
        generated = self.listeners()
        for group in generated["proxy-groups"][:2]:
            self.assertEqual(group["empty-fallback"], "REJECT")
            self.assertIn("Direct", group["exclude-type"])
        self.assertEqual(generated["proxy-groups"][2], original[2])
        self.config = generated
        self.assertEqual(self.invoke("generate", []).returncode, 0)
        self.assertEqual(self.listeners()["proxy-groups"], original)
        self.assertNotIn("x-openclash-device-egress", self.listeners())

    def test_listener_pin_tcp_udp_and_unicode_names_survive_roundtrip(self):
        result = self.invoke("generate", [self.binding()])
        self.assertEqual(result.returncode, 0, result.stderr)
        config = self.listeners()
        listener = config["listeners"][0]
        self.assertEqual(listener["proxy"], self.binding()["target"])
        self.assertEqual(listener["type"], "tproxy")
        self.assertTrue(listener["udp"])
        self.assertEqual(listener["port"], 7901)
        self.assertEqual(config["proxies"], self.config["proxies"])
        self.assertNotIn("rules", config)

    def test_paused_section_reserves_ordinal_port(self):
        result = self.invoke("generate", [self.binding(enabled="0"), self.binding(mac="AA:BB:CC:DD:EE:02")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.listeners()["listeners"][0]["port"], 7902)

    def test_missing_and_unsafe_targets_have_no_inbound(self):
        self.config["proxy-groups"] = [{"name": "bad", "proxies": ["DIRECT"]}]
        result = self.invoke("generate", [self.binding(target="missing"), self.binding(target="bad")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.listeners()["listeners"], [])

    def test_all_openclash_ports_checked_before_writing(self):
        for key, value in [("port", 7901), ("socks-port", 7901), ("redir-port", 7901), ("tproxy-port", 7901), ("mixed-port", 7901), ("external-controller", "127.0.0.1:7901"), ("dns", {"listen": "0.0.0.0:7901"})]:
            with self.subTest(key=key):
                self.config[key] = value
                result = self.invoke("generate", [self.binding()])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads(self.path.read_text()), self.config)
                del self.config[key]

    def test_custom_listener_port_ranges_checked(self):
        self.config["listeners"] = [{"name": "user", "type": "mixed", "port": "7900-7905"}]
        self.assertNotEqual(self.invoke("generate", [self.binding()]).returncode, 0)

    def test_repeated_generation_replaces_only_owned_listeners(self):
        self.config["listeners"] = [{"name": "user", "type": "mixed", "port": 9000}, {"name": "openclash-device-old", "port": 7901}]
        self.assertEqual(self.invoke("generate", [self.binding()]).returncode, 0)
        generated = self.listeners()
        self.assertEqual(len(generated["listeners"]), 2)
        self.assertEqual(generated["listeners"][0], self.config["listeners"][0])
        self.config = generated
        self.assertEqual(self.invoke("generate", [self.binding()]).returncode, 0)
        self.assertEqual(self.listeners(), generated)

    def test_last_removal_strips_only_managed_listeners(self):
        self.config["listeners"] = [{"name": "user", "port": 9000}, {"name": "openclash-device-old", "port": 7901}]
        self.assertEqual(self.invoke("generate", []).returncode, 0)
        self.assertEqual(self.listeners()["listeners"], [{"name": "user", "port": 9000}])

    def test_no_sections_preserves_file_bytes(self):
        self.assertEqual(self.invoke("generate", []).returncode, 0)
        self.assertEqual(self.path.read_text(), json.dumps(self.config, ensure_ascii=False))

    def test_invalid_yaml_preserves_original(self):
        self.path.write_text("broken: [")
        result = subprocess.run(["ruby", str(SHARE / "device_egress.rb"), "generate", str(self.path)], input="[]", text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.path.read_text(), "broken: [")


class GuardInstallTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("etc/openclash", "var/lock", "bin"):
            (self.root / name).mkdir(parents=True)
        script = (SHARE / "device_egress_guard.sh").read_text()
        script = script.replace("/etc/openclash", str(self.root / "etc/openclash")).replace("/var/lock", str(self.root / "var/lock"))
        (self.root / "guard.sh").write_text(script)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ':' + os.environ['PATH'], TEST_ROOT=str(self.root))
        self.command("flock", "exit 0")
        self.command("fw4", "exit 0")
        self.command("logger", "exit 0")
        self.command("lua", 'echo "generator failure" >&2; exit 1')
        self.command("nft", '''
echo "$*" >> "$TEST_ROOT/commands"
case "$*" in
 "-c -f "*)
   if [ "${FAIL_NFT:-0}" = 1 ] && ! grep -q 'priority -300' "$3"; then echo 'invalid nft input' >&2; exit 1; fi;;
 "-f "*) cp "$2" "$TEST_ROOT/applied";;
 "-j list table inet openclash_guard") echo '{"nftables":[]}' ;;
esac
exit 0
''')

    def command(self, name, body):
        path = self.root / "bin" / name
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def run_guard(self, *args):
        return subprocess.run(["sh", str(self.root / "guard.sh"), *map(str, args)], env=self.env, capture_output=True, text=True)

    def test_success_caches_exact_policy_and_flushes_flowtable(self):
        source = self.root / "candidate"
        source.write_text("add table inet openclash_guard\ndelete table inet openclash_guard\n")
        result = self.run_guard("install", source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "etc/openclash/device-guard.nft").read_text(), source.read_text())
        self.assertIn("flush flowtable inet fw4 ft", (self.root / "commands").read_text())

    def test_nft_rejection_installs_emergency_and_fails_save(self):
        source = self.root / "candidate"
        source.write_text("invalid nft input\n")
        self.env["FAIL_NFT"] = '1'
        result = self.run_guard("install", source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid nft input", result.stderr)
        self.assertIn("priority -300; policy drop", (self.root / "applied").read_text())
        self.assertEqual((self.root / "applied").read_bytes(), (self.root / "etc/openclash/device-guard.nft").read_bytes())

    def test_generator_failure_uses_independent_emergency_fallback(self):
        result = self.run_guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('oifname { "lo", "br-lan" } accept', (self.root / "applied").read_text())

    def test_boot_load_replays_cache_without_generator(self):
        cache = self.root / "etc/openclash/device-guard.nft"
        cache.write_text("previous policy\n")
        before = cache.stat()
        self.command("lua", 'case "$2" in check-cache) exit 0;; *) exit 1;; esac')
        result = self.run_guard("load")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "applied").read_text(), "previous policy\n")
        self.assertEqual(cache.read_text(), "previous policy\n")
        self.assertEqual(cache.stat().st_ino, before.st_ino)
        self.assertEqual(cache.stat().st_mtime_ns, before.st_mtime_ns)

    def test_rejected_cache_is_replaced_by_emergency_policy(self):
        cache = self.root / "etc/openclash/device-guard.nft"
        cache.write_text("invalid cached policy\n")
        self.command("lua", 'case "$2" in check-cache) exit 0;; *) exit 1;; esac')
        self.env["FAIL_NFT"] = '1'
        result = self.run_guard("load")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("priority -300; policy drop", cache.read_text())
        self.assertEqual(cache.read_bytes(), (self.root / "applied").read_bytes())


if __name__ == '__main__':
    unittest.main()
