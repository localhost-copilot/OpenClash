import gzip
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SHARE = REPO / "luci-app-openclash/root/usr/share/openclash"
VERSION = "v1.19.29-openconnect.11"
BASE = f"https://github.com/clash-cube/mihomo/releases/download/{VERSION}"
BASH = shutil.which("bash")


class CoreUpdateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in ("etc/openclash/core", "tmp/etc/openclash/core", "tmp/lock", "lib", "share", "bin"):
            (self.root / path).mkdir(parents=True, exist_ok=True)
        self.env = dict(os.environ, PATH=f"{self.root / 'bin'}:{os.environ['PATH']}", TEST_ROOT=str(self.root))
        self.write("lib/functions.sh", "")
        self.write("share/log.sh", 'LOG_ERROR() { echo "$*" >> "$TEST_ROOT/log"; }; LOG_TIP() { :; }; LOG_WARN() { :; }\n')
        self.write("share/uci.sh", '''uci_get_config() {
case "$1" in
 core_type) echo Meta;; core_version) echo linux-arm64;; release_branch) echo master;;
 small_flash_memory) echo "${SMALL_FLASH:-0}";; github_address_mod) echo "${CDN:-0}";;
 smart_enable) echo 0;; *) return 1;; esac; }
''')
        self.write("share/openclash_ps.sh", '''inc_job_counter() { echo active > "$TEST_ROOT/jobs"; }
dec_job_counter_and_restart() { echo "$1" > "$TEST_ROOT/restart"; rm -f "$TEST_ROOT/jobs"; }
''')
        self.write("share/openclash_curl.sh", '''DOWNLOAD_FILE_CURL() {
 echo "$1" > "$TEST_ROOT/url"
 [ "${FAIL_DOWNLOAD:-0}" != 1 ] || return 1
 cp "$TEST_ROOT/payload.gz" "$2"
}
''')
        self.command("flock", "#!/bin/sh\nexit 0\n")
        self.command("sleep", "#!/bin/sh\nexit 0\n")
        self.command("lua", '''#!/usr/bin/env python3
import json,os,sys
if os.environ.get("NO_RELEASE") == "1": sys.exit(1)
print(json.dumps({"version":"''' + VERSION + '''", "url":"''' + BASE + '''/mihomo-linux-arm64-''' + VERSION + '''.gz", "asset":"mihomo-linux-arm64-''' + VERSION + '''.gz"}))
''')
        self.command("jsonfilter", '''#!/usr/bin/env python3
import json,sys
print(json.load(sys.stdin)[sys.argv[-1][2:]])
''')
        script = (SHARE / "openclash_core.sh").read_text()
        paths = {"/lib/": "lib/", "/usr/share/openclash/": "share/", "/etc/": "etc/", "/tmp/": "tmp/"}
        script = re.sub(r"/(?:lib|usr/share/openclash|etc|tmp)/", lambda m: str(self.root / paths[m[0]]) + "/", script)
        # macOS ships Bash 3, which lacks OpenWrt's multi-digit FD redirects.
        script = script.replace("872", "8")
        self.write("update.sh", script)
        self.target = self.root / "etc/openclash/core/clash_meta"
        self.write("etc/openclash/core/clash_meta", '#!/bin/sh\necho "Mihomo Meta old linux arm64"\n')
        self.target.chmod(0o755)
        self.original = self.target.read_bytes()
        self.payload(VERSION)

    def write(self, name, content):
        (self.root / name).write_text(content)

    def command(self, name, content):
        self.write(f"bin/{name}", content)
        (self.root / "bin" / name).chmod(0o755)

    def payload(self, version):
        (self.root / "payload.gz").write_bytes(gzip.compress(f'#!/bin/sh\necho "Mihomo Meta {version} linux arm64"\n'.encode()))

    def run_update(self, *args):
        return subprocess.run([BASH, str(self.root / "update.sh"), "Meta", *args], env=self.env, capture_output=True, text=True)

    def assert_preserved(self):
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual((self.root / "restart").read_text().strip(), "0")
        self.assertFalse((self.root / "jobs").exists())
        self.assertEqual(list(self.target.parent.glob("*.new.*")), [])

    def test_gzip_release_replaces_core_and_requests_restart(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(VERSION.encode(), self.target.read_bytes())
        self.assertEqual((self.root / "url").read_text().strip(), f"{BASE}/mihomo-linux-arm64-{VERSION}.gz")
        self.assertEqual((self.root / "restart").read_text().strip(), "1")
        self.assertFalse((self.root / "jobs").exists())

    def test_missing_release_preserves_existing_core_and_releases_job(self):
        self.env["NO_RELEASE"] = "1"
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assert_preserved()

    def test_wrong_binary_version_preserves_existing_core(self):
        self.payload("v1.19.29")
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Core version mismatch", (self.root / "log").read_bytes())
        self.assert_preserved()

    def test_failed_download_preserves_existing_core(self):
        self.env["FAIL_DOWNLOAD"] = "1"
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assert_preserved()

    def test_corrupt_gzip_preserves_existing_core(self):
        (self.root / "payload.gz").write_text("CDN error page")
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assert_preserved()

    def test_explicit_upstream_url_is_rejected(self):
        result = self.run_update("https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz")
        self.assertNotEqual(result.returncode, 0)
        self.assert_preserved()

    def test_explicit_wrong_arch_is_rejected(self):
        result = self.run_update(f"{BASE}/mihomo-linux-amd64-v1-{VERSION}.gz")
        self.assertNotEqual(result.returncode, 0)
        self.assert_preserved()

    def test_jsdelivr_uses_release_directly(self):
        self.env["CDN"] = "https://fastly.jsdelivr.net/"
        self.assertEqual(self.run_update().returncode, 0)
        self.assertTrue((self.root / "url").read_text().startswith(BASE))

    def test_github_proxy_is_retained(self):
        self.env["CDN"] = "https://proxy.example/"
        self.assertEqual(self.run_update().returncode, 0)
        self.assertTrue((self.root / "url").read_text().startswith("https://proxy.example/" + BASE))

    def test_small_flash_installs_to_temporary_core_path(self):
        self.env["SMALL_FLASH"] = "1"
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(VERSION.encode(), (self.root / "tmp/etc/openclash/core/clash_meta").read_bytes())
        self.assertEqual(self.target.read_bytes(), self.original)


class ChecksumTest(unittest.TestCase):
    def check(self, manifest, expected_return=0, url=None):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "payload").write_bytes(b"release core")
            import hashlib
            digest = hashlib.sha256(b"release core").hexdigest()
            (root / "checksums").write_text(manifest.replace("HASH", digest))
            source = (SHARE / "openclash_curl.sh").read_text()
            source = re.sub(r"^\. /usr/share/openclash/.*$", "", source, flags=re.M)
            (root / "curl.sh").write_text(source)
            binary = root / "sha256sum"
            binary.write_text('#!/usr/bin/env python3\nimport hashlib,sys\nprint(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())\n')
            binary.chmod(0o755)
            filename = f"mihomo-linux-arm64-{VERSION}.gz"
            script = '''source "$1/curl.sh"
LOG_ERROR() { :; }; LOG_WARN() { :; }; LOG_OUT() { :; }
curl() { cat "$TEST_ROOT/checksums"; }
resolve_checksum_from_url "$2" || exit 20
verify_sha256_checksum "$1/payload" "$CHECKSUM_FILENAME" "$CHECKSUM_URL"
'''
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", TEST_ROOT=temp)
            result = subprocess.run([BASH, "-c", script, "test", temp, url or f"{BASE}/{filename}"], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, expected_return, result.stderr)

    def test_matching_release_checksum(self):
        self.check(f"HASH  ./mihomo-linux-arm64-{VERSION}.gz\n")

    def test_missing_checksum_fails_closed(self):
        self.check("", 1)

    def test_mismatching_checksum_fails_closed(self):
        self.check(f"{'0' * 64}  mihomo-linux-arm64-{VERSION}.gz\n", 1)

    def test_filename_is_matched_exactly(self):
        self.check(f"HASH  mihomo-linux-arm64-{VERSION}.gz.backup\n", 1)

    def test_plugin_release_also_requires_checksum(self):
        self.check("", 1, "https://github.com/localhost-copilot/OpenClash/releases/download/v0.48.002.1/luci-app-openclash_0.48.002.1_all.ipk")
