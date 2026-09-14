require "test_helper"

class Weather::PhotonClientTest < ActiveSupport::TestCase
  setup do
    @client = Weather::PhotonClient.new
    @feature = {
      type: "Feature", geometry: { type: "Point", coordinates: [ -87.6315646, 41.8928566 ] },
      properties: { countrycode: "US", housenumber: "600", street: "North Clark Street",
        city: "Chicago", state: "Illinois", postcode: "60654" }
    }
  end

  test "normalizes complete US addresses without changing the provider street name" do
    request = stub_photon([ @feature ])
    assert_equal [ { address: "600 North Clark Street, Chicago, IL", country: "US", postal_code: "60654",
      latitude: 41.8928566, longitude: -87.6315646 } ], @client.suggestions("600 N Clark St")
    assert_requested request, times: 1
  end

  test "supports Washington DC and normalizes ZIP plus four while preserving leading zeros" do
    dc = with_properties(city: "Washington", state: "District of Columbia", postcode: "20001")
    boston = with_properties(city: "Boston", state: "MA", postcode: "02108-1234")
    stub_photon([ dc, boston ])
    locations = @client.suggestions("600 N Clark St")
    assert_equal [ "600 North Clark Street, Washington, DC", "600 North Clark Street, Boston, MA" ], locations.map { |location| location.fetch(:address) }
    assert_equal %w[20001 02108], locations.map { |location| location.fetch(:postal_code) }
  end

  test "discards incomplete foreign and unsupported addresses and invalid point coordinates" do
    features = [ nil, {}, with_properties(countrycode: "CA"), with_properties(state: "Puerto Rico"),
      with_properties(housenumber: nil), with_properties(street: ""), with_properties(city: nil),
      with_properties(postcode: "6065"), with_properties(postcode: nil),
      @feature.merge(geometry: { type: "LineString", coordinates: [ -87.6, 41.8 ] }),
      @feature.merge(geometry: { type: "Point", coordinates: [ -181, 41.8 ] }),
      @feature.merge(geometry: { type: "Point", coordinates: [ -87.6, 91 ] }),
      @feature.merge(geometry: { type: "Point", coordinates: [ "-87.6", 41.8 ] }), @feature ]
    stub_photon(features)
    assert_equal [ "600 North Clark Street, Chicago, IL" ], @client.suggestions("600 N Clark St").map { |location| location.fetch(:address) }
  end

  test "deduplicates addresses before limiting suggestions to five" do
    additional = (601..606).map { |number| with_properties(housenumber: number.to_s) }
    stub_photon([ @feature, @feature, *additional ])
    assert_equal (600..604).map { |number| "#{number} North Clark Street, Chicago, IL" },
      @client.suggestions("600 N Clark St").map { |location| location.fetch(:address) }
  end

  test "rejects invalid envelopes and accepts an empty result list" do
    [ {}, { type: "FeatureCollection", features: nil }, { type: "Feature", features: [] } ].each do |payload|
      stub_photon([], payload: payload)
      error = assert_raises(Weather::Error) { @client.suggestions("600 N Clark St") }
      assert_equal "invalid_provider_response", error.code
      assert_equal :bad_gateway, error.status
    end
    stub_photon([])
    assert_empty @client.suggestions("600 N Clark St")
  end

  test "preserves provider timeouts and rate limiting errors" do
    stub_request(:get, Weather::PhotonClient::ENDPOINT).with(query: query).to_timeout
    error = assert_raises(Weather::Error) { @client.suggestions("600 N Clark St") }
    assert_equal "provider_timeout", error.code
    assert_equal :gateway_timeout, error.status

    stub_request(:get, Weather::PhotonClient::ENDPOINT).with(query: query).to_return(status: 429)
    error = assert_raises(Weather::Error) { @client.suggestions("600 N Clark St") }
    assert_equal "provider_rate_limited", error.code
    assert_equal :service_unavailable, error.status
  end

  private

  def with_properties(**properties)
    @feature.merge(properties: @feature.fetch(:properties).merge(properties))
  end

  def query
    { q: "600 N Clark St", countrycode: "US", layer: "house", limit: "5", lang: "en" }
  end

  def stub_photon(features, payload: { type: "FeatureCollection", features: features })
    stub_request(:get, Weather::PhotonClient::ENDPOINT).with(query: query).to_return(body: payload.to_json)
  end
end
