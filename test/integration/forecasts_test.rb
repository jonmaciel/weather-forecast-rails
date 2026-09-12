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
    assert_equal false, data.fetch("from_cache")
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

  test "shares weather across addresses in the same normalized ZIP but preserves each address" do
    census = stub_census
    weather = stub_weather
    query
    original = response.parsed_body

    @match["matchedAddress"] = "125 MAIN ST, BOSTON, MA, 02108"
    @match["addressComponents"]["zip"] = "02108"
    @match["coordinates"]["y"] = 42.361
    second_address = "125 Main St, Boston, MA 02108"
    second_census = stub_census(address: second_address)
    post forecasts_path, params: { address: second_address }, as: :json

    assert_response :success
    assert_equal true, response.parsed_body.fetch("from_cache")
    assert_equal original.fetch("current"), response.parsed_body.fetch("current")
    assert_equal @match["matchedAddress"], response.parsed_body.dig("location", "address")
    assert_equal 42.361, response.parsed_body.dig("location", "latitude")
    assert_requested weather, times: 1
    assert_requested census, times: 1
    assert_requested second_census, times: 1
  end

  test "expires after 30 minutes without extending the TTL on a cache hit" do
    travel_to Time.zone.local(2026, 9, 12, 10, 0, 0) do
      stub_census
      weather = stub_weather
      query
      assert_equal false, response.parsed_body.fetch("from_cache")

      travel 30.minutes - 1.second
      query
      assert_equal true, response.parsed_body.fetch("from_cache")
      assert_requested weather, times: 1

      travel 1.second
      query
      assert_response :success
      assert_equal false, response.parsed_body.fetch("from_cache")
      assert_requested weather, times: 2
    end
  end

  test "isolates different ZIP codes even when coordinates are identical" do
    stub_census
    weather = stub_weather
    query

    @match["addressComponents"]["zip"] = "02109"
    stub_census
    query
    assert_equal false, response.parsed_body.fetch("from_cache")
    assert_equal "02109", response.parsed_body.dig("location", "postal_code")
    assert_requested weather, times: 2

    query
    assert_equal true, response.parsed_body.fetch("from_cache")
    assert_requested weather, times: 2
  end

  test "does not cache provider failures and caches a later successful response" do
    stub_census
    failed_request = stub_request(:get, /api.open-meteo.com/).to_return(status: 503)
    query
    assert_error :bad_gateway, "provider_unavailable"
    query
    assert_error :bad_gateway, "provider_unavailable"
    assert_requested failed_request, times: 2

    stub_weather
    query
    assert_response :success
    assert_equal false, response.parsed_body.fetch("from_cache")
    query
    assert_equal true, response.parsed_body.fetch("from_cache")
    assert_requested :get, /api.open-meteo.com/, times: 3
  end

  test "does not serve expired weather when refreshing fails" do
    travel_to Time.zone.local(2026, 9, 12, 10, 0, 0) do
      stub_census
      stub_weather
      query
      travel 30.minutes
      stub_request(:get, /api.open-meteo.com/).to_timeout
      query
      assert_error :gateway_timeout, "provider_timeout"
      assert_not response.parsed_body.key?("current")
    end
  end

  test "home renders an accessible search form and empty state" do
    get root_path
    assert_response :success
    assert_select "form[action=?][method=post]", forecasts_path
    assert_select "label[for=address]", text: "Street address"
    assert_select "input#address[required][maxlength='300'][aria-describedby=address-help]"
    assert_select "#address-help", text: /US addresses only/
    assert_select "#forecast-heading", text: "What's it like out there?"
    assert_select "a[href='https://open-meteo.com/']"
  end

  test "HTML submission displays temperature timestamp and cache indicator" do
    stub_census
    weather = stub_weather
    2.times do |index|
      post forecasts_path, params: { address: "123 Main St, Boston, MA 02108" }
      assert_response :success
      assert_equal "text/html", response.media_type
      assert_select "input#address[value=?]", "123 Main St, Boston, MA 02108"
      assert_select "#forecast-heading", text: @match["matchedAddress"]
      assert_select ".temperature", text: "0°F"
      assert_select "time[datetime='2026-09-12T10:15']", text: /Sep 12, 2026/
      assert_select ".cache-badge", text: index.zero? ? "Just fetched" : "From cache"
      assert_select "#search-error", count: 0
    end
    assert_requested weather, times: 1
  end

  test "HTML errors preserve and escape the input and allow correction" do
    address = '<script>alert("example")</script>'
    stub_census(matches: [], address: address)
    post forecasts_path, params: { address: address }
    assert_response :unprocessable_content
    assert_select "#search-error[role=alert]", text: /Address not found/
    assert_select "input#address[aria-invalid=true][value=?]", address
    assert_select "script", count: 0
    assert_select ".temperature", count: 0
    assert_select "input[type=submit]"
  end

  test "HTML timeout and unavailable messages leave the form usable" do
    stub_census
    stub_request(:get, /api.open-meteo.com/).to_timeout
    post forecasts_path, params: { address: "123 Main St, Boston, MA 02108" }
    assert_response :gateway_timeout
    assert_select "#search-error", text: /took too long/
    assert_select "input#address[aria-invalid=true]", count: 0

    stub_request(:get, /api.open-meteo.com/).to_return(status: 503)
    post forecasts_path, params: { address: "123 Main St, Boston, MA 02108" }
    assert_response :bad_gateway
    assert_select "#search-error", text: /unavailable/
    assert_select "input[type=submit]"
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
