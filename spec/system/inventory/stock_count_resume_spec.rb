require "rails_helper"

# Browser coverage of the counting sheet for a count resumed with legacy
# (pre-upgrade, unverified) quantities — the SC-000008 shape: the old entry 3
# for a product whose ledger on-hand is 4.004.
#   * the sheet shows the last entered quantity (3), not the system stock;
#   * saving untouched keeps the row unverified (Complete then adopts 4.004);
#   * retyping 3 records a fresh physical count that Complete keeps;
#   * "Save & Complete" warns how many products were not physically counted,
#     saves, then completes.
RSpec.describe "Stock count — resuming and completing (browser)", type: :system do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :owner, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:serum)    { business.products.create!(name: "Serum", sku: "GKM-84978", initial_cost_price: 50, average_cost_price: 50) }
  let!(:wax)      { business.products.create!(name: "Wax", sku: "WX-1", initial_cost_price: 2, average_cost_price: 2) }

  let!(:count) do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: serum, quantity: BigDecimal("4.004"), unit_cost: 50)
    r.items.build(product: wax, quantity: 7, unit_cost: 2)
    Inventory::GoodsReceiptPoster.new(r).call
    c = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current, created_by: owner, status: :in_progress)
    c.items.build(product: serum, system_quantity: 4, counted_quantity: 3)   # legacy: no source, no count time
    c.items.build(product: wax, system_quantity: 7, counted_quantity: 5)
    c.save!
    c
  end

  before { sign_in owner }

  def row_for(sku) = find("tr[data-line-row][data-sku='#{sku}']")
  def quantity_field(sku) = row_for(sku).find("input[data-quantity-field]")
  def item(product) = count.items.reload.find_by!(product: product)

  it "shows the last entered quantity and keeps an untouched row unverified" do
    visit edit_inventory_stock_count_path(count)
    expect(quantity_field("GKM-84978").value).to eq("3")
    expect(row_for("GKM-84978")).to have_text("4.004")

    click_button I18n.t("inventory.stock_counts.save_counts")
    expect(page).to have_current_path(inventory_stock_count_path(count))
    expect(item(serum)).to have_attributes(counted_quantity: 3, quantity_source: nil, counted_at: nil)

    visit edit_inventory_stock_count_path(count)
    expect(quantity_field("GKM-84978").value).to eq("3")
  end

  it "records a retyped 3 as a physical count that completion keeps (not 4.004)" do
    visit edit_inventory_stock_count_path(count)
    quantity_field("GKM-84978").fill_in(with: "3")
    click_button I18n.t("inventory.stock_counts.save_counts")
    expect(page).to have_current_path(inventory_stock_count_path(count))

    expect(item(serum)).to have_attributes(quantity_source: "physical", counted_quantity: 3,
                                           system_quantity: BigDecimal("4.004"), difference: BigDecimal("-1.004"))
    expect(item(wax)).to have_attributes(quantity_source: nil)                     # untouched row unchanged

    accept_confirm(I18n.t("inventory.stock_counts.complete_confirm_unverified", count: 1)) do
      click_button I18n.t("inventory.stock_counts.complete_action")
    end
    expect(page).to have_text(I18n.t("inventory.stock_counts.completed"))
    expect(item(serum)).to have_attributes(quantity_source: "physical", counted_quantity: 3)
    expect(item(wax)).to have_attributes(quantity_source: "system", counted_quantity: 7, difference: 0)
  end

  it "Save & Complete warns about uncounted products, saves the typed quantity, then completes" do
    visit edit_inventory_stock_count_path(count)
    quantity_field("GKM-84978").fill_in(with: "3")

    accept_confirm(I18n.t("inventory.stock_counts.save_and_complete_confirm.some", count: 1)) do
      click_button I18n.t("inventory.stock_counts.save_and_complete_action")
    end
    expect(page).to have_text(I18n.t("inventory.stock_counts.saved_and_completed"))
    expect(count.reload).to be_completed
    expect(item(serum)).to have_attributes(quantity_source: "physical", counted_quantity: 3)
    expect(item(wax)).to have_attributes(quantity_source: "system")
  end
end
