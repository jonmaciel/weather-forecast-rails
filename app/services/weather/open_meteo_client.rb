module Weather
  class OpenMeteoClient
    ENDPOINT = "https://api.open-meteo.com/v1/forecast"

    def initialize(http: HttpClient.new)
      @http = http
    end

    def current(latitude:, longitude:)
      data = @http.get(ENDPOINT, latitude: latitude, longitude: longitude,
        current: "temperature_2m", temperature_unit: "fahrenheit", timezone: "auto")
      current = data.fetch("current")
      temperature = current.fetch("temperature_2m")
      unit = data.fetch("current_units").fetch("temperature_2m")
      time = current.fetch("time")
      timezone = data.fetch("timezone")
      raise TypeError unless temperature.is_a?(Numeric) && temperature.finite? && unit == "°F"
      raise TypeError unless time.is_a?(String) && time.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?\z/)
      DateTime.iso8601(time)
      raise TypeError unless timezone.is_a?(String) && timezone.present?

      { temperature: temperature, unit: unit, time: time, timezone: timezone,
        source: "Open-Meteo", source_url: "https://open-meteo.com/" }
    rescue KeyError, TypeError, NoMethodError, Date::Error
      raise Error.new("invalid_provider_response", "The weather service returned an invalid response.")
    end
  end
end
