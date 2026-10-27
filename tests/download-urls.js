const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('luci-app-openclash/root/www/luci-static/resources/openclash/js/update.js', 'utf8');
const functions = source.slice(source.indexOf('    function classifyAddr('), source.indexOf('    function findSHAbyVersion('));
const context = {smart_enable: {value: '0'}, isOix: false, pkgType: 'opkg'};
vm.createContext(context);
vm.runInContext(functions, context);
const tag = 'v1.19.29-openconnect.11';
const base = `https://github.com/clash-cube/mihomo/releases/download/${tag}/mihomo-linux-arm64-${tag}.gz`;
for (const branch of ['master', 'dev']) {
    assert.equal(context.buildDownloadURL('', 'core', branch, tag, '', 'linux-arm64'), base);
    assert.equal(context.buildDownloadURL('https://fastly.jsdelivr.net/', 'core', branch, tag, tag, 'linux-arm64'), base);
    assert.equal(context.buildDownloadURL('https://proxy.example/', 'core', branch, tag, tag, 'linux-arm64'), 'https://proxy.example/' + base);
}
assert.equal(context.buildDownloadURL('', 'core', 'master', 'v1.19.29', '', 'linux-arm64'), '');
assert.equal(context.buildDownloadURL('', 'core', 'master', tag, '', '0'), '');
const plugin = context.buildDownloadURL('', 'plugin', 'master', 'v0.48.002.1', '', 'linux-arm64');
assert.equal(plugin, 'https://github.com/localhost-copilot/OpenClash/releases/download/v0.48.002.1/luci-app-openclash_0.48.002.1_all.ipk');
context.pkgType = 'apk';
assert.match(context.buildDownloadURL('https://proxy.example/', 'plugin', 'dev', 'v0.48.002.1', 'v0.48.002.1', 'linux-arm64'), /^https:\/\/proxy\.example\/https:\/\/github.com\/localhost-copilot\/OpenClash\/releases\/download\/v0\.48\.002\.1\/luci-app-openclash-0\.48\.002\.1\.apk$/);
context.smart_enable.value = '1';
assert.match(context.buildDownloadURL('', 'core', 'master', 'alpha-smart-g123', '', 'linux-arm64'), /vernesong\/OpenClash\/core\/master\/smart\/clash-linux-arm64\.tar\.gz$/);
context.isOix = true;
assert.match(context.buildDownloadURL('', 'core', 'master', 'oix-v1', '', 'linux-arm64'), /^https:\/\/dl\.dler\.io\/mihomo-oix\//);
console.log('Download URL checks passed');
