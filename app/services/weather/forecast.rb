module Weather
  class Forecast
    CACHE_TTL = 30.minutes

    def initialize(geocoder: CensusClient.new, weather: OpenMeteoClient.new, cache: Rails.cache, zip_lookup: ZipCodeClient.new,
      address_suggestions: AddressSuggestions.new)
      @zip_lookup = zip_lookup
      @geocoder = geocoder
      @weather = weather
      @cache = cache
      @address_suggestions = address_suggestions
    end

    def call(address:, location_id: nil, address_token: nil)
      unless address.is_a?(String) && address.strip.present? && address.length <= 300
        raise Error.new("invalid_address", "Enter a US address or ZIP code of up to 300 characters.", status: :unprocessable_content)
      end
      input = address.strip
      location = if !address_token.nil?
        @address_suggestions.resolve(address_token, address: input)
      elsif input.match?(/\A\d{5}(?:-\d{4})?\z/)
        @zip_lookup.lookup(input[0, 5], location_id: location_id)
      elsif input.match?(/\A[\d\s-]+\z/)
        raise Error.new("invalid_zip", "Enter a five-digit ZIP code, optionally followed by a four-digit extension (12345-6789).", status: :unprocessable_content)
      else
        @geocoder.lookup(input)
      end
      # Resolve each input before reusing ZIP-level weather; location stays request-specific.
      cache_key = [ "forecast", "v2", "open-meteo", location.fetch(:country), location.fetch(:postal_code), "fahrenheit" ]
      from_cache = true
      forecast = @cache.fetch(cache_key, expires_in: CACHE_TTL) do
        from_cache = false
        @weather.forecast(latitude: location.fetch(:latitude), longitude: location.fetch(:longitude))
      end
      { location: location, **forecast, from_cache: from_cache }
    end
  end
end
