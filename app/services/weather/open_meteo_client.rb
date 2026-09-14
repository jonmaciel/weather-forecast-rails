module Weather
  class OpenMeteoClient
    ENDPOINT = "https://api.open-meteo.com/v1/forecast"

    def initialize(http: HttpClient.new)
      @http = http
    end

    def forecast(latitude:, longitude:)
      data = @http.get(ENDPOINT, latitude: latitude, longitude: longitude,
        current: "temperature_2m", daily: "temperature_2m_max,temperature_2m_min", forecast_days: 1,
        temperature_unit: "fahrenheit", timezone: "auto")
      current = parse_current(data)
      { current: current, daily: parse_daily(data, current.fetch(:time)) }
    rescue KeyError, TypeError, NoMethodError, Date::Error
      raise Error.new("invalid_provider_response", "The weather service returned an invalid response.")
    end

    private

    def parse_current(data)
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
    end

    def parse_daily(data, current_time)
      daily = data.fetch("daily")
      units = data.fetch("daily_units")
      dates, highs, lows = daily.values_at("time", "temperature_2m_max", "temperature_2m_min")
      raise TypeError unless [ dates, highs, lows ].all? { |values| values.is_a?(Array) && values.length == 1 }
      date, high, low = dates.first, highs.first, lows.first
      raise TypeError unless date.is_a?(String) && date == current_time[0, 10]
      Date.iso8601(date)
      raise TypeError unless [ high, low ].all? { |value| value.is_a?(Numeric) && value.finite? } && high >= low
      raise TypeError unless units.fetch("temperature_2m_max") == "°F" && units.fetch("temperature_2m_min") == "°F"

      { date: date, high: high, low: low, unit: "°F" }
    end
  end
end
