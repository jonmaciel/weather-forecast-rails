require "test_helper"

class ForecastsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @match = {
      "matchedAddress" => "123 MAIN ST, BOSTON, MA, 02108",
      "addressComponents" => { "state" => "MA", "zip" => "02108-1234" },
      "coordinates" => { "x" => -71.06, "y" => 42.36 }
    }
    @weather = {
      "current" => { "temperature_2m" => 0, "time" => "2026-09-12T10:15" },
      "current_units" => { "temperature_2m" => "°F" }, "timezone" => "America/New_York"
    }
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "returns normalized location and current weather, preserving zero temperature and leading ZIP zeros" do
    census = stub_census
    weather = stub_weather
    post forecasts_path, params: { address: "  123 Main St, Boston, MA 02108  " }, as: :json
    assert_response :success
    data = response.parsed_body
    assert_equal "02108", data.dig("location", "postal_code")
    assert_equal "US", data.dig("location", "country")
    assert_equal 0, data.dig("current", "temperature")
    assert_equal "°F", data.dig("current", "unit")
    assert_equal "America/New_York", data.dig("current", "timezone")
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_requested census, times: 1
    assert_requested weather, times: 1
  end

  test "rejects absent blank oversized and structured addresses before calling providers" do
    [ nil, " ", "a" * 301, [ "Boston" ], { city: "Boston" } ].each do |address|
      post forecasts_path, params: { address: address }, as: :json
      assert_error :unprocessable_content, "invalid_address"
    end
    assert_not_requested :get, /census.gov|open-meteo.com/
  end

  test "reports unmatched and ambiguous addresses without calling the weather API" do
    [ [ [], "address_not_found" ], [ [ @match, @match ], "ambiguous_address" ] ].each do |matches, code|
      stub_census(matches: matches)
      query
      assert_error :unprocessable_content, code
    end
    assert_not_requested :get, Weather::OpenMeteoClient::ENDPOINT
  end

  test "rejects unsupported states and missing ZIP codes" do
    @match["addressComponents"]["state"] = "PR"
    stub_census
    query
    assert_error :unprocessable_content, "unsupported_address"
    @match["addressComponents"] = { "state" => "MA", "zip" => "" }
    stub_census
    query
    assert_error :unprocessable_content, "missing_postal_code"
  end

  test "rejects malformed geocoder coordinates and payloads" do
    @match["coordinates"]["y"] = 999
    stub_census
    query
    assert_error :bad_gateway, "invalid_provider_response"
    stub_request(:get, /geocoding.geo.census.gov/).to_return(body: '{"result":null}')
    query
    assert_error :bad_gateway, "invalid_provider_response"
  end

  test "handles weather timeout without retrying" do
    stub_census
    request = stub_request(:get, /api.open-meteo.com/).to_timeout
    query
    assert_error :gateway_timeout, "provider_timeout"
    assert_requested request, times: 1
  end

  test "handles geocoder network failure" do
    stub_request(:get, /geocoding.geo.census.gov/).to_raise(SocketError)
    query
    assert_error :bad_gateway, "provider_unavailable"
  end

  test "handles rate limiting and upstream server errors" do
    stub_census
    [ [ 429, :service_unavailable, "provider_rate_limited" ], [ 503, :bad_gateway, "provider_unavailable" ] ].each do |status, expected, code|
      stub_request(:get, /api.open-meteo.com/).to_return(status: status, body: "private upstream details")
      query
      assert_error expected, code
      assert_not_includes response.body, "private upstream details"
    end
  end

  test "rejects invalid JSON and incomplete weather data" do
    stub_census
    [ "not json", "[]", "{}", @weather.merge("current" => { "temperature_2m" => nil }).to_json,
      @weather.merge("current_units" => { "temperature_2m" => "°C" }).to_json ].each do |body|
      stub_request(:get, /api.open-meteo.com/).to_return(body: body)
      query
      assert_error :bad_gateway, "invalid_provider_response"
    end
  end

  test "filters addresses from parameter logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("address" => "123 Main St")["address"]
  end

  test "rejects empty successful provider responses" do
    stub_census
    stub_request(:get, /api.open-meteo.com/).to_return(status: 204)
    query
    assert_error :bad_gateway, "invalid_provider_response"
  end

  private

  def query
    post forecasts_path, params: { address: "123 Main St, Boston, MA 02108" }, as: :json
  end

  def assert_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
  end

  def stub_census(matches: [ @match ], address: "123 Main St, Boston, MA 02108")
    stub_request(:get, Weather::CensusClient::ENDPOINT).with(query: {
      address: address, benchmark: "Public_AR_Current", format: "json"
    }).to_return(body: { result: { addressMatches: matches } }.to_json)
  end

  def stub_weather
    stub_request(:get, Weather::OpenMeteoClient::ENDPOINT).with(query: {
      latitude: "42.36", longitude: "-71.06", current: "temperature_2m",
      temperature_unit: "fahrenheit", timezone: "auto"
    }).to_return(body: @weather.to_json)
  end
end
