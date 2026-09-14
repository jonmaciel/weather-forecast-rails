require "test_helper"

class ForecastReliabilityTest < ActionDispatch::IntegrationTest
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @manual_address = "123 Main St, Boston, MA 02108"
    @zip_place = { id: 4930956, name: "Boston", admin1: "Massachusetts", country_code: "US",
      postcodes: [ "02108" ], latitude: 42.361, longitude: -71.061 }
    @selected_place = @zip_place.merge(id: 4930957, name: "Beacon Hill", latitude: 42.362, longitude: -71.062)
    @zip_selection = { address: "Beacon Hill, Massachusetts 02108", selected_label: "Beacon Hill, Massachusetts 02108",
      selected_zip: "02108", selected_location_id: "4930957" }
    @census = stub_request(:get, Weather::CensusClient::ENDPOINT).with(query: {
      address: @manual_address, benchmark: "Public_AR_Current", format: "json"
    }).to_return(body: { result: { addressMatches: [ {
      matchedAddress: "123 MAIN ST, BOSTON, MA, 02108", addressComponents: { state: "MA", zip: "02108-1234" },
      coordinates: { x: -71.06, y: 42.36 }
    } ] } }.to_json)
    @zip_lookup = stub_request(:get, Weather::ZipCodeClient::ENDPOINT).with(query: {
      name: "02108", countryCode: "US", count: "100", language: "en", format: "json"
    }).to_return(body: { results: [ @zip_place ] }.to_json)
    @selected_zip_lookup = stub_selected_zip
    @photon = stub_request(:get, Weather::PhotonClient::ENDPOINT).with(query: {
      q: "125 Main St", countrycode: "US", layer: "house", limit: "5", lang: "en"
    }).to_return(body: { type: "FeatureCollection", features: [ {
      type: "Feature", geometry: { type: "Point", coordinates: [ -71.063, 42.363 ] },
      properties: { housenumber: "125", street: "Main Street", city: "Boston", state: "Massachusetts",
        countrycode: "US", postcode: "02108-5678" }
    } ] }.to_json)
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "manual addresses ZIP variants and selected locations share weather without sharing location metadata" do
    address_selection = lookup_address
    weather = stub_weather(latitude: 42.36, longitude: -71.06)
    inputs = [
      [ { address: @manual_address }, "123 MAIN ST, BOSTON, MA, 02108", 42.36, -71.06 ],
      [ { address: "02108" }, "Boston, Massachusetts 02108", 42.361, -71.061 ],
      [ { address: " 02108-1234 " }, "Boston, Massachusetts 02108", 42.361, -71.061 ],
      [ @zip_selection, "Beacon Hill, Massachusetts 02108", 42.362, -71.062 ],
      [ address_selection, "125 Main Street, Boston, MA", 42.363, -71.063 ]
    ]

    original = nil
    inputs.each_with_index do |(params, address, latitude, longitude), index|
      data = forecast(params)
      original ||= data
      assert_equal !index.zero?, data.fetch("from_cache")
      assert_equal address, data.dig("location", "address")
      assert_equal "02108", data.dig("location", "postal_code")
      assert_equal "US", data.dig("location", "country")
      assert_equal latitude, data.dig("location", "latitude")
      assert_equal longitude, data.dig("location", "longitude")
      assert_equal original.fetch("current"), data.fetch("current")
      assert_equal original.fetch("daily"), data.fetch("daily")
    end

    assert_requested weather, times: 1
    assert_requested @census, times: 1
    assert_requested @zip_lookup, times: 2
    assert_requested @selected_zip_lookup, times: 1
    assert_requested @photon, times: 1
  end

  test "a different Census street direction returns a correctable error before fetching weather" do
    address = "600 N Clark St, Chicago, IL"
    census = stub_request(:get, Weather::CensusClient::ENDPOINT).with(query: {
      address: address, benchmark: "Public_AR_Current", format: "json"
    }).to_return(body: { result: { addressMatches: [ {
      matchedAddress: "600 S CLARK ST, CHICAGO, IL, 60605",
      addressComponents: { state: "IL", zip: "60605", preDirection: "S", streetName: "CLARK" },
      coordinates: { x: -87.6307519, y: 41.8744675 }
    } ] } }.to_json)

    post forecasts_path, params: { address: address }, as: :json
    assert_error :unprocessable_content, "address_mismatch"

    post forecasts_path, params: { address: address }
    assert_response :unprocessable_content
    assert_select "#search-error[role=alert]", text: /different street direction/
    assert_select "input#address[aria-invalid=true][value=?]", address
    assert_select ".temperature", count: 0
    assert_requested census, times: 2
    assert_not_requested :get, /api\.open-meteo\.com\/v1\/forecast/
    assert_not_requested :get, /photon\.komoot\.io/
  end

  test "cross-entrypoint cache hits do not extend expiry and failed refreshes remain retryable" do
    travel_to Time.zone.local(2026, 9, 14, 10, 0, 0) do
      address_selection = lookup_address
      initial_weather = stub_weather(latitude: 42.36, longitude: -71.06)
      original = forecast(address: @manual_address)
      assert_equal false, original.fetch("from_cache")

      travel 30.minutes - 1.second
      cached = forecast(address: "02108-1234")
      assert_equal true, cached.fetch("from_cache")
      assert_equal original.fetch("current"), cached.fetch("current")
      assert_requested initial_weather, times: 1

      travel 1.second
      failed_refresh = stub_request(:get, Weather::OpenMeteoClient::ENDPOINT)
        .with(query: hash_including(latitude: "42.362", longitude: "-71.062"))
        .to_return(status: 503, body: "private upstream details")
      post forecasts_path, params: @zip_selection, as: :json
      assert_error :bad_gateway, "provider_unavailable"
      assert_not_includes response.body, "private upstream details"
      assert_requested failed_refresh, times: 1

      travel 1.second
      recovered_weather = stub_weather(latitude: 42.363, longitude: -71.063, temperature: 9)
      failed_retry = stub_request(:get, Weather::OpenMeteoClient::ENDPOINT)
        .with(query: hash_including(latitude: "42.363", longitude: "-71.063")).to_timeout
      post forecasts_path, params: address_selection, as: :json
      assert_error :gateway_timeout, "provider_timeout"
      assert_requested failed_retry, times: 1

      remove_request_stub(failed_retry)
      travel 1.second
      recovered = forecast(address_selection)
      assert_equal false, recovered.fetch("from_cache")
      assert_equal 9, recovered.dig("current", "temperature")
      assert_equal 42.363, recovered.dig("location", "latitude")
      assert_equal 19, recovered.dig("daily", "high")

      reused = forecast(address: @manual_address)
      assert_equal true, reused.fetch("from_cache")
      assert_equal recovered.fetch("current"), reused.fetch("current")
      assert_equal recovered.fetch("daily"), reused.fetch("daily")
      assert_equal 42.36, reused.dig("location", "latitude")
      assert_requested recovered_weather, times: 2 # The matching timeout and subsequent success.
      assert_requested :get, /api\.open-meteo\.com\/v1\/forecast/, times: 4
      assert_requested @census, times: 2
      assert_requested @zip_lookup, times: 1
      assert_requested @selected_zip_lookup, times: 1
      assert_requested @photon, times: 1
    end
  end

  test "warm weather never bypasses forged mismatched or expired location selections" do
    travel_to Time.zone.local(2026, 9, 14, 10, 0, 0) do
      address_selection = lookup_address
      weather = stub_weather(latitude: 42.363, longitude: -71.063)
      assert_equal false, forecast(address_selection).fetch("from_cache")

      post forecasts_path, params: address_selection.merge(selected_address_token: "#{address_selection.fetch(:selected_address_token)}tampered"), as: :json
      assert_error :unprocessable_content, "invalid_address_selection"
      relabeled = "126 Main Street, Boston, MA"
      post forecasts_path, params: address_selection.merge(address: relabeled, selected_label: relabeled), as: :json
      assert_error :unprocessable_content, "invalid_address_selection"

      mismatch = stub_selected_zip(@selected_place.merge(id: 4930958))
      post forecasts_path, params: @zip_selection, as: :json
      assert_error :unprocessable_content, "invalid_zip_selection"
      assert_requested mismatch, times: 1
      assert_requested weather, times: 1

      # Refresh weather while the original selection remains valid, then let only the token expire.
      travel 59.minutes
      assert_equal false, forecast(address_selection).fetch("from_cache")
      travel 2.minutes
      post forecasts_path, params: address_selection, as: :json
      assert_error :unprocessable_content, "invalid_address_selection"

      refreshed_selection = lookup_address
      assert_equal true, forecast(refreshed_selection).fetch("from_cache")
      assert_requested weather, times: 2
      assert_requested @photon, times: 2
      assert_not_requested :get, /geocoding\.geo\.census\.gov/
      assert_not_requested :get, /geocoding-api\.open-meteo\.com\/v1\/search/
    end
  end

  private

  def lookup_address
    post address_lookup_path, params: { address: "125 Main St" }, as: :json
    assert_response :success
    suggestion = response.parsed_body.fetch("suggestions").sole
    assert_equal "02108", suggestion.fetch("zip")
    { address: suggestion.fetch("label"), selected_label: suggestion.fetch("label"), selected_address_token: suggestion.fetch("token") }
  end

  def forecast(params)
    post forecasts_path, params: params, as: :json
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    response.parsed_body
  end

  def assert_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert response.parsed_body.dig("error", "message").present?
    assert_not response.parsed_body.key?("current")
    assert_not response.parsed_body.key?("daily")
  end

  def stub_selected_zip(place = @selected_place)
    stub_request(:get, Weather::ZipCodeClient::LOCATION_ENDPOINT).with(query: { id: "4930957" })
      .to_return(body: place.to_json)
  end

  def stub_weather(latitude:, longitude:, temperature: 0)
    stub_request(:get, Weather::OpenMeteoClient::ENDPOINT).with(query: {
      latitude: latitude.to_s, longitude: longitude.to_s, current: "temperature_2m",
      temperature_unit: "fahrenheit", timezone: "auto",
      daily: "temperature_2m_max,temperature_2m_min", forecast_days: "1"
    }).to_return(body: {
      current: { temperature_2m: temperature, time: "2026-09-14T10:00" },
      current_units: { temperature_2m: "°F" }, timezone: "America/New_York",
      daily: { time: [ "2026-09-14" ], temperature_2m_max: [ temperature + 10 ], temperature_2m_min: [ temperature - 5 ] },
      daily_units: { temperature_2m_max: "°F", temperature_2m_min: "°F" }
    }.to_json)
  end
end
