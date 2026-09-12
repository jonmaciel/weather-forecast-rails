require "net/http"
require "json"

module Weather
  class HttpClient
    def get(endpoint, params)
      uri = URI(endpoint)
      uri.query = URI.encode_www_form(params)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 3
      http.read_timeout = 10
      http.write_timeout = 10
      http.max_retries = 0
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "WeatherForecast/1.0"
      response = http.request(request)

      if response.code == "429"
        raise Error.new("provider_rate_limited", "The weather services are busy. Please try again later.", status: :service_unavailable)
      end
      unless response.is_a?(Net::HTTPSuccess)
        raise Error.new("provider_unavailable", "A weather service is unavailable. Please try again later.")
      end

      data = JSON.parse(response.body)
      raise JSON::ParserError unless data.is_a?(Hash)
      data
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
      raise Error.new("provider_timeout", "A weather service took too long to respond. Please try again.", status: :gateway_timeout)
    rescue JSON::ParserError, TypeError
      raise Error.new("invalid_provider_response", "A weather service returned an invalid response.")
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::ProtocolError
      raise Error.new("provider_unavailable", "A weather service could not be reached. Please try again later.")
    end
  end
end
