# Weather Forecast

A Ruby on Rails weather app with address/ZIP lookup, current temperature, daily
high/low, and a 30-minute forecast cache by ZIP.

## Quick start with Docker

```sh
git clone https://github.com/jonmaciel/weather-forecast.git
cd weather-forecast
docker compose up --build --wait
```

Open http://localhost:3001. No local Ruby installation is needed.
For portable CI run `bin/docker-ci`. See [Docker and deployment](docs/docker.md)
for production builds, runtime secrets, health checks and deployment requirements.

## Requirements for running without Docker

- Ruby 4.0.6 (see `.ruby-version`)
- Rails 8.1.3.1 (installed through Bundler)
- A C compiler and development tools for native gems
- No database, Redis, or Node.js is required

On macOS, install Xcode Command Line Tools if needed (`xcode-select --install`).
With rbenv and an up-to-date ruby-build:

```sh
rbenv install -s 4.0.6
ruby --version
bin/setup --skip-server
bin/dev
```

Open http://localhost:3000. The `/up` endpoint reports application health.
Run all commands from the project directory. rbenv selects Ruby using `.ruby-version`.

## Verification

```sh
bin/rails test
bin/rails test:system
bin/rails zeitwerk:check
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
```

The browser suite uses Capybara/Selenium and Chrome or Chromium. On a host, install
Chrome; Selenium may download its matching driver on the first run. To avoid host
browser dependencies, run `bin/docker-ci`: its dedicated test image includes both
Chromium and ChromeDriver. Application runtime still needs no browser or Node.js.

## Current scope

The application uses ERB, plain CSS and a small JavaScript autocomplete,
with Rails quality tools and CI. Active Record is disabled.
Address lookup and current/daily weather retrieval are available through `POST /forecasts`.
Successful forecasts are cached by ZIP for 30 minutes. The responsive ERB
interface includes an address form, results, cache status and recoverable errors.
No API credentials are needed for the non-commercial demo.

Development uses the Rails in-memory cache. Entries are local to each process
and disappear when the server restarts. No Redis or Node.js installation is needed.

## Configuration and secrets

Do not commit API keys, `.env` files, or `config/master.key`.
Document provider-specific environment variables when an API is selected.

## Integration decisions

See [the integration decision](docs/integration-decisions.md) for provider choices,
supported addresses, units, failure handling, and cache behavior.

## Trying the forecast service

For a live request from the terminal:

```sh
bin/rails runner 'puts Weather::Forecast.new.call(address: "4600 Silver Hill Rd, Washington, DC 20233").to_json'
```

The service accepts full addresses or ZIP codes in the 50 US states and
Washington, DC and returns Fahrenheit. Manual street addresses use Census;
selected street suggestions use Photon data verified by the application, and ZIP
queries use Open-Meteo geocoding. All paths share one Open-Meteo weather request
for current conditions and daily high/low. Live provider requests need network access.

`POST /forecasts` accepts an `address` parameter and returns `location` and
`current` and `daily` JSON objects plus a boolean `from_cache` indicator. The endpoint retains Rails CSRF protection. The HTML form includes the session's
CSRF token; JSON callers must also provide it. Use `Accept: application/json`
(or `/forecasts.json`) for JSON; HTML submissions render the results page.
Errors return `{ "error": { "code": "...", "message": "..." } }` with HTTP 422
for invalid or unresolved addresses, 502 for provider failures, 503 for provider
rate limits, and 504 for timeouts. HTTP responses remain `no-store` so browsers
do not retain address-specific results. The forecast cache contains weather data;
suggestions have a separate short-lived in-memory cache. Address parameters,
selection tokens and the selected display label are filtered from logs.
Opening `GET /forecasts` redirects to the form (303) instead of returning a routing
error; weather queries continue to use POST so addresses stay out of URLs.

Tests use WebMock and block external HTTP requests. The JSON gem is constrained
to version 2.x because Rails 8.1.3.1 passes positional parser options that JSON 3
no longer accepts. Ruby and Rails remain at the configured versions.

## Forecast cache

The first successful lookup for a ZIP returns `from_cache: false`. Subsequent
lookups for the same ZIP return `from_cache: true` for 30 minutes without calling
Open-Meteo again. Reads do not extend expiration. After expiration, the next
request retrieves fresh weather. Errors are never cached or replaced by expired
weather. The key includes a schema version, provider, country, ZIP and unit.

Before reading the weather cache, manual addresses and ZIPs are resolved through
their geocoder; selected street addresses are verified locally using a signed,
expiring token. They keep the chosen Photon location instead of being matched
again by Census. A geocoder failure can still prevent a response for manual or
ZIP input even when weather is cached. Inputs
sharing a ZIP reuse weather from the first successful lookup in that window,
even when their resolved coordinates differ. This is a deliberate approximation
for the ZIP area. ZIPs are normalized to five digits, preserving leading zeros.

The in-memory cache is per process, may evict entries under memory pressure, and
is lost on restart. Run repeated requests against the same server to see cache
hits; separate `rails runner` invocations do not share a cache. Simultaneous cold
requests may both call the weather provider; request coalescing is not implemented.
The UI displays "Just fetched" on a miss and "From cache" on a hit.

## Browser workflow

