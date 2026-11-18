// Run against the OS-temp fixture produced by test-run-actions.ps1.
// Set PLAYWRIGHT_MODULE if Playwright is not on NODE_PATH.
const { chromium, devices } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const assert = require('node:assert/strict');

const mimeTypes = {
  '.js': 'text/javascript', '.html': 'text/html', '.css': 'text/css',
  '.woff2': 'font/woff2', '.woff': 'font/woff', '.json': 'application/json',
};
const permissions = ['clipboard-read', 'clipboard-write'];
const normalizeNewlines = text => text.replace(/\r\n/g, '\n');
const executionScript = /^& \{\r?\n#requires -Version 7\.0\r?\n[\s\S]*\r?\n\}\r?\n?$/;

async function openExample(context, url, marker) {
  const page = await context.newPage();
  await page.addInitScript(() => {
    const clipboard = navigator.clipboard;
    const writeText = clipboard.writeText.bind(clipboard);
    clipboard.writeText = text => {
      window.copiedText = Promise.resolve(text);
      return writeText(text);
    };
    const write = clipboard.write.bind(clipboard);
    clipboard.write = items => {
      window.copiedText = items[0].getType('text/plain').then(blob => blob.text()).catch(() => null);
      return write(items);
    };
  });
  await page.goto(url);
  await page.waitForFunction(() => window.docfx?.ready);
  const sample = page.locator('pre.docfx-runnable').filter({ hasText: marker });
  const toolbar = sample.locator('.docfx-run-toolbar');
  const original = sample.locator(':scope > a.code-action');
  const status = sample.getByRole('status');
  await sample.waitFor();
  assert.equal(await original.count(), 1);
  assert.equal(await toolbar.locator('button').count(), 2);
  assert.equal(await sample.locator('code.hljs').count(), 1);
  assert.equal(await page.getByRole('link', { name: /View (Native|Docker) Script/ }).count(), 0);
  const association = sample.locator('xpath=following-sibling::*[1]');
  assert.equal(await association.getAttribute('hidden'), '');
  const actions = await Promise.all(['Native', 'Docker'].map(async label => {
    const name = 'Copy ' + label + ' run script';
    const button = toolbar.getByRole('button', { name, exact: true });
    assert.ok((await button.getAttribute('title')).startsWith(name));
    assert.equal(await button.locator('svg[aria-hidden=true]').count(), 1);
    const href = await association.locator('a[data-transport=' + label.toLowerCase() + ']').getAttribute('href');
    const asset = new URL(href, url).href;
    const response = await page.request.get(asset);
    assert.ok(response.ok());
    const script = await response.text();
    assert.match(script, executionScript, label + ' asset must be one complete script block');
    assert.doesNotMatch(script, /RequirePassingTests|ManifestStdin/);
    return { label, button, asset, script };
  }));
  const navigations = [];
  const downloads = [];
  const popups = [];
  page.on('framenavigated', frame => { if (frame === page.mainFrame()) navigations.push(frame.url()); });
  page.on('download', download => downloads.push(download.suggestedFilename()));
  page.on('popup', popup => popups.push(popup));
  const checkPageUnchanged = () => {
    assert.equal(page.url(), url);
    assert.deepEqual(navigations, []);
    assert.deepEqual(downloads, []);
    assert.deepEqual(popups, []);
  };
  return { page, sample, original, toolbar, status, actions, checkPageUnchanged };
}

async function checkGeometry({ sample, original, actions }) {
  const block = await sample.boundingBox();
  const controls = [...actions.map(action => action.button), original];
  const boxes = await Promise.all(controls.map(control => control.boundingBox()));
  for (const box of boxes) {
    assert.ok(box.y >= block.y && box.y - block.y < 10, 'actions must start in the top row');
    assert.ok(Math.abs(box.y - boxes[2].y) < 1, 'all three actions must share a row');
  }
  for (let index = 1; index < boxes.length; index++) {
    const previous = boxes[index - 1];
    assert.ok(Math.abs(boxes[index].x - previous.x - previous.width) < 5, 'controls must be adjacent');
  }
  assert.ok(Math.abs(block.x + block.width - boxes[2].x - boxes[2].width) < 8, 'copy stays at the top right');
}

async function checkClipboard(page, expected) {
  assert.equal(await page.evaluate(() => window.copiedText), expected);
  assert.equal(normalizeNewlines(await page.evaluate(() => navigator.clipboard.readText())), normalizeNewlines(expected));
}

async function checkCopy(example, index, activate) {
  const { page, actions, status, sample, checkPageUnchanged } = example;
  const { label, button, asset, script } = actions[index];
  const block = await sample.boundingBox();
  await Promise.all([
    page.waitForResponse(response => response.url() === asset && response.ok()),
    activate(button),
  ]);
  await status.filter({ hasText: label + ' script copied.' }).waitFor();
  await checkClipboard(page, script);
  assert.deepEqual(await sample.boundingBox(), block, 'copy feedback must not move or resize the code block');
  checkPageUnchanged();
}

(async () => {
  const site = path.resolve(process.argv[2]);
  const representative = process.argv[3] && path.resolve(process.argv[3]);
  const server = http.createServer((req, res) => {
    let pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    let root = site;
    if (representative && pathname.startsWith('/representative/')) {
      root = representative;
      pathname = pathname.slice('/representative'.length);
    }
    const file = path.resolve(root, '.' + pathname);
    if (!file.startsWith(root + path.sep)) { res.writeHead(403).end(); return; }
    try {
      const content = fs.readFileSync(file);
      res.setHeader('Content-Type', mimeTypes[path.extname(file)] || 'text/plain');
      if (file.endsWith('.ps1')) {
        res.setHeader('Content-Disposition', 'attachment');
        // Model a host that lets browsers cache scripts; a regenerated script must still be copied fresh.
        res.setHeader('Cache-Control', 'max-age=3600');
        res.setHeader('Last-Modified', fs.statSync(file).mtime.toUTCString());
      }
      res.end(content);
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = 'http://127.0.0.1:' + server.address().port;
  const browser = await chromium.launch({ headless: false });
  try {
    const context = await browser.newContext({ permissions, viewport: { width: 1280, height: 900 } });
    const harnessUrl = base + '/docs/packages.html';
    const explanation = 'The test runs the displayed method and checks the correlation identifier returned from the DI container.';
    const harness = await openExample(context, harnessUrl, 'class CorrelationStore');
    assert.ok(await harness.page.getByText(explanation, { exact: true }).isVisible(),
      'the recipe explanation must remain visible after the toolbar is attached');
    await harness.page.close();

    const marker = 'ShouldBootstrapMinimalWorkerProgram';
    const desktop = await openExample(context, base + '/docs/integration.html', marker);
    const { page, sample, original, toolbar, actions, status, checkPageUnchanged } = desktop;
    assert.ok(await page.evaluate(() => window.context7 === true));
    const opacity = () => toolbar.evaluate(node => getComputedStyle(node).opacity);
    assert.equal(await opacity(), '0');
    await sample.hover();
    assert.equal(await opacity(), '1');
    await checkGeometry(desktop);

    const code = await sample.locator('code').innerText();
    await original.click();
    await sample.locator('a.code-action .bi-check-lg').waitFor();
    await checkClipboard(page, code);
    await page.evaluate(async () => (await import('../public/run-actions.js')).enhanceRunActions());
    await sample.locator('a.code-action .bi-clipboard').waitFor({ state: 'attached' });
    assert.equal(await toolbar.locator('button').count(), 2);

    await page.mouse.move(0, 0);
    await sample.locator('xpath=preceding-sibling::*[1]').locator('a').last().focus();
    assert.equal(await opacity(), '0');
    await page.keyboard.press('Tab');
    assert.ok(await actions[0].button.evaluate(button => button === document.activeElement && button.matches(':focus-visible')));
    assert.equal(await opacity(), '1');
    await checkCopy(desktop, 0, button => button.press('Enter'));
    await checkCopy(desktop, 1, button => button.click());
    await status.filter({ hasText: 'Docker script copied.' }).waitFor({ state: 'hidden' });

    await actions[0].button.press('Shift+Enter');
    const preview = page.getByRole('dialog', { name: 'Native run script' });
    await preview.waitFor();
    assert.equal(await preview.locator('pre').textContent(), actions[0].script);
    await checkClipboard(page, actions[1].script);
    await page.keyboard.press('Escape');
    await preview.waitFor({ state: 'detached' });
    assert.ok(await actions[0].button.evaluate(button => button === document.activeElement));
    checkPageUnchanged();

    const api = await openExample(context, base + '/api/fixture.html', marker);
    await checkCopy(api, 0, button => button.press('Enter'));
    await checkCopy(api, 1, button => button.press('Enter'));
    // Regeneration keeps the asset URL; the copy must reflect the current bytes, not the cached response.
    const assetFile = path.resolve(site, '.' + decodeURIComponent(new URL(api.actions[0].asset).pathname));
    const published = fs.readFileSync(assetFile);
    const regenerated = api.actions[0].script.replace(/\r?\n\}\r?\n?$/, '\n# regenerated\n}\n');
    try {
      fs.writeFileSync(assetFile, regenerated);
      await api.status.filter({ hasText: 'Docker script copied.' }).waitFor({ state: 'hidden' });
      await api.actions[0].button.press('Enter');
      await api.status.filter({ hasText: 'Native script copied.' }).waitFor();
      await checkClipboard(api.page, regenerated);
    } finally { fs.writeFileSync(assetFile, published); }
    await api.page.close();

    const mobile = await browser.newContext({ ...devices['iPhone 13'], permissions });
    const touch = await openExample(mobile, base + '/docs/integration.html', marker);
    assert.ok(await touch.page.evaluate(() => matchMedia('(hover: none)').matches));
    assert.equal(await touch.toolbar.evaluate(node => getComputedStyle(node).opacity), '1');
    await touch.sample.scrollIntoViewIfNeeded();
    await checkGeometry(touch);
    assert.ok(await touch.sample.locator('code').evaluate(code => {
      code.scrollLeft = code.scrollWidth;
      return code.scrollLeft > 0;
    }), 'wide C# still scrolls horizontally');
    await checkGeometry(touch);
    await checkCopy(touch, 0, button => button.tap());
    await checkCopy(touch, 1, button => button.tap());
    await mobile.close();

    const noJs = await browser.newContext({ javaScriptEnabled: false });
    const fallback = await noJs.newPage();
    await fallback.goto(page.url());
    assert.equal(await fallback.getByRole('link', { name: 'View Native Script' }).count(), 1);
    assert.equal(await fallback.getByRole('link', { name: 'View Docker Script' }).count(), 1);
    assert.ok((await fallback.locator('pre code').innerText()).includes('Assert.Equal'));
    await fallback.goto(harnessUrl);
    assert.ok(await fallback.getByText(explanation, { exact: true }).isVisible());
    await noJs.close();

    await page.bringToFront();
    await page.route('**/native.ps1', route => route.fulfill({ status: 404, body: 'missing' }));
    const block = await sample.boundingBox();
    await actions[0].button.press('Enter');
    await status.filter({ hasText: 'Could not copy Native script.' }).waitFor();
    assert.deepEqual(await sample.boundingBox(), block);
    assert.equal(normalizeNewlines(await page.evaluate(() => navigator.clipboard.readText())), normalizeNewlines(actions[1].script));
    checkPageUnchanged();

    // Legacy unwrapped and truncated scripts are not complete paste units and must never reach the clipboard.
    const unwrapped = actions[0].script.replace(/^& \{\r?\n/, '').replace(/\r?\n\}\r?\n?$/, '\n');
    const truncated = actions[0].script.replace(/\r?\n\}\r?\n?$/, '\n');
    for (const body of [unwrapped, truncated]) {
      await status.filter({ hasText: 'Could not copy Native script.' }).waitFor({ state: 'hidden' });
      await page.unroute('**/native.ps1');
      await page.route('**/native.ps1', route => route.fulfill({ status: 200, contentType: 'text/plain', body }));
      await actions[0].button.press('Enter');
      await status.filter({ hasText: 'Could not copy Native script.' }).waitFor();
      assert.equal(normalizeNewlines(await page.evaluate(() => navigator.clipboard.readText())), normalizeNewlines(actions[1].script));
      checkPageUnchanged();
    }

    if (representative) {
      await context.route('https://context7.com/widget.js', route => route.fulfill({ contentType: 'text/javascript', body: '' }));
      const visual = await openExample(context, base + '/representative/api/Codebelt.Extensions.Xunit.TestOutputHelperAccessor.html', 'ShouldExposeCurrentOutput');
      await visual.page.locator('script[src="https://context7.com/widget.js"][data-library="/codebeltnet/xunit"]').waitFor({ state: 'attached' });
      await visual.sample.hover();
      await checkGeometry(visual);
      if (process.env.DOCFX_ACTIONS_SCREENSHOT) await visual.sample.screenshot({ path: process.env.DOCFX_ACTIONS_SCREENSHOT });
      await checkCopy(visual, 0, button => button.click());
      await checkCopy(visual, 1, button => button.click());
    }
    console.log('Browser checks passed: aligned controls, full clipboard payloads, keyboard and touch, preview and feedback, no navigation or downloads, Context7 and DocFX rendering.');
  } finally {
    await browser.close();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
