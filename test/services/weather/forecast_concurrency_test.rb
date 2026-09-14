require "test_helper"
require "timeout"

class Weather::ForecastConcurrencyTest < ActiveSupport::TestCase
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @threads = []
    @calls = Queue.new
    @started = Queue.new
    @release = Queue.new
    @locations = {
      "123 Main St, Boston, MA" => location("123 MAIN ST, BOSTON, MA, 02108", "02108", 42.36),
      "125 Main St, Boston, MA" => location("125 MAIN ST, BOSTON, MA, 02108", "02108", 42.361),
      "127 Main St, Boston, MA" => location("127 MAIN ST, BOSTON, MA, 02108", "02108", 42.362),
      "10 Water St, Boston, MA" => location("10 WATER ST, BOSTON, MA, 02109", "02109", 42.363)
    }
    locations = @locations
    @geocoder = Object.new
    @geocoder.define_singleton_method(:lookup) { |address| locations.fetch(address) }

    calls, started, release = @calls, @started, @release
    @weather = Object.new
    @weather.define_singleton_method(:forecast) do |**coordinates|
      calls << coordinates
      started << coordinates
      response = release.pop
      raise response if response.is_a?(Exception)

      response
    end
  end

  teardown do
    @threads.each(&:kill)
    @threads.each { |thread| thread.join(2) }
  end

  test "separate service instances share one cold weather lookup while keeping each caller's location" do
    addresses = @locations.keys.first(3)
    leader = forecast_async(addresses.first)
    assert_equal({ latitude: 42.36, longitude: -71.06 }, await_weather)
    waiters = addresses.drop(1).map { |address| forecast_async(address) }
    await_waiting(*waiters)
    assert_equal 1, @calls.size
    @release << weather_data(70)

    [ leader, *waiters ].each_with_index do |thread, index|
      result = outcome(thread)
      assert_equal @locations.fetch(addresses.fetch(index)), result.fetch(:location)
      assert_equal weather_data(70), result.slice(:current, :daily)
      assert_equal !index.zero?, result.fetch(:from_cache)
    end

    assert_equal true, outcome(forecast_async(addresses.last)).fetch(:from_cache)
    assert_equal 1, @calls.size
  end

  test "a pending weather lookup does not hold up another ZIP" do
    first = forecast_async(@locations.keys.first)
    await_weather
    other_zip = forecast_async(@locations.keys.last)
    assert_equal({ latitude: 42.363, longitude: -71.06 }, await_weather)
    assert_equal 2, @calls.size
    2.times { @release << weather_data(70) }

    assert_equal false, outcome(first).fetch(:from_cache)
    assert_equal false, outcome(other_zip).fetch(:from_cache)
  end

  test "separate cache instances do not share an in-flight weather result" do
    first = forecast_async(@locations.keys.first)
    await_weather
    other_cache = forecast_async(@locations.keys.first, cache: ActiveSupport::Cache::MemoryStore.new)
    await_weather
    assert_equal 2, @calls.size
    2.times { @release << weather_data(70) }

    assert_equal false, outcome(first).fetch(:from_cache)
    assert_equal false, outcome(other_cache).fetch(:from_cache)
  end

  test "waiting callers share a provider failure and a later request can recover without cached errors" do
    addresses = @locations.keys.first(3)
    leader = forecast_async(addresses.first)
    await_weather
    waiters = addresses.drop(1).map { |address| forecast_async(address) }
    await_waiting(*waiters)
    @release << Weather::Error.new("provider_unavailable", "Temporarily unavailable")

    [ leader, *waiters ].each do |thread|
      error = outcome(thread)
      assert_kind_of Weather::Error, error
      assert_equal "provider_unavailable", error.code
    end
    assert_equal 1, @calls.size

    recovery = forecast_async(addresses.last)
    await_weather
    @release << weather_data(72)
    recovered = outcome(recovery)
    assert_equal false, recovered.fetch(:from_cache)
    assert_equal 72, recovered.dig(:current, :temperature)
    cached = outcome(forecast_async(addresses.first))
    assert_equal true, cached.fetch(:from_cache)
    assert_equal recovered.fetch(:current), cached.fetch(:current)
    assert_equal 2, @calls.size
  end

  test "concurrent callers refresh once at exactly thirty minutes without serving expired weather" do
    travel_to Time.zone.local(2026, 9, 14, 10, 0, 0) do
      addresses = @locations.keys.first(3)
      initial = forecast_async(addresses.first)
      await_weather
      @release << weather_data(70)
      assert_equal false, outcome(initial).fetch(:from_cache)

      travel 30.minutes - 1.second
      cached = outcome(forecast_async(addresses.last))
      assert_equal true, cached.fetch(:from_cache)
      assert_equal 70, cached.dig(:current, :temperature)
      assert_equal 1, @calls.size

      travel 1.second
      leader = forecast_async(addresses.first)
      await_weather
      waiters = addresses.drop(1).map { |address| forecast_async(address) }
      await_waiting(*waiters)
      assert_equal 2, @calls.size
      @release << weather_data(75)

      [ leader, *waiters ].each_with_index do |thread, index|
        refreshed = outcome(thread)
        assert_equal !index.zero?, refreshed.fetch(:from_cache)
        assert_equal weather_data(75), refreshed.slice(:current, :daily)
      end
      assert_equal 2, @calls.size
    end
  end

  private

  def location(address, zip, latitude)
    { address: address, country: "US", postal_code: zip, latitude: latitude, longitude: -71.06 }
  end

  def weather_data(temperature)
    { current: { temperature: temperature }, daily: { high: temperature + 5, low: temperature - 5 } }
  end

  def forecast_async(address, cache: @cache)
    service = Weather::Forecast.new(cache: cache, geocoder: @geocoder, weather: @weather)
    Thread.new do
      service.call(address: address)
    rescue StandardError => error
      error
    end.tap { |thread| @threads << thread }
  end

  def await_weather
    Timeout.timeout(2) { @started.pop }
  end

  def await_waiting(*threads)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until threads.all? { |thread| thread.status == "sleep" }
      flunk "Forecast callers did not start waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      Thread.pass
    end
  end

  def outcome(thread)
    assert thread.join(2), "A forecast caller did not finish within the test deadline"
    thread.value
  end
end
