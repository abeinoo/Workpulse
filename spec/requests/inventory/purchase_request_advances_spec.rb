require "rails_helper"

# Advances fund the request's responsible employee's custody (Rami here).
# Receipt-deduction pages concern historical (legacy) advances, built by
# #legacy_confirmed_advance on a request without a responsible employee.
RSpec.describe "Purchase Request advance payments (HTTP)", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 121) }

  let(:request_record) do
    pr = PurchaseRequest.new(business: business, supplier: supplier, created_by: owner, responsible_employee: responsible)
    pr.items.build(product: product, quantity: 2, unit_price: 121, source_warehouse: warehouse) # 242
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def user_with(*permissions)
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:responsible) { purchaser_with_custody(business, first_name: "Rami") }
  let(:recorder)  { user_with("view_inventory", "manage_purchase_request_advances", "create_purchase_requests") }
  let(:confirmer) { user_with("view_inventory", "confirm_purchase_request_advances") }
  let(:pr_only)   { user_with("view_inventory", "create_purchase_requests", "approve_purchase_requests") }

  def post_advance(amount: 100, source_kind: "company_cash", custody_account_id: nil, key: SecureRandom.uuid)
    post inventory_purchase_request_advances_path(request_record), params: {
      idempotency_key: key,
      purchase_request_advance: { amount: amount, source_kind: source_kind, custody_account_id: custody_account_id,
                                  paid_on: Date.current.to_s, reference: "DEP-9", notes: "deposit" }
    }
  end

  # The request as it was before the funding workflow: no responsible employee.
  def make_legacy_request! = request_record.update_column(:responsible_employee_id, nil)

  # An employee with the purchasing permission (eligible custody holder).
  def purchaser(**attrs)
    @purchaser_role ||= business.permission_roles.create!(name: "Purchaser",
                                                          permissions: %w[view_inventory create_purchase_requests])
    create(:user, business: business, **attrs).tap { |u| u.update_column(:permission_role_id, @purchaser_role.id) }
  end

  # Recorded — and therefore already executed (no confirmation step).
  def recorded_advance(amount = 100)
    Inventory::PurchaseRequestAdvanceRecorder.new(
      purchase_request_id: request_record.id, actor: recorder,
      params: { amount: amount, source_kind: "company_cash", paid_on: Date.current }
    ).call.advance
  end

  describe "recording" do
    it "lets a manage_purchase_request_advances user record an advance, executed at once (no confirmation)" do
      sign_in recorder
      expect { post_advance }.to change(PurchaseRequestAdvance, :count).by(1)

      expect(response).to redirect_to(inventory_purchase_request_path(request_record, anchor: "advances"))
      expect(flash[:notice]).to eq(I18n.t("inventory.purchase_request_advances.created"))
      expect(PurchaseRequestAdvance.last).to have_attributes(status: "confirmed", amount: 100, created_by_id: recorder.id,
                                                             confirmed_by_id: recorder.id)
      expect(custody_of(responsible).reload.computed_balance).to eq(100)
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

    it "records an amount above the request total (242) for every method" do
      sign_in recorder
      own = create(:custody_account, business: business, user: recorder)
      expect { post_advance(amount: 300) }.to change(PurchaseRequestAdvance, :count).by(1)
      expect { post_advance(amount: "24200.50", source_kind: "bank_account") }.to change(PurchaseRequestAdvance, :count).by(1)
      expect { post_advance(amount: 1000, source_kind: "employee_custody", custody_account_id: own.id) }
        .to change(PurchaseRequestAdvance, :count).by(1)
      expect(request_record.advances.order(:id).pluck(:amount)).to eq([ 300, 24_200.5, 1000 ])
      expect(request_record.reload.total_amount).to eq(242)
    end

    it "re-renders the form for a zero or negative amount" do
      sign_in recorder
      [ 0, -5 ].each do |amount|
        expect { post_advance(amount: amount) }.not_to change(PurchaseRequestAdvance, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    it "the form has no maximum and no pending step: it explains the excess and the immediate posting (EN and AR)" do
      recorded_advance(500)
      recorded_advance(70)
      scope = "inventory.purchase_request_advances"

      %w[en ar].each do |locale|
        recorder.update!(preferred_locale: locale)
        sign_in recorder
        get new_inventory_purchase_request_advance_path(request_record)
        page = Nokogiri::HTML(response.body)

        amount = page.at_css("input[name='purchase_request_advance[amount]']")
        expect(amount["max"]).to be_nil
        expect(amount["min"]).to eq("0.01")
        expect(page.at_css("#advance-amount-hint").text).to eq(I18n.t("#{scope}.amount_hint", locale: locale))
        expect(page.at_css("[data-testid='advance-funded-total']").text).to include("570.00")
        expect(page.at_css("[data-testid='advance-pending-total']")).to be_nil
        expect(page.at_css("[data-testid='advance-immediate-hint']").text).to eq(I18n.t("#{scope}.immediate_hint", locale: locale))
        expect(response.body).to include(ERB::Util.html_escape(I18n.t("#{scope}.summary.total", locale: locale)))
        expect(page.at_css("[data-testid='advance-capacity']")).to be_nil
      end
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
      let!(:with_account)    { purchaser(first_name: "Ahmed") }
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
        expect(response.body).not_to include(ERB::Util.html_escape(without_account.full_name))
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

      it "accepts a custody transfer above the balance and posts it at once into a negative balance (50 − 100 = −50)" do
        sign_in manager
        key = SecureRandom.uuid
        expect {
          2.times { post_advance(amount: 100, source_kind: "employee_custody", custody_account_id: ahmed_custody.id, key: key) }
        }.to change(PurchaseRequestAdvance, :count).by(1) # the repeated POST is the same advance

        advance = PurchaseRequestAdvance.last
        expect(advance).to be_confirmed
        expect(ahmed_custody.reload.computed_balance).to eq(-50)
        expect(custody_of(responsible).reload.computed_balance).to eq(100)
        expect(CustodyTransaction.where(txn_type: "transfer").pluck(:amount)).to contain_exactly(-100, 100)
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

  describe "no confirmation step; reverse / cancel" do
    it "there is no confirm endpoint" do
      advance = recorded_advance
      sign_in confirmer
      expect { Rails.application.routes.recognize_path("/inventory/purchase_requests/1/advances/2/confirm", method: :post) }
        .to raise_error(ActionController::RoutingError)
      post "/inventory/purchase_requests/#{request_record.id}/advances/#{advance.id}/confirm"
      expect(response).to have_http_status(:not_found)
      expect(advance.reload).to be_confirmed
    end

    it "the responsible employee cannot record on their own request (blocking state, and the POST is refused)" do
      responsible.permission_role.update!(permissions: responsible.permission_role.permissions + %w[manage_purchase_request_advances])
      sign_in responsible

      get inventory_purchase_request_path(request_record)
      html = Nokogiri::HTML(response.body)
      expect(html.at_css("[data-testid='add-advance-disabled']")).to be_present
      expect(html.at_css("[data-testid='advance-recorder-is-responsible-hint']")).to be_present

      get new_inventory_purchase_request_advance_path(request_record)
      expect(Nokogiri::HTML(response.body).at_css("[data-testid='advance-recorder-is-responsible']")).to be_present
      expect(response.body).not_to include("purchase_request_advance[amount]")

      expect { post_advance }.not_to change(PurchaseRequestAdvance, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(CustodyTransaction.where.not(txn_type: "top_up")).to be_empty
    end

    it "reversing needs confirm_purchase_request_advances (Reverse / Cancel) and a reason" do
      advance = recorded_advance(20)

      [ recorder, pr_only ].each do |user|
        sign_in user
        post reverse_inventory_purchase_request_advance_path(request_record, advance), params: { reason: "refund" }
        expect(advance.reload).to be_confirmed
      end

      sign_in confirmer
      post reverse_inventory_purchase_request_advance_path(request_record, advance), params: { reason: "" }
      expect(advance.reload).to be_confirmed
      post reverse_inventory_purchase_request_advance_path(request_record, advance), params: { reason: "refund" }
      expect(advance.reload).to be_reversed
      expect(custody_of(responsible).reload.computed_balance).to eq(0)
    end

    it "an advance still pending from the old workflow is cancelled with a reason — never executed" do
      old = old_pending_funding_advance(request: request_record, amount: 10, actor: recorder)
      sign_in confirmer
      post cancel_inventory_purchase_request_advance_path(request_record, old), params: { reason: "" }
      expect(old.reload).to be_pending
      post cancel_inventory_purchase_request_advance_path(request_record, old), params: { reason: "not needed" }
      expect(old.reload).to have_attributes(status: "cancelled", cancellation_reason: "not needed")
      expect(CustodyTransaction.where.not(txn_type: "top_up")).to be_empty

      sign_in recorder # manage_purchase_request_advances may cancel one too
      other = old_pending_funding_advance(request: request_record, amount: 5, actor: recorder)
      post cancel_inventory_purchase_request_advance_path(request_record, other), params: { reason: "obsolete" }
      expect(other.reload).to be_cancelled
    end

    it "the page labels an old pending advance and offers only Cancel; a recorded one offers only Reverse" do
      old = old_pending_funding_advance(request: request_record, amount: 10, actor: recorder)
      new_one = recorded_advance(30)
      sign_in confirmer

      get inventory_purchase_request_path(request_record)
      html = Nokogiri::HTML(response.body)
      old_row = html.at_css("#advance-#{old.id}")
      expect(old_row.at_css("[data-testid='advance-old-pending-hint']")).to be_present
      expect(old_row.text).to include(I18n.t("inventory.purchase_request_advances.statuses.pending"))
      expect(old_row.css("form").map { |f| f["action"] })
        .to eq([ cancel_inventory_purchase_request_advance_path(request_record, old) ])

      new_row = html.at_css("#advance-#{new_one.id}")
      expect(new_row.css("form").map { |f| f["action"] })
        .to eq([ reverse_inventory_purchase_request_advance_path(request_record, new_one) ])
      expect(response.body).not_to include("/confirm")
    end
  end

  describe "pages" do
    it "shows the advances section with totals and the table on the purchase request" do
      advance = recorded_advance(100)
      sign_in recorder

      get inventory_purchase_request_path(request_record)
      html = Nokogiri::HTML(response.body)

      expect(html.at_css("#advances")).to be_present
      expect(html.at_css("[data-testid='advance-summary-total']").text).to include("242.00")
      expect(html.at_css("[data-testid='advance-summary-advances']").text).to include("0.00")
      expect(html.at_css("[data-testid='advance-summary-funded']").text).to include("100.00")
      expect(html.at_css("[data-testid='advance-summary-remaining']").text).to include("242.00")
      expect(html.at_css("[data-testid='advance-summary-count']").text.strip).to eq("0")
      row = html.at_css("#advance-#{advance.id}")
      expect(row.text).to include(I18n.t("inventory.purchase_request_advances.method_labels.funding_company_cash"),
                                  I18n.t("inventory.purchase_request_advances.funding_not_supplier_payment"),
                                  responsible.full_name)
      expect(response.body).to include(new_inventory_purchase_request_advance_path(request_record))
    end

    it "hides the add button from users without the permission" do
      sign_in pr_only
      get inventory_purchase_request_path(request_record)
      expect(response.body).not_to include(new_inventory_purchase_request_advance_path(request_record))
    end

    it "renders the new-advance form in Arabic with the custody options limited to the user's own account" do
      own   = create(:custody_account, business: business, user: recorder, name: "My Float")
      other = create(:custody_account, business: business, user: purchaser, name: "Other Float")
      recorder.update!(preferred_locale: "ar")
      sign_in recorder

      get new_inventory_purchase_request_advance_path(request_record)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('dir="rtl"', "إضافة دفعة مقدمة", "تحويل من عهدة موظف", "نقدي من الشركة",
                                       "تحويل بنكي من الشركة", "الموظف المسؤول عن الشراء")
      expect(Nokogiri::HTML(response.body).at_css("[data-testid='recipient-name']").text).to eq(responsible.full_name)
      options = Nokogiri::HTML(response.body).css("select[name='purchase_request_advance[custody_account_id]'] option")
                                             .map { |o| o["value"] }.compact_blank
      expect(options).to eq([ own.id.to_s ])
      expect(options).not_to include(other.id.to_s)
    end

    it "before approving a custody-paid receipt, shows current balance, amount due and a negative balance after — and approval succeeds" do
      make_legacy_request!
      legacy_confirmed_advance(request: request_record, amount: 100, actor: confirmer)
      holder  = create(:user, business: business, first_name: "Ahmed")
      account = create(:custody_account, business: business, user: holder).tap do |a|
        a.custody_transactions.create!(business: business, txn_type: "top_up", amount: 50)
        a.refresh_balance!
      end
      request_record.update_column(:responsible_employee_id, holder.id) # only the responsible employee pays from custody
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

    it "shows the amount due on a receipt created from the request (historical advance)" do
      make_legacy_request!
      advance = legacy_confirmed_advance(request: request_record, amount: 100, actor: confirmer)
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
