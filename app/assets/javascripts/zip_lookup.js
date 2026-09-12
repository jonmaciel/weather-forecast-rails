const input = document.querySelector('[data-zip-lookup-url]');
const panel = document.querySelector('#zip-suggestion');
const status = document.querySelector('#zip-status');

if (input && panel && status) {
  let timer;
  let request;
  let generation = 0;

  const reset = () => {
    clearTimeout(timer);
    request?.abort();
    generation += 1;
    panel.replaceChildren();
    panel.hidden = true;
    status.textContent = '';
  };

  input.addEventListener('input', () => {
    reset();
    const value = input.value.trim();
    if (!/^\d{5}(?:-\d{4})?$/.test(value)) return;
    const version = generation;
    const zip = value.slice(0, 5);
    timer = setTimeout(async () => {
      const controller = new AbortController();
      request = controller;
      const timeout = setTimeout(() => controller.abort(), 12000);
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
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'zip-option';
        button.textContent = `${result.label} · ZIP ${result.zip}`;
        button.addEventListener('click', () => input.form.requestSubmit());
        panel.append(button);
        panel.hidden = false;
        status.textContent = 'Location found. Select it to view the weather, or use the search button.';
      } catch {
        if (version === generation) status.textContent = 'Preview unavailable. You can still submit your search.';
      } finally {
        clearTimeout(timeout);
      }
    }, 350);
  });

  input.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') reset();
    if (event.key === 'ArrowDown' && !panel.hidden) {
      event.preventDefault();
      panel.querySelector('button')?.focus();
    }
  });
  panel.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') { reset(); input.focus(); }
    if (event.key === 'ArrowUp') { event.preventDefault(); input.focus(); }
  });
}
