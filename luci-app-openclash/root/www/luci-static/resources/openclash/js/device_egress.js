(function () {
    'use strict';
    const root = document.getElementById('device-egress');
    const url = root.dataset.url;
    let data = null, busy = false, failures = 0, timer, pending, generation = 0, refreshQueued = false;
    const delays = new Map();
    const nodes = new Map();
    const previousDisabled = new WeakMap();
    let pickerSequence = 0;

    function normalize(value) {
        ['rows', 'devices', 'targets'].forEach(key => {
            if (value[key] && !Array.isArray(value[key]) && Object.keys(value[key]).length === 0) value[key] = [];
            if (!Array.isArray(value[key])) throw new Error('status');
        });
        ['rows', 'devices'].forEach(key => value[key].forEach(item => {
            const mac = String(item.mac || '').toUpperCase();
            if (item.name && item.name.toUpperCase() === mac) item.name = mac;
            item.mac = mac;
        }));
        return value;
    }

    function el(tag, text, className) {
        const node = document.createElement(tag);
        if (text !== undefined && text !== null) node.textContent = String(text);
        if (className) node.className = className;
        return node;
    }
    function fmt(text, ...values) {
        let index = 0;
        return text.replace(/%[sd]/g, () => String(values[index++]));
    }
    function button(text, action, className) {
        const node = el('button', text, className);
        node.type = 'button';
        node.disabled = busy || !data || !data.supported;
        node.addEventListener('click', action);
        return node;
    }
    function link(text, path) {
        const node = el('a', text);
        node.href = path;
        return node;
    }
    function clear(node) { node.replaceChildren(); }
    function deviceTitle(device) { return device.name || device.mac; }
    function placeRowAction(card) {
        const action = card.querySelector('.de-inline-action');
        if (action) card.querySelector(window.innerWidth < 768 ? '.de-actions' : '.de-state-detail').append(action);
    }
    function closeMenus(except) {
        root.querySelectorAll('.de-menu[open]').forEach(menu => { if (menu !== except) menu.open = false; });
    }
    function positionMenu(menu) {
        if (!menu.open) return;
        const choices = menu.querySelector('.de-menu-items');
        choices.style.maxHeight = Math.max(44, window.innerHeight - 16) + 'px';
        menu.classList.remove('de-menu-up');
        const anchor = menu.getBoundingClientRect();
        if (anchor.bottom <= 8 || anchor.top >= window.innerHeight - 8) { menu.open = false; return; }
        const height = choices.getBoundingClientRect().height;
        const below = window.innerHeight - anchor.bottom - 8;
        const above = anchor.top - 8;
        const upward = height > below && above > below;
        menu.classList.toggle('de-menu-up', upward);
        choices.style.maxHeight = Math.max(44, upward ? above : below) + 'px';
    }
    document.addEventListener('click', event => {
        root.querySelectorAll('.de-menu[open]').forEach(menu => { if (!menu.contains(event.target)) menu.open = false; });
    });
    document.addEventListener('keydown', event => {
        if (event.key === 'Escape') closeMenus();
    });
    window.addEventListener('resize', () => {
        nodes.forEach(placeRowAction);
        root.querySelectorAll('.de-menu[open]').forEach(positionMenu);
    });
    document.addEventListener('scroll', () => root.querySelectorAll('.de-menu[open]').forEach(positionMenu), true);
    const warnings = el('div', null, 'de-warnings');
    const summary = el('section', null, 'de-card de-summary');
    const list = el('div', null, 'de-list');
    const columns = el('div', null, 'de-columns de-desktop');
    ["<%:Device%>", "<%:Egress%>", "<%:Status%>"].forEach(text => columns.append(el('strong', text)));
    columns.hidden = true;
    const directory = el('section', null, 'de-directory');
    directory.append(columns, list);
    const error = el('div', null, 'de-error');
    error.setAttribute('role', 'alert');
    root.append(el('h2', "<%:Device Egress%>"), el('p', "<%:Route all Internet traffic from selected devices through one node or group. These devices lose Internet access when OpenClash stops, restarts or fails to start; they never connect directly.%>"), warnings, error, summary, directory,
        el('p', "<%:Bound devices bypass mainland bypass, blacklists, whitelists, source traffic access control and proxy mode (global/direct); IPv6 Internet access is blocked. Groups selected as egress exclude direct nodes and reject connections when no usable nodes remain; other devices using the same group are also affected.%>", 'de-note'));

    function showError(problem, host = error) {
        clear(host);
        if (!problem) return;
        host.append(el('p', problem.message || String(problem)));
        if (problem.details) {
            const details = el('details');
            details.append(el('summary', "<%:Show details%>"), el('pre', problem.details));
            host.append(details);
        }
    }
    function badge(text, tone) { return el('span', text, 'de-badge de-' + tone); }
    function status(row, unknown) {
        if (unknown) return ["<%:Unknown%>", '', 'muted'];
        switch (row.state) {
        case 'paused': return ["<%:Paused%>", "<%:Uses ordinary rules%>", 'muted'];
        case 'unprotected': return ["<%:Unprotected%>", "<%:May connect directly when stopped%>", 'danger'];
        case 'stopped': return ["<%:Blocked%>", "<%:OpenClash is not running%>", 'danger'];
        case 'starting': return ["<%:Blocked%>", "<%:OpenClash is starting%>", 'warning-text'];
        case 'missing': return ["<%:Blocked%>", "<%:Egress is missing from the current configuration%>", 'danger'];
        case 'direct': return ["<%:Blocked%>", "<%:Group contains DIRECT%>", 'danger'];
        case 'inbound': return ["<%:Blocked%>", "<%:Core has not loaded device egress; check the runtime log%>", 'danger'];
        case 'ip_changed': return ["<%:Blocked%>", fmt("<%:Device IP has changed to %s%>", row.current_ip), 'danger'];
        case 'active': return ["<%:Using node%>", '', 'success'];
        default: return ["<%:Unknown%>", '', 'muted'];
        }
    }
    function exitDescription(row) {
        let text = row.kind === 'group' ? "<%:Group%>" : "<%:Node%>";
        if (row.current && data.running) text += ' · ' + fmt("<%:Current %s%>", row.current);
        if (delays.has(row.id)) {
            const delay = delays.get(row.id);
            text += ' · ' + (delay === false ? "<%:Timeout%>" : delay + ' ms');
        }
        return text;
    }
    function warning(text, action) {
        const node = el('div', null, 'de-warning');
        node.append(el('span', text));
        if (action) node.append(action);
        warnings.append(node);
    }
    function render(unknown = false) {
        if (!data) {
            clear(summary);
            summary.append(badge("<%:Status unknown%>", 'muted'), el('p', "<%:Unable to retrieve status; retrying.%>"));
            return;
        }
        const scroll = list.scrollTop;
        columns.hidden = !data.rows.length;
        const open = new Set(Array.from(list.querySelectorAll('details[open]')).map(node => node.dataset.id));
        clear(warnings);
        if (!data.supported) warning("<%:This firmware does not support device egress (requires firewall4 / nftables).%>");
        if (data.offloading) warning("<%:Flow offloading is enabled. Established connections may bypass protection. Disabling it is recommended.%>", link("<%:Go to firewall settings%>", root.dataset.firewall));
        data.rows.filter(row => row.random_mac).forEach(row => warning(fmt("<%:%s uses a random MAC. Disable rotating / private addresses for this network in the device's Wi-Fi settings, otherwise a MAC change will remove its protection.%>", row.name)));
        if (data.target_error) warning("<%:Unable to read the current configuration.%>");
        clear(summary);
        const enabled = data.rows.filter(row => row.enabled === '1');
        const active = enabled.filter(row => row.state === 'active').length;
        let title, subtitle, tone;
        if (unknown) {
            title = "<%:Status unknown%>"; subtitle = "<%:Unable to retrieve status; retrying.%>"; tone = 'muted';
        } else if (!enabled.length) {
            title = "<%:Device egress is not configured%>"; tone = 'muted';
            subtitle = "<%:After adding a device, it loses Internet access when OpenClash stops and never connects directly.%>";
        } else if (data.guard) {
            title = "<%:Protection is active%>"; tone = 'success';
            subtitle = fmt("<%:%d devices: %d using nodes, %d blocked%>", enabled.length, active, enabled.length - active);
        } else {
            title = "<%:Protection is inactive%>"; tone = 'danger';
            subtitle = "<%:These devices may connect directly when OpenClash stops.%>";
        }
        const description = el('div');
        description.append(badge(title, tone), el('p', subtitle));
        if (!unknown && enabled.length && !data.guard) description.append(button("<%:Reapply protection%>", () => write({operation: 'reapply'})));
        const meta = el('p', null, 'de-meta');
        meta.append(document.createTextNode(data.running ? "<%:OpenClash is running%>" : "<%:OpenClash is not running%>"));
        meta.append(el('span', ' · ' + fmt("<%:Configuration %s%>", data.config), 'de-desktop'));
        meta.append(document.createTextNode(' · '), el('span', fmt("<%:Updated at %s%>", data.updated), 'de-desktop'), el('span', data.updated, 'de-mobile'));
        description.append(meta);
        summary.append(description, button("<%:+ Add device%>", () => edit(), 'de-add'));

        // Reuse each card element; preserve menus and the list's scroll position.
        const present = new Set();
        if (!data.rows.length) {
            clear(list); nodes.clear();
            const empty = el('section', null, 'de-card de-empty');
            empty.append(el('p', "<%:No device egress configured yet%>"), button("<%:+ Add device%>", () => edit()));
            list.append(empty);
        } else {
            if (!nodes.size) clear(list);
            data.rows.forEach(row => {
                present.add(row.id);
                let card = nodes.get(row.id);
                if (!card) { card = el('article', null, 'de-card de-device'); nodes.set(row.id, card); }
                clear(card);
                const state = status(row, unknown);
                const identity = el('div', null, 'de-identity');
                const address = el('div', row.ip);
                address.append(el('span', ' · ' + (row.online ? "<%:Online%>" : "<%:Offline%>"), 'de-mobile'));
                identity.append(el('strong', deviceTitle(row)), address, el('small', row.mac + ' · ' + (row.online ? "<%:Online%>" : "<%:Offline%>"), 'de-desktop'));
                const egress = el('div', null, 'de-egress');
                egress.append(el('span', "<%:Egress%>" + ' ', 'de-mobile'), el('strong', row.target), el('div', exitDescription(row), (delays.get(row.id) === false ? 'de-warning-text' : 'de-meta') + ' de-desktop'));
                let mobileDescription = row.current && data.running ? ' · ' + fmt("<%:Current %s%>", row.current) : '';
                if (delays.has(row.id)) mobileDescription += ' · ' + (delays.get(row.id) === false ? "<%:Timeout%>" : delays.get(row.id) + ' ms');
                egress.append(el('span', mobileDescription, 'de-mobile' + (delays.get(row.id) === false ? ' de-warning-text' : '')));
                const stateNode = el('div', null, 'de-state');
                const stateDetail = el('small', state[1], 'de-state-detail');
                stateNode.append(badge(state[0], state[2]), stateDetail);
                const actions = el('div', null, 'de-actions');
                const menu = el('details', null, 'de-menu');
                menu.dataset.id = row.id; menu.open = open.has(row.id);
                const toggle = el('summary', '⋯'); toggle.setAttribute('aria-label', "<%:More actions%>");
                toggle.addEventListener('click', event => {
                    event.preventDefault();
                    const opening = !menu.open;
                    closeMenus(menu); menu.open = opening; positionMenu(menu);
                });
                menu.addEventListener('toggle', () => { if (menu.open) { closeMenus(menu); positionMenu(menu); } });
                const choices = el('div', null, 'de-menu-items');
                choices.addEventListener('click', () => { menu.open = false; });
                if (row.enabled === '1') choices.append(button("<%:Pause%>", () => confirmAction(row, 'pause')));
                else if (unknown || row.state !== 'paused') choices.append(button("<%:Resume%>", () => write({operation: 'resume', id: row.id})));
                if (unknown || (row.state !== 'active' && row.state !== 'paused')) choices.append(button("<%:Test latency%>", () => latency(row)));
                choices.append(button("<%:Delete%>", () => confirmAction(row, 'delete'), 'de-danger-text'));
                menu.append(toggle, choices);
                actions.append(button("<%:Edit%>", () => edit(row)), menu);
                const inline = el('span', null, 'de-inline-action');
                if (!unknown && row.state === 'paused') inline.append(button("<%:Resume%>", () => write({operation: 'resume', id: row.id})));
                if (!unknown && row.state === 'active') inline.append(button("<%:Test latency%>", () => latency(row)));
                if (!unknown && row.state === 'unprotected') inline.append(button("<%:Reapply protection%>", () => write({operation: 'reapply'})));
                if (!unknown && (row.state === 'missing' || row.state === 'direct')) inline.append(button("<%:Change egress%>", () => edit(row)));
                if (!unknown && row.state === 'inbound') inline.append(link("<%:Runtime log%>", url + '/log'));
                if (!unknown && row.state === 'ip_changed') inline.append(button("<%:Use new IP%>", () => edit(Object.assign({}, row, {ip: row.current_ip}))));
                // One action per row, positioned in the status cell on desktop and the action bar on mobile.
                if (inline.children.length) {
                    if (state[1]) stateDetail.append(el('span', ' · ', 'de-desktop'));
                    stateDetail.append(inline);
                }
                card.append(identity, egress, stateNode, actions);
                placeRowAction(card);
                list.append(card);
            });
            nodes.forEach((card, id) => { if (!present.has(id)) { card.remove(); nodes.delete(id); } });
        }
        list.scrollTop = scroll;
    }
    async function refresh() {
        clearTimeout(timer);
        if (busy || document.hidden) return;
        if (pending) { refreshQueued = true; return; }
        refreshQueued = false;
        const version = generation;
        pending = new AbortController();
        const timeout = setTimeout(() => pending && pending.abort(), 15000);
        try {
            const response = await fetch(url + '/device_egress_status', {cache: 'no-store', signal: pending.signal, credentials: 'same-origin'});
            if (!response.ok) throw new Error('status');
            const next = normalize(await response.json());
            if (version !== generation) return;
            data = next; failures = 0; render();
        } catch (problem) {
            if (version === generation && !document.hidden) {
                failures++;
                if (failures >= 2 || !data) render(true);
            }
        } finally {
            clearTimeout(timeout); pending = null;
            if (!busy && !document.hidden) timer = setTimeout(refresh, refreshQueued ? 0 : 5000);
        }
    }
    function setBusy(value) {
        busy = value; generation++;
        clearTimeout(timer);
        if (pending) pending.abort();
        root.querySelectorAll('button, input').forEach(node => {
            if (value) { previousDisabled.set(node, node.disabled); node.disabled = true; }
            else node.disabled = previousDisabled.get(node) || !data || !data.supported;
        });
        root.setAttribute('aria-busy', String(value));
    }
    async function write(request, host = error) {
        if (busy || !data || !data.supported) return null;
        setBusy(true); showError(null, host);
        try {
            const response = await fetch(url + '/device_egress_write', {method: 'POST', credentials: 'same-origin',
                body: new URLSearchParams({token: root.dataset.token, payload: JSON.stringify(request)})});
            const result = await response.json();
            if (!response.ok || result.error) throw Object.assign(new Error(result.error || "<%:Unable to apply device egress.%>"), {details: result.details});
            if (result.rows) { data = normalize(result); failures = 0; }
            return result;
        } catch (problem) { showError(problem, host); return null; }
        finally { setBusy(false); render(failures >= 2); timer = setTimeout(refresh, 0); }
    }
    async function latency(row) {
        const result = await write({operation: 'latency', id: row.id});
        if (result) { delays.set(row.id, result.delay); render(); }
    }
    function dialog(title) {
        closeMenus();
        const node = el('dialog', null, 'de-dialog');
        const heading = el('div', null, 'de-dialog-header');
        const close = button('✕', () => { if (!busy) node.close(); });
        close.autofocus = true;
        close.setAttribute('aria-label', "<%:Close%>");
        const titleNode = el('h3', title); titleNode.id = 'de-dialog-title';
        heading.append(titleNode, close);
        node.setAttribute('aria-labelledby', titleNode.id);
        node.append(heading);
        node.addEventListener('cancel', event => { if (busy) event.preventDefault(); });
        const scrollY = window.scrollY;
        document.documentElement.classList.add('de-modal-open');
        document.body.classList.add('de-modal-open');
        document.body.style.setProperty('--de-page-top', -scrollY + 'px');
        node.addEventListener('close', () => {
            node.remove();
            document.documentElement.classList.remove('de-modal-open');
            document.body.classList.remove('de-modal-open');
            document.body.style.removeProperty('--de-page-top');
            window.scrollTo(0, scrollY);
        });
        root.append(node);
        return node;
    }
    function confirmAction(row, operation) {
        const deleting = operation === 'delete';
        const node = dialog(fmt(deleting ? "<%:Delete device egress for %s?%>" : "<%:Pause device egress for %s?%>", deviceTitle(row)));
        const content = el('div', null, 'de-dialog-body');
        const localError = el('div', null, 'de-error'); localError.setAttribute('role', 'alert');
        content.append(el('p', deleting ? "<%:After deletion, this device uses ordinary OpenClash rules and connects directly when OpenClash stops.%>" : "<%:While paused, this device uses ordinary rules and connects directly when OpenClash stops.%>"), localError);
        const footer = el('div', null, 'de-dialog-footer');
        const apply = button(deleting ? "<%:Delete%>" : "<%:Pause%>", async () => {
            apply.textContent = "<%:Applying…%>";
            const result = await write({operation, id: row.id}, localError);
            if (result) node.close(); else apply.textContent = deleting ? "<%:Delete%>" : "<%:Pause%>";
        }, deleting ? 'de-danger-text' : '');
        footer.append(button("<%:Cancel%>", () => node.close()), apply);
        node.append(content, footer); node.showModal();
    }
    function combobox(placeholder, selected, populate, onClear) {
        const picker = el('div', null, 'de-picker');
        const input = el('input'); input.placeholder = placeholder; input.value = selected || '';
        input.setAttribute('aria-label', placeholder); input.setAttribute('role', 'combobox');
        input.setAttribute('aria-autocomplete', 'list'); input.setAttribute('aria-expanded', 'false');
        input.autocomplete = 'off';
        const options = el('div', null, 'de-options'); options.id = 'de-options-' + ++pickerSequence;
        options.setAttribute('role', 'listbox'); options.setAttribute('aria-label', placeholder);
        input.setAttribute('aria-controls', options.id); options.hidden = true;
        let active = -1, choices = [], selectedText = input.value;
        function activate(index) {
            active = index;
            choices.forEach((choice, i) => choice.setAttribute('aria-selected', String(i === active)));
            if (active < 0) input.removeAttribute('aria-activedescendant');
            else {
                input.setAttribute('aria-activedescendant', choices[active].id);
                choices[active].scrollIntoView({block: 'nearest'});
            }
        }
        function close() {
            options.hidden = true; input.setAttribute('aria-expanded', 'false'); activate(-1);
            input.value = selectedText;
        }
        function choose(label, action) { selectedText = label; close(); action(); }
        function fill(query) {
            clear(options); choices = []; active = -1; input.removeAttribute('aria-activedescendant');
            populate(query.toLocaleLowerCase(), (title, subtitle, disabled, action) => {
                const choice = button('', () => choose(title, action));
                choice.id = options.id + '-' + choices.length; choice.tabIndex = -1;
                choice.setAttribute('role', 'option'); choice.setAttribute('aria-selected', 'false');
                choice.disabled = choice.disabled || disabled; choice.setAttribute('aria-disabled', String(choice.disabled));
                choice.append(el('strong', title)); if (subtitle) choice.append(el('span', subtitle));
                // Keep focus on the input so keyboard navigation and outside blur use one owner.
                choice.addEventListener('pointerdown', event => event.preventDefault());
                choices.push(choice); options.append(choice);
            }, heading => options.append(el('div', heading, 'de-option-heading')));
        }
        function open(query) { fill(query); options.hidden = false; input.setAttribute('aria-expanded', 'true'); }
        input.addEventListener('focus', () => { input.select(); open(''); });
        input.addEventListener('click', () => { if (options.hidden) open(''); });
        input.addEventListener('input', () => { selectedText = ''; if (onClear) onClear(); open(input.value); });
        input.addEventListener('blur', close);
        input.addEventListener('keydown', event => {
            if (event.key === 'Escape' && !options.hidden) { event.preventDefault(); event.stopPropagation(); close(); }
            if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
                event.preventDefault(); if (options.hidden) open('');
                const direction = event.key === 'ArrowDown' ? 1 : -1;
                let index = active < 0 ? (direction > 0 ? -1 : choices.length) : active;
                while ((index += direction) >= 0 && index < choices.length) {
                    if (!choices[index].disabled) { activate(index); break; }
                }
            }
            if (event.key === 'Enter' && !options.hidden) {
                event.preventDefault(); if (active >= 0 && !choices[active].disabled) choices[active].click();
            }
        });
        picker.append(input, options); fill('');
        return picker;
    }
    function edit(row) {
        const node = dialog(row ? "<%:Edit device%>" : "<%:Add device%>");
        const body = el('div', null, 'de-dialog-body');
        const localError = el('div', null, 'de-error'); localError.setAttribute('role', 'alert');
        const fields = {};
        function field(label, key, value) {
            const labelNode = el('label');
            const input = el('input'); input.value = value || ''; input.name = key;
            if (key === 'ip') input.inputMode = 'decimal';
            if (key === 'mac') {
                input.autocapitalize = 'characters';
                input.addEventListener('input', () => { input.value = input.value.toUpperCase(); });
            }
            labelNode.append(el('span', label), input); fields[key] = input;
            return labelNode;
        }
        body.append(el('h4', "<%:Device%>"));
        const nameField = field("<%:Name%>", 'name', row && row.name);
        const macField = field("<%:MAC%>", 'mac', row && row.mac);
        const ipField = field("<%:IPv4%>", 'ip', row && row.ip);
        const picker = combobox("<%:Search name, IP or MAC%>", row && deviceTitle(row), (query, option) => {
            data.devices.filter(device => [device.name, device.ip, device.mac].join(' ').toLocaleLowerCase().includes(query)).forEach(device => {
                const title = deviceTitle(device);
                const added = data.rows.some(item => item.mac === device.mac && (!row || item.id !== row.id));
                const subtitle = [device.ip, title === device.mac ? '' : device.mac, device.online ? "<%:Online%>" : "<%:Offline%>", device.fixed ? "<%:Static IP%>" : "<%:Dynamic IP%>", added ? "<%:Already added%>" : ''].filter(Boolean).join(' · ');
                option(title, subtitle, added, () => {
                    fields.name.value = device.name || ''; fields.mac.value = device.mac; fields.ip.value = device.ip || '';
                    updateDynamic();
                });
            });
            option("<%:Manual entry%>", '', false, () => fields.name.focus());
        });
        body.append(picker, nameField, macField, ipField);
        const dynamic = el('div', null, 'de-warning');
        let fixedLease = null;
        const fixedButton = button("<%:Fix this IP%>", async () => {
            const device = values();
            const result = await write({operation: 'fix', device}, localError);
            if (result) { fixedLease = device; updateDynamic(); }
        });
        function updateDynamic() {
            const {mac, ip} = values();
            const justFixed = fixedLease && fixedLease.mac === mac && fixedLease.ip === ip;
            const validIP = /^(?:\d{1,3}\.){3}\d{1,3}$/.test(ip) && ip.split('.').every(part => Number(part) <= 255 && String(Number(part)) === part);
            const isStatic = data.devices.some(item => item.mac === mac && item.fixed && item.ip === ip);
            dynamic.hidden = !validIP || (isStatic && !justFixed);
            dynamic.className = justFixed ? 'de-fixed de-note' : 'de-warning';
            if (justFixed) { dynamic.replaceChildren(el('span', fmt("<%:Fixed to %s%>", ip))); return; }
            fixedButton.textContent = "<%:Fix this IP%>"; fixedButton.disabled = busy || !data.supported;
            dynamic.replaceChildren(el('span', "<%:This IP is assigned dynamically by DHCP. If it changes, this device loses Internet access.%>"), fixedButton);
        }
        fields.mac.addEventListener('input', updateDynamic); fields.ip.addEventListener('input', updateDynamic);
        body.append(dynamic);
        updateDynamic();
        body.append(el('h4', "<%:Egress%>"));
        let target = row ? row.target : '';
        const targets = combobox("<%:Search nodes or groups%>", target, (query, option, heading) => {
            ['group', 'node'].forEach(kind => {
                heading(kind === 'group' ? "<%:Groups%>" : "<%:Nodes%>");
                data.targets.filter(item => item.kind === kind && item.name.toLocaleLowerCase().includes(query)).forEach(item => {
                    option(item.name, item.type + (item.current && data.running ? ' · ' + fmt("<%:Current %s%>", item.current) : '') + (item.unsafe ? ' · ' + "<%:Contains DIRECT; unavailable%>" : ''), item.unsafe, () => { target = item.name; });
                });
            });
        }, () => { target = ''; });
        body.append(targets);
        body.append(el('p', fmt("<%:The node list comes from the current configuration %s. If a new configuration has no egress with the same name, this device loses Internet access.%>", data.config), 'de-note'), el('h4', "<%:After saving:%>"));
        const consequences = el('ul', null, 'de-consequences');
        ["<%:This device's IPv4 Internet traffic only uses the selected egress%>", "<%:IPv6 Internet access is blocked%>", "<%:No Internet access when OpenClash stops, restarts or fails to start; never a direct connection%>", "<%:If OpenClash is running, it reloads and interrupts connections for all devices for a few seconds%>"].forEach(text => consequences.append(el('li', text)));
        body.append(consequences, localError);
        const footer = el('div', null, 'de-dialog-footer');
        const save = button("<%:Save and apply%>", async () => {
            if (!target) { showError(new Error("<%:Please select an egress.%>"), localError); return; }
            save.textContent = "<%:Applying…%>";
            const result = await write({operation: 'save', id: row && row.id, device: Object.assign(values(), {target})}, localError);
            if (result) node.close(); else save.textContent = "<%:Save and apply%>";
        });
        function values() { return {name: fields.name.value, mac: fields.mac.value.trim().toUpperCase(), ip: fields.ip.value.trim()}; }
        footer.append(button("<%:Cancel%>", () => node.close()), save);
        node.append(body, footer); node.showModal();
    }
    document.addEventListener('visibilitychange', () => {
        clearTimeout(timer);
        if (document.hidden) { generation++; if (pending) pending.abort(); }
        else refresh();
    });
    render(true); refresh();
}());
