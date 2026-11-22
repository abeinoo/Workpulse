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

  def fill_level(row, unit_name, contains)
    row.find("select[data-package-unit-field]").select(unit_name)
    row.find("[data-contains-field]").fill_in(with: contains)
  end

  def levels = all("[data-packaging-level-row]")
  def chain_lines = find("[data-packaging-editor-target='chain']").all("li").map(&:text)

  { "en" => { ml: "ml", bottle: "Bottle", carton: "Carton", chain: [ "1 carton = 10 bottles = 2500 ml", "1 bottle = 250 ml" ] },
    "ar" => { ml: "مل", bottle: "زجاجة", carton: "كرتونة", chain: [ "1 كرتونة = 10 زجاجة = 2500 مل", "1 زجاجة = 250 مل" ] } }.each do |locale, l|
    it "liquid product: the owner picks ml as the base unit; every label, total and the chain follow it (#{locale})" do
      liquid = business.products.create!(name: "Toner", sku: "TN-1", initial_cost_price: 0, average_cost_price: 0) # Measure still "pieces"
      owner.update!(preferred_locale: locale)
      sign_in owner
      visit packaging_inventory_product_path(liquid)
      find("#packaging_unit_of_measure").select(I18n.t("inventory.measures.ml.name", locale: locale))
      2.times { click_button I18n.t("inventory.packaging.add_level", locale: locale) }
      fill_level(levels[0], l[:bottle], "250")
      fill_level(levels[1], l[:carton], "10")

      expect(levels[0]).to have_css("[data-contains-unit]", exact_text: l[:ml])
      expect(levels[1]).to have_css("[data-contains-unit]", exact_text: l[:bottle])
      expect(levels[1]).to have_css("[data-level-base]", exact_text: "= 2500 #{l[:ml]}")
      expect(page).to have_css("[data-packaging-editor-target='chain'] li", count: 2)
      expect(chain_lines).to eq(l[:chain])
      expect(find("[data-testid='packaging-levels']").text + chain_lines.join).not_to include(I18n.t("inventory.measures.pieces.short", locale: locale))

      find("[data-testid='packaging-save']").click
      expect(page).to have_text(I18n.t("inventory.packaging.saved", locale: locale))
      liquid.reload
      expect([ liquid.unit_of_measure, liquid.measure_amount ]).to eq([ "ml", 250 ])
      expect(liquid.active_packaging_levels.map { |lv| [ lv.package_unit, lv.base_quantity.to_i ] }).to eq([ [ "bottle", 250 ], [ "carton", 2500 ] ])
    end
  end

  it "countable product: pieces, 1 box = 10 pieces, 1 carton = 12 boxes; then edited to 1 carton = 24 boxes" do
    sign_in owner
    visit inventory_product_path(razor)
    find("[data-testid='edit-packaging']").click
    expect(find("#packaging_unit_of_measure").value).to eq("pieces")
    2.times { click_button I18n.t("inventory.packaging.add_level") }
    fill_level(levels[0], "Box", "10")
    fill_level(levels[1], "Carton", "12")
    expect(levels[0]).to have_css("[data-contains-unit]", exact_text: "pcs")
    expect(chain_lines).to eq([ "1 carton = 12 boxes = 120 pcs", "1 box = 10 pcs" ])
    find("[data-testid='packaging-save']").click
    expect(page).to have_text(I18n.t("inventory.packaging.saved"))
    expect(find("[data-testid='packaging-chain']")).to have_text("1 carton = 12 boxes")

    # Editing the saved configuration: it is shown as saved, and changing the
    # outer level replaces only that level (no stock yet, so it may change).
    find("[data-testid='edit-packaging']").click
    expect(chain_lines).to eq([ "1 carton = 12 boxes = 120 pcs", "1 box = 10 pcs" ])
    box_id = level_of(razor, "box").id
    levels[1].find("[data-contains-field]").fill_in(with: "24")
    expect(chain_lines.first).to eq("1 carton = 24 boxes = 240 pcs")
    find("[data-testid='packaging-save']").click
    expect(page).to have_text(I18n.t("inventory.packaging.saved"))
    expect(razor.reload.active_packaging_levels.map { |lv| [ lv.package_unit, lv.base_quantity.to_i ] }).to eq([ [ "box", 10 ], [ "carton", 240 ] ])
    expect(level_of(razor, "box").id).to eq(box_id) # the unchanged inner level is kept, not recreated
  end

  it "the base unit is locked in the editor once stock has moved" do
    configure_packaging!(razor, owner, [ "box", 10 ])
    receive_units!(product: razor, warehouse: main, lines: [ [ "box", 2, 10 ] ])
    sign_in owner
    visit packaging_inventory_product_path(razor)
    expect(find("#packaging_unit_of_measure")).to be_disabled
    expect(page).to have_text(I18n.t("inventory.packaging.locked_base_unit"))
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
