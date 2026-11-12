require "rails_helper"

# The SC-000008 workflow, end to end in the browser: GKM-84978 holds the
# pre-upgrade, unverified quantity 3 while the ledger on-hand is 4.004.
#   * typing 3 (or pressing "Confirm count") and saving records a fresh
#     physical count of 3 against the 4.004 baseline — the PATCH carries
#     counted_quantity "3" and entered "1" for that row;
#   * completing keeps that 3 (never 4.004) and approval posts −1.004 while
#     preserving a receipt posted after the count;
#   * an untouched unverified row still adopts the system quantity (D9).
# The real request parameters are captured from the in-process app server.
RSpec.describe "Stock count — confirming an unverified quantity (browser, SC-000008)", type: :system do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :owner, business: business) }
  let(:approver) do
    role = business.permission_roles.create!(name: "Approver", permissions: %w[view_inventory post_stock_counts])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end
  let(:warehouse) { business.warehouses.create!(name: "المخزن الرئيسي") }
  let!(:serum)    { business.products.create!(name: "سيروم - دودج", sku: "GKM-84978", initial_cost_price: 50, average_cost_price: 50) }
  let!(:wax)      { business.products.create!(name: "Wax", sku: "WX-1", initial_cost_price: 2, average_cost_price: 2) }

  def receive!(product, qty)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: product.average_cost_price)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  let!(:count) do
    receive!(serum, BigDecimal("4.004"))
    receive!(wax, 7)
    c = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current, created_by: owner, status: :in_progress)
    c.items.build(product: serum, system_quantity: 4, counted_quantity: 3)   # legacy: no source, no count time
    c.items.build(product: wax, system_quantity: 7, counted_quantity: 5)     # legacy, left untouched
    c.save!
    c
  end
  let(:serum_item) { count.items.find_by!(product: serum) }

  # Every StockCountsController#update the browser sends, with its real params.
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
  def submitted_row(item)
    requests.last.fetch("stock_count").fetch("items_attributes").values.find { |row| row["id"] == item.id.to_s }
  end
  def reload_item(product) = count.items.reload.find_by!(product: product)
  # .badge text is upper-cased by CSS.
  def status_text(key) = /#{Regexp.escape(I18n.t("inventory.stock_counts.sources.#{key}"))}/i

  it "typing 3 then Save & Complete records a physical 3 that completion keeps and approval posts as −1.004" do
    visit inventory_stock_count_path(count)
    click_link I18n.t("inventory.stock_counts.continue_counting")

    field = row_for("GKM-84978").find("input[data-quantity-field]")
    expect(field.value).to eq("3")                                            # the old unverified entry
    expect(row_for("GKM-84978")).to have_css("[data-entry-status]", text: status_text("legacy"))

    field.fill_in(with: "3")                                                  # the counter enters 3 explicitly
    expect(row_for("GKM-84978")).to have_css("[data-entry-status]", text: status_text("entered_status"))

    accept_confirm(I18n.t("inventory.stock_counts.save_and_complete_confirm.some", count: 1)) do
      click_button I18n.t("inventory.stock_counts.save_and_complete_action")
    end
    expect(page).to have_text(I18n.t("inventory.stock_counts.saved_and_completed"))

    # The request the browser actually sent for this row.
    expect(submitted_row(serum_item)).to include("counted_quantity" => "3", "entered" => "1", "original_counted_quantity" => "3")
    expect(requests.last).to include("save_and_complete")

    item = reload_item(serum)
    expect(item).to have_attributes(quantity_source: "physical", counted_quantity: 3, legacy_counted_quantity: 3,
                                    system_quantity: BigDecimal("4.004"), difference: BigDecimal("-1.004"))
    expect(item.counted_at).to be_present
    expect(item.baseline_at).to eq(item.counted_at)
    expect(count.reload).to be_completed
    expect(reload_item(wax)).to have_attributes(quantity_source: "system", counted_quantity: 7, difference: 0)   # untouched → D9

    receive!(serum, 2)                                                        # after the count: must be kept
    expect(Inventory::StockCountApprover.new(stock_count_id: count.id, actor: approver).call.ok?).to be(true)
    lines = count.reload.active_stock_adjustment.items.map { |i| [ i.product_id, i.quantity_difference ] }
    expect(lines).to eq([ [ serum.id, BigDecimal("-1.004") ] ])
    expect(serum.stock_in(warehouse)).to eq(5)                                # 4.004 − 1.004 + 2
  end

  it "\"Confirm count\" confirms the shown 3 as a physical count without retyping" do
    visit edit_inventory_stock_count_path(count)
    within(row_for("GKM-84978")) { click_button I18n.t("inventory.stock_counts.sources.confirm_action") }
    expect(row_for("GKM-84978")).to have_css("[data-entry-status]", text: status_text("entered_status"))

    click_button I18n.t("inventory.stock_counts.save_counts")
    expect(page).to have_current_path(inventory_stock_count_path(count))
    expect(submitted_row(serum_item)).to include("counted_quantity" => "3", "entered" => "1")
    expect(reload_item(serum)).to have_attributes(quantity_source: "physical", counted_quantity: 3,
                                                  system_quantity: BigDecimal("4.004"))

    accept_confirm { click_button I18n.t("inventory.stock_counts.complete_action") }
    expect(page).to have_text(I18n.t("inventory.stock_counts.completed"))
    expect(reload_item(serum)).to have_attributes(quantity_source: "physical", counted_quantity: 3)   # not 4.004
  end

  it "an untouched unverified 3 stays unverified on save, and Complete adopts 4.004 (D9)" do
    visit edit_inventory_stock_count_path(count)
    click_button I18n.t("inventory.stock_counts.save_counts")
    expect(page).to have_current_path(inventory_stock_count_path(count))
    expect(submitted_row(serum_item)).to include("counted_quantity" => "3", "entered" => "0")
    expect(reload_item(serum)).to have_attributes(quantity_source: nil, counted_quantity: 3, counted_at: nil)

    accept_confirm(I18n.t("inventory.stock_counts.complete_confirm_unverified", count: 2)) do
      click_button I18n.t("inventory.stock_counts.complete_action")
    end
    expect(page).to have_text(I18n.t("inventory.stock_counts.completed"))
    expect(reload_item(serum)).to have_attributes(quantity_source: "system", counted_quantity: BigDecimal("4.004"),
                                                  legacy_counted_quantity: 3, difference: 0)
  end
end
