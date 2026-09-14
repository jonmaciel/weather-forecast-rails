require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 1000 ] do |options|
    options.binary = ENV["CHROME_BIN"] if ENV["CHROME_BIN"].present?
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--no-sandbox") if ENV["CI"].present?
  end
end
