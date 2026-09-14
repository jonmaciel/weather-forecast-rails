module Weather
  class Forecast
    CACHE_TTL = 30.minutes
    REQUESTS = RequestCoalescer.new

    def initialize(cache: Rails.cache, geocoder: CensusClient.new, weather: OpenMeteoClient.new, zip_lookup: ZipCodeClient.new,
      address_suggestions: AddressSuggestions.new(cache: cache), requests: REQUESTS)
      @locations = LocationResolver.new(geocoder: geocoder, zip_lookup: zip_lookup, address_suggestions: address_suggestions, cache: cache)
      @weather = weather
      @cache = cache
      @requests = requests
    end

    def call(address:, location_id: nil, address_token: nil)
      location = @locations.call(address: address, location_id: location_id, address_token: address_token)
      # Location stays request-specific even when callers share weather for a ZIP.
      cache_key = [ "forecast", "v2", "open-meteo", location.fetch(:country), location.fetch(:postal_code), "fahrenheit" ]
      from_cache = true
      forecast = @requests.call([ @cache, cache_key ]) do
        @cache.fetch(cache_key, expires_in: CACHE_TTL) do
          from_cache = false
          @weather.forecast(latitude: location.fetch(:latitude), longitude: location.fetch(:longitude))
        end
      end
      { location: location, **forecast, from_cache: from_cache }
    end
  end
end
