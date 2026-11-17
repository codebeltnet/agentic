// Run against the OS-temp fixture produced by test-run-actions.ps1.
// Requires Playwright; set PLAYWRIGHT_MODULE to its installed module when not on NODE_PATH.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const assert = require('node:assert/strict');
(async () => {
  const site = path.resolve(process.argv[2]);
  const server = http.createServer((req, res) => {
    const file = path.resolve(site, '.' + decodeURIComponent(new URL(req.url, 'http://localhost').pathname));
    if (!file.startsWith(site + path.sep)) { res.writeHead(403).end(); return; }
    try {
      const content = fs.readFileSync(file);
      res.setHeader('Content-Type', file.endsWith('.js') ? 'text/javascript' : file.endsWith('.html') ? 'text/html' : 'text/plain');
      res.end(content);
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ headless: false });
  try {
    const context = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] });
    const page = await context.newPage();
    await page.addInitScript(() => {
      const write = navigator.clipboard.writeText.bind(navigator.clipboard);
      navigator.clipboard.writeText = async text => { window.copiedScript = text; return write(text); };
    });
    await page.goto(base + '/docs/integration.html');
    await page.waitForFunction(() => window.context7 === true);
    await page.getByRole('button', {name: 'Copy Native', exact: true}).waitFor();
    for (const label of ['Native', 'Docker']) {
      const button = page.getByRole('button', {name: `Copy ${label}`, exact: true});
      await button.focus();
      assert.equal(await button.evaluate(b => getComputedStyle(b.parentElement).opacity), '1');
      const href = await page.getByRole('link', {name: `View ${label} Script`}).getAttribute('href');
      const expected = await (await page.request.get(new URL(href, page.url()).href)).text();
      assert.ok(expected.includes('ShouldBootstrapMinimalWorkerProgram'));
      await button.press('Enter');
      await page.getByRole('status').filter({hasText: `${label} script copied`}).waitFor();
      assert.equal(await page.evaluate(() => window.copiedScript), expected);
      assert.equal((await page.evaluate(() => navigator.clipboard.readText())).replace(/\r\n/g, '\n'), expected.replace(/\r\n/g, '\n'));
      assert.ok(expected.includes('84b13767cb9484f8f3a36a71875662edfdb3e511'));
    }
    // Reapplying the component never duplicates controls or the existing DocFX copy button.
    await page.evaluate(async () => (await import('../public/run-actions.js')).enhanceRunActions());
    assert.equal(await page.getByRole('button', {name: 'Copy Native', exact: true}).count(), 1);
    assert.ok(await page.locator('pre code').innerText());
    const originalCode = await page.locator('pre code').innerText();
    await page.locator('pre a.code-action').press('Enter');
    await page.waitForFunction(code => window.copiedScript === code, originalCode);
    assert.equal(await page.getByRole('button', {name: 'Copy Native', exact: true}).count(), 1);
    const apiPage = await context.newPage();
    await apiPage.goto(base + '/api/fixture.html');
    for (const label of ['Native', 'Docker']) {
      const button = apiPage.getByRole('button', {name: `Copy ${label}`, exact: true});
      await button.waitFor();
      await button.press('Enter');
      await apiPage.getByRole('status').filter({hasText: `${label} script copied`}).waitFor();
    }
    const noJs = await browser.newContext({ javaScriptEnabled: false });
    const fallback = await noJs.newPage();
    await fallback.goto(page.url());
    assert.equal(await fallback.getByRole('link', {name: 'View Native Script'}).count(), 1);
    assert.equal(await fallback.getByRole('link', {name: 'View Docker Script'}).count(), 1);
    assert.ok((await fallback.locator('pre code').innerText()).includes('Assert.Equal'));
    // Failure remains inspectable via the same ordinary links.
    await page.route('**/native.ps1', route => route.fulfill({status: 404, body: 'missing'}));
    await page.getByRole('button', {name: 'Copy Native', exact: true}).press('Enter');
    await page.getByRole('status').filter({hasText: 'Could not copy Native'}).waitFor();
    console.log('Browser checks passed: both complete clipboard payloads, keyboard focus/activation, Context7, idempotent enhancement, no-JS fallback and fetch failure.');
  } finally { await browser.close(); server.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
