module Weather
  class PhotonClient
    ENDPOINT = "https://photon.komoot.io/api/"
    STATE_CODES = {
      "Alabama" => "AL", "Alaska" => "AK", "Arizona" => "AZ", "Arkansas" => "AR", "California" => "CA",
      "Colorado" => "CO", "Connecticut" => "CT", "Delaware" => "DE", "District of Columbia" => "DC",
      "Florida" => "FL", "Georgia" => "GA", "Hawaii" => "HI", "Idaho" => "ID", "Illinois" => "IL",
      "Indiana" => "IN", "Iowa" => "IA", "Kansas" => "KS", "Kentucky" => "KY", "Louisiana" => "LA",
      "Maine" => "ME", "Maryland" => "MD", "Massachusetts" => "MA", "Michigan" => "MI", "Minnesota" => "MN",
      "Mississippi" => "MS", "Missouri" => "MO", "Montana" => "MT", "Nebraska" => "NE", "Nevada" => "NV",
      "New Hampshire" => "NH", "New Jersey" => "NJ", "New Mexico" => "NM", "New York" => "NY",
      "North Carolina" => "NC", "North Dakota" => "ND", "Ohio" => "OH", "Oklahoma" => "OK", "Oregon" => "OR",
      "Pennsylvania" => "PA", "Rhode Island" => "RI", "South Carolina" => "SC", "South Dakota" => "SD",
      "Tennessee" => "TN", "Texas" => "TX", "Utah" => "UT", "Vermont" => "VT", "Virginia" => "VA",
      "Washington" => "WA", "West Virginia" => "WV", "Wisconsin" => "WI", "Wyoming" => "WY"
    }.freeze

    def initialize(http: HttpClient.new)
      @http = http
    end

    def suggestions(query)
      data = @http.get(ENDPOINT, q: query, countrycode: "US", layer: "house", limit: 5, lang: "en")
      features = data.fetch("features")
      raise TypeError unless data["type"] == "FeatureCollection" && features.is_a?(Array)

      features.filter_map { |feature| location_from(feature) }
        .uniq { |location| [ location.fetch(:address).downcase, location.fetch(:postal_code) ] }.first(5)
    rescue KeyError, TypeError
      raise Error.new("invalid_provider_response", "The address suggestion service returned an invalid response.")
    end

    private

    def location_from(feature)
      return unless feature.is_a?(Hash) && feature["type"] == "Feature"
      properties = feature["properties"]
      geometry = feature["geometry"]
      return unless properties.is_a?(Hash) && geometry.is_a?(Hash) && geometry["type"] == "Point"
      return unless properties["countrycode"] == "US"

      number, street, city, state, postcode = properties.values_at("housenumber", "street", "city", "state", "postcode")
      return unless [ number, street, city, state, postcode ].all? { |value| value.is_a?(String) && value.strip.present? }
      state = state.strip
      state_code = STATE_CODES[state] || (state if STATE_CODES.value?(state))
      return unless state_code && postcode.strip.match?(/\A\d{5}(?:-\d{4})?\z/)

      coordinates = geometry["coordinates"]
      return unless coordinates.is_a?(Array) && coordinates.length >= 2
      longitude, latitude = coordinates
      return unless latitude.is_a?(Numeric) && latitude.finite? && latitude.between?(-90, 90)
      return unless longitude.is_a?(Numeric) && longitude.finite? && longitude.between?(-180, 180)

      { address: "#{number.strip} #{street.strip}, #{city.strip}, #{state_code}", country: "US",
        postal_code: postcode.strip[0, 5], latitude: latitude, longitude: longitude }
    end
  end
end
