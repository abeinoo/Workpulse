require "rails_helper"

# SC-000008, several products at once, in the browser: every row starts as a
# pre-upgrade (unverified) quantity, like all 163 rows of SC-000008. Some are
# typed, one is confirmed with "Confirm count", others are left untouched; then
# Save & Complete and approval run through the real UI / services.
#   * typed and confirmed rows are physical counts with their own quantity
#     and the ledger baseline at entry time — never replaced at completion;
#   * untouched rows adopt the system quantity (D9) with zero difference;
#   * approval posts exactly the physical differences, a later receipt is
#     preserved, and untouched rows generate no movement.
# The real PATCH params are captured from the in-process app server.
RSpec.describe "Stock count — many products, typed / confirmed / untouched (browser, SC-000008)", type: :system do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :owner, business: business) }
  let(:approver) do
    role = business.permission_roles.create!(name: "Approver", permissions: %w[view_inventory post_stock_counts])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end
  let(:warehouse) { business.warehouses.create!(name: "المخزن الرئيسي") }

  # sku => [ledger on-hand, the counter's pre-upgrade (unverified) quantity] — values from SC-000008
  let(:plan) do
    { "GKM-84978" => [ BigDecimal("4.004"), 3 ],
      "EEJ-20480" => [ 11, 10 ],
      "Lord1"     => [ 100, 120 ],
      "CYS2"      => [ 6, 23 ],
      "AYA2"      => [ 0, 6 ],
      "Shave1"    => [ 7, 5 ] }
  end

  let!(:products) do
    plan.to_h do |sku, (on_hand, _)|
      product = business.products.create!(name: "Product #{sku}", sku: sku, initial_cost_price: 10, average_cost_price: 10)
      receive!(product, on_hand) if on_hand.positive?
      [ sku, product ]
    end
  end

  let!(:count) do
    c = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current, created_by: owner, status: :in_progress)
    plan.each { |sku, (on_hand, entered)| c.items.build(product: products[sku], system_quantity: on_hand, counted_quantity: entered) }
    c.save!
    c
  end

  def receive!(product, qty)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  let(:requests) { [] }
  around do |example|
    callback = lambda do |*, payload|
      next unless payload[:controller] == "Inventory::StockCountsController" && payload[:action] == "update"

      requests << payload[:params].deep_dup
    end
    ActiveSupport::Notifications.subscribed(callback, "start_processing.action_controller") { example.run }
  end

  before { sign_in owner }

  def row_for(sku) = find("tr[data-line-row][data-sku='#{sku}']")
  def item(sku) = count.items.reload.find_by!(product: products[sku])
  def submitted(sku)
    id = item(sku).id.to_s
    requests.last.fetch("stock_count").fetch("items_attributes").values.find { |row| row["id"] == id }
  end

  it "keeps every typed or confirmed quantity as a physical count; untouched rows follow D9" do
    visit edit_inventory_stock_count_path(count)
    row_for("GKM-84978").find("input[data-quantity-field]").fill_in(with: "3")    # typed, equal to old entry
    within(row_for("EEJ-20480")) { click_button I18n.t("inventory.stock_counts.sources.confirm_action") }   # confirmed 10
    row_for("Lord1").find("input[data-quantity-field]").fill_in(with: "118")       # typed, different
    row_for("CYS2").find("input[data-quantity-field]").fill_in(with: "6")          # typed, equal to system
    # AYA2 and Shave1 are left untouched.

    accept_confirm(I18n.t("inventory.stock_counts.save_and_complete_confirm.some", count: 2)) do
      click_button I18n.t("inventory.stock_counts.save_and_complete_action")
    end
    expect(page).to have_text(I18n.t("inventory.stock_counts.saved_and_completed"))

    # The request: every row present; entered = 1 exactly for the four counted rows.
    expect(requests.last.dig("stock_count", "items_attributes").size).to eq(plan.size)
    expect(submitted("GKM-84978")).to include("counted_quantity" => "3",   "entered" => "1")
    expect(submitted("EEJ-20480")).to include("counted_quantity" => "10",  "entered" => "1")
    expect(submitted("Lord1")).to     include("counted_quantity" => "118", "entered" => "1")
    expect(submitted("CYS2")).to      include("counted_quantity" => "6",   "entered" => "1")
    expect(submitted("AYA2")).to      include("counted_quantity" => "6",   "entered" => "0", "original_counted_quantity" => "6")
    expect(submitted("Shave1")).to    include("counted_quantity" => "5",   "entered" => "0", "original_counted_quantity" => "5")

    expect(count.reload).to be_completed
    expected = {
      "GKM-84978" => [ "physical", 3,   BigDecimal("4.004"), BigDecimal("-1.004") ],
      "EEJ-20480" => [ "physical", 10,  11,  -1 ],
      "Lord1"     => [ "physical", 118, 100, 18 ],
      "CYS2"      => [ "physical", 6,   6,   0 ],
      "AYA2"      => [ "system",   0,   0,   0 ],
      "Shave1"    => [ "system",   7,   7,   0 ]
    }
    expected.each do |sku, (source, counted, baseline, difference)|
      row = item(sku)
      expect([ sku, row.quantity_source, row.counted_quantity, row.system_quantity, row.difference ])
        .to eq([ sku, source, counted, baseline, difference ])
      expect(row.counted_at).to(source == "physical" ? be_present : be_nil)
      expect(row.legacy_counted_quantity).to eq(plan[sku].last)          # the old entry is kept as history
    end

    receive!(products["Lord1"], 5)                                            # after the count: preserved
    movements_before = InventoryMovement.count
    expect(Inventory::StockCountApprover.new(stock_count_id: count.id, actor: approver).call.ok?).to be(true)

    adjustment = count.reload.active_stock_adjustment
    lines = adjustment.items.to_h { |i| [ i.product.sku, i.quantity_difference ] }
    expect(lines).to eq("GKM-84978" => BigDecimal("-1.004"), "EEJ-20480" => -1, "Lord1" => 18)
    expect(InventoryMovement.count - movements_before).to eq(3)               # no movement for CYS2 / untouched rows
    expect(adjustment.inventory_movements.map { |m| m.product.sku }).to contain_exactly("GKM-84978", "EEJ-20480", "Lord1")

    final = products.transform_values { |p| p.stock_in(warehouse) }
    expect(final).to eq("GKM-84978" => 3, "EEJ-20480" => 10, "Lord1" => 123,   # 118 counted + 5 received later
                        "CYS2" => 6, "AYA2" => 0, "Shave1" => 7)
  end
end
