require "test_helper"
require_relative "support/chrome_stale_element_text"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Use Chrome's visibility endpoint instead of Selenium's JS atom during DOM changes.
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 1000 ], options: { native_displayed: true } do |options|
    options.binary = ENV["CHROME_BIN"] if ENV["CHROME_BIN"].present?
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--no-sandbox") if ENV["CI"].present?
  end
end

Capybara::Selenium::ChromeNode.prepend(ChromeStaleElementText)
