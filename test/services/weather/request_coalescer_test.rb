require "test_helper"
require "timeout"

class Weather::RequestCoalescerTest < ActiveSupport::TestCase
  setup do
    @coalescer = Weather::RequestCoalescer.new
    @threads = []
    @started = Queue.new
    @release = Queue.new
  end

  teardown do
    @threads.each(&:kill)
    @threads.each { |thread| thread.join(2) }
  end

  test "wait timeout must be finite and positive" do
    [ nil, 0, -1, Float::INFINITY, Float::NAN, Complex(1, 1) ].each do |timeout|
      assert_raises(ArgumentError) { Weather::RequestCoalescer.new(wait_timeout: timeout) }
    end
  end

  test "overlapping callers share one result and completed flights do not cache it" do
    result = { temperature: 70 }
    leader = async_call("02108") do
      @started << true
      @release.pop
      result
    end
    await_start
    waiters = 2.times.map { async_call("02108") { raise "A waiter must not run its block" } }
    await_waiting(*waiters)
    @release << true

    assert_same result, outcome(leader)
    waiters.each { |thread| assert_same result, outcome(thread) }
    assert_equal :new_result, @coalescer.call("02108") { :new_result }
  end

  test "provider failures are shared with current waiters and a later call can recover" do
    error = Weather::Error.new("provider_unavailable", "Temporarily unavailable")
    leader = async_call("02108") do
      @started << true
      @release.pop
      raise error
    end
    await_start
    waiters = 2.times.map { async_call("02108") { raise "A waiter must not retry the failed request" } }
    await_waiting(*waiters)
    @release << true

    assert_same error, outcome(leader)
    waiters.each { |thread| assert_same error, outcome(thread) }
    assert_equal :recovered, @coalescer.call("02108") { :recovered }
  end

  test "a blocked request does not block a different key or cache instance" do
    first_cache = Object.new
    second_cache = Object.new
    leader = async_call([ first_cache, "02108" ]) do
      @started << true
      @release.pop
      :first
    end
    await_start

    other_zip = async_call([ first_cache, "02109" ]) { :other_zip }
    other_cache = async_call([ second_cache, "02108" ]) { :other_cache }
    assert_equal :other_zip, outcome(other_zip)
    assert_equal :other_cache, outcome(other_cache)

    @release << true
    assert_equal :first, outcome(leader)
  end

  test "a waiter timeout does not remove or replace an active leader" do
    @coalescer = Weather::RequestCoalescer.new(wait_timeout: 0.1)
    leader = async_call("02108") do
      @started << true
      @release.pop
      :completed
    end
    await_start
    timed_out = async_call("02108") { raise "A waiter must not replace the leader" }
    error = outcome(timed_out)
    assert_kind_of Weather::Error, error
    assert_equal "provider_timeout", error.code
    assert_equal :gateway_timeout, error.status

    later_waiter = async_call("02108") { raise "The active leader must still own the key" }
    await_waiting(later_waiter)
    @release << true
    assert_equal :completed, outcome(leader)
    assert_equal :completed, outcome(later_waiter)
  end

  test "an unexpected leader exception releases waiters and permits another request" do
    error = RuntimeError.new("Unexpected provider adapter failure")
    leader = async_call("02108") do
      @started << true
      @release.pop
      raise error
    end
    await_start
    waiter = async_call("02108") { raise "A waiter must not run its block" }
    await_waiting(waiter)
    @release << true

    assert_same error, outcome(leader)
    assert_same error, outcome(waiter)
    assert_equal :recovered, @coalescer.call("02108") { :recovered }
  end

  test "terminating the leader releases waiters and removes the flight" do
    leader = async_call("02108") do
      @started << true
      @release.pop
    end
    await_start
    waiter = async_call("02108") { raise "A waiter must not run its block" }
    await_waiting(waiter)
    leader.kill
    assert leader.join(2), "The leader did not terminate"

    error = outcome(waiter)
    assert_kind_of Weather::Error, error
    assert_equal "provider_unavailable", error.code
    assert_equal :bad_gateway, error.status
    assert_equal :recovered, @coalescer.call("02108") { :recovered }
  end

  private

  def async_call(key, &block)
    Thread.new do
      @coalescer.call(key, &block)
    rescue StandardError => error
      error
    end.tap { |thread| @threads << thread }
  end

  def await_start
    Timeout.timeout(2) { @started.pop }
  end

  def await_waiting(*threads)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until threads.all? { |thread| thread.status == "sleep" }
      flunk "Callers did not start waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      Thread.pass
    end
  end

  def outcome(thread)
    assert thread.join(2), "A caller did not finish within the test deadline"
    thread.value
  end
end
