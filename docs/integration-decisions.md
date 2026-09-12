# Integration decisions

Date: 2026-09-12. Status: address lookup, current weather, 30-minute cache and HTML interface implemented.

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
ZIP in the result's `postcodes` and country US. Reject no matches and multiple
matches instead of choosing an arbitrary location. Coordinates represent the
associated locality, not the precise ZIP centroid. Coverage is provider-dependent;
users can try a full address if ZIP lookup fails. GeoNames attribution is shown.

Source: [Geocoding API](https://open-meteo.com/en/docs/geocoding-api).

### Weather: Open-Meteo

Use `https://api.open-meteo.com/v1/forecast` with the resolved latitude/longitude,
`current=temperature_2m`, `temperature_unit=fahrenheit`, and `timezone=auto`.
Keep the returned timestamp and unit alongside the temperature. Current values
are model-derived conditions; do not describe them as direct station readings.
Daily maximum/minimum can be added later.

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

Keep small provider clients separate from a forecast service and controller.
Use Ruby's Net::HTTP with fixed HTTPS endpoints, encoded query parameters,
verified TLS, a 3-second connection timeout and a 10-second read timeout.
Do not retry during the initial synchronous request. Translate timeouts, rate
limits, non-success responses and malformed payloads into controlled errors.
Tests stub HTTP calls and do not need internet access.

Normalize ZIPs as five-character strings, preserving leading zeros and reducing
ZIP+4 to its first five digits. Cache successful weather payloads for 30 minutes
under a versioned key containing provider, country, ZIP and unit. Different
addresses in the same ZIP reuse the first successful forecast in that window;
this is a deliberate area-level approximation. Keep the current matched address
outside that shared payload. The appropriate geocoder still runs before the weather-cache lookup.
Do not cache errors; derive the cache indicator separately for each request.

Rails.cache uses process-local memory for local development. Restarting loses
entries; multiple processes do not share them. No database is needed. A shared
cache can replace this store if the deployment requirements change.

Filter the address parameter from Rails logs. Send the full address only
to the geocoder, and only coordinates to the weather API. Do not persist searches.

## Verification performed

A live smoke check on 2026-09-12 resolved the Census documentation's public
example address (4600 Silver Hill Rd, Washington, DC 20233), returned ZIP 20233
and coordinates, and retrieved a numeric current temperature in Fahrenheit from
Open-Meteo using those coordinates. Automated tests also cover provider failures, invalid inputs and payloads,
cache reuse between addresses, ZIP isolation, expiration at 30 minutes without
sliding renewal, and recovery after errors. Broader address coverage is not
guaranteed by the live example.
