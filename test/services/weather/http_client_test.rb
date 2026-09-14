require "test_helper"

class Weather::HttpClientTest < ActiveSupport::TestCase
  setup do
    @client = Weather::HttpClient.new
    @endpoint = Weather::OpenMeteoClient::ENDPOINT
  end

  test "network and TLS failures return controlled errors without leaking upstream details" do
    [ SocketError, Errno::ECONNRESET, EOFError, OpenSSL::SSL::SSLError ].each do |failure|
      request = stub_request(:get, @endpoint).to_raise(failure.new("private upstream details"))
      error = assert_raises(Weather::Error) { @client.get(@endpoint, {}) }
      assert_equal "provider_unavailable", error.code
      assert_equal :bad_gateway, error.status
      assert_not_includes error.message, "private upstream details"
      assert_requested request, times: 1
      WebMock.reset!
    end
  end

  test "connection read and write timeouts fail once and permit a later successful request" do
    [ Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout ].each do |failure|
      request = stub_request(:get, @endpoint).to_raise(failure).then.to_return(body: '{"available":true}')
      error = assert_raises(Weather::Error) { @client.get(@endpoint, {}) }
      assert_equal "provider_timeout", error.code
      assert_equal :gateway_timeout, error.status
      assert_requested request, times: 1
      assert_equal({ "available" => true }, @client.get(@endpoint, {}))
      assert_requested request, times: 2
      WebMock.reset!
    end
  end

  test "an upstream redirect never forwards a request to its destination" do
    request = stub_request(:get, @endpoint).to_return(status: 302, headers: { "Location" => "https://other.example/forecast" })
    error = assert_raises(Weather::Error) { @client.get(@endpoint, {}) }
    assert_equal "provider_unavailable", error.code
    assert_equal 302, error.provider_status
    assert_requested request, times: 1
    assert_not_requested :get, "https://other.example/forecast"
  end

  test "malformed HTTP and corrupt compressed responses become provider errors" do
    [ Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::DataError, Zlib::BufError ].each do |failure|
      request = stub_request(:get, @endpoint).to_raise(failure.new("private upstream details"))
      error = assert_raises(Weather::Error) { @client.get(@endpoint, {}) }
      assert_equal "invalid_provider_response", error.code
      assert_equal :bad_gateway, error.status
      assert_not_includes error.message, "private upstream details"
      assert_requested request, times: 1
      WebMock.reset!
    end
  end
end
