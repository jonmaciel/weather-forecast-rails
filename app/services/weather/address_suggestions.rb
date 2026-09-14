module Weather
  class AddressSuggestions
    TTL = 1.hour
    PURPOSE = "address_selection"

    def initialize(client: PhotonClient.new, cache: Rails.cache, verifier: Rails.application.message_verifier(PURPOSE))
      @client = client
      @cache = cache
      @verifier = verifier
    end

    def call(address)
      unless address.is_a?(String) && address.strip.length.between?(6, 300) && address.match?(/[[:alpha:]]/)
        raise Error.new("invalid_address_query", "Enter at least six characters of a street address.", status: :unprocessable_content)
      end

      query = address.strip.gsub(/\s+/, " ")
      locations = @cache.fetch([ "address-suggestions", "v1", query.downcase ], expires_in: TTL) do
        @client.suggestions(query)
      end
      locations.map do |location|
        { label: location.fetch(:address), zip: location.fetch(:postal_code),
          token: @verifier.generate(location.stringify_keys, purpose: PURPOSE, expires_in: TTL) }
      end
    end

    def resolve(token, address:)
      # Only locations validated by the provider adapter can be signed by this app.
      location = @verifier.verified(token, purpose: PURPOSE) if token.is_a?(String) && token.bytesize <= 4096
      unless location.is_a?(Hash) && location["address"] == address
        raise Error.new("invalid_address_selection", "That address selection is invalid or expired. Edit the field and select an address again.", status: :unprocessable_content)
      end

      location.symbolize_keys
    end
  end
end
