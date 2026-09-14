require "application_system_test_case"

class ForecastRecoveryTest < ApplicationSystemTestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @query = "600 N Clark St"
    @label = "600 North Clark Street, Chicago, IL"
    @photon = stub_request(:get, Weather::PhotonClient::ENDPOINT).with(query: hash_including(q: @query)).to_return(body: {
      type: "FeatureCollection", features: [ {
        type: "Feature", geometry: { type: "Point", coordinates: [ -87.6315646, 41.8928566 ] },
        properties: { housenumber: "600", street: "North Clark Street", city: "Chicago", state: "Illinois", countrycode: "US", postcode: "60654" }
      } ]
    }.to_json)
    @weather = stub_request(:get, Weather::OpenMeteoClient::ENDPOINT).with(query: hash_including(latitude: "41.8928566", longitude: "-87.6315646"))
    visit root_path
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "retrying a weather outage preserves the selected address and caches only the successful forecast" do
    @weather.to_return({ status: 503 }, { body: weather_response.to_json })
    select_address
    token = selected_token

    click_on "Check the weather"
    assert_selector "#search-error[role=alert]", text: "unavailable"
    assert_field "address", with: @label
    assert_equal token, selected_token
    assert_equal @label, find("#selected_label", visible: :all).value
    assert_no_selector ".temperature"
    assert_requested @weather, times: 1

    click_on "Check the weather"
    assert_selector "#forecast-heading", text: @label
    assert_selector ".cache-badge", text: "Just fetched"
    assert_no_selector "#search-error"
    assert_equal token, selected_token
    assert_requested @weather, times: 2

    click_on "Check the weather"
    assert_selector "#forecast-heading", text: @label
    assert_selector ".cache-badge", text: "From cache"
    assert_requested @weather, times: 2
    assert_requested @photon, times: 1
    assert_not_requested :get, /\A#{Regexp.escape(Weather::CensusClient::ENDPOINT)}(?:\?|\z)/
  end

  test "an expired selection can be replaced through the input without falling back to a different address" do
    @weather.to_return(body: weather_response.to_json)
    select_address
    expired_token = selected_token

    travel Weather::AddressSuggestions::TTL + 1.second do
      click_on "Check the weather"
      assert_selector "#search-error[role=alert]", text: "invalid or expired"
      assert_field "address", with: @label
      assert_equal expired_token, selected_token
      assert_no_selector ".temperature"
      assert_not_requested :get, /\A#{Regexp.escape(Weather::OpenMeteoClient::ENDPOINT)}(?:\?|\z)/
      assert_not_requested :get, /\A#{Regexp.escape(Weather::CensusClient::ENDPOINT)}(?:\?|\z)/

      fill_in "Address or ZIP code", with: @query
      assert_equal "", selected_token
      assert_equal "", find("#selected_label", visible: :all).value
      find("[role=option]", text: @label).click
      assert_field "address", with: @label
      assert selected_token.present?
      assert_not_equal expired_token, selected_token

      click_on "Check the weather"
      assert_selector "#forecast-heading", text: @label
      assert_selector ".location-detail", text: "ZIP 60654"
      assert_selector ".cache-badge", text: "Just fetched"
      assert_no_selector "#search-error"
      assert_requested @weather, times: 1
      assert_requested @photon, times: 2
      assert_not_requested :get, /\A#{Regexp.escape(Weather::CensusClient::ENDPOINT)}(?:\?|\z)/
    end
  end

  private

  def select_address
    fill_in "Address or ZIP code", with: @query
    find("[role=option]", text: @label).click
    assert_field "address", with: @label
    assert selected_token.present?
  end

  def selected_token
    find("#selected_address_token", visible: :all).value
  end

  def weather_response
    {
      current: { temperature_2m: 70, time: "2026-09-14T10:15" }, current_units: { temperature_2m: "°F" }, timezone: "America/Chicago",
      daily: { time: [ "2026-09-14" ], temperature_2m_max: [ 80 ], temperature_2m_min: [ 55 ] },
      daily_units: { temperature_2m_max: "°F", temperature_2m_min: "°F" }
    }
  end
end
