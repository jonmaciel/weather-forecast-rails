module Weather
  class ZipCodeClient
    ENDPOINT = "https://geocoding-api.open-meteo.com/v1/search"
    LOCATION_ENDPOINT = "https://geocoding-api.open-meteo.com/v1/get"
    MAX_LOCATION_ID = 2_147_483_647 # The provider accepts signed 32-bit IDs.

    def initialize(http: HttpClient.new)
      @http = http
    end

    def suggestions(prefix)
      suggestions = search(prefix).flat_map do |result|
        next [] unless result["country_code"] == "US"
        # Suggestions and lookups validate the same provider location fields.
        location = location_details(result)
        zips = postcodes(result).select { |zip| zip.is_a?(String) && zip.match?(/\A\d{5}\z/) && zip.start_with?(prefix) }
        zips.map do |zip|
          { zip: zip, label: location.fetch(:display_name), location_id: result.fetch("id").to_s }
        end
      end
      suggestions.uniq.sort_by { |item| [ item.fetch(:zip), item.fetch(:label), item.fetch(:location_id) ] }.first(5)
    rescue KeyError, TypeError
      raise Error.new("invalid_provider_response", "The ZIP lookup service returned an invalid response.")
    end

    def lookup(zip, location_id: nil)
      validate_location_id!(location_id)
      unless location_id.nil?
        match = @http.get(LOCATION_ENDPOINT, id: location_id)
        raise invalid_selection if match.empty?
        location = location_from(match, zip)
        unless match.fetch("id").to_s == location_id && match.fetch("country_code") == "US" && postcodes(match).include?(zip)
          raise invalid_selection
        end
        return location
      end

      matches = search(zip).select do |result|
        result["country_code"] == "US" && postcodes(result).include?(zip)
      end
      if matches.empty?
        raise Error.new("zip_not_found", "ZIP code not found. Check the ZIP or try a full US street address.", status: :unprocessable_content)
      end
      if matches.length > 1
        raise Error.new("ambiguous_zip", "This ZIP matches multiple locations. Select a suggestion or enter a full street address.", status: :unprocessable_content)
      end

      location_from(matches.first, zip)
    rescue Error => error
      # /get reports unknown IDs as HTTP 400; outages retain their original error.
      raise invalid_selection if location_id && error.provider_status == 400
      raise
    rescue KeyError, TypeError
      raise Error.new("invalid_provider_response", "The ZIP lookup service returned an invalid response.")
    end

    def validate_location_id!(location_id)
      return if location_id.nil?

      unless location_id.is_a?(String) && location_id.match?(/\A[1-9]\d{0,9}\z/) && location_id.to_i <= MAX_LOCATION_ID
        raise invalid_selection
      end
    end

    private

    def search(query)
      data = @http.get(ENDPOINT, name: query, countryCode: "US", count: 100, language: "en", format: "json")
      results = data.fetch("results", [])
      raise TypeError unless results.is_a?(Array) && results.all? { |result| result.is_a?(Hash) }
      results
    end

    def postcodes(match)
      values = match.fetch("postcodes", [])
      raise TypeError unless values.is_a?(Array)
      values
    end

    def location_from(match, zip)
      location = location_details(match)
      { **location, address: "#{location.fetch(:display_name)} #{zip}", country: "US", postal_code: zip }
    end

    def location_details(match)
      id = match.fetch("id")
      name = match.fetch("name")
      state = match.fetch("admin1")
      latitude = match.fetch("latitude")
      longitude = match.fetch("longitude")
      raise TypeError unless id.is_a?(Integer) && id.between?(1, MAX_LOCATION_ID)
      raise TypeError unless name.is_a?(String) && name.present? && state.is_a?(String) && state.present?
      raise TypeError unless latitude.is_a?(Numeric) && latitude.finite? && latitude.between?(-90, 90)
      raise TypeError unless longitude.is_a?(Numeric) && longitude.finite? && longitude.between?(-180, 180)

      { display_name: "#{name}, #{state}", latitude: latitude, longitude: longitude }
    end

    def invalid_selection
      Error.new("invalid_zip_selection", "That location no longer matches this ZIP. Select a suggestion again or enter a full street address.", status: :unprocessable_content)
    end
  end
end
