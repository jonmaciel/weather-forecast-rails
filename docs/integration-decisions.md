# Integration decisions

Date: 2026-09-12. Status: address lookup, current and daily weather, 30-minute cache and HTML interface implemented.

## Scope

Support full street addresses and ZIP codes in the 50 US states and Washington, DC. This is
an application assumption based on the ZIP-code requirement, not an explicit
requirement from the brief. This restriction is displayed near the form.
Use Fahrenheit with an explicit unit label and the location's timezone.
International addresses are outside the supported scope. ZIP-only inputs accept
five digits or ZIP+4, retaining the existing `address` API parameter.

## Providers

### Manual address lookup: US Census Geocoder

Use `https://geocoding.geo.census.gov/geocoder/locations/onelineaddress` with
`address`, `benchmark=Public_AR_Current`, and `format=json`. The public endpoint
requires no API key. Extract the matched address, `addressComponents.zip`, and
coordinates (`x` is longitude; `y` is latitude).

The service requires a street address and estimates coordinates from address
ranges. It is not proof that an address exists or receives mail. Its coverage
also includes territories, but our initial scope is narrower. Reject missing
ZIPs, unsupported states, no matches, and ambiguous matches with actionable
messages; never silently select an arbitrary candidate.

Reject a confirmed street-direction conflict with `address_mismatch` (422), such
as `600 N Clark St` being returned as `600 S Clark St`. The guard compares an
explicit direction after the house number only when the remaining street name
matches Census's structured fields. It accepts equivalent abbreviations and
preserves street names such as `North Avenue`. This is a conservative check,
not complete address validation; missing optional fields do not imply a conflict.

