module Finance
  module Dashboard
    # Thin wrapper over Grover (headless-Chrome HTML -> PDF), mirroring
    # Performance::Exports::PdfRenderer so request specs can stub .render
    # instead of shelling out to a real browser.
    class PdfRenderer
      def self.render(html)
        Grover.new(html, format: "A4", print_background: true, prefer_css_page_size: false).to_pdf
      end
    end
  end
end
