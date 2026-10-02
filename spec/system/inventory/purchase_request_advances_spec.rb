require "rails_helper"

# Arabic (RTL) browser flows for advance payments: record from employee
# custody → confirm by a second user → totals → receiving page amount due →
# reversal restores custody.
RSpec.describe "Purchase Request advance payments (Arabic)", type: :system do
  let(:business)  { create(:business) }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 121) }

  def user_with(*permissions, first_name:)
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions)
    create(:user, business: business, first_name: first_name, preferred_locale: "ar")
      .tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let!(:recorder)  { user_with("view_inventory", "manage_purchase_request_advances", first_name: "Ahmed") }
  let!(:confirmer) { user_with("view_inventory", "confirm_purchase_request_advances", "approve_goods_receipts", first_name: "Sara") }
  let!(:custody) do
    create(:custody_account, business: business, user: recorder, name: "Ahmed Float").tap do |a|
      a.custody_transactions.create!(business: business, txn_type: "top_up", amount: 500)
      a.refresh_balance!
    end
  end
  let!(:request_record) do
    pr = PurchaseRequest.new(business: business, supplier: supplier, created_by: recorder)
    pr.items.build(product: product, quantity: 2, unit_price: 121, source_warehouse: warehouse) # 242
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def ar(key, **) = I18n.t("inventory.purchase_request_advances.#{key}", locale: :ar, **)

  def summary(testid) = find("[data-testid='#{testid}']").text

  it "records a custody advance, confirms it as another user, shows totals, and reverses it" do
    sign_in recorder
    visit inventory_purchase_request_path(request_record)

    expect(page).to have_css("html[dir='rtl']")
    within("#advances") do
      expect(page).to have_content(ar("title"))
      click_link ar("add_action")
    end

    fill_in ar("fields.amount"), with: "100"
    expect(page).not_to have_select(ar("fields.custody_account")) # hidden until custody is chosen
    choose ar("source_kinds.employee_custody")
    find("select[name='purchase_request_advance[custody_account_id]'] option",
         text: /#{Regexp.escape(recorder.full_name)}/).select_option
    fill_in ar("fields.reference"), with: "DEP-77"
    click_button ar("submit")

    expect(page).to have_content(ar("created"))
    advance = PurchaseRequestAdvance.last
    within("#advance-#{advance.id}") do
      expect(page).to have_content(ar("statuses.pending"))
      expect(page).to have_content(ar("method_labels.employee_custody", name: recorder.full_name))
      expect(page).not_to have_button(ar("actions.confirm")) # recorder lacks the confirm permission
    end
    expect(custody.reload.computed_balance).to eq(500) # nothing moved yet

    sign_out recorder
    sign_in confirmer
    visit inventory_purchase_request_path(request_record)
    within("#advance-#{advance.id}") do
      accept_confirm { click_button ar("actions.confirm") }
    end

    expect(page).to have_content(ar("confirmed"))
    within("#advance-#{advance.id}") { expect(page).to have_content(ar("statuses.confirmed")) }
    expect(summary("advance-summary-total")).to include("242")
    expect(summary("advance-summary-advances")).to include("100")
    expect(summary("advance-summary-remaining")).to include("142")
    expect(summary("advance-summary-count")).to eq("1")
    expect(custody.reload.computed_balance).to eq(400)

    within("#advance-#{advance.id}") do
      find("summary", text: ar("actions.reverse")).click
      fill_in ar("reason_label"), with: "تم استرداد العربون"
      accept_confirm { click_button ar("actions.reverse_submit") }
    end

    expect(page).to have_content(ar("reversed"))
    within("#advance-#{advance.id}") { expect(page).to have_content(ar("statuses.reversed")) }
    expect(summary("advance-summary-remaining")).to include("242")
    expect(custody.reload.computed_balance).to eq(500)
  end

  it "previews a negative balance after payment without blocking it (50 − 100 = −50)" do
    custody.custody_transactions.create!(business: business, txn_type: "adjustment", amount: -450)
    custody.refresh_balance!

    sign_in recorder
    visit new_inventory_purchase_request_advance_path(request_record)
    choose ar("source_kinds.employee_custody")
    find("select[name='purchase_request_advance[custody_account_id]'] option",
         text: /#{Regexp.escape(recorder.full_name)}/).select_option

    expect(find("[data-testid='custody-current']").text).to include("50.00")
    expect(page).not_to have_css("[data-testid='custody-negative-note']", visible: true)

    fill_in ar("fields.amount"), with: "100"
    expect(find("[data-testid='custody-advance']").text).to include("100.00")
    expect(find("[data-testid='custody-after']").text).to include("−50.00")
    expect(page).to have_css("[data-testid='custody-negative-note']", visible: true,
                             text: ar("custody_preview.negative_note"))

    click_button ar("submit")
    expect(page).to have_content(ar("created"))
    advance = PurchaseRequestAdvance.last
    expect(advance).to have_attributes(amount: 100, custody_account_id: custody.id, status: "pending")

    sign_out recorder
    sign_in confirmer
    visit inventory_purchase_request_path(request_record)
    within("#advance-#{advance.id}") { accept_confirm { click_button ar("actions.confirm") } }
    expect(page).to have_content(ar("confirmed"))
    expect(custody.reload.computed_balance).to eq(-50)
  end

  it "shows the amount due now on the receiving page" do
    advance = Inventory::PurchaseRequestAdvanceRecorder.new(
      purchase_request_id: request_record.id, actor: recorder,
      params: { amount: 100, source_kind: "company_cash", paid_on: Date.current }
    ).call.advance
    Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: advance.id, actor: confirmer).confirm!

    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: request_record,
                                            received_on: Date.current, created_by: recorder, funding_source_kind: "company_cash")
    receipt.items.build(product: product, quantity: 2, unit_cost: 121, purchase_request_item: request_record.items.first)
    receipt.save!
    receipt.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: confirmer).approve!

    sign_in confirmer
    visit inventory_goods_receipt_path(receipt)

    within("#purchase-request-advances-summary") do
      expect(page).to have_content(ar("receiving.request_total"))
      expect(page).to have_content(ar("receiving.advances_paid"))
      expect(page).to have_content(ar("receiving.received_value"))
      expect(page).to have_content(ar("receiving.amount_due_now"))
      expect(find("[data-testid='advance-amount-due']").text).to include("142")
    end
  end
end
