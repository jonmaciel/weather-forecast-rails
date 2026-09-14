module Weather
  class CensusClient
    ENDPOINT = "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress"
    STATES = %w[AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY].freeze
    DIRECTIONS = {
      "N" => "N", "NORTH" => "N", "S" => "S", "SOUTH" => "S",
      "E" => "E", "EAST" => "E", "W" => "W", "WEST" => "W",
      "NE" => "NE", "NORTHEAST" => "NE", "NW" => "NW", "NORTHWEST" => "NW",
      "SE" => "SE", "SOUTHEAST" => "SE", "SW" => "SW", "SOUTHWEST" => "SW"
    }.freeze

    def initialize(http: HttpClient.new)
      @http = http
    end

    def lookup(address)
      data = @http.get(ENDPOINT, address: address, benchmark: "Public_AR_Current", format: "json")
      matches = data.fetch("result").fetch("addressMatches")
      raise TypeError unless matches.is_a?(Array)
      if matches.empty?
        raise Error.new("address_not_found", "Address not found. Enter a US street address with city and state or ZIP code.", status: :unprocessable_content)
      end
      if matches.length > 1
        raise Error.new("ambiguous_address", "More than one address matched. Please include city, state and ZIP code.", status: :unprocessable_content)
      end

      match = matches.first
      components = match.fetch("addressComponents")
      unless STATES.include?(components.fetch("state"))
        raise Error.new("unsupported_address", "Only addresses in the 50 US states and Washington, DC are supported.", status: :unprocessable_content)
      end
      zip = components.fetch("zip")
      unless zip.is_a?(String) && zip.match?(/\A\d{5}(?:-\d{4})?\z/)
        raise Error.new("missing_postal_code", "The address has no usable ZIP code. Please enter a more complete address.", status: :unprocessable_content)
      end
      latitude = match.fetch("coordinates").fetch("y")
      longitude = match.fetch("coordinates").fetch("x")
      label = match.fetch("matchedAddress")
      raise TypeError unless latitude.is_a?(Numeric) && latitude.finite? && latitude.between?(-90, 90)
      raise TypeError unless longitude.is_a?(Numeric) && longitude.finite? && longitude.between?(-180, 180)
      raise TypeError unless label.is_a?(String) && label.present?
      validate_direction!(address, components)

      { address: label, country: "US", postal_code: zip[0, 5], latitude: latitude, longitude: longitude }
    rescue KeyError, TypeError, NoMethodError
      raise Error.new("invalid_provider_response", "The address service returned an invalid response.")
    end

    private

    def validate_direction!(address, components)
      direction = components["preDirection"]
      street_name = components["streetName"]
      raise TypeError unless [ direction, street_name ].all? { |value| value.nil? || value.is_a?(String) }
      return if direction.blank? || street_name.blank?

      matched_direction = DIRECTIONS[direction.upcase.delete(". ")]
      raise TypeError unless matched_direction

      words = address.split(",", 2).first.upcase.delete(".").split
      return unless words.shift&.match?(/\A\d+[A-Z]?\z/)
      requested_direction = DIRECTIONS[words.shift]
      name_words = street_name.upcase.delete(".").split
      # Match the remaining street name so "North Avenue" is not read as a direction.
      return unless requested_direction && words.first(name_words.length) == name_words
      return if requested_direction == matched_direction

      raise Error.new("address_mismatch", "The address service matched a different street direction. Confirm the address or select an autocomplete suggestion.", status: :unprocessable_content)
    end
  end
end
