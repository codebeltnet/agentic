// Optional modern-template enhancement. Links and C# remain usable without JavaScript.
export function enhanceRunActions(root = document) {
  for (const links of root.querySelectorAll('.docfx-run-actions:not([data-enhanced])')) {
    const previous = links.previousElementSibling;
    const pre = previous?.matches('pre') ? previous : previous?.querySelector('pre');
    if (!pre?.querySelector('code.lang-csharp, code.language-csharp, code.lang-cs, code.language-cs')) continue;
    links.dataset.enhanced = 'true';
    const toolbar = document.createElement('span');
    toolbar.className = 'docfx-run-toolbar';
    toolbar.setAttribute('role', 'group');
    toolbar.setAttribute('aria-label', 'Runnable example scripts');
    const status = document.createElement('span');
    status.setAttribute('role', 'status');
    status.className = 'docfx-run-status';
    links.append(status);
    for (const link of links.querySelectorAll('a[data-transport]')) {
      const transport = link.dataset.transport;
      const label = transport === 'native' ? 'Native' : 'Docker';
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'docfx-run-copy';
      button.title = `Copy the complete ${label} PowerShell script. Review View ${label} Script before executing.`;
      button.setAttribute('aria-label', `Copy ${label}`);
      const icon = document.createElement('span');
      icon.textContent = '⧉';
      icon.setAttribute('aria-hidden', 'true');
      button.append(icon, ` Copy ${label}`);
      button.addEventListener('click', async () => {
        button.disabled = true;
        try {
          const url = new URL(link.href, document.baseURI);
          if (url.origin !== location.origin) throw new Error('Script must be hosted on this site.');
          const response = await fetch(url);
          if (!response.ok) throw new Error(`Script unavailable (${response.status}).`);
          const script = await response.text();
          if (!script.startsWith('#requires -Version 7.0')) throw new Error('Response is not an execution script.');
          await navigator.clipboard.writeText(script);
          status.textContent = `${label} script copied. Review before executing.`;
        } catch (error) {
          status.textContent = `Could not copy ${label}. Open View ${label} Script to copy it manually. ${error.message}`;
        } finally { button.disabled = false; }
      });
      toolbar.append(button);
    }
    pre.classList.add('docfx-runnable');
    pre.append(toolbar);
  }
}
if (typeof document !== 'undefined') {
  const style = document.createElement('style');
  style.textContent = `.docfx-runnable{position:relative}.docfx-run-toolbar{display:flex;gap:.4rem;justify-content:flex-end;position:sticky;left:0;bottom:0;opacity:0}.docfx-runnable:hover .docfx-run-toolbar,.docfx-runnable:focus-within .docfx-run-toolbar{opacity:1}.docfx-run-copy{font:inherit;font-size:.8rem;color:var(--bs-body-color);background:var(--bs-body-bg);border:1px solid var(--bs-border-color);border-radius:.25rem;padding:.25rem .5rem}.docfx-run-copy:focus-visible{outline:2px solid currentColor;outline-offset:2px}.docfx-run-actions{font-size:.85rem}.docfx-run-status{display:block}@media(hover:none){.docfx-run-toolbar{opacity:1}}`;
  document.head.append(style);
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => enhanceRunActions(), { once: true });
  else enhanceRunActions();
}
