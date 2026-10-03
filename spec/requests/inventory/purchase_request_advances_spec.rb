require "rails_helper"

RSpec.describe "Purchase Request advance payments (HTTP)", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 121) }

  let(:request_record) do
    pr = PurchaseRequest.new(business: business, supplier: supplier, created_by: owner)
    pr.items.build(product: product, quantity: 2, unit_price: 121, source_warehouse: warehouse) # 242
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def user_with(*permissions)
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:recorder)  { user_with("view_inventory", "manage_purchase_request_advances") }
  let(:confirmer) { user_with("view_inventory", "confirm_purchase_request_advances") }
  let(:pr_only)   { user_with("view_inventory", "create_purchase_requests", "approve_purchase_requests") }

  def post_advance(amount: 100, source_kind: "company_cash", custody_account_id: nil, key: SecureRandom.uuid)
    post inventory_purchase_request_advances_path(request_record), params: {
      idempotency_key: key,
      purchase_request_advance: { amount: amount, source_kind: source_kind, custody_account_id: custody_account_id,
                                  paid_on: Date.current.to_s, reference: "DEP-9", notes: "deposit" }
    }
  end

  def pending_advance(amount = 100)
    Inventory::PurchaseRequestAdvanceRecorder.new(
      purchase_request_id: request_record.id, actor: recorder,
      params: { amount: amount, source_kind: "company_cash", paid_on: Date.current }
    ).call.advance
  end

  describe "recording" do
    it "lets a manage_purchase_request_advances user record a pending advance" do
      sign_in recorder
      expect { post_advance }.to change(PurchaseRequestAdvance, :count).by(1)

      expect(response).to redirect_to(inventory_purchase_request_path(request_record, anchor: "advances"))
      expect(PurchaseRequestAdvance.last).to have_attributes(status: "pending", amount: 100, created_by_id: recorder.id)
    end

    it "denies purchase-request users without the advance permission (direct POST)" do
      sign_in pr_only
      expect { post_advance }.not_to change(PurchaseRequestAdvance, :count)
      expect(response).to redirect_to(root_path)

      get new_inventory_purchase_request_advance_path(request_record)
      expect(response).to redirect_to(root_path)
    end

    it "denies a confirm-only user from recording" do
      sign_in confirmer
      expect { post_advance }.not_to change(PurchaseRequestAdvance, :count)
    end

    it "re-renders the form with the error when the amount exceeds what remains" do
      sign_in recorder
      expect { post_advance(amount: 300) }.not_to change(PurchaseRequestAdvance, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("242.00")
    end

    it "ignores a duplicate submission with the same idempotency key" do
      sign_in recorder
      key = SecureRandom.uuid
      post_advance(key: key)
      expect { post_advance(key: key) }.not_to change(PurchaseRequestAdvance, :count)
    end

    it "cannot pay from another employee's custody without manage_employee_balances (tampered id)" do
      someone = create(:custody_account, business: business, user: create(:user, business: business))
      someone.custody_transactions.create!(business: business, txn_type: "top_up", amount: 1000)
      sign_in recorder

      expect { post_advance(source_kind: "employee_custody", custody_account_id: someone.id) }
        .not_to change(PurchaseRequestAdvance, :count)
      expect(response.body).to include(I18n.t("inventory.purchase_request_advances.errors.custody_account_required"))
    end

    context "with a balances manager choosing the employee" do
      # Business-wide custody visibility (the existing per-permission scope).
      let(:manager) do
        role = business.permission_roles.create!(
          name: "Balances manager",
          permissions: %w[view_inventory manage_purchase_request_advances confirm_purchase_request_advances
                          view_employee_balances manage_employee_balances],
          permission_scopes: { "view_employee_balances" => "business" }
        )
        create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
      end
      let!(:with_account)    { create(:user, business: business, first_name: "Ahmed") }
      let!(:without_account) { create(:user, business: business, first_name: "Omar") }
      let!(:ahmed_custody) do
        create(:custody_account, business: business, user: with_account, name: "Ahmed Float").tap do |a|
          a.custody_transactions.create!(business: business, txn_type: "top_up", amount: 50)
          a.refresh_balance!
        end
      end

      it "lists only employees who actually have an active custody account" do
        create(:custody_account, business: business, user: create(:user, business: business), active: false)
        sign_in manager
        get new_inventory_purchase_request_advance_path(request_record)

        options = Nokogiri::HTML(response.body)
                          .css("select[name='purchase_request_advance[custody_account_id]'] option")
                          .map { |o| [ o["value"], o["data-balance"] ] }.reject { |v, _| v.blank? }
        expect(options).to eq([ [ ahmed_custody.id.to_s, "50.0" ] ])
        expect(response.body).not_to include(without_account.full_name)
      end

      it "rejects (server-side) a custody account that is inactive or doesn't exist" do
        inactive = create(:custody_account, business: business, user: without_account, active: false)
        sign_in manager

        [ inactive.id, 999_999 ].each do |id|
          expect { post_advance(source_kind: "employee_custody", custody_account_id: id) }
            .not_to change(PurchaseRequestAdvance, :count)
          expect(response.body).to include(I18n.t("inventory.purchase_request_advances.errors.custody_account_required"))
        end
      end

      it "accepts an advance above the balance and confirms it into a negative balance (50 − 100 = −50)" do
        sign_in manager
        expect { post_advance(amount: 100, source_kind: "employee_custody", custody_account_id: ahmed_custody.id) }
          .to change(PurchaseRequestAdvance, :count).by(1)

        advance = PurchaseRequestAdvance.last
        # Confirmation by a different user (self-confirmation is blocked).
        sign_in user_with("view_inventory", "confirm_purchase_request_advances")
        2.times { post confirm_inventory_purchase_request_advance_path(request_record, advance) }

        expect(advance.reload).to be_confirmed
        expect(ahmed_custody.reload.computed_balance).to eq(-50)
        expect(ahmed_custody.custody_transactions.where(txn_type: "inventory_purchase").sum(:amount)).to eq(-100)
      end
    end

    it "cannot touch another business's purchase request" do
      other = create(:business)
      foreign_supplier = other.suppliers.create!(name: "X")
      foreign = PurchaseRequest.new(business: other, supplier: foreign_supplier)
      foreign.items.build(product: other.products.create!(name: "P", sku: "P-1"), quantity: 1, unit_price: 5)
      foreign.save!
      foreign.update_column(:status, "approved")
      sign_in recorder

      post inventory_purchase_request_advances_path(foreign), params: { purchase_request_advance: { amount: 1, source_kind: "company_cash" } }
      expect(response).to have_http_status(:not_found)
      expect(PurchaseRequestAdvance.count).to eq(0)
    end
  end

  describe "confirm / cancel / reverse" do
    it "requires confirm_purchase_request_advances to confirm" do
      advance = pending_advance
      sign_in recorder
      post confirm_inventory_purchase_request_advance_path(request_record, advance)
      expect(advance.reload).to be_pending

      sign_in pr_only
      post confirm_inventory_purchase_request_advance_path(request_record, advance)
      expect(advance.reload).to be_pending

      sign_in confirmer
      post confirm_inventory_purchase_request_advance_path(request_record, advance)
      expect(advance.reload).to be_confirmed
      expect(request_record.reload.advances_total).to eq(100)
    end

    it "a repeated confirm POST does not post a second settlement" do
      advance = pending_advance
      sign_in confirmer
      2.times { post confirm_inventory_purchase_request_advance_path(request_record, advance) }

      expect(request_record.reload.financial_settlements.count).to eq(1)
    end

    it "cancels a pending advance with a reason; reverses a confirmed one with a reason" do
      sign_in confirmer
      to_cancel = pending_advance(10)
      post cancel_inventory_purchase_request_advance_path(request_record, to_cancel), params: { reason: "" }
      expect(to_cancel.reload).to be_pending
      post cancel_inventory_purchase_request_advance_path(request_record, to_cancel), params: { reason: "not needed" }
      expect(to_cancel.reload).to be_cancelled

      to_reverse = pending_advance(20)
      post confirm_inventory_purchase_request_advance_path(request_record, to_reverse)
      sign_in recorder
      post reverse_inventory_purchase_request_advance_path(request_record, to_reverse), params: { reason: "refund" }
      expect(to_reverse.reload).to be_confirmed # recorder lacks confirm permission
      sign_in confirmer
      post reverse_inventory_purchase_request_advance_path(request_record, to_reverse), params: { reason: "refund" }
      expect(to_reverse.reload).to be_reversed
    end
  end

  describe "pages" do
    it "shows the advances section with totals and the table on the purchase request" do
      advance = pending_advance(100)
      Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: advance.id, actor: confirmer).confirm!
      sign_in recorder

      get inventory_purchase_request_path(request_record)
      html = Nokogiri::HTML(response.body)

      expect(html.at_css("#advances")).to be_present
      expect(html.at_css("[data-testid='advance-summary-total']").text).to include("242.00")
      expect(html.at_css("[data-testid='advance-summary-advances']").text).to include("100.00")
      expect(html.at_css("[data-testid='advance-summary-remaining']").text).to include("142.00")
      expect(html.at_css("[data-testid='advance-summary-count']").text.strip).to eq("1")
      expect(html.at_css("#advance-#{advance.id}").text).to include(I18n.t("inventory.purchase_request_advances.method_labels.company_cash"))
      expect(response.body).to include(new_inventory_purchase_request_advance_path(request_record))
    end

    it "hides the add button from users without the permission" do
      sign_in pr_only
      get inventory_purchase_request_path(request_record)
      expect(response.body).not_to include(new_inventory_purchase_request_advance_path(request_record))
    end

    it "renders the new-advance form in Arabic with the custody options limited to the user's own account" do
      own   = create(:custody_account, business: business, user: recorder, name: "My Float")
      other = create(:custody_account, business: business, user: create(:user, business: business), name: "Other Float")
      recorder.update!(preferred_locale: "ar")
      sign_in recorder

      get new_inventory_purchase_request_advance_path(request_record)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('dir="rtl"', "إضافة دفعة مقدمة", "من عهدة الموظف", "دفع مباشر من الشركة")
      options = Nokogiri::HTML(response.body).css("select[name='purchase_request_advance[custody_account_id]'] option")
                                             .map { |o| o["value"] }.compact_blank
      expect(options).to eq([ own.id.to_s ])
      expect(options).not_to include(other.id.to_s)
    end

    it "before approving a custody-paid receipt, shows current balance, amount due and a negative balance after — and approval succeeds" do
      advance = pending_advance(100)
      Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: advance.id, actor: confirmer).confirm!
      holder  = create(:user, business: business, first_name: "Ahmed")
      account = create(:custody_account, business: business, user: holder).tap do |a|
        a.custody_transactions.create!(business: business, txn_type: "top_up", amount: 50)
        a.refresh_balance!
      end
      receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: request_record,
                                              received_on: Date.current, created_by: holder,
                                              funding_source_kind: "employee_custody", funding_source: account)
      receipt.items.build(product: product, quantity: 2, unit_cost: 121, purchase_request_item: request_record.items.first)
      receipt.save!
      receipt.update_column(:approval_status, "pending_approval")
      approver = user_with("view_inventory", "approve_goods_receipts")
      approver.update!(preferred_locale: "ar")
      sign_in approver

      get inventory_goods_receipt_path(receipt)
      html = Nokogiri::HTML(response.body)
      expect(html.at_css("#custody-payment-preview")).to be_present
      expect(html.at_css("[data-testid='custody-preview-current']").text).to include("50.00")
      expect(html.at_css("[data-testid='custody-preview-due']").text).to include("142.00")
      expect(html.at_css("[data-testid='custody-preview-after']").text).to include("-92.00")
      expect(html.at_css("[data-testid='custody-preview-negative']")).to be_present
      approve_button = html.css("form[action='#{approve_inventory_goods_receipt_path(receipt)}'] button, " \
                                "form[action='#{approve_inventory_goods_receipt_path(receipt)}'] input[type=submit]").first
      expect(approve_button).to be_present
      expect(approve_button["disabled"]).to be_nil
      expect(response.body).not_to include("غير كاف")

      post approve_inventory_goods_receipt_path(receipt)
      expect(receipt.reload).to be_approval_approved
      expect(account.reload.computed_balance).to eq(-92)
    end

    it "shows the amount due on a receipt created from the request" do
      advance = pending_advance(100)
      Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: advance.id, actor: confirmer).confirm!
      receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: request_record,
                                              received_on: Date.current, created_by: owner, funding_source_kind: "supplier_credit")
      receipt.items.build(product: product, quantity: 2, unit_cost: 121, purchase_request_item: request_record.items.first)
      receipt.save!
      sign_in owner

      get inventory_goods_receipt_path(receipt)
      html = Nokogiri::HTML(response.body)
      expect(html.at_css("#purchase-request-advances-summary")).to be_present
      expect(html.at_css("[data-testid='advance-amount-due']").text).to include("142.00") # preview before approval

      receipt.update_column(:approval_status, "pending_approval")
      Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: confirmer).approve!
      get inventory_goods_receipt_path(receipt)
      html = Nokogiri::HTML(response.body)
      expect(html.at_css("[data-testid='advance-amount-due']").text).to include("142.00")
      expect(response.body).to include(I18n.t("inventory.purchase_request_advances.advance_ref", id: advance.id))
    end
  end
end