Open http://localhost:3000, enter a US address or ZIP code and submit the form.
The result shows the matched location, temperature in Fahrenheit, daily high/low,
conditions time and timezone. The daily forecast has an explicit local date, so a
cached result near midnight is not misleadingly labeled “today”. Submit again to see the cache indicator. Invalid addresses and
provider failures preserve the input so it can be corrected or retried.

The page uses server-rendered ERB and CSS, supports form submission without JavaScript, and stacks
its panels on narrow screens. Labels, keyboard focus styling and associated
error messages support keyboard and assistive-technology use. Weather attribution
is shown in the footer. HTML and JSON flows are covered by the integration suite.

## ZIP-only search

Enter `20233`, `02108`, or ZIP+4 such as `02108-1234` in the same form. The JSON
endpoint also accepts these strings in its existing `address` parameter. Leading
zeros are significant; send ZIPs as strings, not JSON numbers. ZIP+4 is normalized
to five digits. Invalid numeric formats are rejected without a provider request.

ZIP lookup uses Open-Meteo geocoding and requires an exact match in the returned
US location's postal-code list. Unknown ZIPs ask the user to correct the ZIP or
supply a full address. If a ZIP matches several localities, select a suggestion
or enter a full address; the application never chooses one arbitrarily. This
provider returns locality coordinates, not a precise ZIP centroid; forecasts are approximate for the area.
Some ZIPs may be absent from its dataset. Street and ZIP searches share the same
30-minute weather cache. Location attribution includes GeoNames.

## Address and ZIP suggestions

With JavaScript enabled, suggestions start at three ZIP digits or six street
address characters containing a letter, after a 300 ms delay. Up to five options
appear in the same list attached to the input, without shifting the page. ZIP
selection fills a locality such as `Athens, Tennessee 37303`. Street selection
fills the house number, street, city and state; its ZIP is shown separately in
the option and forecast result. Selection never submits the weather form.
Edit the field directly to change either selection.

While typing, the popup stays open with a loading indicator inside it. It retains
its previous height while waiting, and outdated options cannot be selected.
Empty results and lookup failures appear in the same popup; Enter still submits
the typed text, and Escape or Tab dismisses the popup to reach the search button.
Loading and result counts are announced without moving focus. The spinner respects
reduced-motion preferences.

ZIP selection uses `selected_zip` and `selected_location_id`; street selection uses
`selected_address_token`. Both retain a `selected_label` snapshot, and editing
clears selection metadata. The server revalidates a selected ZIP with its provider
or verifies the street token and its exact address label. Tokens expire after one
hour and are signed, not encrypted. Invalid or expired selections return a
recoverable error. ZIP+4 is retained in the input and normalized for weather lookup.

Plain ZIPs, full street addresses and resubmitting a selection rendered by the
server work without JavaScript. Copying just the city/state label into a new
form does not carry its ZIP selection: enter the ZIP or a full street address.
A ZIP identifies a locality; selecting one does not supply a street or number.

Keyboard interaction: Down/Up navigate suggestions while focus stays in the input.
Enter confirms the highlighted option (or the first option); Tab confirms and
advances focus; Right confirms only at the end of the input with no selected text.
Escape dismisses the list. The search button (or Enter after selection) submits the
forecast request. Editing discards the current selection. Stale requests are
cancelled and ignored, and composition input is respected.

`GET /zip-lookup?zip=021` accepts three to five digits and returns a suggestions
array, for example:
`{ "suggestions": [{ "zip": "02108", "label": "Boston, Massachusetts", "location_id": "4930956" }] }`.
ZIPs and provider IDs are strings; IDs are positive integers up to `2147483647`,
matching the provider's signed 32-bit range. Results, including empty lists, are
cached by prefix for one hour; suggestions never fetch weather. Errors use the same
`{ "error": { "code": "...", "message": "..." } }` envelope as forecasts;
`invalid_zip_prefix` returns 422. Failures leave manual search usable. ZIP lookup
is not an exhaustive USPS directory and does not supply street addresses.

`POST /address-lookup` accepts an `address` body parameter of 6–300 characters,
including a letter, and returns suggestions containing `label`, `zip` and `token`.
It retains Rails CSRF protection and never requests weather. Only complete US
Photon candidates are offered; coverage is not a postal-validity guarantee.
Manual submission continues to use Census, without an automatic provider fallback.
Photon's public demo needs no key but has usage limits and no availability guarantee;
the footer credits Photon and OpenStreetMap. See the integration notes for caching
and token validation details.

The interaction draws on the editable selection in
[Google Places autocomplete](https://developers.google.com/maps/documentation/javascript/place-autocomplete-overview)
and the manual-entry fallback in the
[GOV.UK address pattern](https://design-system.service.gov.uk/patterns/addresses/).
Loading feedback draws on [MUI Autocomplete](https://mui.com/material-ui/api/autocomplete/)
and [W3C status messages](https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html),
with combobox semantics from [WAI-ARIA](https://www.w3.org/WAI/ARIA/apg/patterns/combobox/).
These are UX references; the app uses the providers described above.

## Delivery

See [submission notes](docs/submission.md) for the final review checklist and a
suggested walkthrough. The repository contains application code and documentation;
no external assignment documents are needed to run it.
