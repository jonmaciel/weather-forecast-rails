const input = document.querySelector('[data-zip-lookup-url]');
const panel = document.querySelector('#zip-suggestion');
const status = document.querySelector('#zip-status');
const selectedZip = document.querySelector('#selected_zip');
const selectedLabel = document.querySelector('#selected_label');
const selectedLocationId = document.querySelector('#selected_location_id');

if (input && panel && status && selectedZip && selectedLabel && selectedLocationId) {
  let timer;
  let request;
  let generation = 0;
  let suggestions = [];
  let activeIndex = -1;
  let selected = selectedZip.value && selectedLabel.value === input.value;
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
    suggestions = [];
    activeIndex = -1;
    panel.replaceChildren();
    panel.hidden = true;
    input.setAttribute('aria-expanded', 'false');
    input.removeAttribute('aria-activedescendant');
    input.removeAttribute('aria-busy');
  };

  const accept = () => {
    if (!suggestions.length) return;
    selected = suggestions[Math.max(activeIndex, 0)];
    const zip = /^\d{5}-\d{4}$/.test(input.value.trim()) ? input.value.trim() : selected.zip;
    input.value = `${selected.label} ${zip}`;
    selectedZip.value = zip;
    selectedLabel.value = input.value;
    selectedLocationId.value = selected.location_id;
    close();
    status.textContent = 'City and ZIP selected. You can edit this field or check the weather.';
  };

  const lookup = () => {
    close();
    selected = undefined;
    selectedZip.value = '';
    selectedLabel.value = '';
    selectedLocationId.value = '';
    status.textContent = '';
    const value = input.value.trim();
    if (composing || !/^(?:\d{3,5}|\d{5}-\d{4})$/.test(value)) return;
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
          status.textContent = result.error?.message || 'Preview unavailable. You can still submit your search.';
          return;
        }
        if (!Array.isArray(result.suggestions) || result.suggestions.some(item =>
          typeof item.zip !== 'string' || !/^\d{5}$/.test(item.zip) || !item.zip.startsWith(zip) ||
          typeof item.location_id !== 'string' || !/^[1-9]\d*$/.test(item.location_id) ||
          typeof item.label !== 'string')) throw new Error('Invalid suggestions');
        suggestions = result.suggestions.slice(0, 5);
        if (!suggestions.length) {
          status.textContent = 'No matching ZIPs found. Keep typing or enter a full address.';
          return;
        }
        suggestions.forEach((item, index) => {
          const option = document.createElement('div');
          option.id = `zip-location-option-${index}`;
          option.className = 'zip-option';
          option.setAttribute('role', 'option');
          option.setAttribute('aria-selected', 'false');
          const label = document.createElement('span');
          label.className = 'zip-option-label';
          label.textContent = item.label;
          const code = document.createElement('span');
          code.className = 'zip-option-code';
          code.textContent = `ZIP ${item.zip}`;
          option.append(label, code);
          option.addEventListener('mousedown', (event) => event.preventDefault());
          option.addEventListener('click', () => { activeIndex = index; accept(); input.focus(); });
          panel.append(option);
        });
        panel.hidden = false;
        input.setAttribute('aria-expanded', 'true');
        status.textContent = '↑ ↓ to browse · Enter or Tab to select · Esc to close';
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
      status.textContent = selected ? 'City and ZIP selected. You can still edit this field.' : '';
      return;
    }
    if (!suggestions.length) {
      if (event.key === 'ArrowDown' && !selected) { event.preventDefault(); lookup(); }
      return;
    }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      activeIndex = activeIndex < 0
        ? (event.key === 'ArrowDown' ? 0 : suggestions.length - 1)
        : (activeIndex + (event.key === 'ArrowDown' ? 1 : -1) + suggestions.length) % suggestions.length;
      Array.from(panel.children).forEach((option, index) => {
        option.setAttribute('aria-selected', String(index === activeIndex));
        if (index === activeIndex) {
          input.setAttribute('aria-activedescendant', option.id);
          // Scroll only the list, keeping the page and input in place.
          if (option.offsetTop < panel.scrollTop) panel.scrollTop = option.offsetTop;
          if (option.offsetTop + option.offsetHeight > panel.scrollTop + panel.clientHeight) {
            panel.scrollTop = option.offsetTop + option.offsetHeight - panel.clientHeight;
          }
        }
      });
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
