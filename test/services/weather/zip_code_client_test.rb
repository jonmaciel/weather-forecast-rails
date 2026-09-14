require "test_helper"

class Weather::ZipCodeClientTest < ActiveSupport::TestCase
  setup do
    @client = Weather::ZipCodeClient.new
    @place = {
      id: 5110302, name: "Brooklyn", admin1: "New York", country_code: "US",
      postcodes: [ "11201" ], latitude: 40.65, longitude: -73.95
    }
  end

  test "each locality suggested for an ambiguous ZIP can be resolved by its own provider ID" do
    park = @place.merge(id: 8449753, name: "Brooklyn Bridge Park", latitude: 40.7, longitude: -73.996)
    places = [ @place, park ]
    search = stub_search(places)
    suggestions = @client.suggestions("11201")
    assert_equal places.map { |place| {
      zip: "11201", label: "#{place.fetch(:name)}, New York", location_id: place.fetch(:id).to_s
    } }.sort_by { |item| item.fetch(:label) }, suggestions

    places.each do |place|
      request = stub_location(place)
      result = @client.lookup("11201", location_id: place.fetch(:id).to_s)
      assert_equal "#{place.fetch(:name)}, New York", result.fetch(:display_name)
      assert_equal "11201", result.fetch(:postal_code)
      assert_equal place.fetch(:latitude), result.fetch(:latitude)
      assert_equal place.fetch(:longitude), result.fetch(:longitude)
      assert_requested request, times: 1
    end
    assert_requested search, times: 1
  end

  test "malformed selected IDs are rejected before making a provider request" do
    [ "", "0", "-1", "01", "1.5", "5110302suffix", "2147483648", "1" * 17,
      5110302, false, [ "5110302" ] ].each do |id|
      assert_selection_error { @client.lookup("11201", location_id: id) }
    end
    assert_not_requested :get, /geocoding-api.open-meteo.com/
  end

  test "unknown IDs and selections outside the ZIP or country never fall back to a search result" do
    [ {}, @place.merge(id: 8449753), @place.merge(country_code: "CA"), @place.merge(postcodes: [ "11202" ]) ].each do |payload|
      stub_location(payload, id: "5110302")
      assert_selection_error { @client.lookup("11201", location_id: "5110302") }
    end
    assert_not_requested :get, /\A#{Regexp.escape(Weather::ZipCodeClient::ENDPOINT)}(?:\?|\z)/
  end

  test "malformed location responses produce controlled provider errors" do
    [ @place.merge(id: nil), @place.merge(id: 5110302.5), @place.merge(id: "5110302"),
      @place.merge(latitude: nil), @place.merge(longitude: 181), @place.merge(name: ""), @place.merge(postcodes: nil) ].each do |payload|
      stub_location(payload, id: "5110302")
      error = assert_raises(Weather::Error) { @client.lookup("11201", location_id: "5110302") }
      assert_equal "invalid_provider_response", error.code
      assert_equal :bad_gateway, error.status
    end
    assert_not_requested :get, /\A#{Regexp.escape(Weather::ZipCodeClient::ENDPOINT)}(?:\?|\z)/
  end

  test "an unknown provider ID is a selection error while outages and rate limits remain provider errors" do
    [ [ 400, "invalid_zip_selection", :unprocessable_content ],
      [ 503, "provider_unavailable", :bad_gateway ],
      [ 429, "provider_rate_limited", :service_unavailable ] ].each do |status, code, expected_status|
      stub_request(:get, Weather::ZipCodeClient::LOCATION_ENDPOINT).with(query: { id: "5110302" })
        .to_return(status: status, body: { error: true, reason: "Location ID not found." }.to_json)
      error = assert_raises(Weather::Error) { @client.lookup("11201", location_id: "5110302") }
      assert_equal code, error.code
      assert_equal expected_status, error.status
    end
    assert_not_requested :get, /\A#{Regexp.escape(Weather::ZipCodeClient::ENDPOINT)}(?:\?|\z)/
  end

  test "suggestions validate provider IDs and coordinates before offering a locality" do
    [ @place.merge(id: nil), @place.merge(id: "5110302"), @place.merge(id: 0),
      @place.merge(latitude: "40.65"), @place.merge(latitude: 91), @place.merge(longitude: -181) ].each do |place|
      stub_search([ place ])
      error = assert_raises(Weather::Error) { @client.suggestions("11201") }
      assert_equal "invalid_provider_response", error.code
      assert_equal :bad_gateway, error.status
    end
  end

  private

  def assert_selection_error
    error = assert_raises(Weather::Error) { yield }
    assert_equal "invalid_zip_selection", error.code
    assert_equal :unprocessable_content, error.status
  end

  def stub_search(places)
    stub_request(:get, Weather::ZipCodeClient::ENDPOINT).with(query: {
      name: "11201", countryCode: "US", count: "100", language: "en", format: "json"
    }).to_return(body: { results: places }.to_json)
  end

  def stub_location(payload, id: payload.fetch(:id).to_s)
    stub_request(:get, Weather::ZipCodeClient::LOCATION_ENDPOINT).with(query: { id: id })
      .to_return(body: payload.to_json)
  end
end
