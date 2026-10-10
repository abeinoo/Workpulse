require "rails_helper"

RSpec.describe "Purchase Requests — single actions column, summary cards, needs-action filter", type: :request do
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

  describe "one actions column (no separate الإجراء التالي)" do
    def actions_for(doc, pr)
      doc.css("tbody tr").find { |tr| tr.text.include?(pr.request_number) }.at_css("td.pr-list__actions")
    end

    it "offers each state its next step once, from the existing routes, and عرض everywhere" do
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
      doc = Nokogiri::HTML(response.body)

      headers = doc.css("thead th").map { |th| th.text.strip }
      expect(headers).not_to include(I18n.t("inventory.purchase_requests.next_action_column"))
      expect(headers.count(I18n.t("inventory.purchase_requests.table_actions"))).to eq(1)

      [ draft, pending, approved, partially_received, fully_received, partially_closed, rejected, cancelled ].each do |pr|
        expect(actions_for(doc, pr).at_css("a[href=\"#{inventory_purchase_request_path(pr)}\"][data-testid=\"pr-view\"]")).to be_present
      end

      receipt_link = ->(pr) { actions_for(doc, pr).css("a[href=\"#{new_inventory_goods_receipt_path(purchase_request_id: pr.id)}\"]") }
      expect(receipt_link.(approved).size).to eq(1)            # once — no duplicate
      expect(receipt_link.(partially_received).size).to eq(1)
      [ draft, pending, fully_received, partially_closed, rejected, cancelled ].each { |pr| expect(receipt_link.(pr)).to be_empty }

      expect(actions_for(doc, draft).at_css("form[action=\"#{submit_inventory_purchase_request_path(draft)}\"]")).to be_present
      expect(actions_for(doc, pending).at_css("form[action=\"#{approve_inventory_purchase_request_path(pending)}\"]")).to be_present
      expect(actions_for(doc, pending).at_css("form[action=\"#{reject_inventory_purchase_request_path(pending)}\"] textarea[name=rejection_reason][required]")).to be_present

      expect(actions_for(doc, fully_received).text).to include(I18n.t("inventory.purchase_requests.all_received"))
      [ rejected, cancelled ].each do |pr|
        expect(actions_for(doc, pr).css("form, button")).to be_empty
      end
    end

    it "shows approval status and receiving progress separately (a received request reads معتمد, not its receiving label twice)" do
      pr = request_with(status: "approved", quantity: 24)
      confirm_receipt!(pr, quantity: 5)
      sign_in owner
      get inventory_purchase_requests_path

      row = Nokogiri::HTML(response.body).css("tbody tr").find { |tr| tr.text.include?(pr.reload.request_number) }
      expect(row.at_css("td.pr-list__status").text.strip).to eq(I18n.t("inventory.purchase_requests.statuses.approved"))
      receiving = row.at_css("td.pr-list__receiving")
      expect(receiving.text).to include(I18n.t("inventory.purchase_requests.receiving_statuses.partial"), "5 / 24")
      expect(receiving.at_css("[role=progressbar]")["aria-valuenow"]).to eq("21")
    end
  end

  describe "summary cards" do
    it "shows the operational states, each filtering the list, with active excluding rejected/cancelled" do
      request_with(status: "draft")
      request_with(status: "pending_approval")
      request_with(status: "approved")
      pr = request_with(status: "approved", quantity: 10)
      confirm_receipt!(pr, quantity: 6)
      Inventory::PurchaseRequestRemainingCloser.new(purchase_request_id: pr.id, actor: owner, reason: "x").call
      request_with(status: "rejected")
      request_with(status: "cancelled")

      sign_in owner
      get inventory_purchase_requests_path

      doc = Nokogiri::HTML(response.body)
      value = ->(key) { doc.at_css("[data-testid=pr-summary-#{key}] .stat-card__value").text.strip }
      # active = draft + pending_approval + approved + partially_closed = 4 (rejected/cancelled excluded)
      expect(value.("active")).to eq("4")
      expect(value.("pending_approval")).to eq("1")
      expect(value.("approved")).to eq("1")
      expect(value.("partially_received")).to eq("0")
      expect(value.("fully_received")).to eq("0")
      expect(doc.at_css("[data-testid=pr-summary-pending_approval]")["href"])
        .to eq(inventory_purchase_requests_path(status: "pending_approval"))
      expect(doc.at_css("[data-testid=pr-summary-active]")["aria-current"]).to eq("true")
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
