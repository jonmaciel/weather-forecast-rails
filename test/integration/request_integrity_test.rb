require "test_helper"

class RequestIntegrityTest < ActionDispatch::IntegrationTest
  setup do
    @previous_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @previous_forgery_protection
  end

  test "forecast and suggestion endpoints reject missing forged and cross-origin CSRF credentials" do
    get root_path
    token = css_select('meta[name="csrf-token"]').first["content"]
    [ {}, { "X-CSRF-Token" => "invalid" },
      { "X-CSRF-Token" => token, "Origin" => "https://other.example" } ].each do |headers|
      [ forecasts_path, address_lookup_path ].each do |path|
        post path, params: { address: "600 N Clark St" }, headers: headers, as: :json
        assert_response :unprocessable_content
      end
    end
    assert_not_requested :get, /census\.gov|open-meteo\.com|photon\.komoot\.io/
  end

  test "the rendered form token authorizes JSON suggestions and a manual HTML forecast" do
    get root_path
    token = css_select('meta[name="csrf-token"]').first["content"]
    photon = stub_request(:get, Weather::PhotonClient::ENDPOINT).with(query: hash_including(q: "600 N Clark St"))
      .to_return(body: { type: "FeatureCollection", features: [] }.to_json)

    post address_lookup_path, params: { address: "600 N Clark St" }, headers: { "X-CSRF-Token" => token }, as: :json
    assert_response :success
    assert_empty response.parsed_body.fetch("suggestions")
    assert_requested photon, times: 1

    zip = stub_request(:get, Weather::ZipCodeClient::ENDPOINT).with(query: hash_including(name: "20233")).to_return(body: {
      results: [ { id: 4140963, name: "Washington", admin1: "District of Columbia", country_code: "US",
        postcodes: [ "20233" ], latitude: 38.9, longitude: -77.04 } ]
    }.to_json)
    weather = stub_request(:get, Weather::OpenMeteoClient::ENDPOINT).with(query: hash_including(latitude: "38.9", longitude: "-77.04")).to_return(body: {
      current: { temperature_2m: 70, time: "2026-09-14T10:15" }, current_units: { temperature_2m: "°F" }, timezone: "America/New_York",
      daily: { time: [ "2026-09-14" ], temperature_2m_max: [ 80 ], temperature_2m_min: [ 55 ] },
      daily_units: { temperature_2m_max: "°F", temperature_2m_min: "°F" }
    }.to_json)

    post forecasts_path, params: { address: "20233", authenticity_token: token }
    assert_response :success
    assert_select "#forecast-heading", text: "Washington, District of Columbia"
    assert_select ".temperature", text: "70°F"
    assert_select "input#address[value='20233']"
    assert_requested zip, times: 1
    assert_requested weather, times: 1
    assert_not_requested :get, /census\.gov/
  end
end
