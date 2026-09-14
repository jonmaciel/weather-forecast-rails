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

### Address lookup: US Census Geocoder

Use `https://geocoding.geo.census.gov/geocoder/locations/onelineaddress` with
`address`, `benchmark=Public_AR_Current`, and `format=json`. The public endpoint
requires no API key. Extract the matched address, `addressComponents.zip`, and
coordinates (`x` is longitude; `y` is latitude).

The service requires a street address and estimates coordinates from address
ranges. It is not proof that an address exists or receives mail. Its coverage
also includes territories, but our initial scope is narrower. Reject missing
ZIPs, unsupported states, no matches, and ambiguous matches with actionable
messages; never silently select an arbitrary candidate.

Source: [Census API documentation](https://geocoding.geo.census.gov/geocoder/Geocoding_Services_API.html).

### ZIP lookup: Open-Meteo geocoding

Use `https://geocoding-api.open-meteo.com/v1/search` with the normalized ZIP,
`countryCode=US`, `count=100`, `language=en` and `format=json`. Require the exact
ZIP in the result's `postcodes` and country US. With no selection, reject no matches
and multiple matches instead of choosing an arbitrary location. For a selected
locality, resolve its provider ID through `/v1/get?id=...`, then verify the exact
ID, country and ZIP membership. This avoids depending on the search result limit
when resolving a previously selected locality. Validate label and coordinates in
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
  selected for ZIP-only input, with Census retained for street addresses.
  [Documentation](https://open-meteo.com/en/docs/geocoding-api).
- Public Nominatim: broader coverage, but its public service has a strict
  one-request-per-second limit and requires an identifying User-Agent and
  attribution. Census keeps this US-only demo simpler.
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
| `Forecast#call(address:, location_id: nil)` | `location`, `current`, `daily`, and boolean `from_cache` |

Locations have a five-digit string ZIP, country `US`, nonempty labels and finite
coordinates within latitude/longitude bounds. `current` contains a finite
`temperature`, `unit` (`°F`), ISO local `time`, `timezone`, `source` and `source_url`.
`daily` contains the matching local `date`, finite `high` and `low` (`high >= low`),
and `unit`. The service accepts a ZIP or street address, never a presentation label.

The form carries `selected_zip`, `selected_location_id` and a `selected_label`
snapshot. Editing clears all three. The controller forwards selection metadata
only for an unchanged label; the ZIP client independently revalidates the ID and
ZIP with the provider. It rejects malformed IDs before making a network request.
The ID range follows the provider's signed 32-bit parameter.

Expected failures raise `Weather::Error` with `code`, message and HTTP `status`.
Both JSON endpoints expose `{ "error": { "code": "...", "message": "..." } }`.
Invalid input, unresolved/ambiguous locations and `invalid_zip_selection` return
422; the last covers malformed/unknown IDs or a selected locality outside the
submitted ZIP/country. Invalid suggestion prefixes use `invalid_zip_prefix`.
Malformed provider payloads use `invalid_provider_response` (502), other provider
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
shared payload. The appropriate geocoder runs before the weather-cache lookup
to resolve each input and revalidate selected IDs. Consequently, a geocoder
failure still prevents a response even if that ZIP's weather is cached.
Do not cache errors; derive the cache indicator separately for each request.
The weather cache remains schema `v2`; suggestion entries use `v2` to include IDs.
Suggestion lists, including empty results, are cached by prefix for one hour.

Rails.cache uses process-local memory. Restarting loses entries and multiple
processes do not share them. Concurrent misses may each request fresh weather;
there is no lock or request coalescing, and each reports `from_cache: false`.
Reads do not renew the 30-minute TTL. No database is needed. Shared caching and
request coalescing are deferred until deployment or traffic requires them.

Filter the address parameter from Rails logs. Send the full address only
to the geocoder, and only coordinates to the weather API. Do not persist searches.

## Verification performed

A live smoke check on 2026-09-12 resolved the Census documentation's public
example address (4600 Silver Hill Rd, Washington, DC 20233), returned ZIP 20233
and coordinates, and retrieved a numeric current temperature in Fahrenheit from
Open-Meteo using those coordinates. Integration and browser tests also cover provider failures, invalid inputs and payloads,
cache reuse between addresses, ZIP isolation, expiration at 30 minutes without
sliding renewal, and recovery after errors. Broader address coverage is not
guaranteed by the live example.
