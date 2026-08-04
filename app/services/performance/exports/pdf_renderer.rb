# Thin wrapper over Grover (headless-Chrome HTML -> PDF) so callers depend on
# this interface rather than the gem directly — request specs stub .render
# instead of shelling out to a real browser, and the actual Chromium
# dependency stays isolated to this one class.
module Performance
  module Exports
    class PdfRenderer
      def self.render(html)
        Grover.new(html, format: "A4", print_background: true, prefer_css_page_size: false).to_pdf
      end
    end
  end
end
