require "rails_helper"

RSpec.describe Inventory::GoodsReceiptDraftService, type: :model do
  let(:business)  { create(:business) }
  let(:actor)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0) }

  def new_receipt
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, created_by: actor)
    r.items.build(product: product, quantity: 1, unit_cost: 10)
    r
  end

  it "saves a new receipt and logs a create audit entry" do
    receipt = new_receipt
    result = described_class.new(receipt, actor: actor).call

    expect(result.ok?).to be(true)
    expect(receipt).to be_persisted
    expect(receipt).to be_draft
    expect(receipt).to be_approval_draft
    log = AuditLog.for_auditable(receipt).find_by(action: "create")
    expect(log).to be_present
    expect(log.actor).to eq(actor)
  end

  it "never touches stock, custody, or settlements on save" do
    receipt = new_receipt
    described_class.new(receipt, actor: actor).call

    expect(product.reload.current_stock).to eq(0)
    expect(receipt.financial_settlements.count).to eq(0)
  end

  it "updates an existing receipt and logs an update audit entry" do
    receipt = new_receipt
    described_class.new(receipt, actor: actor).call

    receipt.notes = "updated note"
    result = described_class.new(receipt, actor: actor).call

    expect(result.ok?).to be(true)
    expect(receipt.reload.notes).to eq("updated note")
    log = AuditLog.for_auditable(receipt).find_by(action: "update")
    expect(log).to be_present
  end

  describe "funding source resolution" do
    let(:someone_else) { create(:custody_account, business: business) }

    it "charges Employee Custody to the actor's own active account, overriding anything preset" do
      mine    = create(:custody_account, business: business, user: actor)
      receipt = new_receipt
      receipt.funding_source_kind = "employee_custody"
      receipt.funding_source      = someone_else

      expect(described_class.new(receipt, actor: actor).call).to be_ok
      expect(receipt.reload.funding_source).to eq(mine)
    end

    it "fails with the no-custody-account message when the actor has no active account" do
      create(:custody_account, business: business, user: actor, active: false)
      receipt = new_receipt
      receipt.funding_source_kind = "employee_custody"
      receipt.funding_source      = someone_else

      expect(described_class.new(receipt, actor: actor).call).not_to be_ok
      expect(receipt).not_to be_persisted
      expect(receipt.errors[:base]).to include(I18n.t("activerecord.errors.models.goods_receipt.attributes.base.no_custody_account"))
      expect(receipt.errors[:funding_source]).to be_empty
    end

    %w[company_cash bank_account supplier_credit].each do |kind|
      it "saves #{kind} with no funding_source, even if one was preset" do
        receipt = new_receipt
        receipt.funding_source_kind = kind
        receipt.funding_source      = someone_else

        expect(described_class.new(receipt, actor: actor).call).to be_ok
        expect(receipt.reload.funding_source).to be_nil
      end
    end
  end

  it "returns a failed Result without raising when the receipt is invalid" do
    # GoodsReceipt.new (not business.goods_receipts.build) so this unsaved,
    # invalid record never lands in `business`'s in-memory association target
    # — building it there would make the next association-autosave validate
    # (and fail on) this record.
    receipt = GoodsReceipt.new(business: business, warehouse: warehouse, received_on: Date.current) # no items
    result = described_class.new(receipt, actor: actor).call

    expect(result.ok?).to be(false)
    expect(AuditLog.for_auditable(receipt).count).to eq(0)
  end
end
