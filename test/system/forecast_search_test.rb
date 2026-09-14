require "application_system_test_case"

class ForecastSearchTest < ApplicationSystemTestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    stub_zip("373", "Athens", "Tennessee", %w[37303 37304], id: 4611932)
    stub_zip("37304", "Athens", "Tennessee", %w[37303 37304], id: 4611932)
    stub_zip("021", "Boston", "Massachusetts", %w[02108], id: 4930956)
    stub_zip("02108", "Boston", "Massachusetts", %w[02108], id: 4930956)
    stub_weather
    visit root_path
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "keyboard selection fills a readable label and submits the selected ZIP" do
    fill_in "Address or ZIP code", with: "373"
    assert_selector "[role=option]", count: 2
    address.send_keys(:arrow_down, :arrow_down, :enter)
    assert_field "address", with: "Athens, Tennessee 37304"
    assert_selector "#selected_location_id[value='4611932']", visible: :all
    assert_no_selector "[role=listbox]"
    assert_current_path root_path
    click_on "Check the weather"
    assert_selector "#forecast-heading", text: "Athens, Tennessee"
    assert_selector ".daily-forecast", text: "80°F"
    assert_selector ".daily-forecast", text: "55°F"
    assert_field "address", with: "Athens, Tennessee 37304"
    assert_selector "#selected_location_id[value='4611932']", visible: :all
    click_on "Check the weather"
    assert_selector ".cache-badge", text: "From cache"
    assert_requested :get, /api.open-meteo.com\/v1\/forecast/, times: 1
    assert_not_requested :get, /geocoding.geo.census.gov/
  end

  test "selecting different locations for one ZIP preserves the place and shares weather cache" do
    places = [
      { id: 5110302, name: "Brooklyn", admin1: "New York", country_code: "US", postcodes: %w[11201], latitude: 40.65, longitude: -73.95 },
      { id: 7162414, name: "Brooklyn Bridge Park", admin1: "New York", country_code: "US", postcodes: %w[11201], latitude: 40.7, longitude: -73.99 }
    ]
    stub_request(:get, Weather::ZipCodeClient::ENDPOINT).with(query: hash_including(name: "11201")).to_return(body: { results: places }.to_json)
    places.each do |place|
      stub_request(:get, Weather::ZipCodeClient::LOCATION_ENDPOINT).with(query: hash_including(id: place.fetch(:id).to_s)).to_return(body: place.to_json)
    end

    places.each_with_index do |place, index|
      fill_in "Address or ZIP code", with: "11201"
      assert_selector "[role=option]", count: 2
      find("[role=option]", text: "#{place.fetch(:name)}, New York").click
      assert_selector "#selected_location_id[value='#{place.fetch(:id)}']", visible: :all
      click_on "Check the weather"
      assert_selector "#forecast-heading", text: "#{place.fetch(:name)}, New York"
      assert_selector "#selected_location_id[value='#{place.fetch(:id)}']", visible: :all
      assert_selector ".cache-badge", text: index.zero? ? "Just fetched" : "From cache"
      assert_requested :get, Weather::ZipCodeClient::LOCATION_ENDPOINT, query: hash_including(id: place.fetch(:id).to_s), times: 1
    end

    assert_requested :get, /api.open-meteo.com\/v1\/forecast/, times: 1
    assert_not_requested :get, /geocoding.geo.census.gov/
  end

  test "Tab accepts the first option and preserves normal focus navigation" do
    fill_in "Address or ZIP code", with: "021"
    assert_selector "[role=option]", count: 1
    address.send_keys(:tab)
    assert_field "address", with: "Boston, Massachusetts 02108"
    assert_selector ".search-button:focus"
    assert_current_path root_path
  end

  test "Right accepts only at the end while Escape and Shift Tab leave input unchanged" do
    fill_in "Address or ZIP code", with: "021"
    assert_selector "[role=option]"
    address.send_keys(:home, :arrow_right)
    assert_field "address", with: "021"
    assert_selector "[role=option]"
    address.send_keys(:escape)
    assert_no_selector "[role=option]"
    address.send_keys(:arrow_down)
    assert_selector "[role=option]"
    address.send_keys([ :shift, :tab ])
    assert_field "address", with: "021"
    address.click
    assert_selector "[role=option]"
    address.send_keys(:end, :arrow_right)
    assert_field "address", with: "Boston, Massachusetts 02108"
  end

  test "click selection preserves ZIP plus four and can be replaced" do
    fill_in "Address or ZIP code", with: "02108-1234"
    find("[role=option]", text: "Boston").click
    assert_field "address", with: "Boston, Massachusetts 02108-1234"
    assert_selector "#selected_zip[value='02108-1234']", visible: :all
    assert_selector "#selected_location_id[value='4930956']", visible: :all
    fill_in "Address or ZIP code", with: "373"
    find("[role=option]", text: "37304").click
    assert_field "address", with: "Athens, Tennessee 37304"
    assert_selector "#selected_zip[value='37304']", visible: :all
    assert_selector "#selected_location_id[value='4611932']", visible: :all
  end

  test "editing a selection submits the street address instead of the old ZIP" do
    fill_in "Address or ZIP code", with: "373"
    find("[role=option]", text: "37304").click
    street = "123 Main St, Boston, MA 02108"
    stub_request(:get, Weather::CensusClient::ENDPOINT).with(query: hash_including(address: street)).to_return(body: {
      result: { addressMatches: [ { matchedAddress: street, addressComponents: { state: "MA", zip: "02108" }, coordinates: { x: -71.06, y: 42.36 } } ] }
    }.to_json)
    fill_in "Address or ZIP code", with: street
    assert_selector "#selected_location_id[value='']", visible: :all
    click_on "Check the weather"
    assert_selector "#forecast-heading", text: street
    assert_not_requested :get, Weather::ZipCodeClient::ENDPOINT, query: hash_including(name: "37304")
    assert_not_requested :get, Weather::ZipCodeClient::LOCATION_ENDPOINT, query: hash_including(id: "4611932")
  end

  test "preview failure leaves plain ZIP submission usable" do
    stub_request(:get, Weather::ZipCodeClient::ENDPOINT).with(query: hash_including(name: "021")).to_return(status: 503)
    fill_in "Address or ZIP code", with: "021"
    assert_selector "#zip-status", text: "unavailable"
    fill_in "Address or ZIP code", with: "02108"
    click_on "Check the weather"
    assert_selector "#forecast-heading", text: "Boston, Massachusetts"
  end

  test "short prefixes do not request suggestions and results follow the latest input" do
    fill_in "Address or ZIP code", with: "02"
    assert_no_selector "[role=option]"
    fill_in "Address or ZIP code", with: "373"
    assert_selector "[role=option]", text: "Athens"
    fill_in "Address or ZIP code", with: "021"
    assert_selector "[role=option]", text: "Boston"
    assert_no_selector "[role=option]", text: "Athens"
    assert_not_requested :get, Weather::ZipCodeClient::ENDPOINT, query: hash_including(name: "02")
  end

  private

  def address
    find("#address")
  end

  def stub_zip(prefix, city, state, postcodes, id:)
    place = { id: id, name: city, admin1: state, country_code: "US", postcodes: postcodes, latitude: 42.36, longitude: -71.06 }
    stub_request(:get, Weather::ZipCodeClient::ENDPOINT).with(query: hash_including(name: prefix)).to_return(body: {
      results: [ place ]
    }.to_json)
    stub_request(:get, Weather::ZipCodeClient::LOCATION_ENDPOINT).with(query: hash_including(id: id.to_s)).to_return(body: place.to_json)
  end

  def stub_weather
    stub_request(:get, Weather::OpenMeteoClient::ENDPOINT).with(query: hash_including(daily: "temperature_2m_max,temperature_2m_min")).to_return(body: {
      current: { temperature_2m: 70, time: "2026-09-12T10:15" }, current_units: { temperature_2m: "°F" }, timezone: "America/New_York",
      daily: { time: [ "2026-09-12" ], temperature_2m_max: [ 80 ], temperature_2m_min: [ 55 ] },
      daily_units: { temperature_2m_max: "°F", temperature_2m_min: "°F" }
    }.to_json)
  end
end
