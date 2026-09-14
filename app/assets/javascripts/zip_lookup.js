const input = document.querySelector('[data-zip-lookup-url]');
const panel = document.querySelector('#zip-suggestion');
const list = document.querySelector('#zip-options');
const feedback = document.querySelector('#zip-feedback');
const feedbackMessage = document.querySelector('#zip-feedback-message');
const spinner = document.querySelector('.zip-spinner');
const status = document.querySelector('#zip-status');
const selectedZip = document.querySelector('#selected_zip');
const selectedLabel = document.querySelector('#selected_label');
const selectedLocationId = document.querySelector('#selected_location_id');
const selectedAddressToken = document.querySelector('#selected_address_token');

if (input && panel && list && feedback && feedbackMessage && spinner && status && selectedZip && selectedLabel && selectedLocationId && selectedAddressToken) {
  let timer;
  let request;
  let generation = 0;
  let suggestions = [];
  let activeIndex = -1;
  let hasSelection = Boolean(selectedZip.value || selectedAddressToken.value) && selectedLabel.value === input.value;
  let composing = false;

  input.setAttribute('role', 'combobox');
  input.setAttribute('aria-autocomplete', 'list');
  input.setAttribute('aria-controls', list.id);
  input.setAttribute('aria-expanded', 'false');
  list.setAttribute('role', 'listbox');
  list.setAttribute('aria-label', 'Address and ZIP suggestions');

  const cancelLookup = () => {
    clearTimeout(timer);
    request?.abort();
    request = undefined;
    generation += 1;
    suggestions = [];
    activeIndex = -1;
    input.removeAttribute('aria-activedescendant');
    input.removeAttribute('aria-busy');
    list.removeAttribute('aria-busy');
  };

  const close = () => {
    cancelLookup();
    list.replaceChildren();
    panel.hidden = true;
    panel.style.minHeight = '';
    input.setAttribute('aria-expanded', 'false');
    status.textContent = '';
  };

  const announce = (message) => {
    if (status.textContent !== message) status.textContent = message;
  };

  const showFeedback = (message, loading = false) => {
    // Keep the previous list height while its replacement is loading.
    panel.style.minHeight = loading && !panel.hidden ? `${panel.getBoundingClientRect().height}px` : '';
    list.replaceChildren();
    feedback.hidden = false;
    feedback.classList.remove('is-hint');
    spinner.hidden = !loading;
    feedbackMessage.textContent = message;
    panel.scrollTop = 0;
    panel.hidden = false;
    input.setAttribute('aria-expanded', 'true');
    if (loading) {
      input.setAttribute('aria-busy', 'true');
      list.setAttribute('aria-busy', 'true');
    } else {
      announce(message);
    }
  };

  const accept = () => {
    if (!suggestions.length) return;
    const suggestion = suggestions[Math.max(activeIndex, 0)];
    if (suggestion.token) {
      input.value = suggestion.label;
      selectedAddressToken.value = suggestion.token;
    } else {
      const zip = /^\d{5}-\d{4}$/.test(input.value.trim()) ? input.value.trim() : suggestion.zip;
      input.value = `${suggestion.label} ${zip}`;
      selectedZip.value = zip;
      selectedLocationId.value = suggestion.location_id;
    }
    hasSelection = true;
    selectedLabel.value = input.value;
    close();
    announce('Location selected. You can edit this field or check the weather.');
  };

  const fetchSuggestions = async (value, isZip, signal) => {
    const zip = value.slice(0, 5);
    const url = new URL(isZip ? input.dataset.zipLookupUrl : input.dataset.addressLookupUrl, window.location.origin);
    const options = { signal, headers: { Accept: 'application/json' } };
    if (isZip) {
      url.searchParams.set('zip', zip);
    } else {
      options.method = 'POST';
      options.headers['Content-Type'] = 'application/json';
      options.headers['X-CSRF-Token'] = document.querySelector('meta[name="csrf-token"]')?.content || '';
      options.body = JSON.stringify({ address: value });
    }
    const response = await fetch(url, options);
    if (!response.ok) throw new Error('Suggestions unavailable');
    const result = await response.json();
    if (!Array.isArray(result.suggestions) || result.suggestions.some(item =>
      !item || typeof item.zip !== 'string' || !/^\d{5}$/.test(item.zip) ||
      typeof item.label !== 'string' || !item.label.trim() ||
      (isZip ? (!item.zip.startsWith(zip) || typeof item.location_id !== 'string' || !/^[1-9]\d*$/.test(item.location_id))
        : (typeof item.token !== 'string' || !item.token)))) throw new Error('Invalid suggestions');
    return result.suggestions.slice(0, 5);
  };

  const renderSuggestions = () => {
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
      list.append(option);
    });
    panel.style.minHeight = '';
    spinner.hidden = true;
    feedback.classList.add('is-hint');
    feedbackMessage.textContent = '↑ ↓ to browse · Enter or Tab to select · Esc to close';
    announce(`${suggestions.length} ${suggestions.length === 1 ? 'suggestion' : 'suggestions'} available. Use the arrow keys to browse.`);
  };

  const lookup = () => {
    cancelLookup();
    hasSelection = false;
    selectedZip.value = '';
    selectedLabel.value = '';
    selectedLocationId.value = '';
    selectedAddressToken.value = '';
    const value = input.value.trim();
    const isZip = /^(?:\d{3,5}|\d{5}-\d{4})$/.test(value);
    if (composing || (!isZip && (value.length < 6 || value.length > 300 || !/[a-z]/i.test(value)))) {
      close();
      announce('');
      return;
    }
    showFeedback('Searching for locations…', true);
    const version = generation;
    timer = setTimeout(async () => {
      const controller = new AbortController();
      request = controller;
      const timeout = setTimeout(() => controller.abort(), 12000);
      announce('Searching for locations…');
      try {
        const results = await fetchSuggestions(value, isZip, controller.signal);
        if (version !== generation) return;
        suggestions = results;
        if (!suggestions.length) {
          showFeedback(isZip ? 'No matching ZIPs found. Keep typing or enter a full address.'
            : 'No matching addresses found. Add a city and state, or try a ZIP code.');
          return;
        }
        renderSuggestions();
      } catch {
        if (version === generation) showFeedback('Suggestions unavailable. Press Enter to search without a suggestion.');
      } finally {
        clearTimeout(timeout);
        if (version === generation) {
          input.removeAttribute('aria-busy');
          list.removeAttribute('aria-busy');
        }
      }
    }, 300);
  };

  input.addEventListener('input', lookup);
  input.addEventListener('compositionstart', () => { composing = true; close(); });
  input.addEventListener('compositionend', () => { composing = false; lookup(); });
  // Restored focus and error autofocus should not reopen suggestions.
  input.addEventListener('click', () => { if (!hasSelection && panel.hidden) lookup(); });
  input.addEventListener('blur', close);
  input.form.addEventListener('submit', close);
  input.addEventListener('keydown', (event) => {
    if (event.isComposing || composing || event.ctrlKey || event.metaKey || event.altKey) return;
    if (event.key === 'Escape') {
      close();
      announce(hasSelection ? 'Location selected. You can still edit this field.' : 'Suggestions closed.');
      return;
    }
    if (!suggestions.length) {
      if (event.key === 'ArrowDown' && !hasSelection && panel.hidden) { event.preventDefault(); lookup(); }
      return;
    }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      activeIndex = activeIndex < 0
        ? (event.key === 'ArrowDown' ? 0 : suggestions.length - 1)
        : (activeIndex + (event.key === 'ArrowDown' ? 1 : -1) + suggestions.length) % suggestions.length;
      Array.from(list.children).forEach((option, index) => {
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
