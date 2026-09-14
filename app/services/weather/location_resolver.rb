require "digest/sha2"

module Weather
  class LocationResolver
    CACHE_TTL = 1.hour

    def initialize(geocoder:, zip_lookup:, address_suggestions:, cache:)
      @geocoder = geocoder
      @zip_lookup = zip_lookup
      @address_suggestions = address_suggestions
      @cache = cache
    end

    def call(address:, location_id: nil, address_token: nil)
      unless address.is_a?(String) && address.strip.present? && address.length <= 300
        raise Error.new("invalid_address", "Enter a US address or ZIP code of up to 300 characters.", status: :unprocessable_content)
      end
      input = address.strip
      # Selection signatures, expiry and labels must be checked on every request.
      return @address_suggestions.resolve(address_token, address: input) unless address_token.nil?

      if input.match?(/\A\d{5}(?:-\d{4})?\z/)
        zip = input[0, 5]
        @zip_lookup.validate_location_id!(location_id)
        @cache.fetch([ "location", "v1", "open-meteo", zip, location_id || "search" ], expires_in: CACHE_TTL) do
          @zip_lookup.lookup(zip, location_id: location_id)
        end
      elsif input.match?(/\A[\d\s-]+\z/)
        raise Error.new("invalid_zip", "Enter a five-digit ZIP code, optionally followed by a four-digit extension (12345-6789).", status: :unprocessable_content)
      else
        # Keep addresses out of cache keys and cache instrumentation logs.
        identity = Digest::SHA256.hexdigest(input.gsub(/\s+/, " ").downcase)
        @cache.fetch([ "location", "v1", "census", identity ], expires_in: CACHE_TTL) do
          @geocoder.lookup(input)
        end
      end
    end
  end
end
