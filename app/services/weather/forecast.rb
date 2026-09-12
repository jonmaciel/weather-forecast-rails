module Weather
  class Forecast
    CACHE_TTL = 30.minutes

    def initialize(geocoder: CensusClient.new, weather: OpenMeteoClient.new, cache: Rails.cache)
      @geocoder = geocoder
      @weather = weather
      @cache = cache
    end

    def call(address:)
      unless address.is_a?(String) && address.strip.present? && address.length <= 300
        raise Error.new("invalid_address", "Enter a US street address of up to 300 characters.", status: :unprocessable_content)
      end
      location = @geocoder.lookup(address.strip)
      cache_key = [ "forecast", "v1", "open-meteo", location.fetch(:country), location.fetch(:postal_code), "fahrenheit" ]
      from_cache = true
      current = @cache.fetch(cache_key, expires_in: CACHE_TTL) do
        from_cache = false
        @weather.current(latitude: location.fetch(:latitude), longitude: location.fetch(:longitude))
      end
      { location: location, current: current, from_cache: from_cache }
    end
  end
end
