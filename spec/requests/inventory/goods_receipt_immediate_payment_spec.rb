require "rails_helper"

# Company Cash, Bank Account and Employee Custody are immediate payment
# sources: approving the receipt records the full payment on the
# FinancialSettlement ledger, so it reads Settled / Paid = total / Remaining = 0
# with no "Financial Settlement" action. Supplier Credit is the only source
# that leaves a payable to be settled later.
RSpec.describe "Goods receipt — immediate payment by funding source", type: :request do
  let(:business)  { create(:business, currency: "EGP") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 0, average_cost_price: 0) }

  let(:creator_role) do
    business.permission_roles.create!(name: "Receiver", permissions: %w[view_inventory create_goods_receipts])
  end
  let(:manager_role) do
    business.permission_roles.create!(name: "Manager", permissions: %w[view_inventory approve_goods_receipts
                                                                       confirm_goods_receipts void_goods_receipts])
  end
  let(:creator) { create(:user, business: business).tap { |u| u.update_column(:permission_role_id, creator_role.id) } }
  let(:manager) { create(:user, business: business).tap { |u| u.update_column(:permission_role_id, manager_role.id) } }

  let!(:custody) do
    create(:custody_account, business: business, user: creator).tap do |a|
      a.custody_transactions.create!(business: business, txn_type: "top_up", amount: 2000)
      a.refresh_balance!
    end
  end

  def status_label(key, locale: :en) = I18n.t("inventory.goods_receipts.financial_statuses.#{key}", locale: locale)
  def settle_path(receipt) = new_inventory_goods_receipt_settlement_path(receipt)

  # Creates (as the creator) and submits a 5 x 100 = 500 receipt, then approves it as the manager.
  def approved_receipt(kind)
    sign_in creator
    post inventory_goods_receipts_path, params: { goods_receipt: {
      warehouse_id: warehouse.id, supplier_id: supplier.id, received_on: Date.current, funding_source_kind: kind,
      items_attributes: { "0" => { product_id: product.id, quantity: 5, unit_cost: 100 } }
    } }
    receipt = business.goods_receipts.order(:id).last
    post submit_inventory_goods_receipt_path(receipt)

    sign_in manager
    post approve_inventory_goods_receipt_path(receipt)
    receipt.reload
  end

  def detail(label)
    row = Nokogiri::HTML(response.body).css(".detail-list__row").find { |r| r.at_css("dt")&.text&.squish == label }
    row&.at_css("dd")&.text&.squish
  end

  def show_financials(receipt, locale: :en)
    get inventory_goods_receipt_path(receipt)
    I18n.with_locale(locale) do
      { status:    detail(I18n.t("inventory.goods_receipts.financial_status")),
        paid:      detail(I18n.t("inventory.goods_receipts.paid_amount")),
        remaining: detail(I18n.t("inventory.goods_receipts.remaining_amount")) }
    end
  end

  %w[company_cash bank_account].each do |kind|
    describe kind do
      it "is settled in full at approval, with no settlement action" do
        receipt = approved_receipt(kind)

        expect(receipt).to be_approval_approved
        expect(receipt).to be_settled
        expect(receipt.total_settled_amount).to eq(500)
        expect(receipt.remaining_settlement_amount).to eq(0)

        settlement = receipt.financial_settlements.sole
        expect(settlement).to have_attributes(amount: 500, source_kind: kind, funding_source: nil,
                                              reference: receipt.receipt_number, created_by: manager)
        expect(CustodyTransaction.where(source: receipt)).to be_empty # no fake account balance

        expect(show_financials(receipt)).to eq(status: status_label(:settled), paid: "EGP 500.00", remaining: "EGP 0.00")
        expect(response.body).not_to include(settle_path(receipt))
      end
    end
  end

  describe "employee_custody" do
    it "is settled at approval from the creator's own custody, with one settlement and one custody transaction" do
      receipt = approved_receipt("employee_custody")

      expect(receipt).to be_settled
      expect(receipt.financial_settlements.sole).to have_attributes(amount: 500, funding_source: custody)
      expect(custody.custody_transactions.where(txn_type: "inventory_purchase").sole.amount).to eq(-500)
      expect(custody.reload.computed_balance).to eq(1500)

      expect(show_financials(receipt)).to eq(status: status_label(:settled), paid: "EGP 500.00", remaining: "EGP 0.00")
      expect(response.body).not_to include(settle_path(receipt))
    end
  end

  describe "supplier_credit" do
    it "stays pending with the settlement action, then settles through partial payments" do
      receipt = approved_receipt("supplier_credit")

      expect(receipt.financial_settlements).to be_empty
      expect(show_financials(receipt)).to eq(status: status_label(:pending_settlement), paid: "EGP 0.00", remaining: "EGP 500.00")
      expect(response.body).to include(settle_path(receipt))

      post inventory_goods_receipt_settlements_path(receipt),
           params: { settlement: { source_kind: "bank_account", amount: "200", payment_date: Date.current.to_s } }
      expect(show_financials(receipt)).to eq(status: status_label(:partially_settled), paid: "EGP 200.00", remaining: "EGP 300.00")
      expect(response.body).to include(settle_path(receipt))

      post inventory_goods_receipt_settlements_path(receipt),
           params: { settlement: { source_kind: "company_cash", amount: "300", payment_date: Date.current.to_s } }
      expect(show_financials(receipt)).to eq(status: status_label(:settled), paid: "EGP 500.00", remaining: "EGP 0.00")
      expect(response.body).not_to include(settle_path(receipt))
    end
  end

  describe "before approval" do
    it "records no payment for a cash receipt that is only submitted" do
      sign_in creator
      post inventory_goods_receipts_path, params: { goods_receipt: {
        warehouse_id: warehouse.id, received_on: Date.current, funding_source_kind: "company_cash",
        items_attributes: { "0" => { product_id: product.id, quantity: 5, unit_cost: 100 } }
      } }
      receipt = business.goods_receipts.order(:id).last
      post submit_inventory_goods_receipt_path(receipt)

      expect(receipt.financial_settlements).to be_empty
      get inventory_goods_receipt_path(receipt)
      expect(response.body).not_to include(settle_path(receipt))
    end
  end

  describe "no duplicate settlements" do
    it "a second approval attempt is refused and records nothing more" do
      receipt = approved_receipt("bank_account")
      result = Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: manager).approve!

      expect(result).not_to be_ok
      expect(receipt.financial_settlements.count).to eq(1)
    end

    it "voiding reverses the cash payment exactly once" do
      receipt = approved_receipt("company_cash")
      patch void_inventory_goods_receipt_path(receipt), params: { void_reason: "Wrong supplier" }
      patch void_inventory_goods_receipt_path(receipt), params: { void_reason: "Again" }

      receipt.reload
      expect(receipt).to be_voided
      expect(receipt.financial_settlements.map(&:amount)).to contain_exactly(500, -500)
      expect(receipt.financial_settlements.find_by(amount: -500).reverses_settlement).to eq(receipt.financial_settlements.find_by(amount: 500))
      expect(receipt.total_settled_amount).to eq(0)
    end
  end

  describe "receiving and stock are unchanged" do
    %w[company_cash bank_account employee_custody supplier_credit].each do |kind|
      it "#{kind}: approval moves no stock; confirmation receives it and moves no money" do
        receipt = approved_receipt(kind)
        settled_before = receipt.total_settled_amount
        expect(product.reload.current_stock).to eq(0)

        post confirm_inventory_goods_receipt_path(receipt)

        expect(receipt.reload).to be_confirmed
        expect(product.reload.current_stock).to eq(5)
        expect(receipt.total_settled_amount).to eq(settled_before)
      end
    end
  end

  describe "historical receipts" do
    it "leaves an already-approved cash receipt with no settlement untouched (still payable via the existing flow)" do
      legacy = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, funding_source_kind: "company_cash")
      legacy.items.build(product: product, quantity: 1, unit_cost: 70)
      legacy.save!
      legacy.update_column(:approval_status, "approved") # approved before this change: no payment recorded

      approved_receipt("company_cash") # a new approval elsewhere must not touch it

      expect(legacy.reload.financial_settlements).to be_empty
      expect(legacy).to be_pending_settlement
      get inventory_goods_receipt_path(legacy)
      expect(response.body).to include(settle_path(legacy))
    end
  end

  describe "RTL / LTR" do
    it "shows the Arabic settled figures right-to-left" do
      receipt = approved_receipt("bank_account")
      manager.update!(preferred_locale: "ar")

      financials = show_financials(receipt, locale: :ar)
      expect(response.body).to include('dir="rtl"')
      expect(financials).to eq(status: "تمت التسوية", paid: "500.00 ج.م", remaining: "0.00 ج.م")
    end

    it "shows the Arabic pending figures and settlement action for supplier credit" do
      receipt = approved_receipt("supplier_credit")
      manager.update!(preferred_locale: "ar")

      financials = show_financials(receipt, locale: :ar)
      expect(financials).to eq(status: "بانتظار التسوية", paid: "0.00 ج.م", remaining: "500.00 ج.م")
      expect(response.body).to include(I18n.t("inventory.goods_receipts.settlements.action", locale: :ar))
    end

    it "renders English left-to-right" do
      receipt = approved_receipt("company_cash")
      get inventory_goods_receipt_path(receipt)
      expect(response.body).to include('dir="ltr"')
    end
  end
end
