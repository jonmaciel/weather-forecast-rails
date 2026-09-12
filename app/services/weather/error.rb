module Weather
  class Error < StandardError
    attr_reader :code, :status

    def initialize(code, message, status: :bad_gateway)
      @code = code
      @status = status
      super(message)
    end
  end
end
