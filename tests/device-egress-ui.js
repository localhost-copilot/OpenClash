// Deterministic DOM/fetch/clock harness. No browser, network or extra packages.
// Layout and theme checks still require a real browser on the target LuCI.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const repo = path.resolve(__dirname, '..');
// DEVICE_EGRESS_JS also exercises the release-minified asset with this DOM harness.
const source = fs.readFileSync(process.env.DEVICE_EGRESS_JS || path.join(repo, 'luci-app-openclash/root/www/luci-static/resources/openclash/js/device_egress.js'), 'utf8');
const po = fs.readFileSync(path.join(repo, 'luci-app-openclash/po/zh-cn/openclash.zh-cn.po'), 'utf8');
const translations = {};
for (const match of po.matchAll(/msgid ("(?:[^"\\]|\\.)*")\s+msgstr ("(?:[^"\\]|\\.)*")/g)) translations[JSON.parse(match[1])] = JSON.parse(match[2]);
// Like the other page scripts, LuCI expands translation markers inside JS literals.
// There is no JS escaping layer here. Check every used zh translation, including
// both quote styles because esbuild may choose a different delimiter.
const messages = new Set();
const translatedSource = source.replace(/<%:([\s\S]*?)%>/g, (_, message) => {
    messages.add(message);
    assert(Object.hasOwn(translations, message) && translations[message], 'Missing zh translation: ' + message);
    const text = translations[message];
    assert(!/["'\\\r\n\u2028\u2029]/.test(text), 'Unsafe JS literal translation: ' + message);
    assert.deepEqual(text.match(/%[sd]/g), message.match(/%[sd]/g), 'Changed placeholders: ' + message);
    return text;
});
assert(messages.size > 0, 'No translation markers found');
new vm.Script(translatedSource);

class Element {
    constructor(tag) {
        this.tagName = tag; this.children = []; this.dataset = {}; this.listeners = {}; this.attributes = {}; this.disabled = false; this.hidden = false; this.open = false; this.scrollTop = 0; this.className = ''; this._text = ''; this.value = '';
        this.style = {setProperty(key, value) { this[key] = value; }, removeProperty(key) { delete this[key]; }};
        this.classList = {
            add: name => { if (!this.className.split(' ').includes(name)) this.className = (this.className + ' ' + name).trim(); },
            remove: name => { this.className = this.className.split(' ').filter(item => item !== name).join(' '); },
            toggle: (name, force) => this.classList[force ? 'add' : 'remove'](name)
        };
    }
    set textContent(text) { this._text = String(text); this.children.forEach(node => { node.parent = null; }); this.children = []; }
    get textContent() { return this._text + this.children.map(node => node.textContent).join(''); }
    set innerHTML(_) { throw new Error('HTML insertion is forbidden'); }
    append(...children) { children.forEach(node => { node.remove(); this.children.push(node); node.parent = this; }); }
    remove() { if (this.parent) this.parent.children = this.parent.children.filter(node => node !== this); this.parent = null; }
    replaceChildren(...children) { this.textContent = ''; this.append(...children); }
    setAttribute(key, value) { this.attributes[key] = String(value); }
    removeAttribute(key) { delete this.attributes[key]; }
    addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener); }
    async emit(type, event = {}) { for (const listener of this.listeners[type] || []) await listener({target: this, preventDefault() {}, stopPropagation() {}, ...event}); }
    async click() { if (!this.disabled) await this.emit('click'); }
    focus() { this.focused = true; }
    select() {}
    scrollIntoView() {}
    contains(node) { return node === this || this.children.some(child => child.contains(node)); }
    getBoundingClientRect() { return this.rect || {top: 100, bottom: 144, height: 44}; }
    showModal() { this.open = true; }
    close() { this.open = false; this.emit('close'); }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    querySelectorAll(selector) {
        const matches = node => selector.split(',').some(part => {
            part = part.trim();
            const classMatch = part.match(/^\.([\w-]+)(\[open\])?$/);
            return part === node.tagName || (classMatch && node.className.split(' ').includes(classMatch[1]) && (!classMatch[2] || node.open)) || (part === 'details[open]' && node.tagName === 'details' && node.open);
        });
        const result = [];
        const walk = node => node.children.forEach(child => { if (matches(child)) result.push(child); walk(child); });
        walk(this); return result;
    }
}
const row = (id, state, changes = {}) => Object.assign({id, name: 'MacBook <img src=x onerror=alert(1)>😀', mac: 'AA:BB:CC:DD:EE:01', ip: '192.168.50.20', target: '香港 <b>😀', enabled: '1', online: true, fixed: false, kind: 'node', state}, changes);
function fixture() {
    return {supported: true, guard: true, running: true, config: 'clash-config.yaml', updated: '12:04:31', offloading: false,
        rows: [row('one', 'active'), row('two', 'missing', {name: 'iPad', mac: 'AA:BB:CC:DD:EE:02', ip: '192.168.50.21'}), row('three', 'paused', {name: 'TV', mac: 'AA:BB:CC:DD:EE:03', ip: '192.168.50.22', enabled: '0'})],
        devices: [{name: 'MacBook <img src=x onerror=alert(1)>😀', mac: 'AA:BB:CC:DD:EE:01', ip: '192.168.50.20', fixed: false, online: true}],
        targets: [{name: 'safe', type: 'vmess', kind: 'node', unsafe: false}, {name: 'bad', type: 'select', kind: 'group', unsafe: true}]};
}
async function harness(initial = fixture()) {
    const root = new Element('div');
    root.dataset = {url: '/openclash', token: 'csrf', firewall: '/firewall'};
    const document = new Element('document'); document.hidden = false;
    document.documentElement = new Element('html'); document.body = new Element('body');
    const window = new Element('window'); window.innerWidth = 1440; window.innerHeight = 900; window.scrollY = 100;
    window.scrollTo = (_, y) => { window.scrollY = y; };
    document.getElementById = id => id === 'device-egress' ? root : null;
    document.createElement = tag => new Element(tag);
    document.createTextNode = text => { const node = new Element('#text'); node.textContent = text; return node; };
    let now = 0, sequence = 0, polls = 0, fail = false, holding = false, release;
    const timers = new Map(), writes = [];
    let state = initial;
    const fetch = async (url, options) => {
        if (url.endsWith('_status')) {
            polls++;
            if (fail) return {ok: false};
            return {ok: true, json: async () => structuredClone(state)};
        }
        const request = JSON.parse(options.body.get('payload'));
        assert.equal(options.method, 'POST'); assert.equal(options.body.get('token'), 'csrf');
        writes.push(request);
        if (holding) await new Promise(resolve => { release = resolve; });
        const result = request.operation === 'fix' ? {fixed: true} : request.operation === 'latency' ? {delay: false} : structuredClone(state);
        return {ok: true, json: async () => result};
    };
    const flush = async () => { await new Promise(resolve => setImmediate(resolve)); };
    vm.runInNewContext(translatedSource, {document, window, fetch, URLSearchParams, AbortController, console,
        setTimeout: (callback, delay) => { const id = ++sequence; timers.set(id, {callback, at: now + delay}); return id; },
        clearTimeout: id => timers.delete(id)});
    await flush();
    return {root, document, window, writes, flush,
        state(value) { state = value; }, fail(value) { fail = value; }, hold(value) { holding = value; }, release() { release(); },
        get polls() { return polls; },
        async tick(duration) {
            const end = now + duration;
            while (true) {
                const next = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
                if (!next || next[1].at > end) break;
                now = next[1].at; timers.delete(next[0]); next[1].callback(); await flush();
            }
            now = end; await flush();
        }};
}
function all(root, tag) { return root.querySelectorAll(tag); }
function buttons(root, label) { return all(root, 'button').filter(node => node.textContent === label); }
function classes(root, className) {
    const result = [];
    const walk = node => { if (node.className.split(' ').includes(className)) result.push(node); node.children.forEach(walk); };
    walk(root); return result;
}
let passed = 0;
async function test(name, fn) { await fn(); console.log('ok - ' + name); passed++; }
(async () => {
    await test('Chinese state model and user names render as text', async () => {
        const h = await harness();
        assert(h.root.textContent.includes('断网保护已生效'));
        assert(h.root.textContent.includes('2 台设备：1 台走节点，1 台已阻断'));
        assert(h.root.textContent.includes('MacBook <img src=x onerror=alert(1)>😀'));
        assert.equal(all(h.root, 'img').length, 0);
        assert.equal(all(h.root, 'b').length, 0);
        assert(h.root.textContent.includes('出口不在当前配置中'));
        assert(h.root.textContent.includes('按普通规则上网'));
        assert(h.root.textContent.includes('被选作出口的策略组会排除直连类节点，组内没有可用节点时拒绝连接，使用同一策略组的其他设备也会受影响。'));
    });
    await test('second failed poll replaces every device badge with unknown', async () => {
        const h = await harness(); h.fail(true);
        await h.tick(5000); assert(h.root.textContent.includes('断网保护已生效'));
        await h.tick(5000);
        assert(h.root.textContent.includes('状态未知'));
        assert(!h.root.textContent.includes('断网保护已生效'));
        assert.deepEqual(classes(h.root, 'de-state').map(node => node.children[0].textContent), ['未知', '未知', '未知']);
    });
    await test('hidden page pauses polling and visibility resumes immediately', async () => {
        const h = await harness(); const initial = h.polls;
        h.document.hidden = true; await h.document.emit('visibilitychange'); await h.tick(60000);
        assert.equal(h.polls, initial);
        h.document.hidden = false; await h.document.emit('visibilitychange'); await h.flush();
        assert.equal(h.polls, initial + 1);
    });
    await test('polling preserves expanded menus and list scroll', async () => {
        const h = await harness();
        classes(h.root, 'de-menu')[0].open = true; classes(h.root, 'de-list')[0].scrollTop = 123;
        await h.tick(5000);
        assert(classes(h.root, 'de-menu')[0].open); assert.equal(classes(h.root, 'de-list')[0].scrollTop, 123);
    });
    await test('pause/delete show the exact confirmations; resume is immediate', async () => {
        const h = await harness();
        await buttons(h.root, '暂停')[0].click();
        let modal = all(h.root, 'dialog')[0];
        assert(modal.textContent.includes('暂停 MacBook <img src=x onerror=alert(1)>😀 的设备出口？'));
        assert(modal.textContent.includes('暂停期间，这台设备按普通规则上网；OpenClash 停止时它会直连。'));
        await buttons(modal, '取消')[0].click();
        await buttons(h.root, '删除')[0].click(); modal = all(h.root, 'dialog')[0];
        assert(modal.textContent.includes('删除后，这台设备会按 OpenClash 的普通规则上网；OpenClash 停止时它会直连。'));
        assert(buttons(modal, '删除')[0].className.includes('de-danger-text'));
        await buttons(modal, '取消')[0].click();
        await buttons(h.root, '恢复')[0].click();
        assert.equal(h.writes.at(-1).operation, 'resume'); assert.equal(all(h.root, 'dialog').length, 0);
    });
    await test('DHCP pin is independent and unsafe choices remain disabled after it', async () => {
        const h = await harness(); await buttons(h.root, '编辑')[0].click();
        const modal = all(h.root, 'dialog')[0];
        const unsafe = all(modal, 'button').find(node => node.textContent.includes('包含 DIRECT，不能使用'));
        assert(unsafe.disabled);
        await buttons(modal, '固定这个 IP')[0].click();
        assert.equal(h.writes[0].operation, 'fix'); assert.equal(h.writes.length, 1);
        assert(unsafe.disabled); assert.equal(classes(modal, 'de-fixed')[0].textContent, '已固定为 192.168.50.20');
        assert.equal(buttons(modal, '固定这个 IP').length, 0);
        assert(all(modal, 'input').find(node => node.name === 'mac').value === 'AA:BB:CC:DD:EE:01');
    });
    await test('save is one POST; applying disables buttons, blocks closure and pauses polls', async () => {
        const h = await harness(); await buttons(h.root, '编辑')[0].click(); h.hold(true);
        const modal = all(h.root, 'dialog')[0];
        const operation = buttons(modal, '保存并应用')[0].click(); await h.flush();
        assert.equal(buttons(modal, '正在应用…').length, 1); assert(all(modal, 'button').every(node => node.disabled));
        const initial = h.polls; await h.tick(20000); assert.equal(h.polls, initial);
        let prevented = false; modal.listeners.cancel[0]({preventDefault() { prevented = true; }}); assert(prevented);
        h.hold(false); h.release(); await operation;
        assert.equal(h.writes.length, 1); assert.equal(h.writes[0].operation, 'save'); assert.equal(all(h.root, 'dialog').length, 0);
    });
    await test('latency timeout retains using-node state', async () => {
        const h = await harness(); await buttons(h.root, '测试延迟')[0].click();
        assert(classes(h.root, 'de-device')[0].textContent.includes('超时'));
        assert.equal(classes(h.root, 'de-state')[0].children[0].textContent, '走节点');
    });
    await test('iptables firmware is read-only and shows exact warning', async () => {
        const state = fixture(); state.supported = false;
        const h = await harness(state);
        assert(h.root.textContent.includes('当前固件不支持设备出口（需要 firewall4 / nftables）。'));
        assert(all(h.root, 'button').every(node => node.disabled));
    });
    await test('empty LuCI JSON tables render empty state with no protection badge', async () => {
        const state = fixture(); state.rows = {}; state.devices = {}; state.targets = {};
        const h = await harness(state);
        assert(h.root.textContent.includes('未设置设备出口'));
        assert(h.root.textContent.includes('还没有设置设备出口'));
        assert(!h.root.textContent.includes('断网保护已生效'));
    });
    await test('DHCP warning requires a valid non-static IPv4 and tracks field changes', async () => {
        const h = await harness(); await buttons(h.root, '+ 添加设备')[0].click();
        const modal = all(h.root, 'dialog')[0];
        const ip = all(modal, 'input').find(node => node.name === 'ip');
        const mac = all(modal, 'input').find(node => node.name === 'mac');
        const warning = classes(modal, 'de-warning')[0];
        assert(warning.hidden);
        for (const value of ['999.1.1.1', '192.168.1', '192.168.01.20', 'hello']) { ip.value = value; await ip.emit('input'); assert(warning.hidden); }
        ip.value = '192.168.50.60'; mac.value = 'aa:bb:cc:dd:ee:60'; await ip.emit('input'); assert(!warning.hidden);
        await buttons(modal, '固定这个 IP')[0].click(); assert.equal(h.writes[0].device.mac, 'AA:BB:CC:DD:EE:60');
        assert.equal(warning.textContent, '已固定为 192.168.50.60');
        ip.value = '192.168.50.61'; await ip.emit('input'); assert(warning.textContent.includes('这个 IP 由 DHCP 动态分配'));
        const state = fixture(); state.devices[0].fixed = true;
        const fixed = await harness(state); await buttons(fixed.root, '编辑')[0].click();
        assert(classes(all(fixed.root, 'dialog')[0], 'de-warning')[0].hidden);
    });
    await test('comboboxes skip disabled options, select with keys and retain manual fields', async () => {
        const state = fixture();
        state.devices.push({name: '', mac: 'aa:bb:cc:dd:ee:60', ip: '', online: false, fixed: false});
        const h = await harness(state); await buttons(h.root, '+ 添加设备')[0].click();
        const modal = all(h.root, 'dialog')[0];
        const [device, target] = classes(modal, 'de-picker');
        const deviceInput = all(device, 'input')[0], targetInput = all(target, 'input')[0];
        const fallback = all(device, 'button').find(node => node.textContent.startsWith('AA:BB:CC:DD:EE:60'));
        assert.equal(all(fallback, 'span')[0].textContent, '离线 · 动态 IP');
        const named = all(device, 'button')[0];
        assert.equal(all(named, 'span')[0].textContent, '192.168.50.20 · AA:BB:CC:DD:EE:01 · 在线 · 动态 IP · 已添加');
        deviceInput.value = 'dd:ee:60'; await deviceInput.emit('input');
        assert.deepEqual(all(device, 'strong').map(node => node.textContent), ['AA:BB:CC:DD:EE:60', '手动输入']);
        await deviceInput.emit('focus'); await deviceInput.emit('keydown', {key: 'ArrowDown'}); await deviceInput.emit('keydown', {key: 'Enter'});
        assert.equal(deviceInput.value, 'AA:BB:CC:DD:EE:60');
        assert(classes(device, 'de-options')[0].hidden);
        assert.equal(all(modal, 'input').find(node => node.name === 'mac').value, 'AA:BB:CC:DD:EE:60');
        assert.equal(all(device, 'strong')[0].textContent, state.devices[0].name);
        await deviceInput.emit('focus'); await buttons(device, '手动输入')[0].click();
        assert(all(modal, 'input').find(node => node.name === 'name').focused);
        await targetInput.emit('focus'); await targetInput.emit('keydown', {key: 'ArrowDown'}); await targetInput.emit('keydown', {key: 'Enter'});
        assert.equal(targetInput.value, 'safe'); assert(classes(target, 'de-options')[0].hidden);
        await targetInput.click(); assert(!classes(target, 'de-options')[0].hidden);
        await buttons(target, 'safevmess')[0].click(); assert(classes(target, 'de-options')[0].hidden);
        await targetInput.emit('focus'); let stopped = false;
        await targetInput.emit('keydown', {key: 'Escape', stopPropagation() { stopped = true; }});
        assert(stopped); assert(modal.open); assert(classes(target, 'de-options')[0].hidden);
        const mac = all(modal, 'input').find(node => node.name === 'mac'); mac.value = 'aa:bb:cc:dd:ee:60';
        await mac.emit('input'); assert.equal(mac.value, 'AA:BB:CC:DD:EE:60');
        await buttons(modal, '保存并应用')[0].click(); assert.equal(h.writes[0].device.mac, 'AA:BB:CC:DD:EE:60');
    });
    await test('row actions follow viewport and menus close or flip without duplicate actions', async () => {
        const h = await harness(); const cards = classes(h.root, 'de-device');
        assert.equal(buttons(classes(cards[0], 'de-actions')[0], '测试延迟').length, 0);
        assert.equal(buttons(classes(cards[0], 'de-state')[0], '测试延迟').length, 1);
        assert.deepEqual(all(classes(cards[0], 'de-menu')[0], 'button').map(node => node.textContent), ['暂停', '删除']);
        assert.deepEqual(all(classes(cards[2], 'de-menu')[0], 'button').map(node => node.textContent), ['删除']);
        const menus = classes(h.root, 'de-menu');
        menus[0].rect = {top: 850, bottom: 894, height: 44};
        await all(menus[0], 'summary')[0].click(); assert(menus[0].open); assert(menus[0].className.includes('de-menu-up'));
        await all(menus[1], 'summary')[0].click(); assert(!menus[0].open); assert(menus[1].open);
        await h.document.emit('click', {target: h.root}); assert(!menus[1].open);
        await all(menus[0], 'summary')[0].click(); await h.document.emit('keydown', {key: 'Escape'}); assert(!menus[0].open);
        await all(menus[0], 'summary')[0].click(); menus[0].rect = {top: -100, bottom: -56, height: 44};
        await h.document.emit('scroll'); assert(!menus[0].open);
        h.window.innerWidth = 390; await h.window.emit('resize');
        assert.equal(buttons(classes(cards[0], 'de-actions')[0], '测试延迟').length, 1);
        assert.equal(buttons(classes(cards[0], 'de-state')[0], '测试延迟').length, 0);
    });
    await test('dialog locks page scroll and restores the previous position on close', async () => {
        const h = await harness(); await buttons(h.root, '编辑')[0].click();
        assert(h.document.body.className.includes('de-modal-open')); assert.equal(h.document.body.style['--de-page-top'], '-100px');
        await buttons(all(h.root, 'dialog')[0], '✕')[0].click();
        assert(!h.document.body.className.includes('de-modal-open')); assert.equal(h.window.scrollY, 100);
    });
    await test('edit and confirmation dialogs avoid theme header/footer element rules', async () => {
        const h = await harness();
        for (const open of [() => buttons(h.root, '+ 添加设备')[0].click(),
                            () => buttons(h.root, '编辑')[0].click(),
                            () => buttons(h.root, '暂停')[0].click(),
                            () => buttons(h.root, '删除')[0].click()]) {
            await open();
            const modal = all(h.root, 'dialog')[0];
            assert.equal(all(modal, 'header').length + all(modal, 'footer').length, 0);
            const [heading, body, footer] = modal.children;
            assert(heading.className.includes('de-dialog-header'));
            assert(body.className.includes('de-dialog-body'));
            assert(footer.className.includes('de-dialog-footer'));
            assert.equal(buttons(footer, '取消').length, 1);
            assert.equal(all(footer, 'button').length, 2);
            await buttons(modal, '取消')[0].click();
        }
    });
    console.log('Translation audit: ' + messages.size + ' zh msgstr safe in JS literals; placeholders preserved');
    console.log('Device egress UI: ' + passed + ' tests passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
