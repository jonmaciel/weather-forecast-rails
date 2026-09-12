# Weather Forecast

A Ruby on Rails application for a weather forecast interface.

## Quick start with Docker

```sh
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
bin/rails zeitwerk:check
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
```

## Current scope

The initial setup includes a Rails application, a home page rendered with ERB,
plain CSS and the standard Rails quality tools and CI. Active Record is disabled.
Address lookup and current weather retrieval are available through `POST /forecasts`.
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
Washington, DC and returns Fahrenheit. Street addresses use Census; ZIP-only
queries use Open-Meteo geocoding. Both paths use Open-Meteo for current conditions. Network access is required for live requests only.

`POST /forecasts` accepts an `address` parameter and returns `location` and
`current` JSON objects plus a boolean `from_cache` indicator. The endpoint retains Rails CSRF protection. The HTML form includes the session's
CSRF token; JSON callers must also provide it. Use `Accept: application/json`
(or `/forecasts.json`) for JSON; HTML submissions render the results page.
Errors return `{ "error": { "code": "...", "message": "..." } }` with HTTP 422
for invalid or unresolved addresses, 502 for provider failures, 503 for provider
rate limits, and 504 for timeouts. HTTP responses remain `no-store` so browsers
do not retain address-specific results; the server caches only weather data.
Address parameters are filtered from logs.

Tests use WebMock and block external HTTP requests. The JSON gem is constrained
to version 2.x because Rails 8.1.3.1 passes positional parser options that JSON 3
no longer accepts. Ruby and Rails remain at the configured versions.

## Forecast cache

The first successful lookup for a ZIP returns `from_cache: false`. Subsequent
lookups for the same ZIP return `from_cache: true` for 30 minutes without calling
Open-Meteo again. Reads do not extend expiration. After expiration, the next
request retrieves fresh weather. Errors are never cached or replaced by expired
weather. The key includes a schema version, provider, country, ZIP and unit.

Each request resolves the input through Census (street address) or Open-Meteo
geocoding (ZIP). Inputs sharing a ZIP
reuse weather but retain their own matched address and coordinates in the result.
The ZIP is normalized to five digits, including leading zeros. This deliberately
approximates weather for the whole ZIP using the first successful lookup.

The in-memory cache is per process, may evict entries under memory pressure, and
is lost on restart. Run repeated requests against the same server to see cache
hits; separate `rails runner` invocations do not share a cache. Simultaneous cold
requests may both call the weather provider; request coalescing is not implemented.
The UI displays "Just fetched" on a miss and "From cache" on a hit.

## Browser workflow

Open http://localhost:3000, enter a US address or ZIP code and submit the form.
The result shows the matched location, temperature in Fahrenheit, conditions time
and timezone. Submit again to see the cache indicator. Invalid addresses and
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
US location's postal-code list. Unknown ZIPs and ambiguous results ask the user
to correct the ZIP or supply a full address. This provider returns locality
coordinates, not a precise ZIP centroid; forecasts are approximate for the area.
Some ZIPs may be absent from its dataset. Street and ZIP searches share the same
30-minute weather cache. Location attribution includes GeoNames.

## ZIP locality suggestions

With JavaScript enabled, entering five ZIP digits (or ZIP+4) displays a selectable
city/state suggestion after a short delay. Selecting it submits the weather form;
manual submission and full street addresses still work without JavaScript.
Suggestions are ZIP lookups, not street-address autocomplete. The endpoint
`GET /zip-lookup?zip=02108` accepts only five digits, caches successful locality
lookups for one hour and never fetches weather. Failures leave manual search usable.
ZIP results display city/state as the heading and ZIP separately below it.
