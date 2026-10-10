require "rails_helper"

# Purchase Request page › أذونات الاستلام: each Goods Receipt can be approved,
# rejected or received right there. These are the SAME goods-receipt actions
# (GoodsReceiptsController#approve / #reject / #confirm → GoodsReceiptApproval /
# GoodsReceiptConfirmationService), gated by the SAME GoodsReceiptPolicy, and
# they redirect back to the Purchase Request — nothing is re-implemented here.
RSpec.describe "Purchase Request page — goods receipt actions", type: :request do
  let(:business)  { create(:business) }
  let(:admin)     { create(:user, :super_admin, business: business, preferred_locale: "ar") }
  let(:supplier)  { business.suppliers.create!(name: "مورد مستحضرات") }
  let(:warehouse) { business.warehouses.create!(name: "المستودع الرئيسي") }
  let!(:shampoo)  { business.products.create!(name: "شامبو", sku: "SH-1", average_cost_price: 10) }

  def user_with(*perms)
    role = create(:permission_role, business: business, permissions: perms.map(&:to_s))
    create(:user, business: business, permission_role: role, preferred_locale: "ar")
  end

  let(:approver)  { user_with(:view_inventory, :approve_goods_receipts) }
  let(:confirmer) { user_with(:view_inventory, :confirm_goods_receipts) }
  let(:viewer)    { user_with(:view_inventory) }

  let!(:pr) do
    request = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: admin)
    request.items.build(product: shampoo, quantity: 10, unit_price: 20, source_warehouse: warehouse)
    request.save!
    request.update_columns(status: "pending_approval", submitted_by_id: admin.id)
    Inventory::PurchaseRequestApproval.new(purchase_request_id: request.id, actor: admin).approve!
    request.reload
  end

  def receipt(quantity: 4, state: :pending)
    r = business.goods_receipts.build(purchase_request: pr, supplier: supplier, warehouse: warehouse,
                                      received_on: Date.current, funding_source_kind: "supplier_credit")
    r.items.build(product: shampoo, quantity: quantity, unit_cost: 20, purchase_request_item: pr.items.first)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    approval = Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: admin)
    case state
    when :approved  then approval.approve!
    when :received  then approval.approve!
                         Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: r.id, actor: admin).call
    when :rejected  then approval.reject!(reason: "سعر خاطئ")
    when :cancelled then Inventory::GoodsReceiptVoider.new(goods_receipt_id: r.id, actor: admin, reason: "مكرر").call
    end
    r.reload
  end

  let(:pr_url) { "http://www.example.com#{inventory_purchase_request_path(pr)}" }

  def from_pr(verb, path, **params)
    send(verb, path, params: params, headers: { "HTTP_REFERER" => pr_url })
  end

  def actions_cell(receipt, as:)
    sign_in as
    get inventory_purchase_request_path(pr)
    doc = Nokogiri::HTML(response.body)
    row = doc.css("#goods-receipts tbody tr").find { |tr| tr.text.include?(receipt.receipt_number) }
    row.at_css("td.col-actions")
  end

  def posts_to?(cell, path) = cell.css("form[action='#{path}']").any?

  it "adds approval-status, receipt-status and actions columns to أذونات الاستلام" do
    receipt
    sign_in admin
    get inventory_purchase_request_path(pr)
    headers = Nokogiri::HTML(response.body).css("#goods-receipts thead th").map { |th| th.text.strip }
    expect(headers).to include("حالة الاعتماد", "حالة الاستلام", "الإجراءات")
  end

  describe "A. pending approval" do
    let!(:pending) { receipt }

    it "shows اعتماد and رفض (with the existing reason form) and عرض to an authorized approver" do
      cell = actions_cell(pending, as: approver)
      expect(posts_to?(cell, approve_inventory_goods_receipt_path(pending))).to be true
      reject_form = cell.at_css("form[action='#{reject_inventory_goods_receipt_path(pending)}']")
      expect(reject_form.at_css("textarea[name='rejection_reason'][required]")).to be_present
      expect(cell.at_css("a[href='#{inventory_goods_receipt_path(pending)}']")).to be_present
    end

    it "approving from the Purchase Request stays on it and uses the goods-receipt approval (audit included)" do
      sign_in approver
      from_pr(:post, approve_inventory_goods_receipt_path(pending))

      expect(response).to redirect_to(pr_url)
      expect(pending.reload).to have_attributes(approval_status: "approved", decided_by_id: approver.id)
      expect(AuditLog.where(auditable: pending, action: "approve").count).to eq(1)
    end

    it "rejecting from the Purchase Request stays on it, with the required reason" do
      sign_in approver
      from_pr(:post, reject_inventory_goods_receipt_path(pending), rejection_reason: "سعر خاطئ")

      expect(response).to redirect_to(pr_url)
      expect(pending.reload).to have_attributes(approval_status: "rejected", rejection_reason: "سعر خاطئ")
    end

    it "a rejection without a reason is still refused by the existing validation" do
      sign_in approver
      from_pr(:post, reject_inventory_goods_receipt_path(pending), rejection_reason: "")

      expect(response).to redirect_to(pr_url)
      expect(flash[:alert]).to be_present
      expect(pending.reload.approval_status).to eq("pending_approval")
    end
  end

  describe "B. approved, not received" do
    let!(:approved) { receipt(state: :approved) }

    it "shows تأكيد الإذن to a confirmer, and receiving posts stock exactly once and stays on the request" do
      cell = actions_cell(approved, as: confirmer)
      expect(posts_to?(cell, confirm_inventory_goods_receipt_path(approved))).to be true
      expect(posts_to?(cell, approve_inventory_goods_receipt_path(approved))).to be false

      from_pr(:post, confirm_inventory_goods_receipt_path(approved))
      expect(response).to redirect_to(pr_url)
      expect(approved.reload).to be_confirmed
      expect(shampoo.reload.current_stock).to eq(4)
      expect(InventoryMovement.where(source: approved).count).to eq(1)
      expect(pr.reload.items.first.received_quantity).to eq(4)
      expect(pr).to be_partially_received

      # A repeated request posts nothing again.
      from_pr(:post, confirm_inventory_goods_receipt_path(approved))
      expect(InventoryMovement.where(source: approved).count).to eq(1)
      expect(shampoo.reload.current_stock).to eq(4)
    end
  end

  describe "C. terminal states show عرض only" do
    { "received" => :received, "rejected" => :rejected, "cancelled" => :cancelled }.each do |label, state|
      it label do
        r = receipt(state: state)
        cell = actions_cell(r, as: admin)
        expect(cell.css("form")).to be_empty
        expect(cell.css("button")).to be_empty
        expect(cell.at_css("a[href='#{inventory_goods_receipt_path(r)}']")).to be_present
      end
    end
  end

  describe "D. authorization" do
    let!(:pending) { receipt }

    it "a user who can only view sees no action buttons" do
      cell = actions_cell(pending, as: viewer)
      expect(cell.css("form")).to be_empty
      expect(cell.css("button")).to be_empty
    end

    it "direct backend requests are still refused by GoodsReceiptPolicy" do
      sign_in viewer
      from_pr(:post, approve_inventory_goods_receipt_path(pending))
      from_pr(:post, reject_inventory_goods_receipt_path(pending), rejection_reason: "x")
      expect(pending.reload.approval_status).to eq("pending_approval")

      approved = receipt(state: :approved)
      sign_in approver # can approve, cannot receive
      from_pr(:post, confirm_inventory_goods_receipt_path(approved))
      expect(approved.reload).not_to be_confirmed
      expect(shampoo.reload.current_stock).to eq(0)
    end
  end

  describe "E. regression" do
    it "acting from the goods receipt's own page still returns there" do
      pending = receipt
      sign_in approver
      post approve_inventory_goods_receipt_path(pending),
           headers: { "HTTP_REFERER" => inventory_goods_receipt_url(pending) }
      expect(response).to redirect_to(inventory_goods_receipt_url(pending))
      expect(pending.reload.approval_status).to eq("approved")
    end
  end
end
