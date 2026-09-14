module Weather
  class Error < StandardError
    attr_reader :code, :status, :provider_status

    def initialize(code, message, status: :bad_gateway, provider_status: nil)
      @code = code
      @status = status
      @provider_status = provider_status
      super(message)
    end
  end
end
