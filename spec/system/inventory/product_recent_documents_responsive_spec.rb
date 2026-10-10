require "rails_helper"

# Product page › Recent goods receipts / stock issues: a table on desktop, one
# card per document (.table-wrap--cards) at ≤768px, in both directions, with
# long Arabic names wrapping instead of widening the page. Widths via Chrome
# device emulation (headless Chrome can't shrink a real window below ~500px).
RSpec.describe "Product page recent documents — responsive layout", type: :system do
  let(:business)  { create(:business) }
  let(:admin)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "مستودع الفرع الرئيسي بجوار مسجد النور الكبير - الترعة الجديدة") }
  let(:branch)    { create(:branch, business: business, name: "صالون جدو - الترعة الجديدة بجوار مسجد النور الكبير") }
  let(:supplier)  { business.suppliers.create!(name: "شركة القاهرة لمستلزمات التجميل والعناية بالشعر المحدودة") }
  let(:product)   { business.products.create!(name: "صبغة شعر", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0) }

  let!(:receipt) do
    r = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                      funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 5, unit_cost: 10)
    r.save!
    r
  end
  let!(:issues) do
    Array.new(2) do
      i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: admin)
      i.items.build(product: product, quantity: 2)
      i.save!
      i
    end
  end

  after { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  def emulate(width, height: 1000)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def js(script) = page.evaluate_script(script)

  def visit_product(locale, width)
    admin.update!(preferred_locale: locale)
    sign_in admin
    emulate(width)
    visit inventory_product_path(product)
    expect(page).to have_css("#recent-stock-issues tbody tr", count: 2)
  end

  def row_display(section) = js("getComputedStyle(document.querySelector('##{section} tbody tr')).display")

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    [ 390, 768 ].each do |width|
      it "stacks documents as cards without horizontal overflow (#{locale}, #{width}px)" do
        visit_product(locale, width)

        expect(js("document.documentElement.dir")).to eq(dir)
        expect(js("document.documentElement.scrollWidth")).to be <= width
        %w[recent-goods-receipts recent-stock-issues].each do |section|
          expect(row_display(section)).to eq("block")
          expect(js("document.querySelector('##{section} thead').offsetParent")).to be_nil
          # Each card value carries its column label (labels never rely on the hidden header).
          labels = js("[...document.querySelectorAll('##{section} tbody tr:first-child td')].map(td => td.dataset.label)")
          expect(labels).to all(be_present)
        end

        link = find("#recent-goods-receipts a", text: receipt.receipt_number)
        expect(link.native.size.height).to be >= 24
        within("#recent-stock-issues") { expect(page).to have_link(issues.first.issue_number) }
      end
    end

    it "uses a regular table on desktop (#{locale})" do
      visit_product(locale, 1440)
      expect(js("document.documentElement.scrollWidth")).to be <= 1440
      expect(row_display("recent-stock-issues")).to eq("table-row")
      expect(find("#recent-goods-receipts thead")).to be_visible
    end
  end

  it "opens the linked document from a card" do
    visit_product("ar", 390)
    find("#recent-stock-issues a", text: issues.last.issue_number).click
    expect(page).to have_current_path(inventory_stock_issue_path(issues.last))
  end
end
