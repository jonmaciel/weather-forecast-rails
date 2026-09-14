require "test_helper"

class AddressLookupsTest < ActionDispatch::IntegrationTest
  PHOTON_ENDPOINT = "https://photon.komoot.io/api/"

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @query = "600 N Clark St"
    @label = "600 North Clark Street, Chicago, IL"
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "a suggested address submits its verified coordinates and preserves selection on cached resubmission" do
    photon = stub_photon
    suggestion = lookup
    assert_equal @label, suggestion.fetch("label")
    assert_equal "60654", suggestion.fetch("zip")
    assert_kind_of String, suggestion.fetch("token")
    assert_not_requested :get, /api\.open-meteo\.com\/v1\/forecast/

    weather = stub_weather
    2.times do |index|
      post forecasts_path, params: selection(suggestion)
      assert_response :success
      assert_select "#forecast-heading", text: @label
      assert_select "input#address[value=?]", @label
      assert_select "input#selected_address_token[value=?]", suggestion.fetch("token")
      assert_select "input#selected_label[value=?]", @label
      assert_select ".cache-badge", text: index.zero? ? "Just fetched" : "From cache"
    end
    assert_requested photon, times: 1
    assert_requested weather, times: 1
    assert_not_requested :get, /geocoding\.geo\.census\.gov|geocoding-api\.open-meteo\.com/
  end

  test "cached suggestions issue fresh tokens without fetching weather" do
    travel_to Time.zone.local(2026, 9, 14, 10, 0, 0) do
      photon = stub_photon
      original = lookup
      travel 59.minutes
      refreshed = lookup
      assert_not_equal original.fetch("token"), refreshed.fetch("token")
      assert_requested photon, times: 1
      assert_not_requested :get, /api\.open-meteo\.com\/v1\/forecast/

      travel 2.minutes
      stub_weather
      post forecasts_path, params: selection(refreshed), as: :json
      assert_response :success
      assert_equal "60654", response.parsed_body.dig("location", "postal_code")
      assert_equal 41.8928566, response.parsed_body.dig("location", "latitude")
      assert_requested photon, times: 1
    end
  end

  test "forged structured expired and relabeled tokens never call weather" do
    travel_to Time.zone.local(2026, 9, 14, 10, 0, 0) do
      stub_photon
      suggestion = lookup
      token = suggestion.fetch("token")
      [ "not-a-signed-token", "#{token}tampered", [ token ], { token: token } ].each do |invalid|
        post forecasts_path, params: selection(suggestion).merge(selected_address_token: invalid), as: :json
        assert_invalid_selection
      end

      post forecasts_path, params: selection(suggestion).merge(address: "601 North Clark Street, Chicago, IL", selected_label: "601 North Clark Street, Chicago, IL"), as: :json
      assert_invalid_selection

      travel 1.hour + 1.second
      post forecasts_path, params: selection(suggestion), as: :json
      assert_invalid_selection
    end
    assert_not_requested :get, /geocoding\.geo\.census\.gov|geocoding-api\.open-meteo\.com/
    assert_not_requested :get, /api\.open-meteo\.com\/v1\/forecast/
  end

  test "editing the displayed address discards the old token and uses manual Census lookup" do
    stub_photon
    suggestion = lookup
    edited = "601 North Clark Street, Chicago, IL 60654"
    census = stub_request(:get, Weather::CensusClient::ENDPOINT).with(query: hash_including(address: edited)).to_return(body: {
      result: { addressMatches: [ { matchedAddress: edited, addressComponents: { state: "IL", zip: "60654" }, coordinates: { x: -87.6315646, y: 41.8928566 } } ] }
    }.to_json)
    stub_weather

    post forecasts_path, params: selection(suggestion).merge(address: edited)
    assert_response :success
    assert_select "#forecast-heading", text: edited
    assert_select "input#selected_address_token[value]", count: 0
    assert_select "input#selected_label[value]", count: 0
    assert_requested census, times: 1
  end

  test "invalid address queries do not reach providers" do
    [ nil, "  ", "short", "123456", "a" * 301, " " * 301 + @query, [ @query ], { address: @query } ].each do |address|
      post address_lookup_path, params: { address: address }, as: :json
      assert_response :unprocessable_content
      assert response.parsed_body.dig("error", "code").present?
    end
    assert_not_requested :get, /photon\.komoot\.io|census\.gov|open-meteo\.com/
  end

  test "a failed suggestion lookup is not cached and a later request recovers" do
    stub_request(:get, PHOTON_ENDPOINT).with(query: hash_including(q: @query)).to_return(status: 503, body: "private provider details")
    post address_lookup_path, params: { address: @query }, as: :json
    assert_response :bad_gateway
    assert_equal "provider_unavailable", response.parsed_body.dig("error", "code")
    assert_not_includes response.body, "private provider details"

    stub_photon
    assert_equal @label, lookup.fetch("label")
    assert_requested :get, PHOTON_ENDPOINT, query: hash_including(q: @query), times: 2
    assert_not_requested :get, /api\.open-meteo\.com\/v1\/forecast/
  end

  private

  def lookup
    post address_lookup_path, params: { address: @query }, as: :json
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    response.parsed_body.fetch("suggestions").sole
  end

  def selection(suggestion)
    { address: suggestion.fetch("label"), selected_label: suggestion.fetch("label"), selected_address_token: suggestion.fetch("token") }
  end

  def assert_invalid_selection
    assert_response :unprocessable_content
    assert_equal "invalid_address_selection", response.parsed_body.dig("error", "code")
  end

  def stub_photon
    stub_request(:get, PHOTON_ENDPOINT).with(query: {
      q: @query, countrycode: "US", layer: "house", limit: "5", lang: "en"
    }).to_return(body: {
      type: "FeatureCollection", features: [ {
        type: "Feature", geometry: { type: "Point", coordinates: [ -87.6315646, 41.8928566 ] },
        properties: { housenumber: "600", street: "North Clark Street", city: "Chicago", state: "Illinois", countrycode: "US", postcode: "60654" }
      } ]
    }.to_json)
  end

  def stub_weather
    stub_request(:get, Weather::OpenMeteoClient::ENDPOINT).with(query: hash_including(latitude: "41.8928566", longitude: "-87.6315646")).to_return(body: {
      current: { temperature_2m: 70, time: "2026-09-14T10:15" }, current_units: { temperature_2m: "°F" }, timezone: "America/Chicago",
      daily: { time: [ "2026-09-14" ], temperature_2m_max: [ 80 ], temperature_2m_min: [ 55 ] },
      daily_units: { temperature_2m_max: "°F", temperature_2m_min: "°F" }
    }.to_json)
  end
end
