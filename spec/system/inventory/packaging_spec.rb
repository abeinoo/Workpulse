require "rails_helper"

# Multi-unit inventory in a real browser (docs/inventory/multi_unit_nested_packaging_design.md):
# configure a product's packaging, enter a transfer in boxes with the unit
# selector and its live base-unit hint, and count a stocktake row per level.
RSpec.describe "Multi-unit packaging (browser)", type: :system do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:main)    { business.warehouses.create!(name: "Main", kind: "central") }
  let!(:annex)   { business.warehouses.create!(name: "Annex") }
  let!(:razor)   { business.products.create!(name: "Razor", sku: "RZ-1", initial_cost_price: 0, average_cost_price: 0, unit_of_measure: "pieces") }

  def rows = all("tr[data-line-row]")
  def pick(row, text, name)
    input = row.find("[data-product-combobox-target='input']")
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", input.native)
    input.click
    input.fill_in(with: text)
    find(".pcombo__listbox", visible: true).find(".pcombo__option", text: name).click
  end

  it "configures packaging innermost first, showing what each package equals" do
    sign_in owner
    visit inventory_product_path(razor)
    find("[data-testid='edit-packaging']").click
    click_button I18n.t("inventory.packaging.add_level")
    click_button I18n.t("inventory.packaging.add_level")
    levels = all("[data-packaging-level-row]")
    levels[0].find("select").select("Box")
    levels[0].find("input[type='number']").fill_in(with: "10")
    levels[1].find("select").select("Carton")
    levels[1].find("input[type='number']").fill_in(with: "12")
    expect(levels[1]).to have_css("[data-level-base]", text: "= 120 pcs")
    find("[data-testid='packaging-save']").click

    expect(page).to have_text(I18n.t("inventory.packaging.saved"))
    expect(find("[data-testid='packaging-chain']")).to have_text("1 carton = 12 boxes")
    expect(razor.reload.active_packaging_levels.pluck(:package_unit)).to eq(%w[box carton])
  end

  it "a transfer line offers the product's units and shows the base equivalent before posting" do
    configure_packaging!(razor, owner, [ "box", 10 ], [ "carton", 12 ])
    receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 3, 120 ] ])
    sign_in owner
    visit new_inventory_stock_transfer_path
    select "Main", from: "stock_transfer_source_warehouse_id"
    select "Annex", from: "stock_transfer_destination_warehouse_id"
    click_button "+ #{I18n.t('inventory.stock_transfers.add_item')}" if rows.empty?
    row = rows.first
    pick(row, "RZ-1", "Razor")

    unit = row.find("select[data-unit-select]")
    expect(unit.all("option").map(&:text)).to eq([ "pcs", "Box (10 pcs)", "Carton (120 pcs)" ])
    unit.select("Box (10 pcs)")
    row.find("[data-quantity-field]").fill_in(with: "5")
    expect(row).to have_css("[data-unit-hint]", text: "= 50 pcs")

    find("form input[type='submit'], form button[type='submit']", match: :first).click
    expect(page).to have_text(I18n.t("inventory.stock_transfers.created"))
    expect(find("[data-testid='line-quantity']")).to have_text("5 boxes (50 pcs)")
    expect(packaging_state(razor, annex)).to include("box" => 5, total: 50)
  end

  it "a stocktake row is counted per level and the total is filled in" do
    configure_packaging!(razor, owner, [ "box", 10 ], [ "carton", 12 ])
    receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 1, 120 ] ])
    counter = user_with_stock_permissions(business, :view_inventory, :manage_stock_counts)
    count = record_stock_count!(business: business, warehouse: main, counter: counter, lines: [])
    sign_in counter
    visit edit_inventory_stock_count_path(count)
    row = find("tbody tr[data-product-id='#{razor.id}']")
    breakdown = row.find("[data-testid='count-breakdown']")
    inputs = breakdown.all("input[type='number']")      # carton, box, loose
    inputs[0].fill_in(with: "0")
    inputs[1].fill_in(with: "11")
    inputs[2].fill_in(with: "10")
    expect(row.find("[data-quantity-field]").value).to eq("120")
    click_button I18n.t("inventory.stock_counts.save_counts")

    item = count.reload.items.find_by!(product: razor)
    expect(item.counted_quantity).to eq(120)
    expect(item.packaging_differences).to eq(level_of(razor, "carton").id.to_s => -1, level_of(razor, "box").id.to_s => 11)
  end

  it "the purchase request item editor keeps a line's packaging unit: 2 cartons edited to 3 cartons" do
    configure_packaging!(razor, owner, [ "box", 10 ], [ "carton", 12 ])
    request = business.purchase_requests.create!(warehouse: main, created_by: owner,
                                                 items_attributes: [ { product_id: razor.id, entered_quantity: 2,
                                                                       packaging_level_id: level_of(razor, "carton").id, entered_unit_price: 120 } ])
    line = request.items.sole
    sign_in owner
    visit inventory_purchase_request_path(request)
    find("#item-#{line.id} [data-testid='edit-item']").click
    row = find("[data-purchase-request-item-editor-target='modal'] tr[data-line-row]")
    expect(row.find("[data-quantity-field]").value).to eq("2")
    expect(row.find("select[data-unit-select]").value).to eq(level_of(razor, "carton").id.to_s)
    expect(row).to have_css("[data-unit-hint]", text: "= 240 pcs")

    row.find("[data-quantity-field]").fill_in(with: "3")
    find("[data-testid='item-editor-save']").click
    expect(page).to have_text(I18n.t("inventory.purchase_requests.item_updated"))
    expect(line.reload).to have_attributes(quantity: 360, entered_quantity: 3, packaging_level_id: level_of(razor, "carton").id, unit_price: 1)
  end
end
