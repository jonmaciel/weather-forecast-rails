require "application_system_test_case"

class AddressSearchTest < ApplicationSystemTestCase
  PHOTON_ENDPOINT = "https://photon.komoot.io/api/"

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @query = "600 N Clark St"
    @label = "600 North Clark Street, Chicago, IL"
    stub_photon
    stub_weather
    visit root_path
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "keyboard selection fills a full address and preserves its token on resubmission" do
    fill_in "Address or ZIP code", with: @query
    assert_selector "[role=option]", text: @label
    address.send_keys(:arrow_down, :enter)
    assert_field "address", with: @label
    assert_no_selector "[role=listbox]"
    assert_current_path root_path
    token = find("#selected_address_token", visible: :all).value
    assert token.present?
    assert_not_requested :get, /api\.open-meteo\.com\/v1\/forecast/

    2.times do |index|
      click_on "Check the weather"
      assert_selector "#forecast-heading", text: @label
      assert_selector ".cache-badge", text: index.zero? ? "Just fetched" : "From cache"
      assert_equal token, find("#selected_address_token", visible: :all).value
    end
    assert_requested :get, /api\.open-meteo\.com\/v1\/forecast/, times: 1
    assert_not_requested :get, /geocoding\.geo\.census\.gov|geocoding-api\.open-meteo\.com/
  end

  test "editing between street and ZIP suggestions replaces all selection metadata" do
    stub_request(:get, Weather::ZipCodeClient::ENDPOINT).with(query: hash_including(name: "021")).to_return(body: {
      results: [ { id: 4930956, name: "Boston", admin1: "Massachusetts", country_code: "US", postcodes: %w[02108], latitude: 42.36, longitude: -71.06 } ]
    }.to_json)
    fill_in "Address or ZIP code", with: @query
    find("[role=option]", text: @label).click
    assert find("#selected_address_token", visible: :all).value.present?

    fill_in "Address or ZIP code", with: "021"
    assert_equal "", find("#selected_address_token", visible: :all).value
    assert_equal "", find("#selected_label", visible: :all).value
    find("[role=option]", text: "Boston").click
    assert_field "address", with: "Boston, Massachusetts 02108"
    assert_equal "4930956", find("#selected_location_id", visible: :all).value
    assert_equal "", find("#selected_address_token", visible: :all).value

    fill_in "Address or ZIP code", with: @query
    assert_equal "", find("#selected_zip", visible: :all).value
    assert_equal "", find("#selected_location_id", visible: :all).value
    assert_selector "[role=option]", text: @label
    address.send_keys(:tab)
    assert_field "address", with: @label
    assert_selector ".search-button:focus"
    click_on "Check the weather"
    assert_selector "#forecast-heading", text: @label
    assert_not_requested :get, /geocoding-api\.open-meteo\.com\/v1\/get/
    assert_not_requested :get, /geocoding\.geo\.census\.gov/
  end

  test "a suggestion provider failure leaves a manual street address usable" do
    manual = "600 N Clark St, Chicago, IL 60654"
    stub_request(:get, PHOTON_ENDPOINT).with(query: hash_including(q: manual)).to_return(status: 503)
    census = stub_request(:get, Weather::CensusClient::ENDPOINT).with(query: hash_including(address: manual)).to_return(body: {
      result: { addressMatches: [ { matchedAddress: @label, addressComponents: { state: "IL", zip: "60654" }, coordinates: { x: -87.6315646, y: 41.8928566 } } ] }
    }.to_json)
    fill_in "Address or ZIP code", with: manual
    assert_selector "#zip-feedback", text: "unavailable"
    assert_no_selector "[role=option]"
    address.send_keys(:escape)
    click_on "Check the weather"
    assert_selector "#forecast-heading", text: @label
    assert_field "address", with: manual
    assert_equal "", find("#selected_address_token", visible: :all).value
    assert_requested census, times: 1
    assert_requested :get, /api\.open-meteo\.com\/v1\/forecast/, times: 1
  end

  private

  def address
    find("#address")
  end

  def stub_photon
    stub_request(:get, PHOTON_ENDPOINT).with(query: hash_including(q: @query)).to_return(body: {
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
