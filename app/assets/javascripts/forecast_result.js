const forecastResult = document.querySelector('.forecast-panel:not(.is-empty)');

if (forecastResult && window.matchMedia('(max-width: 760px)').matches) {
  forecastResult.setAttribute('tabindex', '-1');
  forecastResult.focus({ preventScroll: true });
  forecastResult.scrollIntoView({ block: 'start' });
}
