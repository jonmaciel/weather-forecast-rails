module Weather
  class ZipCodeClient
    ENDPOINT = "https://geocoding-api.open-meteo.com/v1/search"

    def initialize(http: HttpClient.new)
      @http = http
    end

    def lookup(zip)
      data = @http.get(ENDPOINT, name: zip, countryCode: "US", count: 100, language: "en", format: "json")
      results = data.fetch("results", [])
      raise TypeError unless results.is_a?(Array)
      matches = results.select do |result|
        raise TypeError unless result.is_a?(Hash)
        postcodes = result.fetch("postcodes", [])
        raise TypeError unless postcodes.is_a?(Array)
        result["country_code"] == "US" && postcodes.include?(zip)
      end
      if matches.empty?
        raise Error.new("zip_not_found", "ZIP code not found. Check the ZIP or try a full US street address.", status: :unprocessable_content)
      end
      if matches.length > 1
        raise Error.new("ambiguous_zip", "This ZIP matches multiple locations. Please enter a full street address.", status: :unprocessable_content)
      end

      match = matches.first
      name = match.fetch("name")
      state = match.fetch("admin1")
      latitude = match.fetch("latitude")
      longitude = match.fetch("longitude")
      raise TypeError unless name.is_a?(String) && name.present? && state.is_a?(String) && state.present?
      raise TypeError unless latitude.is_a?(Numeric) && latitude.finite? && latitude.between?(-90, 90)
      raise TypeError unless longitude.is_a?(Numeric) && longitude.finite? && longitude.between?(-180, 180)

      { address: "#{name}, #{state} #{zip}", country: "US", postal_code: zip, latitude: latitude, longitude: longitude }
    rescue KeyError, TypeError
      raise Error.new("invalid_provider_response", "The ZIP lookup service returned an invalid response.")
    end
  end
end