Source: [Census API documentation](https://geocoding.geo.census.gov/geocoder/Geocoding_Services_API.html).

### Address suggestions: Photon

Use `https://photon.komoot.io/api/` for address suggestions, filtering for US house
locations. Offer up to five complete addresses with valid ZIPs and coordinates;
keep the house number, street, city and state in the label, and show ZIP separately.
This is geographic matching, not postal verification. A chosen address is carried
in a signed token and used directly, avoiding a second provider changing a street
direction or selecting another location. Manual submission still uses Census;
there is no automatic fallback between providers.

The public demo requires no key, permits reasonable usage, and may throttle or
change without notice. Debouncing and caching suit local evaluation; it has no
availability guarantee for production. Credit Photon and OpenStreetMap in the
footer, linking the OSM copyright page for attribution and the ODbL data license.

Sources: [Photon API and demo terms](https://github.com/komoot/photon),
[OpenStreetMap attribution](https://www.openstreetmap.org/copyright).

### ZIP lookup: Open-Meteo geocoding

Use `https://geocoding-api.open-meteo.com/v1/search` with the normalized ZIP,
`countryCode=US`, `count=100`, `language=en` and `format=json`. Require the exact
ZIP in the result's `postcodes` and country US. With no selection, reject no matches
and multiple matches instead of choosing an arbitrary location. For a selected
locality without a cached resolution, resolve its provider ID through
`/v1/get?id=...`, then verify the exact ID, country and ZIP membership. This avoids
depending on the search result limit when resolving a previously selected locality.
Validate label and coordinates in
both paths. Coordinates represent the associated locality, not the precise ZIP
centroid. Coverage is provider-dependent; users can select a suggestion or try a
full address if a plain ZIP is ambiguous. GeoNames attribution is shown.

Source: [Geocoding API](https://open-meteo.com/en/docs/geocoding-api).

### Weather: Open-Meteo

Use `https://api.open-meteo.com/v1/forecast` with the resolved latitude/longitude,
`current=temperature_2m`, `daily=temperature_2m_max,temperature_2m_min`,
`forecast_days=1`, `temperature_unit=fahrenheit`, and `timezone=auto`.
Keep the returned timestamp and unit alongside the temperature. Current values
are model-derived conditions; do not describe them as direct station readings.
Current conditions and daily maximum/minimum share one HTTP request and the same
30-minute cache. Validate numeric bounds, units and the local daily date; display
that explicit date even when a cached forecast crosses midnight. The cache schema
is versioned to avoid reading older payloads without daily data.

The free endpoint needs no key for non-commercial use, allows 10,000 calls/day,
and has no uptime guarantee. This choice assumes a non-commercial local demo.
Commercial use requires a suitable subscription and customer endpoint. Provide
visible Open-Meteo attribution in the results UI, consistent with its
CC BY 4.0 data license.

Sources: [Weather API](https://open-meteo.com/en/docs),
[pricing and usage](https://open-meteo.com/en/pricing).

## Alternatives considered

- Open-Meteo geocoding alone does not cover full street addresses. It is now
  selected for ZIP-only input, with Census retained for manual street submission.
  [Documentation](https://open-meteo.com/en/docs/geocoding-api).
- Public Nominatim: broader coverage, but its public service has a strict
  one-request-per-second limit and requires an identifying User-Agent and
  attribution. Census handles manual addresses; Photon adds optional suggestions.
  [Usage policy](https://operations.osmfoundation.org/policies/nominatim/).

## Application contract

Provider clients normalize external payloads into symbol-keyed hashes. The
forecast service coordinates them; controllers handle form metadata and HTTP
responses.

| Method | Successful result |
| --- | --- |
| `CensusClient#lookup(address)` | A location with `address`, `country`, `postal_code`, `latitude`, `longitude` |
| `ZipCodeClient#lookup(zip, location_id: nil)` | The same location fields, plus `display_name` |
| `ZipCodeClient#suggestions(prefix)` | Up to five hashes with string `zip`, `label`, `location_id`; IDs are positive decimal strings up to `2147483647` |
| `OpenMeteoClient#forecast(latitude:, longitude:)` | `current` and `daily` hashes |
| `PhotonClient#suggestions(query)` | Up to five normalized US address locations |
| `AddressSuggestions#call(address)` | Suggestions with string `label`, `zip`, and signed `token` |
| `AddressSuggestions#resolve(token, address:)` | The signed location when its token and exact address label are valid |
| `Forecast#call(address:, location_id: nil, address_token: nil)` | `location`, `current`, `daily`, and boolean `from_cache` |

Locations have a five-digit string ZIP, country `US`, nonempty labels and finite
coordinates within latitude/longitude bounds. `current` contains a finite
`temperature`, `unit` (`°F`), ISO local `time`, `timezone`, `source` and `source_url`.
`daily` contains the matching local `date`, finite `high` and `low` (`high >= low`),
and `unit`. The service accepts a ZIP or street address; selection metadata supplies
the location without parsing a locality label.

The form carries `selected_zip`/`selected_location_id` or `selected_address_token`,
plus a `selected_label` snapshot. Editing clears all metadata. The controller
forwards a selection only for an unchanged label. For ZIP selections, malformed
IDs are rejected before reading the one-hour location cache. On a cache miss, the
ZIP client validates the ID, country and ZIP with the provider; successful
resolutions are reused until expiry or eviction.
Street tokens use Rails' message verifier with purpose `address_selection` and
one-hour expiration; verification also compares the signed address with the input.
They contain only normalized location data and provide integrity, not encryption.

Expected failures raise `Weather::Error` with `code`, message and HTTP `status`.
All JSON endpoints expose `{ "error": { "code": "...", "message": "..." } }`.
Invalid input, unresolved/ambiguous locations and `invalid_zip_selection` return
422; the last covers malformed/unknown IDs or a selected locality outside the
submitted ZIP/country. Invalid suggestion prefixes use `invalid_zip_prefix`.
Street queries outside 6–300 characters or without a letter return
`invalid_address_query` (422); invalid, forged or expired street selections return
`invalid_address_selection` (422), without falling back to Census.
Malformed provider payloads, HTTP responses and compressed bodies use
`invalid_provider_response` (502), other provider
failures return 502, rate limits 503, and timeouts 504. The HTTP adapter retains
the upstream status internally as `provider_status`: the ZIP client translates
`/get` HTTP 400 for an unknown ID into `invalid_zip_selection`, while outages and
rate limits keep their original provider errors. This internal status is not
included in the public JSON envelope.

HTTP requests use fixed HTTPS endpoints, encoded query parameters, verified TLS,
a 3-second connection timeout and 10-second read/write timeouts, without retries.
Tests stub HTTP calls and do not need external API access.

Normalize ZIPs as five-character strings, preserving leading zeros and reducing
ZIP+4 to its first five digits. Cache successful weather payloads for 30 minutes
under a versioned key containing provider, country, ZIP and unit. Different
addresses in the same ZIP reuse the first successful forecast in that window;
this is a deliberate area-level approximation even when locations within that
ZIP have different coordinates. Keep the current matched location outside that
shared payload. `LocationResolver` validates inputs and resolves locations before
the weather cache is checked. Successful Census and ZIP resolutions use separate
`location/v1` entries for one hour, without sliding renewal. Manual-address keys
include the provider and a SHA-256 digest of the trimmed, collapsed-whitespace,
lowercase input; number, direction, city, state and ZIP remain part of that identity.
ZIP keys include the provider, five-digit ZIP and either the selected locality ID
or a distinct search marker. Malformed IDs are rejected before a cache read;
provider validation binds a selected ID to its ZIP before the result is stored.
Only successful resolutions are cached, never ambiguous, missing or invalid matches.
This trusts validated geographic data for one hour and lets known inputs survive a
geocoder outage; unknown, expired or evicted inputs still depend on the provider.
Signed street tokens bypass this cache and are verified on every request, including
their expiry and exact display label. No token check is skipped for cached weather.
Do not cache errors; derive the cache indicator separately for each request.
The weather cache remains schema `v2`; ZIP suggestion entries use `v2` and are
cached by prefix for one hour. Address suggestions use a separate `v1` cache,
keyed by trimmed, collapsed-whitespace, lowercase query, with the same TTL.
Only normalized locations are cached, including empty lists. Each response signs
fresh one-hour tokens, so a selected snapshot can be almost two hours old; this
is an accepted geographic-data approximation for the demo, independent of the
30-minute weather TTL.

Rails.cache uses process-local memory. Restarting loses entries and multiple
processes do not share them. A shared `RequestCoalescer` coordinates weather calls
by cache instance and forecast key within one process. The leader checks the cache
inside the coordinated operation, preventing duplicate cold or expired refreshes;
unrelated keys run concurrently. Callers already waiting share the value or error.
Waiting has a monotonic 15-second deadline and does not cancel the leader; completed
entries are removed so failures remain retryable. The weather provider's existing
network timeouts still apply to the leader. Geocoding misses are not coalesced.
The request that fetches weather reports `from_cache: false`; reuse by a waiting
caller reports `true`, with each request retaining its own location metadata.
Reads do not renew the 30-minute TTL and expired weather is never served. In
particular, `race_condition_ttl` is not used because it permits stale responses and
does not coordinate a first cold miss. No database is needed. Shared caching and
coordination across processes remain a deployment decision.

Use POST with Rails CSRF protection for street suggestions and forecasts, keeping
addresses out of application URLs. Filter addresses, labels and tokens from logs.
Send address text only to the relevant geocoder and coordinates to the weather
API. Queries and suggestion locations remain in process memory for their TTL;
searches are not stored in a database.

## Verification performed

A live smoke check on 2026-09-12 resolved the Census documentation's public
example address (4600 Silver Hill Rd, Washington, DC 20233), returned ZIP 20233
and coordinates, and retrieved a numeric current temperature in Fahrenheit from
Open-Meteo using those coordinates. Integration and browser tests also cover provider failures, invalid inputs and payloads,
cache reuse between addresses, ZIP isolation, expiration at 30 minutes without
sliding renewal, and recovery after errors. Broader address coverage is not
guaranteed by the live example.

Combined regressions exercise all input paths against one ZIP cache, failed
refreshes followed by recovery, and expired or tampered selections while weather
is still cached. Browser regressions verify that retries preserve the chosen
address and that an expired selection can be replaced. Request-integrity tests
enable Rails CSRF protection explicitly and restore the test configuration after
each case. Transport tests cover connection, TLS, timeout, malformed HTTP and
decompression failures without real provider calls.

Location-cache regressions verify reuse during geocoder outages, normalization,
fixed one-hour expiry, ZIP/locality isolation and rejection of invalid selections
with warm caches. Threaded tests use queues and bounded joins to verify overlapping
calls across separate service instances: one weather request for a cold or exactly
expired ZIP, independent work for other ZIPs/cache stores, shared failures and
recovery. Coalescer tests also cover waiter timeouts and leader termination cleanup.

Browser tests use Capybara's native Chrome visibility option. ChromeDriver can also
report a detached node during text retrieval as an unknown inspector error. A
test-only adapter translates that specific error into a stale-element error so
Capybara's existing bounded synchronization can re-query the element. Other driver
errors propagate unchanged. The tests use no fixed sleeps or whole-test retries.
