require "rails_helper"

RSpec.describe "Purchase Requests — Next Action column, summary cards, needs-action filter", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:product)  { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 100) }

  def request_with(status:, quantity: 10)
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: owner)
    pr.items.build(product: product, quantity: quantity, unit_price: 100)
    pr.save!
    case status
    when "draft"
      # already draft
    when "pending_approval"
      pr.update_columns(status: "pending_approval", submitted_by_id: owner.id)
    else
      pr.update_column(:status, status)
    end
    pr.reload
  end

  def confirm_receipt!(pr, quantity:)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            purchase_request: pr)
    receipt.items.build(product: product, quantity: quantity, unit_cost: 100, purchase_request_item: pr.items.sole)
    receipt.save!
    receipt.update_column(:approval_status, "approved")
    Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: owner).call
  end

  describe "Next Action column" do
    it "shows the correct next action label for every status" do
      sign_in owner

      draft = request_with(status: "draft")
      pending = request_with(status: "pending_approval")
      approved = request_with(status: "approved")
      partially_received = request_with(status: "approved", quantity: 10)
      confirm_receipt!(partially_received, quantity: 6)
      fully_received = request_with(status: "approved", quantity: 5)
      confirm_receipt!(fully_received, quantity: 5)
      partially_closed = request_with(status: "approved", quantity: 10)
      confirm_receipt!(partially_closed, quantity: 6)
      Inventory::PurchaseRequestRemainingCloser.new(purchase_request_id: partially_closed.id, actor: owner, reason: "x").call
      rejected = request_with(status: "rejected")
      cancelled = request_with(status: "cancelled")

      get inventory_purchase_requests_path

      body = response.body
      expect(body).to include(I18n.t("inventory.purchase_requests.next_actions.draft"))
      expect(body).to include(I18n.t("inventory.purchase_requests.next_actions.pending_approval"))
      expect(body).to include(I18n.t("inventory.purchase_requests.next_actions.approved"))
      expect(body).to include(I18n.t("inventory.purchase_requests.next_actions.partially_received"))
      expect(body).to include(I18n.t("inventory.purchase_requests.next_actions.partially_closed"))
      expect(body).to include(I18n.t("inventory.purchase_requests.next_actions.fully_received"))
      expect(body).to include(I18n.t("inventory.purchase_requests.next_actions.rejected"))
      expect(body).to include(I18n.t("inventory.purchase_requests.next_actions.cancelled"))

      # Actionable ones link to the existing routes — no duplicated logic.
      expect(body).to include(edit_inventory_purchase_request_path(draft))
      expect(body).to include(approve_inventory_purchase_request_path(pending))
      expect(body).to include(new_inventory_goods_receipt_path(purchase_request_id: approved.id))
      expect(body).to include(new_inventory_goods_receipt_path(purchase_request_id: partially_received.id))
    end
  end

  describe "summary cards" do
    it "shows correct counts, excluding rejected/cancelled from the active total, including partially_closed as active" do
      request_with(status: "draft")
      request_with(status: "pending_approval")
      approved_only = request_with(status: "approved")
      pr = request_with(status: "approved", quantity: 10)
      confirm_receipt!(pr, quantity: 6)
      Inventory::PurchaseRequestRemainingCloser.new(purchase_request_id: pr.id, actor: owner, reason: "x").call
      request_with(status: "rejected")
      request_with(status: "cancelled")

      sign_in owner
      get inventory_purchase_requests_path

      expect(response.body).to include(I18n.t("inventory.purchase_requests.summary.partially_closed"))

      doc = Nokogiri::HTML(response.body)
      cards = doc.css(".stat-card")
      active_card = cards.find { |c| c.at_css(".stat-card__label")&.text == I18n.t("inventory.purchase_requests.summary.active") }
      closed_card = cards.find { |c| c.at_css(".stat-card__label")&.text == I18n.t("inventory.purchase_requests.summary.partially_closed") }

      # active = draft + pending_approval + approved + partially_closed = 4
      # (rejected/cancelled excluded)
      expect(active_card.at_css(".stat-card__value").text.strip).to eq("4")
      expect(closed_card.at_css(".stat-card__value").text.strip).to eq("1")
      expect(approved_only).to be_approved
    end
  end

  describe "تحتاج إجراء quick filter" do
    it "includes draft/pending_approval/approved/partially_received and excludes fully_received/partially_closed/rejected/cancelled" do
      draft = request_with(status: "draft")
      pending = request_with(status: "pending_approval")
      approved = request_with(status: "approved")
      partially_received = request_with(status: "approved", quantity: 10)
      confirm_receipt!(partially_received, quantity: 6)

      fully_received = request_with(status: "approved", quantity: 5)
      confirm_receipt!(fully_received, quantity: 5)
      partially_closed = request_with(status: "approved", quantity: 10)
      confirm_receipt!(partially_closed, quantity: 6)
      Inventory::PurchaseRequestRemainingCloser.new(purchase_request_id: partially_closed.id, actor: owner, reason: "x").call
      rejected = request_with(status: "rejected")
      cancelled = request_with(status: "cancelled")

      sign_in owner
      get inventory_purchase_requests_path(needs_action: "1")

      body = response.body
      [ draft, pending, approved, partially_received ].each do |pr|
        expect(body).to include(pr.request_number)
      end
      [ fully_received, partially_closed, rejected, cancelled ].each do |pr|
        expect(body).not_to include(pr.request_number)
      end
    end
  end
end
