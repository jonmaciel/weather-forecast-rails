module Weather
  class Forecast
    CACHE_TTL = 30.minutes

    def initialize(geocoder: CensusClient.new, weather: OpenMeteoClient.new, cache: Rails.cache, zip_lookup: ZipCodeClient.new)
      @zip_lookup = zip_lookup
      @geocoder = geocoder
      @weather = weather
      @cache = cache
    end

    def call(address:)
      unless address.is_a?(String) && address.strip.present? && address.length <= 300
        raise Error.new("invalid_address", "Enter a US address or ZIP code of up to 300 characters.", status: :unprocessable_content)
      end
      input = address.strip
      location = if input.match?(/\A\d{5}(?:-\d{4})?\z/)
        @zip_lookup.lookup(input[0, 5])
      elsif input.match?(/\A[\d\s-]+\z/)
        raise Error.new("invalid_zip", "Enter a five-digit ZIP code, optionally followed by a four-digit extension (12345-6789).", status: :unprocessable_content)
      else
        @geocoder.lookup(input)
      end
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
