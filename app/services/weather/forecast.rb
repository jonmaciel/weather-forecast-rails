module Weather
  class Forecast
    def initialize(geocoder: CensusClient.new, weather: OpenMeteoClient.new)
      @geocoder = geocoder
      @weather = weather
    end

    def call(address:)
      unless address.is_a?(String) && address.strip.present? && address.length <= 300
        raise Error.new("invalid_address", "Enter a US street address of up to 300 characters.", status: :unprocessable_content)
      end
      location = @geocoder.lookup(address.strip)
      current = @weather.current(latitude: location.fetch(:latitude), longitude: location.fetch(:longitude))
      { location: location, current: current }
    end
  end
end
