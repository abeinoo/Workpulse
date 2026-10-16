require "rails_helper"

# Browser coverage (Arabic): approval and receiving statuses agree on the goods
# receipt page and list — cancelling a receipt awaiting approval takes it out of
# "بانتظار الاعتماد", and no approval actions remain on it.
RSpec.describe "Goods receipt status consistency (browser, Arabic)", type: :system do
  let(:business)  { create(:business) }
  let(:admin)     { create(:user, :super_admin, business: business, preferred_locale: "ar") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end

  def build_receipt
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 5, unit_cost: 10)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    r.reload
  end

  def approval(receipt) = Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: admin)
  def ar(key) = I18n.t("inventory.goods_receipts.#{key}", locale: :ar)

  def status_badges = all(".badge--md").first(2).map { |b| b.text.strip }

  def row_badges(receipt)
    find("tbody tr", text: receipt.receipt_number).all(".badge").map { |b| b.text.strip }
  end

  before { sign_in admin }

  it "cancelling a receipt awaiting approval leaves the approval workflow" do
    receipt = build_receipt
    visit inventory_goods_receipt_path(receipt)

    expect(status_badges).to eq([ ar("approval_statuses.pending_approval"), ar("receipt_statuses.not_received") ])
    expect(page).to have_css("form[action='#{approve_inventory_goods_receipt_path(receipt)}']")

    find("[data-testid='gr-end']").click
    within("dialog#end-dialog[open]") do
      fill_in "end-dialog-reason", with: "مكرر"
      accept_confirm { click_button ar("cancel_action") }
    end

    expect(page).to have_text(ar("cancelled"))
    expect(status_badges).to eq([ ar("approval_statuses.cancelled"), ar("receipt_statuses.voided") ])
    expect(page).to have_no_css("form[action='#{approve_inventory_goods_receipt_path(receipt)}']")
    expect(page).to have_no_css("form[action='#{reject_inventory_goods_receipt_path(receipt)}']")
    expect(receipt.reload.approval_status).to eq("cancelled")
  end

  it "the list shows a consistent pair for every status combination" do
    pending   = build_receipt
    cancelled = build_receipt.tap do |r|
      Inventory::GoodsReceiptVoider.new(goods_receipt_id: r.id, actor: admin, reason: "مكرر").call
    end
    rejected  = build_receipt.tap { |r| approval(r).reject!(reason: "سعر خاطئ") }
    approved  = build_receipt.tap { |r| approval(r).approve! }
    received  = build_receipt.tap do |r|
      approval(r).approve!
      Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: r.id, actor: admin).call
    end

    visit inventory_goods_receipts_path

    expect(row_badges(pending)).to eq([ ar("approval_statuses.pending_approval"), ar("receipt_statuses.not_received") ])
    expect(row_badges(cancelled)).to eq([ ar("approval_statuses.cancelled"), ar("receipt_statuses.voided") ])
    expect(row_badges(rejected)).to eq([ ar("approval_statuses.rejected"), ar("receipt_statuses.not_receivable") ])
    expect(row_badges(approved)).to eq([ ar("approval_statuses.approved"), ar("receipt_statuses.not_received") ])
    expect(row_badges(received)).to eq([ ar("approval_statuses.approved"), ar("receipt_statuses.received") ])

    # No row reads "awaiting approval" next to "cancelled".
    all("tbody tr").each do |tr|
      badges = tr.all(".badge").map { |b| b.text.strip }
      expect(badges).not_to eq([ ar("approval_statuses.pending_approval"), ar("receipt_statuses.voided") ])
    end
  end
end
