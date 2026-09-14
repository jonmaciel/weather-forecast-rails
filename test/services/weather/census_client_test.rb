require "test_helper"

class Weather::CensusClientTest < ActiveSupport::TestCase
  setup do
    @client = Weather::CensusClient.new
    @match = {
      "matchedAddress" => "600 S CLARK ST, CHICAGO, IL, 60605",
      "addressComponents" => { "state" => "IL", "zip" => "60605", "streetName" => "CLARK", "preDirection" => "S" },
      "coordinates" => { "x" => -87.630751903075, "y" => 41.874467545529 }
    }
  end

  test "rejects Census changing North Clark to South Clark" do
    request = stub_census("600 N Clark St, Chicago, IL")
    error = assert_raises(Weather::Error) { @client.lookup("600 N Clark St, Chicago, IL") }
    assert_equal "address_mismatch", error.code
    assert_equal :unprocessable_content, error.status
    assert_requested request, times: 1
  end

  test "compares abbreviated spelled out and dotted directions without case sensitivity" do
    { "n." => "South", "south" => "N", "E" => "WEST", "west" => "E",
      "N.E." => "NW", "northwest" => "SE", "southeast" => "SW", "SW" => "NE" }.each do |input_direction, matched_direction|
      @match["addressComponents"]["preDirection"] = matched_direction
      address = "600 #{input_direction} Clark St, Chicago, IL"
      stub_census(address)
      error = assert_raises(Weather::Error) { @client.lookup(address) }
      assert_equal "address_mismatch", error.code
    end
  end

  test "accepts equivalent directions" do
    @match["addressComponents"]["preDirection"] = "North"
    @match["matchedAddress"] = "600 N CLARK ST, CHICAGO, IL, 60654"
    @match["addressComponents"]["zip"] = "60654"
    stub_census("600 N. Clark St, Chicago, IL")
    location = @client.lookup("600 N. Clark St, Chicago, IL")
    assert_equal "600 N CLARK ST, CHICAGO, IL, 60654", location.fetch(:address)
    assert_equal "60654", location.fetch(:postal_code)
  end

  test "does not interpret North Avenue as a directional prefix" do
    @match["addressComponents"].merge!("streetName" => "NORTH", "preDirection" => "W")
    @match["matchedAddress"] = "600 W NORTH AVE, CHICAGO, IL, 60605"
    stub_census("600 North Avenue, Chicago, IL")
    assert_equal @match.fetch("matchedAddress"), @client.lookup("600 North Avenue, Chicago, IL").fetch(:address)
  end

  test "handles multiword street names when identifying a direction conflict" do
    @match["addressComponents"]["streetName"] = "MARTIN LUTHER KING"
    address = "600 North Martin Luther King Blvd, Chicago, IL"
    stub_census(address)
    error = assert_raises(Weather::Error) { @client.lookup(address) }
    assert_equal "address_mismatch", error.code
  end

  test "preserves addresses without an explicit direction and providers without optional direction fields" do
    stub_census("600 Clark St, Chicago, IL")
    assert_equal @match.fetch("matchedAddress"), @client.lookup("600 Clark St, Chicago, IL").fetch(:address)

    @match["addressComponents"].delete("preDirection")
    @match["addressComponents"].delete("streetName")
    stub_census("600 N Clark St, Chicago, IL")
    assert_equal @match.fetch("matchedAddress"), @client.lookup("600 N Clark St, Chicago, IL").fetch(:address)
  end

  test "rejects malformed optional direction fields as a provider error" do
    [ [ "preDirection", [] ], [ "preDirection", 1 ], [ "streetName", {} ] ].each do |key, value|
      original = @match["addressComponents"][key]
      @match["addressComponents"][key] = value
      stub_census("600 N Clark St, Chicago, IL")
      error = assert_raises(Weather::Error) { @client.lookup("600 N Clark St, Chicago, IL") }
      assert_equal "invalid_provider_response", error.code
      assert_equal :bad_gateway, error.status
      @match["addressComponents"][key] = original
    end
  end

  private

  def stub_census(address)
    stub_request(:get, Weather::CensusClient::ENDPOINT)
      .with(query: { address: address, benchmark: "Public_AR_Current", format: "json" })
      .to_return(body: { result: { addressMatches: [ @match ] } }.to_json)
  end
end
