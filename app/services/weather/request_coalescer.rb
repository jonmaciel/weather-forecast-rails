module Weather
  class RequestCoalescer
    Flight = Struct.new(:condition, :done, :value, :error, keyword_init: true)
    private_constant :Flight

    def initialize(wait_timeout: 15)
      unless wait_timeout.is_a?(Numeric) && wait_timeout.real? && wait_timeout.finite? && wait_timeout.positive?
        raise ArgumentError, "wait_timeout must be finite and positive"
      end
      @wait_timeout = wait_timeout
      @mutex = Mutex.new
      @flights = {}
    end

    def call(key)
      # Register and publish atomically with respect to asynchronous thread termination.
      Thread.handle_interrupt(Exception => :never) do
        flight, leader = @mutex.synchronize do
          if (existing = @flights[key])
            [ existing, false ]
          else
            created = Flight.new(condition: ConditionVariable.new, done: false)
            @flights[key] = created
            [ created, true ]
          end
        end
        unless leader
          return Thread.handle_interrupt(Exception => :immediate) { wait_for(flight) }
        end

        # Thread termination skips rescue, so ensure still needs an error to publish.
        failure = Error.new("provider_unavailable", "A weather request could not be completed. Please try again.")
        begin
          value = Thread.handle_interrupt(Exception => :immediate) { yield }
          failure = nil
          value
        rescue Exception => error # Publish unexpected failures too, then preserve the leader's exception.
          failure = error
          raise
        ensure
          @mutex.synchronize do
            flight.value = value
            flight.error = failure
            flight.done = true
            @flights.delete(key)
            flight.condition.broadcast
          end
        end
      end
    end

    private

    def wait_for(flight)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @wait_timeout
      @mutex.synchronize do
        until flight.done
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            raise Error.new("provider_timeout", "A weather request took too long to respond. Please try again.", status: :gateway_timeout)
          end
          flight.condition.wait(@mutex, remaining)
        end
        raise flight.error if flight.error

        flight.value
      end
    end
  end
end
