require "test_helper"

class LocationCacheTest < ActionDispatch::IntegrationTest
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @address = "123 Main St, Boston, MA 02108"
    @match = {
      matchedAddress: "123 MAIN ST, BOSTON, MA, 02108",
      addressComponents: { state: "MA", zip: "02108" },
      coordinates: { x: -71.06, y: 42.36 }
    }
    @place = { id: 4930956, name: "Boston", admin1: "Massachusetts", country_code: "US",
      postcodes: [ "02108" ], latitude: 42.36, longitude: -71.06 }
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "normalized manual addresses remain available during a geocoder outage while weather refreshes at 30 minutes" do
    travel_to Time.zone.local(2026, 9, 14, 10, 0, 0) do
      census = stub_census
      weather = stub_weather
      original = forecast(address: @address)
      assert_equal false, original.fetch("from_cache")

      stub_request(:get, Weather::CensusClient::ENDPOINT).with(query: hash_including(address: @address)).to_timeout
      [ "  #{@address}  ", "123 MAIN ST, BOSTON, MA 02108", "123  Main\tSt,\nBoston, MA 02108" ].each do |address|
        cached = forecast(address: address)
        assert_equal true, cached.fetch("from_cache")
        assert_equal original.fetch("location"), cached.fetch("location")
      end

      travel 30.minutes - 1.second
      assert_equal true, forecast(address: @address).fetch("from_cache")
      assert_requested weather, times: 1
      travel 1.second
      stub_weather(temperature: 9)
      refreshed = forecast(address: @address)
      assert_equal false, refreshed.fetch("from_cache")
      assert_equal 9, refreshed.dig("current", "temperature")
      assert_equal original.fetch("location"), refreshed.fetch("location")
      assert_requested census, times: 1
      assert_requested weather, times: 2
    end
  end

  test "a manual location expires at one hour without extending on reads or serving an expired location during an outage" do
    travel_to Time.zone.local(2026, 9, 14, 10, 0, 0) do
      census = stub_census
      weather = stub_weather
      forecast(address: @address)
      travel 1.hour - 1.second
      assert_equal false, forecast(address: @address).fetch("from_cache")
      assert_requested census, times: 1
      assert_requested weather, times: 2

      travel 1.second
      stub_request(:get, Weather::CensusClient::ENDPOINT).with(query: hash_including(address: @address)).to_timeout
      assert_forecast_error({ address: @address }, :gateway_timeout, "provider_timeout")
      assert_requested census, times: 2
      assert_requested weather, times: 2

      stub_census
      assert_equal true, forecast(address: @address).fetch("from_cache")
      assert_requested census, times: 3
      assert_requested weather, times: 2
    end
  end

  test "ZIP extensions share a cached bare lookup while selected localities have independent cached locations" do
    bare = stub_zip
    first_place = @place.merge(id: 4930957, name: "Beacon Hill", latitude: 42.361)
    second_place = @place.merge(id: 4930958, name: "Another locality", latitude: 42.362)
    first = stub_zip_location(first_place)
    second = stub_zip_location(second_place)
    weather = stub_weather
    original = forecast(address: "02108")

    [ " 02108 ", "02108-1234", "02108-5678" ].each do |zip|
      assert_equal original.fetch("location"), forecast(address: zip).fetch("location")
    end
    [ first_place, second_place ].each do |place|
      2.times do
        data = forecast(zip_selection(place))
        assert_equal "#{place.fetch(:name)}, Massachusetts", data.dig("location", "display_name")
        assert_equal place.fetch(:latitude), data.dig("location", "latitude")
        assert_equal true, data.fetch("from_cache")
      end
    end

    stub_request(:get, /geocoding-api\.open-meteo\.com/).to_timeout
    assert_equal original.fetch("location"), forecast(address: "02108").fetch("location")
    assert_equal 42.361, forecast(zip_selection(first_place)).dig("location", "latitude")
    assert_requested bare, times: 1
    assert_requested first, times: 1
    assert_requested second, times: 1
    assert_requested weather, times: 1
    assert_not_requested :get, /geocoding\.geo\.census\.gov/
  end

  test "bare and selected ZIP locations expire at one hour even when read shortly before expiry" do
    travel_to Time.zone.local(2026, 9, 14, 10, 0, 0) do
      bare = stub_zip
      selected = stub_zip_location(@place)
      weather = stub_weather
      inputs = [ { address: "02108" }, zip_selection(@place) ]
      inputs.each { |params| forecast(params) }
      travel 1.hour - 1.second
      inputs.each { |params| forecast(params) }
      assert_requested bare, times: 1
      assert_requested selected, times: 1

      travel 1.second
      inputs.each { |params| assert_equal true, forecast(params).fetch("from_cache") }
      assert_requested bare, times: 2
      assert_requested selected, times: 2
      assert_requested weather, times: 2
    end
  end

  test "a warm selected locality cannot bypass malformed IDs or a different ZIP membership check" do
    location = stub_zip_location(@place)
    weather = stub_weather
    selection = zip_selection(@place)
    forecast(selection)

    [ 4930956, "04930956", "4930956x", "2147483648", [ "4930956" ], { id: "4930956" } ].each do |id|
      assert_forecast_error(selection.merge(selected_location_id: id), :unprocessable_content, "invalid_zip_selection")
    end
    assert_requested location, times: 1

    other_label = "Boston, Massachusetts 02109"
    different_zip = selection.merge(address: other_label, selected_label: other_label, selected_zip: "02109")
    assert_forecast_error(different_zip, :unprocessable_content, "invalid_zip_selection")
    assert_requested location, times: 2

    tampered = stub_zip_location(@place, id: "4930957")
    2.times do
      assert_forecast_error(selection.merge(selected_location_id: "4930957"), :unprocessable_content, "invalid_zip_selection")
    end
    assert_requested tampered, times: 2
    assert_equal true, forecast(selection).fetch("from_cache")
    assert_requested location, times: 2
    assert_requested weather, times: 1
    assert_not_requested :get, /geocoding-api\.open-meteo\.com\/v1\/search/
  end

  test "provider failures and rejected manual matches are retried until a valid location is resolved" do
    invalid_direction = @match.merge(addressComponents: { state: "MA", zip: "02108", preDirection: "S", streetName: "MAIN" })
    address = "123 N Main St, Boston, MA 02108"
    census = stub_request(:get, Weather::CensusClient::ENDPOINT).with(query: hash_including(address: address))
      .to_return(status: 503).then
      .to_return(body: { result: { addressMatches: [] } }.to_json).then
      .to_return(body: { result: { addressMatches: [ invalid_direction ] } }.to_json).then
      .to_return(body: { result: { addressMatches: [ @match ] } }.to_json)
    [ [ :bad_gateway, "provider_unavailable" ], [ :unprocessable_content, "address_not_found" ],
      [ :unprocessable_content, "address_mismatch" ] ].each do |status, code|
      assert_forecast_error({ address: address }, status, code)
    end
    assert_not_requested :get, /api\.open-meteo\.com\/v1\/forecast/

    weather = stub_weather
    assert_equal false, forecast(address: address).fetch("from_cache")
    assert_equal true, forecast(address: address).fetch("from_cache")
    assert_requested census, times: 4
    assert_requested weather, times: 1
  end

  test "failed and ambiguous bare ZIP lookups are not cached as resolved locations" do
    zip = stub_request(:get, Weather::ZipCodeClient::ENDPOINT).with(query: hash_including(name: "02108"))
      .to_return(status: 503).then
      .to_return(body: { results: [ @place, @place.merge(id: 4930957, name: "Another place") ] }.to_json).then
      .to_return(body: { results: [ @place.merge(postcodes: [ "02109" ]) ] }.to_json).then
      .to_return(body: { results: [ @place ] }.to_json)
    [ [ :bad_gateway, "provider_unavailable" ], [ :unprocessable_content, "ambiguous_zip" ],
      [ :unprocessable_content, "zip_not_found" ] ].each do |status, code|
      assert_forecast_error({ address: "02108" }, status, code)
    end
    assert_not_requested :get, /api\.open-meteo\.com\/v1\/forecast/

    weather = stub_weather
    assert_equal false, forecast(address: "02108").fetch("from_cache")
    assert_equal true, forecast(address: "02108-1234").fetch("from_cache")
    assert_requested zip, times: 4
    assert_requested weather, times: 1
  end

  test "a signed selection still expires when first submitted shortly before expiry with a warm manual location" do
    travel_to Time.zone.local(2026, 9, 14, 10, 0, 0) do
      photon = stub_request(:get, Weather::PhotonClient::ENDPOINT).with(query: hash_including(q: "123 Main St"))
        .to_return(body: { type: "FeatureCollection", features: [ {
          type: "Feature", geometry: { type: "Point", coordinates: [ -71.06, 42.36 ] },
          properties: { countrycode: "US", housenumber: "123", street: "Main Street", city: "Boston", state: "Massachusetts", postcode: "02108" }
        } ] }.to_json)
      post address_lookup_path, params: { address: "123 Main St" }, as: :json
      assert_response :success
      suggestion = response.parsed_body.fetch("suggestions").sole
      label = suggestion.fetch("label")
      selection = { address: label, selected_label: label, selected_address_token: suggestion.fetch("token") }

      travel 59.minutes
      census = stub_request(:get, Weather::CensusClient::ENDPOINT).with(query: hash_including(address: label))
        .to_return(body: { result: { addressMatches: [ @match ] } }.to_json)
      weather = stub_weather
      assert_equal false, forecast(address: label).fetch("from_cache")
      assert_equal true, forecast(selection).fetch("from_cache")

      travel 2.minutes
      assert_forecast_error(selection, :unprocessable_content, "invalid_address_selection")
      assert_equal true, forecast(address: label).fetch("from_cache")
      assert_requested photon, times: 1
      assert_requested census, times: 1
      assert_requested weather, times: 1
    end
  end

  private

  def forecast(params)
    post forecasts_path, params: params, as: :json
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    response.parsed_body
  end

  def assert_forecast_error(params, status, code)
    post forecasts_path, params: params, as: :json
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert_not response.parsed_body.key?("current")
  end

  def zip_selection(place)
    label = "#{place.fetch(:name)}, Massachusetts 02108"
    { address: label, selected_label: label, selected_zip: "02108", selected_location_id: place.fetch(:id).to_s }
  end

  def stub_census
    stub_request(:get, Weather::CensusClient::ENDPOINT).with(query: {
      address: @address, benchmark: "Public_AR_Current", format: "json"
    }).to_return(body: { result: { addressMatches: [ @match ] } }.to_json)
  end

  def stub_zip
    stub_request(:get, Weather::ZipCodeClient::ENDPOINT).with(query: {
      name: "02108", countryCode: "US", count: "100", language: "en", format: "json"
    }).to_return(body: { results: [ @place ] }.to_json)
  end

  def stub_zip_location(place, id: place.fetch(:id).to_s)
    stub_request(:get, Weather::ZipCodeClient::LOCATION_ENDPOINT).with(query: { id: id }).to_return(body: place.to_json)
  end

  def stub_weather(temperature: 0)
    stub_request(:get, Weather::OpenMeteoClient::ENDPOINT).with(query: {
      latitude: "42.36", longitude: "-71.06", current: "temperature_2m", temperature_unit: "fahrenheit", timezone: "auto",
      daily: "temperature_2m_max,temperature_2m_min", forecast_days: "1"
    }).to_return(body: {
      current: { temperature_2m: temperature, time: "2026-09-14T10:00" }, current_units: { temperature_2m: "°F" }, timezone: "America/New_York",
      daily: { time: [ "2026-09-14" ], temperature_2m_max: [ temperature + 10 ], temperature_2m_min: [ temperature - 5 ] },
      daily_units: { temperature_2m_max: "°F", temperature_2m_min: "°F" }
    }.to_json)
  end
end
