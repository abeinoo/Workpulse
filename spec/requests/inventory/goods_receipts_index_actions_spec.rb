require "rails_helper"

# Goods Receipts index "الإجراءات" column: each row offers exactly the actions
# GoodsReceiptPolicy allows for that receipt and user, posting to the same
# endpoints (with the same confirmations) as the Show page.
RSpec.describe "Goods receipts index — row actions", type: :request do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let(:admin) { create(:user, :super_admin, business: business) }

  def user_with(*perms)
    role = create(:permission_role, business: business, permissions: perms.map(&:to_s))
    create(:user, business: business, permission_role: role, preferred_locale: "ar")
  end

  let(:approver)  { user_with(:view_inventory, :approve_goods_receipts) }
  let(:confirmer) { user_with(:view_inventory, :confirm_goods_receipts) }
  let(:viewer)    { user_with(:view_inventory) }

  def build_receipt(approval_status: "pending_approval", funding_source_kind: "supplier_credit", funding_source: nil)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: funding_source_kind, funding_source: funding_source)
    r.items.build(product: product, quantity: 5, unit_cost: 10)
    r.save!
    r.update_column(:approval_status, approval_status)
    r.reload
  end

  def approval(receipt) = Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: admin)
  def approved = build_receipt.tap { |r| expect(approval(r).approve!).to be_ok }.reload

  def received
    approved.tap do |r|
      expect(Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: r.id, actor: admin).call).to be_ok
    end.reload
  end

  def cancelled
    build_receipt.tap do |r|
      Inventory::GoodsReceiptVoider.new(goods_receipt_id: r.id, actor: admin, reason: "مكرر").call
    end.reload
  end

  def rejected = build_receipt.tap { |r| expect(approval(r).reject!(reason: "سعر خاطئ")).to be_ok }.reload

  # The actions cell of `receipt`'s row, as Nokogiri.
  def actions_for(receipt, as:, **filters)
    sign_in as
    get inventory_goods_receipts_path(filters)
    row = Nokogiri::HTML(response.body).css("tbody tr").find { |tr| tr.text.include?(receipt.receipt_number) }
    row.at_css("td.td-actions")
  end

  def posts_to?(cell, path) = cell.css("form[action='#{path}']").any?
  def view_link?(cell, receipt) = cell.css("a[href='#{inventory_goods_receipt_path(receipt)}']").any?

  it "adds a الإجراءات column header" do
    build_receipt
    sign_in approver
    get inventory_goods_receipts_path
    expect(Nokogiri::HTML(response.body).css("thead th").map { |th| th.text.strip }).to include("الإجراءات")
  end

  describe "pending approval" do
    let!(:receipt) { build_receipt }

    it "shows Approve and Reject (with reason + confirmation) to an authorized approver" do
      cell = actions_for(receipt, as: approver)

      approve = cell.at_css("form[action='#{approve_inventory_goods_receipt_path(receipt)}']")
      expect(approve.at_css("button").text.strip).to eq("اعتماد")
      expect(approve.at_css("button")["data-turbo-confirm"]).to eq(I18n.t("inventory.goods_receipts.approve_hint", locale: :ar))

      reject = cell.at_css("form[action='#{reject_inventory_goods_receipt_path(receipt)}']")
      expect(reject.at_css("textarea[name='rejection_reason'][required]")).to be_present
      expect(reject.at_css("button[type='submit']")["data-turbo-confirm"])
        .to eq(I18n.t("inventory.goods_receipts.reject_confirm", locale: :ar))
      expect(cell.at_css("[data-testid='row-reject']").text.strip).to eq("رفض")

      expect(posts_to?(cell, confirm_inventory_goods_receipt_path(receipt))).to be false
      expect(view_link?(cell, receipt)).to be true
    end

    it "shows no Approve/Reject to a user without approval permission — only View" do
      [ viewer, confirmer ].each do |user|
        cell = actions_for(receipt, as: user)
        expect(posts_to?(cell, approve_inventory_goods_receipt_path(receipt))).to be false
        expect(posts_to?(cell, reject_inventory_goods_receipt_path(receipt))).to be false
        expect(view_link?(cell, receipt)).to be true
      end
    end

    it "a custody-funded receipt's Approve shows the custody balance preview in a dialog, then approves in place" do
      account = create(:custody_account, business: business, user: admin)
      account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 200)
      account.refresh_balance!
      custody = build_receipt(funding_source_kind: "employee_custody", funding_source: account)

      cell = actions_for(custody, as: approver)
      expect(cell.at_css("button[data-testid='row-approve']").text.strip).to eq("اعتماد")
      dialog = cell.at_css("dialog#approve-dialog-#{custody.id}")
      expect(dialog.at_css("[data-testid='custody-preview-current']").text).to include("200")
      expect(dialog.at_css("[data-testid='custody-preview-due']").text).to include("50")
      expect(dialog.at_css("[data-testid='custody-preview-after']").text).to include("150")
      approve = dialog.at_css("form[action='#{approve_inventory_goods_receipt_path(custody)}'] button")
      expect(approve["data-turbo-confirm"]).to eq(I18n.t("inventory.goods_receipts.approve_hint", locale: :ar))
      expect(cell.css("a[href*='custody-payment-preview']")).to be_empty
    end
  end

  describe "approved, not received" do
    let!(:receipt) { approved }

    it "shows تأكيد الإذن (receiving) to a confirmer, with the Show page's confirmation" do
      cell = actions_for(receipt, as: confirmer)
      confirm = cell.at_css("form[action='#{confirm_inventory_goods_receipt_path(receipt)}'] button")
      expect(confirm.text.strip).to eq("تأكيد الإذن")
      expect(confirm["data-turbo-confirm"]).to eq(I18n.t("inventory.goods_receipts.confirm_hint", locale: :ar))
      expect(posts_to?(cell, approve_inventory_goods_receipt_path(receipt))).to be false
    end

    it "shows no receiving action to a user who cannot confirm" do
      cell = actions_for(receipt, as: approver)
      expect(posts_to?(cell, confirm_inventory_goods_receipt_path(receipt))).to be false
      expect(view_link?(cell, receipt)).to be true
    end
  end

  {
    "fully received" => :received,
    "cancelled"      => :cancelled,
    "rejected"       => :rejected
  }.each do |label, state|
    it "#{label}: no approve, reject or receiving action — only View" do
      receipt = send(state)
      cell = actions_for(receipt, as: admin)

      expect(posts_to?(cell, approve_inventory_goods_receipt_path(receipt))).to be false
      expect(posts_to?(cell, reject_inventory_goods_receipt_path(receipt))).to be false
      expect(posts_to?(cell, confirm_inventory_goods_receipt_path(receipt))).to be false
      expect(cell.css("form").size).to eq(0)
      expect(view_link?(cell, receipt)).to be true
    end
  end

  describe "acting from the index" do
    it "approving returns to the index with its filters, through the same endpoint" do
      receipt = build_receipt
      sign_in approver
      index = inventory_goods_receipts_path(approval_status: "pending_approval")

      post approve_inventory_goods_receipt_path(receipt), headers: { "HTTP_REFERER" => "http://www.example.com#{index}" }

      expect(response).to redirect_to(index)
      expect(receipt.reload.approval_status).to eq("approved")
    end

    it "the backend still refuses an unauthorized approval" do
      receipt = build_receipt
      sign_in viewer
      post approve_inventory_goods_receipt_path(receipt), headers: { "HTTP_REFERER" => inventory_goods_receipts_url }
      expect(receipt.reload.approval_status).to eq("pending_approval")
    end

    it "a refused action reports the service error back on the index" do
      receipt = build_receipt.tap { |r| r.update_column(:created_by_id, approver.id) } # self-approval
      sign_in approver
      post approve_inventory_goods_receipt_path(receipt), headers: { "HTTP_REFERER" => inventory_goods_receipts_url }

      expect(response).to redirect_to(inventory_goods_receipts_url)
      expect(flash[:alert]).to be_present
      expect(receipt.reload.approval_status).to eq("pending_approval")
    end
  end

  describe "Show page (unchanged)" do
    it "still approves and returns to the Show page" do
      receipt = build_receipt
      sign_in approver
      post approve_inventory_goods_receipt_path(receipt),
           headers: { "HTTP_REFERER" => inventory_goods_receipt_url(receipt) }

      expect(response).to redirect_to(inventory_goods_receipt_url(receipt))
      expect(receipt.reload.approval_status).to eq("approved")
    end

    it "with no referer, falls back to the Show page as before" do
      receipt = approved
      sign_in confirmer
      post confirm_inventory_goods_receipt_path(receipt)

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      expect(receipt.reload).to be_confirmed
    end
  end
end
