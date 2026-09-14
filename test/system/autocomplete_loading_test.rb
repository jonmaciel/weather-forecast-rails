require "application_system_test_case"

class AutocompleteLoadingTest < ApplicationSystemTestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    visit root_path
    page.execute_script <<~JS
      window.autocompleteRequests = [];
      window.fetch = (url, options = {}) => new Promise(resolve => {
        const query = options.body ? JSON.parse(options.body).address : new URL(url).searchParams.get('zip');
        // Deliberately ignore cancellation so late responses exercise the generation guard.
        window.autocompleteRequests.push({ query, signal: options.signal, resolve });
        document.documentElement.dataset.autocompleteRequests = String(window.autocompleteRequests.length);
      });
    JS
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "typing replaces options with an inline loader without closing or shrinking the popup" do
    fill_in "Address or ZIP code", with: "373"
    wait_for_requests(1)
    resolve_request("373", [ zip_option("37303"), zip_option("37304") ])
    assert_selector "#zip-options [role=option]", count: 2
    address.send_keys(:arrow_down)
    assert_selector "#address[aria-activedescendant]"
    previous_height = find("#zip-suggestion").rect.height
    observe_popup_visibility

    address.send_keys("0")
    assert_selector "#zip-suggestion #zip-feedback .zip-spinner"
    assert_no_selector "#zip-options [role=option]"
    assert_no_selector "#address[aria-activedescendant]"
    assert_selector "#address[aria-expanded=true]"
    assert_operator find("#zip-suggestion").rect.height, :>=, previous_height - 1
    wait_for_requests(2)

    address.send_keys(:arrow_down)
    assert_equal false, page.evaluate_script("window.autocompleteRequests[1].signal.aborted")
    assert_field "address", with: "3730"
    resolve_request("3730", [ zip_option("37305") ])
    assert_selector "#zip-options [role=option]", text: "37305", count: 1
    assert_no_selector ".zip-spinner"
    assert_equal 2, page.evaluate_script("window.autocompleteRequests.length")
    assert_equal [], page.evaluate_script("window.autocompleteVisibilityChanges")
  end

  test "out of order responses stay stale and dismissed loading results cannot reopen the popup" do
    fill_in "Address or ZIP code", with: "600 N Clark St"
    wait_for_requests(1)
    fill_in "Address or ZIP code", with: "600 N Clark Street, Chicago"
    wait_for_requests(2)
    resolve_request("600 N Clark Street, Chicago", [ address_option("Chicago address") ])
    assert_selector "#zip-options [role=option]", text: "Chicago address"
    resolve_request("600 N Clark St", [ address_option("Outdated address") ])
    assert_selector "#zip-options [role=option]", text: "Chicago address", count: 1
    assert_no_selector "#zip-options [role=option]", text: "Outdated address"

    fill_in "Address or ZIP code", with: "02"
    assert_no_selector "#zip-suggestion"
    fill_in "Address or ZIP code", with: "600 N Clark St, Chicago, IL"
    wait_for_requests(3)
    address.send_keys(:escape)
    assert_no_selector "#zip-suggestion"
    resolve_request("600 N Clark St, Chicago, IL", [ address_option("Dismissed address") ])
    assert_no_selector "#zip-suggestion"
    assert_selector "#address[aria-expanded=false]"

    fill_in "Address or ZIP code", with: "600 N Clark St, Chicago, Illinois"
    wait_for_requests(4)
    address.send_keys(:tab)
    assert_selector ".search-button:focus"
    assert_field "address", with: "600 N Clark St, Chicago, Illinois"
    resolve_request("600 N Clark St, Chicago, Illinois", [ address_option("Blurred address") ])
    assert_no_selector "#zip-suggestion"
    assert_equal "", find("#selected_address_token", visible: :all).value
  end

  test "editing a selection clears its metadata and Enter submits the manual address while loading" do
    fill_in "Address or ZIP code", with: "600 N Clark St"
    wait_for_requests(1)
    resolve_request("600 N Clark St", [ address_option("600 North Clark Street, Chicago, IL") ])
    find("#zip-options [role=option]").click
    assert_equal "address-token", find("#selected_address_token", visible: :all).value

    manual = "4600 Silver Hill Rd, Washington, DC 20233"
    census = stub_request(:get, Weather::CensusClient::ENDPOINT).with(query: hash_including(address: manual)).to_return(body: {
      result: { addressMatches: [ { matchedAddress: manual, addressComponents: { state: "DC", zip: "20233" }, coordinates: { x: -76.93, y: 38.85 } } ] }
    }.to_json)
    stub_request(:get, Weather::OpenMeteoClient::ENDPOINT).with(query: hash_including(latitude: "38.85", longitude: "-76.93")).to_return(body: {
      current: { temperature_2m: 70, time: "2026-09-14T10:15" }, current_units: { temperature_2m: "°F" }, timezone: "America/New_York",
      daily: { time: [ "2026-09-14" ], temperature_2m_max: [ 80 ], temperature_2m_min: [ 55 ] },
      daily_units: { temperature_2m_max: "°F", temperature_2m_min: "°F" }
    }.to_json)

    fill_in "Address or ZIP code", with: manual
    wait_for_requests(2)
    assert_selector "#zip-suggestion #zip-feedback .zip-spinner"
    %w[selected_zip selected_label selected_location_id selected_address_token].each do |name|
      assert_equal "", find("##{name}", visible: :all).value
    end
    address.send_keys(:enter)
    assert_selector "#forecast-heading", text: manual
    assert_field "address", with: manual
    assert_requested census, times: 1
  end

  private

  def address
    find("#address")
  end

  def wait_for_requests(count)
    assert_selector "html[data-autocomplete-requests='#{count}']", visible: :all
  end

  def resolve_request(query, suggestions)
    page.evaluate_async_script(<<~JS, query, suggestions)
      const [query, suggestions, done] = arguments;
      window.autocompleteRequests.find(request => request.query === query).resolve({
        ok: true, json: async () => ({ suggestions })
      });
      // Flush response microtasks and rendering before checking an ignored late response.
      requestAnimationFrame(() => requestAnimationFrame(() => done(true)));
    JS
  end

  def observe_popup_visibility
    page.execute_script <<~JS
      window.autocompleteVisibilityChanges = [];
      const observer = new MutationObserver(records => {
        for (const record of records) {
          if (record.attributeName === 'hidden' ||
              (record.attributeName === 'aria-expanded' &&
                (record.oldValue === 'false' || record.target.getAttribute('aria-expanded') === 'false'))) {
            window.autocompleteVisibilityChanges.push(record.attributeName);
          }
        }
      });
      observer.observe(document.querySelector('#zip-suggestion'), { attributes: true, attributeFilter: ['hidden'], attributeOldValue: true });
      observer.observe(document.querySelector('#address'), { attributes: true, attributeFilter: ['aria-expanded'], attributeOldValue: true });
    JS
  end

  def zip_option(zip)
    { zip: zip, label: "Athens, Tennessee", location_id: "4611932" }
  end

  def address_option(label)
    { zip: "60654", label: label, token: "address-token" }
  end
end
