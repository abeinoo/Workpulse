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

# The app sets `html { scroll-behavior: smooth }`, so the scroll Selenium makes
# before every click animates, and ChromeDriver can dispatch the click at
# coordinates measured mid-scroll: it lands on a neighbouring element and is
# silently lost (e.g. expense_duplicate_branch_spec's "add branch" click hit the
# empty-state text; expense_register_payment_spec's checkbox click hit the notes
# field). Turn smooth scrolling off for every document the system-test browser
# loads. The style goes on <html>, which Turbo visits keep, so it also survives
# Turbo navigation.
module SystemSpecBrowser
  NO_SMOOTH_SCROLL = <<~JS.freeze
    (() => {
      const apply = () => {
        const style = document.createElement("style");
        style.textContent = "html { scroll-behavior: auto !important; }";
        document.documentElement.appendChild(style);
      };
      if (document.documentElement) apply();
      else document.addEventListener("readystatechange", apply, { once: true });
    })();
  JS

  # Registered once per Chrome session (Capybara reuses one across examples);
  # it then applies to every new document in that session.
  def self.disable_smooth_scroll(browser)
    return unless browser.respond_to?(:execute_cdp)
    return if @registered_for.equal?(browser)

    browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: NO_SMOOTH_SCROLL)
    @registered_for = browser
  end
end

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :selenium_chrome_headless_local
    SystemSpecBrowser.disable_smooth_scroll(page.driver.browser)
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
