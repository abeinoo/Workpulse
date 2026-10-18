require "capybara/rspec"

Capybara.register_driver :selenium_chrome_headless_local do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless=new")
  options.add_argument("--no-sandbox")
  options.add_argument("--disable-gpu")
  options.add_argument("--window-size=1400,1000")

  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

Capybara.javascript_driver = :selenium_chrome_headless_local
Capybara.default_max_wait_time = 5

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :selenium_chrome_headless_local
  end

  # Capybara reuses one Chrome session across examples, and a CDP viewport
  # override (Emulation.setDeviceMetricsOverride, used by the responsive specs)
  # outlives the example that set it. Left in place, a 390px mobile override
  # silently becomes the next example's viewport (e.g. the purchase-request specs
  # then see the phone layout). Reset it so every example starts at the
  # configured window size. Config-level after hooks run after the group-level
  # teardown, so failure screenshots still capture the emulated viewport.
  config.after(:each, type: :system) do
    browser = page.driver.browser
    browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if browser.respond_to?(:execute_cdp)
  end
end
