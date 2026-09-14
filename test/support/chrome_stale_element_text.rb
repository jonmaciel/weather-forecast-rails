module ChromeStaleElementText
  def visible_text
    super
  rescue Selenium::WebDriver::Error::UnknownError => error
    # ChromeDriver can misclassify a detached node during Get Element Text.
    # Let Capybara's existing bounded synchronization re-query that element.
    raise unless error.message.include?("unhandled inspector error") &&
      error.message.include?("Node with given id does not belong to the document")

    raise Selenium::WebDriver::Error::StaleElementReferenceError, error.message, error.backtrace
  end
end
