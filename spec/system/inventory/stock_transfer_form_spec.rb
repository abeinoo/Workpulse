require "rails_helper"

# The redesigned transfer form in a real browser: product search, repeated
# barcode scans adding one unit, merged duplicates, live figures from the
# server, the shortage warning and summary, the warehouse pickers excluding
# each other, and the low-stock suggestions modal adding lines. Everything it
# shows comes from the server; submitting re-validates under lock.
RSpec.describe "Stock transfer form", type: :system do
  before { driven_by :selenium_chrome_headless_local }

  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:branch)  { create(:branch, business: business, name: "North", branch_type: "sales") }
  let!(:source)  { business.warehouses.create!(name: "Main Depot", kind: "central") }
  let!(:dest)    { business.warehouses.create!(name: "North Store", kind: "branch", branch: branch) }
  let!(:shampoo) do
    business.products.create!(name: "Argan Shampoo", sku: "SH-1", initial_cost_price: 5, average_cost_price: 5)
            .tap { |p| p.product_barcodes.create!(barcode: "6281000011111", is_primary: true) }
  end
  let!(:soap) { business.products.create!(name: "Olive Soap", sku: "SO-1", initial_cost_price: 2, average_cost_price: 2) }

  before do
    [ [ shampoo, 10 ], [ soap, 40 ] ].each do |item, qty|
      InventoryMovement.create!(business: business, product: item, warehouse: source, direction: :in, reason: :opening_balance,
                                quantity: qty, unit_cost: 1, occurred_on: Date.new(2026, 1, 1))
    end
    ProductWarehouseSetting.create!(product: soap, warehouse: dest, business: business, low_stock_level: 5, reorder_quantity: 12)
    sign_in owner
    visit new_inventory_stock_transfer_path
    select "Main Depot", from: "stock_transfer[source_warehouse_id]"
    select "North Store — North", from: "stock_transfer[destination_warehouse_id]"
  end

  def lines = all("tr[data-stock-transfer-line]:not([hidden])")
  def scan(code)
    find("#barcode_scan").fill_in(with: code)
    find("#barcode_scan").send_keys(:enter)
  end

  it "adds one unit per repeated scan on ONE line, with the server's figures and a shortage warning" do
    3.times { scan("6281000011111") }
    expect(page).to have_css("tr[data-stock-transfer-line] [data-quantity-field]", count: 1)
    expect(lines.first).to have_field(type: "number", with: "3") # waits for the queued scans
    expect(lines.first).to have_css("[data-cell='source_on_hand']", text: "10")
    expect(lines.first).to have_css("[data-cell='source_available']", text: "10")
    expect(find("[data-stock-transfer-form-target='summaryQuantity']")).to have_text("3")

    lines.first.find("[data-quantity-field]").fill_in(with: "12")
    expect(lines.first).to have_css("[data-cell='warning']", text: "2", visible: true)
    expect(find("[data-stock-transfer-form-target='summaryWarnings']")).to have_text("Argan Shampoo")
  end

  it "keeps the two warehouse pickers apart" do
    expect(find("select[name='stock_transfer[destination_warehouse_id]'] option[value='#{source.id}']")).to be_disabled
    expect(find("select[name='stock_transfer[source_warehouse_id]'] option[value='#{dest.id}']")).to be_disabled
  end

  it "adds low-stock suggestions from the modal, merging a product already on the form" do
    scan("6281000011111")
    find("[data-testid='replenishment-button']").click
    within("[data-testid='replenishment-body']") do
      expect(page).to have_css("[data-replenishment-row]", count: 1)
      find("[data-replenishment-check]").check
    end
    find("[data-testid='replenishment-add']").click
    expect(page).to have_css("tr[data-stock-transfer-line]:not([hidden]) select[data-product-field] option[value='#{soap.id}']", visible: :all)
    soap_line = lines.find { |l| l.find("select[data-product-field]", visible: :all).value == soap.id.to_s }
    expect(soap_line.find("[data-quantity-field]").value).to eq("12")

    accept_confirm { click_button I18n.t("inventory.stock_transfers.form.save_and_submit") }
    unless page.has_css?("[data-testid='review-lines']", wait: 10)
      raise "not submitted: #{page.find('body').text.first(600)}"
    end
    transfer = StockTransfer.where(business_id: business.id).order(:id).last
    expect(transfer).to be_pending_approval
    expect(transfer.items.pluck(:product_id, :quantity)).to contain_exactly([ shampoo.id, 1 ], [ soap.id, 12 ])
  end
end
