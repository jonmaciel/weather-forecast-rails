require "test_helper"
require "selenium-webdriver"
require_relative "chrome_stale_element_text"

class ChromeStaleElementTextTest < ActiveSupport::TestCase
  class TextNode
    prepend ChromeStaleElementText

    def initialize(result)
      @result = result
    end

    def visible_text
      raise @result if @result.is_a?(Exception)

      @result
    end
  end

  test "successful text is unchanged" do
    text = "Boston, Massachusetts"

    assert_same text, TextNode.new(text).visible_text
  end

  test "the detached document inspector error becomes a stale element error" do
    original = Selenium::WebDriver::Error::UnknownError.new(
      'unknown error: unhandled inspector error: {"code":-32000,"message":"Node with given id does not belong to the document"}'
    )
    original.set_backtrace([ "selenium/remote/bridge.rb:429:in 'element_text'" ])

    converted = assert_raises(Selenium::WebDriver::Error::StaleElementReferenceError) do
      TextNode.new(original).visible_text
    end

    assert_includes converted.message, original.message
    assert_equal original.backtrace, converted.backtrace
    assert_same original, converted.cause
  end

  test "other unknown errors remain unchanged" do
    [
      "unknown error: browser disconnected",
      "unhandled inspector error: No node with given id found",
      "Node with given id does not belong to the document"
    ].each do |message|
      original = Selenium::WebDriver::Error::UnknownError.new(message)

      error = assert_raises(Selenium::WebDriver::Error::UnknownError) do
        TextNode.new(original).visible_text
      end

      assert_same original, error
    end
  end

  test "existing stale element errors remain unchanged" do
    original = Selenium::WebDriver::Error::StaleElementReferenceError.new("detached element")

    error = assert_raises(Selenium::WebDriver::Error::StaleElementReferenceError) do
      TextNode.new(original).visible_text
    end

    assert_same original, error
  end
end
