// Run against run.sh ui with playwright-core and a local Chromium installation.
// All page requests are restricted to the loopback preview; no screenshots.
'use strict';
const assert = require('node:assert/strict');
const {chromium} = require('playwright-core');
const port = process.env.UI_PORT || '18082';
const origin = `http://127.0.0.1:${port}`;

(async () => {
    const browser = await chromium.launch({
        ...(process.env.CHROMIUM_PATH ? {executablePath: process.env.CHROMIUM_PATH} : {}),
        args: ['--disable-background-networking']
    });
    try {
        const context = await browser.newContext({viewport: {width: 390, height: 844}, locale: 'zh-CN', serviceWorkers: 'block'});
        await context.route('**/*', route => {
            return new URL(route.request().url()).origin === origin ? route.continue() : route.abort();
        });
        const page = await context.newPage();
        await page.goto(origin + '/cgi-bin/luci/admin/services/openclash/device-egress');
        await page.locator('input[name=luci_password]').fill('test');
        await Promise.all([page.waitForNavigation(), page.locator('input[name=luci_password]').press('Enter')]);
        await page.locator('.de-device').first().waitFor();
        const rows = [];
        for (const action of ['add', 'edit', 'pause', 'delete']) {
            if (action === 'add') await page.locator('.de-add').click();
            else if (action === 'edit') await page.locator('.de-device').first().getByRole('button', {name: '编辑', exact: true}).click();
            else {
                await page.locator('.de-device .de-menu > summary').first().click();
                await page.locator('.de-device .de-menu').first().getByRole('button', {name: action === 'pause' ? '暂停' : '删除', exact: true}).click();
            }
            const geometry = await page.locator('dialog[open]').evaluate(dialog => {
                const rect = node => {
                    const r = node.getBoundingClientRect();
                    return {top: r.top, bottom: r.bottom, height: r.height};
                };
                const body = dialog.querySelector('.de-dialog-body');
                return {
                    header: rect(dialog.querySelector('.de-dialog-header')),
                    body: rect(body),
                    bodyPaddingTop: getComputedStyle(body).paddingTop,
                    footer: rect(dialog.querySelector('.de-dialog-footer')),
                    bareElements: dialog.querySelectorAll('header, footer').length,
                    deviceHeading: body.querySelector('h4') && rect(body.querySelector('h4')),
                    deviceSearch: body.querySelector('.de-picker input') && rect(body.querySelector('.de-picker input')),
                    buttons: [...dialog.querySelectorAll('.de-dialog-footer button')].map(button => {
                        const r = button.getBoundingClientRect(), css = getComputedStyle(button);
                        return {label: button.textContent, ...rect(button),
                            visible: css.visibility === 'visible' && css.display !== 'none' && Number(css.opacity) > 0,
                            hit: document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2) === button};
                    })
                };
            });
            assert.equal(geometry.bareElements, 0);
            assert.equal(geometry.header.top, 0);
            assert(geometry.body.top >= geometry.header.bottom);
            assert.equal(geometry.bodyPaddingTop, '16px');
            assert(geometry.footer.top >= geometry.body.bottom - 1);
            for (const button of geometry.buttons) {
                assert(button.top >= 0 && button.bottom <= 844 && button.visible && button.hit, JSON.stringify(button));
            }
            if (action === 'add' || action === 'edit') {
                assert(geometry.deviceHeading.top >= geometry.body.top + 16);
                assert(geometry.deviceSearch.top >= geometry.deviceHeading.bottom);
                assert(geometry.deviceSearch.bottom <= geometry.body.bottom);
            }
            rows.push({action, ...geometry});
            await page.locator('.de-dialog-footer').getByRole('button', {name: '取消', exact: true}).click();
            await page.locator('dialog').waitFor({state: 'detached'});
        }
        await page.locator('#device-egress > .de-note').scrollIntoViewIfNeeded();
        const bottom = await page.evaluate(() => {
            const note = document.querySelector('#device-egress > .de-note').getBoundingClientRect();
            const card = [...document.querySelectorAll('.de-device')].at(-1).getBoundingClientRect();
            const bars = [...document.querySelectorAll('.navbar')].filter(node => getComputedStyle(node).position === 'fixed')
                .map(node => node.getBoundingClientRect()).filter(rect => rect.height && rect.bottom > 700);
            const limit = Math.min(innerHeight, ...bars.map(rect => rect.top));
            return {noteTop: note.top, noteBottom: note.bottom, lastCardTop: card.top, lastCardBottom: card.bottom, limit};
        });
        assert(bottom.noteTop >= 0 && bottom.lastCardTop >= 0 &&
            bottom.noteBottom <= bottom.limit && bottom.lastCardBottom <= bottom.limit, JSON.stringify(bottom));
        console.log(JSON.stringify({viewport: '390x844', theme: process.env.ROUTER_IMAGE, dialogs: rows, bottom}, null, 2));
    } finally {
        await browser.close();
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
