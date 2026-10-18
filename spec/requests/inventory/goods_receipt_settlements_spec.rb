require "rails_helper"

RSpec.describe "Inventory::GoodsReceiptSettlements", type: :request do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:supplier)  { business.suppliers.create!(name: "Acme Supplies") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let(:admin)    { create(:user, :super_admin, business: business) }
  let(:approver) do
    create(:user, business: business,
                  permission_role: create(:permission_role, business: business,
                                                            permissions: %w[view_inventory approve_goods_receipts]))
  end
  let(:viewer) do
    create(:user, business: business,
                  permission_role: create(:permission_role, business: business, permissions: %w[view_inventory]))
  end
  # Employee Custody is always the recording user's own account: the approver's.
  let(:account)  { create(:custody_account, business: business, user: approver, name: "Approver Float") }

  def top_up!(amount)
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: amount)
    account.refresh_balance!
  end

  def approved_credit_receipt
    r = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                      funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 100, unit_cost: 50)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: admin).approve!
    r.reload
  end

  let!(:receipt) { approved_credit_receipt }

  def settlement_t(key, **) = I18n.t("inventory.goods_receipts.settlements.#{key}", **)

  describe "show page" do
    it "shows pending status, Paid/Remaining and a prominent settle button to an approver" do
      sign_in approver
      get inventory_goods_receipt_path(receipt)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("inventory.goods_receipts.financial_statuses.pending_settlement"))
      expect(response.body).to include(new_inventory_goods_receipt_settlement_path(receipt))
      expect(response.body).to include(settlement_t("history_title"))
    end

    it "shows financial info but NO settle button to a view-only user" do
      sign_in viewer
      get inventory_goods_receipt_path(receipt)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("inventory.goods_receipts.financial_statuses.pending_settlement"))
      expect(response.body).to include(settlement_t("history_title"))
      expect(response.body).not_to include(new_inventory_goods_receipt_settlement_path(receipt))
    end

    it "lists the payment history with source, employee, reference, actor, status, and reversal info" do
      top_up!(7_000)
      a = Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: approver, params: {
        source_kind: "employee_custody", amount: "2000"
      }).call.settlement
      Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: admin, params: {
        source_kind: "company_cash", amount: "3000", reference: "CV-42"
      }).call
      Inventory::GoodsReceiptSettlementReverser.new(goods_receipt_id: receipt.id, settlement_id: a.id,
                                                    actor: admin, reason: "Wrong employee").call

      sign_in admin
      get inventory_goods_receipt_path(receipt)
      body = response.body

      expect(body).to include(I18n.t("inventory.goods_receipts.funding_source_kinds.employee_custody"))
      expect(body).to include(I18n.t("inventory.goods_receipts.funding_source_kinds.company_cash"))
      expect(body).to include(html_escaped(approver.full_name))
      expect(body).to include("CV-42")
      expect(body).to include(html_escaped(admin.full_name))
      expect(body).to include(settlement_t("statuses.reversed"))
      expect(body).to include(settlement_t("statuses.active"))
      expect(body).to include("Wrong employee")
      expect(body).to include(I18n.t("inventory.goods_receipts.financial_statuses.partially_settled"))
      expect(body).to include(I18n.t("inventory.goods_receipts.timeline.settlement_reversed"))
    end

    it "hides the settle button once fully settled" do
      Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: admin, params: {
        source_kind: "company_cash", amount: "5000"
      }).call

      sign_in admin
      get inventory_goods_receipt_path(receipt)

      expect(response.body).to include(I18n.t("inventory.goods_receipts.financial_statuses.settled"))
      expect(response.body).not_to include(new_inventory_goods_receipt_settlement_path(receipt))
    end

    it "renders in Arabic (RTL) with Arabic settlement labels" do
      admin.update!(preferred_locale: "ar")
      Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: admin, params: {
        source_kind: "bank_account", amount: "2000"
      }).call

      sign_in admin
      get inventory_goods_receipt_path(receipt)
      body = response.body

      expect(body).to include('dir="rtl"')
      expect(body).to include("سجل التسويات المالية")
      expect(body).to include("تسوية جزئية")
      expect(body).to include("تسوية مالية")
      expect(body).to include("حساب بنكي")
    end
  end

  describe "GET new" do
    it "renders the form with receipt details, totals, and the user's own custody balance — no employee selector" do
      top_up!(7_000)
      sign_in approver
      get new_inventory_goods_receipt_settlement_path(receipt)

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include(receipt.receipt_number)
      expect(body).to include("Acme Supplies")
      expect(body).to include(I18n.t("inventory.goods_receipts.settlements.custody_balance"))
      expect(body).to include("SAR 7,000.00")
      html = Nokogiri::HTML(body)
      expect(html.css("select")).to be_empty
      expect(html.css("[name*='custody_account']")).to be_empty
      FinancialSettlement::PAYMENT_SOURCE_KINDS.each do |kind|
        expect(body).to include(I18n.t("inventory.goods_receipts.funding_source_kinds.#{kind}"))
      end
      # Applying a Purchase Request advance is internal (receipt approval) — never a manual payment choice.
      expect(html.css("input[value='#{FinancialSettlement::ADVANCE_APPLICATION_KIND}']")).to be_empty
    end

    it "renders in Arabic" do
      approver.update!(preferred_locale: "ar")
      sign_in approver
      get new_inventory_goods_receipt_settlement_path(receipt)

      expect(response.body).to include('dir="rtl"')
      expect(response.body).to include("تسجيل تسوية مالية")
      expect(response.body).to include("عهدة موظف")
    end

    it "blocks a view-only user" do
      sign_in viewer
      get new_inventory_goods_receipt_settlement_path(receipt)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST create" do
    it "records a settlement from the user's own custody and redirects" do
      top_up!(7_000)
      sign_in approver

      post inventory_goods_receipt_settlements_path(receipt), params: {
        settlement: { source_kind: "employee_custody", amount: "5000",
                      payment_date: Date.current.to_s, reference: "", notes: "" }
      }

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      expect(receipt.reload).to be_settled
      expect(account.reload.current_balance).to eq(2_000)
    end

    it "re-renders with an error on overpayment" do
      sign_in approver

      post inventory_goods_receipt_settlements_path(receipt), params: {
        settlement: { source_kind: "company_cash", amount: "6000", payment_date: Date.current.to_s }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(settlement_t("errors.exceeds_remaining", remaining: "5,000.00"))
      expect(receipt.financial_settlements.count).to eq(0)
    end

    it "does not let a view-only user record a settlement" do
      sign_in viewer

      post inventory_goods_receipt_settlements_path(receipt), params: {
        settlement: { source_kind: "company_cash", amount: "100" }
      }

      expect(response).to redirect_to(root_path)
      expect(receipt.financial_settlements.count).to eq(0)
    end
  end

  describe "PATCH reverse" do
    let!(:settlement) do
      Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: admin, params: {
        source_kind: "company_cash", amount: "2000"
      }).call.settlement
    end

    it "reverses with a reason" do
      sign_in admin

      patch reverse_inventory_goods_receipt_settlement_path(receipt, settlement), params: { reversal_reason: "Duplicate" }

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      expect(settlement.reload).to be_reversed
      expect(receipt.reload).to be_pending_settlement
    end

    it "refuses without a reason" do
      sign_in admin

      patch reverse_inventory_goods_receipt_settlement_path(receipt, settlement), params: { reversal_reason: "" }

      expect(flash[:alert]).to eq(settlement_t("errors.reason_required"))
      expect(settlement.reload).not_to be_reversed
    end

    it "does not let an approver without void permission reverse" do
      sign_in approver

      patch reverse_inventory_goods_receipt_settlement_path(receipt, settlement), params: { reversal_reason: "x" }

      expect(response).to redirect_to(root_path)
      expect(settlement.reload).not_to be_reversed
    end
  end
end
