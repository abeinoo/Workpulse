require "rails_helper"

RSpec.describe "Purchase Requests — navigation, list UI, and management", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:product_a) { business.products.create!(name: "Product A", sku: "A-1", average_cost_price: 100) }

  def build_request(status: "draft", quantity: 10, created_by: owner)
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: created_by)
    pr.items.build(product: product_a, quantity: quantity, unit_price: 100, source_warehouse: warehouse)
    pr.save!
    pr.update_column(:status, status)
    pr.reload
  end

  # ── 1 & 2: sidebar visibility ─────────────────────────────────────────────
  describe "sidebar navigation" do
    it "shows the طلبات الشراء item to a user who can view inventory" do
      sign_in owner
      get inventory_root_path

      expect(response.body).to include(I18n.t("nav.inventory_purchase_requests"))
      expect(response.body).to include(%(href="#{inventory_purchase_requests_path}"))
    end

    it "hides the طلبات الشراء item from a user without inventory access" do
      role = business.permission_roles.create!(name: "No Inventory", permissions: %w[view_dashboard])
      user = create(:user, business: business)
      user.update_column(:permission_role_id, role.id)
      sign_in user

      get root_path
      expect(response.body).not_to include(I18n.t("nav.inventory_purchase_requests"))
    end
  end

  # ── 3: index loads ──────────────────────────────────────────────────────
  it "loads the index page" do
    sign_in owner
    get inventory_purchase_requests_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("inventory.purchase_requests.title"))
  end

  # ── 11: pagination ──────────────────────────────────────────────────────
  describe "pagination" do
    it "paginates the list instead of loading everything at once" do
      30.times { |n| build_request(status: "draft") }
      sign_in owner

      get inventory_purchase_requests_path
      expect(response.body.scan(/PR-\d{6}/).uniq.size).to eq(Inventory::PurchaseRequestsController::PER_PAGE)
      expect(response.body).to include(I18n.t("common.page_of", page: 1, total: 2))

      get inventory_purchase_requests_path(page: 2)
      remaining = 30 - Inventory::PurchaseRequestsController::PER_PAGE
      expect(response.body.scan(/PR-\d{6}/).uniq.size).to eq(remaining)
    end
  end

  # ── 12: receiving progress ─────────────────────────────────────────────
  it "shows correct receiving progress in the list" do
    pr = build_request(status: "approved", quantity: 10)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            purchase_request: pr)
    receipt.items.build(product: product_a, quantity: 6, unit_cost: 100, purchase_request_item: pr.items.sole)
    receipt.save!
    receipt.update_column(:approval_status, "approved")
    Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: owner).call

    sign_in owner
    get inventory_purchase_requests_path

    expect(response.body).to include("6 / 10")
    expect(response.body).to include(I18n.t("inventory.purchase_requests.receiving_statuses.partial"))
  end

  # ── 13: summary counts ──────────────────────────────────────────────────
  it "shows correct summary counts, excluding rejected and cancelled from the active total" do
    build_request(status: "draft")
    build_request(status: "pending_approval")
    build_request(status: "approved")
    build_request(status: "rejected")
    build_request(status: "cancelled")

    sign_in owner
    get inventory_purchase_requests_path

    expect(response.body).to include(I18n.t("inventory.purchase_requests.summary.active"))
    # 3 active (draft + pending_approval + approved), rejected/cancelled excluded
    doc = Nokogiri::HTML(response.body)
    active_value = doc.at_css(".stat-card .stat-card__value")&.text
    expect(active_value.to_s.strip).to eq("3")
  end

  # ── 14 & 15: details page + related goods receipts ─────────────────────
  it "shows the details page with header info and links related goods receipts" do
    pr = build_request(status: "approved", quantity: 10)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            purchase_request: pr)
    receipt.items.build(product: product_a, quantity: 6, unit_cost: 100, purchase_request_item: pr.items.sole)
    receipt.save!
    receipt.update_column(:approval_status, "approved")
    Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: owner).call

    sign_in owner
    get inventory_purchase_request_path(pr)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(pr.request_number)
    expect(response.body).to include("Acme")
    expect(response.body).to include(I18n.t("inventory.purchase_requests.goods_receipts_section"))
    expect(response.body).to include(receipt.receipt_number)
    expect(response.body).to include(%(href="#{inventory_goods_receipt_path(receipt)}"))
  end

  # ── 16: status-based actions ─────────────────────────────────────────────
  describe "status-based actions in the list" do
    it "shows submit/delete for a draft request, and no approve/receive actions" do
      pr = build_request(status: "draft")
      sign_in owner
      get inventory_purchase_requests_path

      expect(response.body).to include(submit_inventory_purchase_request_path(pr))
      expect(response.body).to include(I18n.t("inventory.purchase_requests.actions.delete"))
      expect(response.body).not_to include(I18n.t("inventory.purchase_requests.actions.create_goods_receipt"))
    end

    it "shows the quick receive action for an approved request, not for a draft one" do
      approved = build_request(status: "approved")
      draft    = build_request(status: "draft")
      sign_in owner
      get inventory_purchase_requests_path

      expect(response.body).to include(new_inventory_goods_receipt_path(purchase_request_id: approved.id))
      expect(response.body).not_to include(new_inventory_goods_receipt_path(purchase_request_id: draft.id))
    end

    it "shows the 'remaining' receive label for a partially received request" do
      pr = build_request(status: "partially_received")
      sign_in owner
      get inventory_purchase_requests_path

      expect(response.body).to include(I18n.t("inventory.purchase_requests.actions.create_goods_receipt_remaining"))
    end

    it "shows no receive action for a fully received request" do
      pr = build_request(status: "fully_received")
      sign_in owner
      get inventory_purchase_requests_path

      expect(response.body).not_to include(new_inventory_goods_receipt_path(purchase_request_id: pr.id))
    end
  end

  # ── 17: permission checks (view) ─────────────────────────────────────────
  it "requires view_inventory (or manage_inventory) to access the index" do
    role = business.permission_roles.create!(name: "No Inventory", permissions: %w[view_dashboard])
    user = create(:user, business: business)
    user.update_column(:permission_role_id, role.id)
    sign_in user

    get inventory_purchase_requests_path
    expect(response).to redirect_to(root_path)
  end

  # ── 18: empty state ───────────────────────────────────────────────────────
  it "shows a useful empty state with a create action when there are no purchase requests" do
    sign_in owner
    get inventory_purchase_requests_path

    expect(response.body).to include(I18n.t("inventory.purchase_requests.empty_state_title"))
    expect(response.body).to include(I18n.t("inventory.purchase_requests.new_action"))
  end
end
