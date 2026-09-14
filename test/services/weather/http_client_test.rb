require "test_helper"

class Weather::HttpClientTest < ActiveSupport::TestCase
  setup do
    @client = Weather::HttpClient.new
    @endpoint = Weather::OpenMeteoClient::ENDPOINT
  end

  test "requests use bounded connection read and write timeouts without automatic retries" do
    http = nil
    constructor = Net::HTTP.method(:new)
    owns_constructor = Net::HTTP.singleton_class.instance_methods(false).include?(:new)
    Net::HTTP.define_singleton_method(:new) do |*arguments|
      http = constructor.call(*arguments)
    end

    request = stub_request(:get, @endpoint).to_return do
      assert http.use_ssl?
      assert_equal 3, http.open_timeout
      assert_equal 10, http.read_timeout
      assert_equal 10, http.write_timeout
      assert_equal 0, http.max_retries
      { body: '{"available":true}' }
    end

    assert_equal({ "available" => true }, @client.get(@endpoint, {}))
    assert_requested request, times: 1
  ensure
    if owns_constructor
      Net::HTTP.define_singleton_method(:new, constructor)
    else
      Net::HTTP.singleton_class.remove_method(:new)
    end
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
