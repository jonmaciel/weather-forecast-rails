const input = document.querySelector('[data-zip-lookup-url]');
const panel = document.querySelector('#zip-suggestion');
const status = document.querySelector('#zip-status');
const selection = document.querySelector('#zip-selection');

if (input && panel && status && selection) {
  let timer;
  let request;
  let generation = 0;
  let suggestion;
  let selected;
  let composing = false;

  input.setAttribute('role', 'combobox');
  input.setAttribute('aria-autocomplete', 'list');
  input.setAttribute('aria-controls', panel.id);
  input.setAttribute('aria-expanded', 'false');
  panel.setAttribute('role', 'listbox');
  panel.setAttribute('aria-label', 'ZIP locations');

  const close = () => {
    clearTimeout(timer);
    request?.abort();
    generation += 1;
    suggestion = undefined;
    panel.replaceChildren();
    panel.hidden = true;
    input.setAttribute('aria-expanded', 'false');
    input.removeAttribute('aria-activedescendant');
    input.removeAttribute('aria-busy');
  };

  const accept = () => {
    if (!suggestion) return;
    selected = suggestion;
    close();
    const label = document.createElement('span');
    label.textContent = `${selected.label} · ZIP ${selected.zip}`;
    selection.replaceChildren(label);
    selection.hidden = false;
    status.textContent = 'Location selected. You can edit the ZIP or check the weather.';
  };

  const lookup = () => {
    close();
    selected = undefined;
    selection.replaceChildren();
    selection.hidden = true;
    status.textContent = '';
    const value = input.value.trim();
    if (composing || !/^\d{5}(?:-\d{4})?$/.test(value)) return;
    const version = generation;
    const zip = value.slice(0, 5);
    timer = setTimeout(async () => {
      const controller = new AbortController();
      request = controller;
      const timeout = setTimeout(() => controller.abort(), 12000);
      input.setAttribute('aria-busy', 'true');
      status.textContent = 'Looking up this ZIP…';
      try {
        const url = new URL(input.dataset.zipLookupUrl, window.location.origin);
        url.searchParams.set('zip', zip);
        const response = await fetch(url, { signal: controller.signal, headers: { Accept: 'application/json' } });
        const result = await response.json();
        if (version !== generation) return;
        if (!response.ok) {
          status.textContent = result.error || 'Preview unavailable. You can still submit your search.';
          return;
        }
        if (result.zip !== zip || typeof result.label !== 'string') throw new Error('Invalid suggestion');
        suggestion = result;
        const option = document.createElement('div');
        option.id = 'zip-location-option';
        option.className = 'zip-option';
        option.setAttribute('role', 'option');
        option.setAttribute('aria-selected', 'false');
        option.textContent = `${result.label} · ZIP ${result.zip}`;
        option.addEventListener('mousedown', (event) => event.preventDefault());
        option.addEventListener('click', () => { accept(); input.focus(); });
        panel.append(option);
        panel.hidden = false;
        input.setAttribute('aria-expanded', 'true');
        status.textContent = 'Enter or Tab to select. Right arrow at the end also selects. Esc dismisses.';
      } catch {
        if (version === generation) status.textContent = 'Preview unavailable. You can still submit your search.';
      } finally {
        clearTimeout(timeout);
        if (version === generation) input.removeAttribute('aria-busy');
      }
    }, 300);
  };

  input.addEventListener('input', lookup);
  input.addEventListener('compositionstart', () => { composing = true; close(); });
  input.addEventListener('compositionend', () => { composing = false; lookup(); });
  input.addEventListener('focus', () => { if (!selected) lookup(); });
  input.addEventListener('blur', () => { close(); if (!selected) status.textContent = ''; });
  input.form.addEventListener('submit', close);
  input.addEventListener('keydown', (event) => {
    if (event.isComposing || composing || event.ctrlKey || event.metaKey || event.altKey) return;
    if (event.key === 'Escape') {
      close();
      status.textContent = selected ? 'Location selected. You can still edit the ZIP.' : '';
      return;
    }
    if (!suggestion) {
      if (event.key === 'ArrowDown' && !selected) { event.preventDefault(); lookup(); }
      return;
    }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      const option = panel.firstElementChild;
      option.setAttribute('aria-selected', 'true');
      input.setAttribute('aria-activedescendant', option.id);
    } else if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      accept();
    } else if (event.key === 'Tab' && !event.shiftKey) {
      // Accept without cancelling the browser's normal forward focus navigation.
      accept();
    } else if (event.key === 'ArrowRight' && !event.shiftKey &&
      input.selectionStart === input.value.length && input.selectionEnd === input.value.length) {
      event.preventDefault();
      accept();
    }
  });
}
