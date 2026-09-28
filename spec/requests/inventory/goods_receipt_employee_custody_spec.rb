require "rails_helper"

# Employee Custody on a goods receipt always means the CURRENT user's own
# active custody account, resolved server-side. A user without one gets a
# clear "you do not have a custody account" message — never the old,
# misleading "Funding source must be selected when … Employee Custody".
RSpec.describe "Goods receipt — Employee Custody funding", type: :request do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 0) }

  let(:creator_role) do
    business.permission_roles.create!(name: "Receiver", permissions: %w[view_inventory create_goods_receipts])
  end
  let(:approver_role) do
    business.permission_roles.create!(name: "Approver",
                                      permissions: %w[view_inventory approve_goods_receipts confirm_goods_receipts])
  end
  let(:with_custody)    { create(:user, business: business).tap { |u| u.update_column(:permission_role_id, creator_role.id) } }
  let(:without_custody) { create(:user, business: business).tap { |u| u.update_column(:permission_role_id, creator_role.id) } }
  let(:approver)        { create(:user, business: business).tap { |u| u.update_column(:permission_role_id, approver_role.id) } }

  let!(:my_account)    { fund(create(:custody_account, business: business, user: with_custody), 1000) }
  let!(:other_account) { fund(create(:custody_account, business: business), 5000) }

  let(:old_message_en) { "must be selected when the funding source is Employee Custody" }
  let(:old_message_ar) { "يجب اختياره عندما يكون مصدر التمويل عهدة الموظف" }
  let(:no_account_en)  { "You do not have a custody account. You cannot use Employee Custody as the funding source." }
  let(:no_account_ar)  { "لا يوجد لديك حساب عهدة. لا يمكنك اختيار «عهدة موظف» كمصدر تمويل." }

  def fund(account, amount)
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: amount)
    account.refresh_balance!
    account
  end

  def create_receipt(kind, extra_receipt_params: {}, extra_params: {})
    post inventory_goods_receipts_path, params: {
      goods_receipt: {
        warehouse_id: warehouse.id, received_on: Date.current, funding_source_kind: kind,
        items_attributes: { "0" => { product_id: product.id, quantity: 2, unit_cost: 50 } }
      }.merge(extra_receipt_params)
    }.merge(extra_params)
  end

  def page = Nokogiri::HTML(response.body)
  def custody_radio = page.at_css("input[name='goods_receipt[funding_source_kind]'][value=employee_custody]")
  def checked_kinds = page.css("input[name='goods_receipt[funding_source_kind]'][checked]").map { |i| i["value"] }
  def form_errors = page.css(".form-error li").map { |li| li.text.squish }

  describe "user WITH a custody account" do
    before { sign_in with_custody }

    it "offers Employee Custody (pre-selected) and shows the ledger balance on the new form" do
      get new_inventory_goods_receipt_path

      expect(custody_radio["disabled"]).to be_nil
      expect(checked_kinds).to eq([ "employee_custody" ])
      expect(page.at_css("#employee-custody-balance").text).to include("1,000.00")
      expect(response.body).not_to include(no_account_en)
    end

    it "creates the receipt charged to their own account, with no funding-source error" do
      expect { create_receipt("employee_custody") }.to change(GoodsReceipt, :count).by(1)

      receipt = GoodsReceipt.last
      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      expect(receipt.funding_source).to eq(my_account)
    end

    it "ignores any submitted account id — in the receipt params or top-level" do
      create_receipt("employee_custody",
                     extra_receipt_params: { funding_source_id: other_account.id, funding_source_type: "CustodyAccount" },
                     extra_params: { funding_source_id: other_account.id, custody_account_id: other_account.id })

      expect(GoodsReceipt.last.funding_source).to eq(my_account)
    end

    it "does not use an inactive account" do
      my_account.update!(active: false)
      expect { create_receipt("employee_custody") }.not_to change(GoodsReceipt, :count)
      expect(form_errors).to eq([ no_account_en ])
    end

    it "keeps approval + stock unchanged: approval deducts custody, confirmation adds stock" do
      create_receipt("employee_custody")
      receipt = GoodsReceipt.last
      post submit_inventory_goods_receipt_path(receipt)
      expect(receipt.reload).to be_approval_pending_approval

      sign_in approver
      post approve_inventory_goods_receipt_path(receipt)
      expect(receipt.reload).to be_approval_approved
      expect(my_account.reload.computed_balance).to eq(900)
      expect(other_account.reload.computed_balance).to eq(5000)
      expect(product.reload.current_stock).to eq(0)

      post confirm_inventory_goods_receipt_path(receipt)
      expect(receipt.reload).to be_confirmed
      expect(product.reload.current_stock).to eq(2)
      expect(my_account.reload.computed_balance).to eq(900) # not charged twice
    end

    it "clears the custody link when a draft is switched to another funding source" do
      create_receipt("employee_custody")
      receipt = GoodsReceipt.last

      patch inventory_goods_receipt_path(receipt), params: { goods_receipt: { funding_source_kind: "company_cash" } }

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      expect(receipt.reload).to have_attributes(funding_source_kind: "company_cash", funding_source: nil)
    end
  end

  describe "user WITHOUT a custody account" do
    before { sign_in without_custody }

    it "shows Employee Custody as unavailable with the reason, and pre-selects nothing" do
      get new_inventory_goods_receipt_path

      expect(custody_radio["disabled"]).to be_present
      expect(custody_radio["aria-describedby"]).to eq("employee-custody-unavailable")
      expect(page.at_css("#employee-custody-unavailable").text.squish).to eq(no_account_en)
      expect(checked_kinds).to be_empty
      %w[company_cash bank_account supplier_credit].each do |kind|
        expect(page.at_css("input[name='goods_receipt[funding_source_kind]'][value=#{kind}]")["disabled"]).to be_nil
      end
    end

    it "blocks submission server-side with exactly the intended message (EN)" do
      expect { create_receipt("employee_custody") }.not_to change(GoodsReceipt, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(form_errors).to eq([ no_account_en ])
      expect(response.body).not_to include(old_message_en)
    end

    it "cannot borrow someone else's account by submitting its id" do
      expect {
        create_receipt("employee_custody",
                       extra_receipt_params: { funding_source_id: other_account.id, funding_source_type: "CustodyAccount" },
                       extra_params: { funding_source_id: other_account.id })
      }.not_to change(GoodsReceipt, :count)
      expect(other_account.reload.computed_balance).to eq(5000)
    end

    it "asks for a funding source when none is chosen" do
      expect { create_receipt("") }.not_to change(GoodsReceipt, :count)
      expect(form_errors).to eq([ "Funding source must be selected" ])
    end

    {
      "company_cash"    => "company_cash",
      "bank_account"    => "bank_account",
      "supplier_credit" => "supplier_credit"
    }.each do |label, kind|
      it "still creates a #{label} receipt with no custody link" do
        expect { create_receipt(kind) }.to change(GoodsReceipt, :count).by(1)
        expect(GoodsReceipt.last).to have_attributes(funding_source_kind: kind, funding_source: nil)
      end
    end
  end

  describe "RTL / LTR" do
    it "renders the Arabic message and RTL layout" do
      without_custody.update!(preferred_locale: "ar")
      sign_in without_custody

      get new_inventory_goods_receipt_path
      expect(response.body).to include('dir="rtl"')
      expect(page.at_css("#employee-custody-unavailable").text.squish).to eq(no_account_ar)

      expect { create_receipt("employee_custody") }.not_to change(GoodsReceipt, :count)
      expect(form_errors).to eq([ no_account_ar ])
      expect(response.body).not_to include(old_message_ar)
      expect(response.body).not_to include("Funding source")
    end

    it "renders English LTR with the balance for a custody holder" do
      sign_in with_custody
      get new_inventory_goods_receipt_path
      expect(response.body).to include('dir="ltr"')
      expect(page.at_css("#employee-custody-balance")).to be_present
    end
  end
end
