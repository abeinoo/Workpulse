require "rails_helper"

# Arabic (RTL) browser flows for advances, which FUND the request's
# responsible employee's custody (Mohamed): record an employee custody
# transfer → posted at once (no confirmation step) → supplier totals unchanged,
# the funding shown → reversal by a user holding Reverse / Cancel restores both
# custodies; a company cash funding preview; an advance still pending from the
# old workflow is only cancelled; and the receiving page amount due for a
# historical (legacy) supplier-payment advance.
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

  # Ahmed records advances from his own custody (500); Mohamed is responsible (200).
  let!(:recorder) { user_with("view_inventory", "manage_purchase_request_advances", "create_purchase_requests", first_name: "Ahmed") }
  let!(:custody) do
    create(:custody_account, business: business, user: recorder, name: "Ahmed Float").tap do |a|
      a.custody_transactions.create!(business: business, txn_type: "top_up", amount: 500)
      a.refresh_balance!
    end
  end
  let!(:responsible) { purchaser_with_custody(business, first_name: "Mohamed", balance: 200, preferred_locale: "ar") }
  let(:responsible_custody) { custody_of(responsible) }
  let!(:confirmer) { user_with("view_inventory", "confirm_purchase_request_advances", "approve_goods_receipts", first_name: "Sara") }
  let!(:request_record) do
    pr = PurchaseRequest.new(business: business, supplier: supplier, created_by: recorder, responsible_employee: responsible)
    pr.items.build(product: product, quantity: 2, unit_price: 121, source_warehouse: warehouse) # 242
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def ar(key, **) = I18n.t("inventory.purchase_request_advances.#{key}", locale: :ar, **)

  def summary(testid) = find("[data-testid='#{testid}']").text

  def balances = [ custody.reload.computed_balance, responsible_custody.reload.computed_balance ]

  it "records an employee custody transfer — posted at once — shows the funding, and another user reverses it" do
    sign_in recorder
    visit inventory_purchase_request_path(request_record)

    expect(page).to have_css("html[dir='rtl']")
    within("#advances") do
      expect(page).to have_content(ar("title"))
      click_link ar("add_action")
    end

    expect(find("[data-testid='recipient-name']").text).to eq(responsible.full_name)
    fill_in ar("fields.amount"), with: "100"
    expect(find("[data-testid='recipient-after']").text).to include("300.00")
    expect(page).not_to have_select(ar("fields.source_employee")) # hidden until a transfer is chosen
    choose ar("source_kinds.employee_custody")
    find("select[name='purchase_request_advance[custody_account_id]'] option",
         text: /#{Regexp.escape(recorder.full_name)}/).select_option
    fill_in ar("fields.reference"), with: "DEP-77"
    expect(page).to have_content(ar("immediate_hint"))
    click_button ar("submit")

    expect(page).to have_content(ar("created"))
    advance = PurchaseRequestAdvance.last
    expect(advance).to have_attributes(custody_account_id: custody.id, recipient_custody_account_id: responsible_custody.id,
                                       status: "confirmed", confirmed_by_id: recorder.id)
    within("#advance-#{advance.id}") do
      expect(page).to have_content(ar("statuses.confirmed"))
      expect(page).to have_content(ar("method_labels.funding_employee_custody"))
      expect(find("[data-testid='advance-funding-parties']").text)
        .to eq("#{recorder.full_name} #{ar('transfer_arrow')} #{responsible.full_name}")
      expect(page).to have_no_css("form[action$='/confirm']") # no confirmation step
      expect(page).to have_no_css("summary", text: ar("actions.reverse")) # recorder lacks Reverse / Cancel
    end
    expect(balances).to eq([ 400, 300 ]) # moved when recorded

    sign_out recorder
    sign_in confirmer
    visit inventory_purchase_request_path(request_record)
    # Funding, not a supplier payment: the request's paid / remaining figures do not move.
    expect(summary("advance-summary-advances")).to include("0.00")
    expect(summary("advance-summary-funded")).to include("100.00")
    expect(summary("advance-summary-remaining")).to include("242")
    expect(balances).to eq([ 400, 300 ])

    within("#advance-#{advance.id}") do
      find("summary", text: ar("actions.reverse")).click
      fill_in ar("reason_label"), with: "تم استرداد المبلغ"
      accept_confirm { click_button ar("actions.reverse_submit") }
    end

    expect(page).to have_content(ar("reversed"))
    within("#advance-#{advance.id}") { expect(page).to have_content(ar("statuses.reversed")) }
    expect(balances).to eq([ 500, 200 ])
  end

  it "previews the source going negative (allowed) and the responsible balance; company cash needs no source" do
    custody.custody_transactions.create!(business: business, txn_type: "adjustment", amount: -450)
    custody.refresh_balance!

    sign_in recorder
    visit new_inventory_purchase_request_advance_path(request_record)
    # The responsible employee's own account is never a source.
    expect(page).to have_no_css("select[name='purchase_request_advance[custody_account_id]'] option",
                                text: responsible.full_name, visible: :all)

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
    expect(find("[data-testid='recipient-after']").text).to include("300.00")

    choose ar("source_kinds.company_cash")
    expect(page).not_to have_select(ar("fields.source_employee"))
    fill_in ar("fields.reference"), with: "CASH-1"
    click_button ar("submit")

    expect(page).to have_content(ar("created"))
    advance = PurchaseRequestAdvance.last
    expect(advance).to have_attributes(source_kind: "company_cash", custody_account_id: nil,
                                       recipient_custody_account_id: responsible_custody.id, status: "confirmed")
    expect(balances).to eq([ 50, 300 ])
  end

  it "an advance still pending from the old workflow is labelled and cancelled with a reason — never executed" do
    old = old_pending_funding_advance(request: request_record, amount: 60, actor: recorder)

    sign_in confirmer
    visit inventory_purchase_request_path(request_record)
    within("#advance-#{old.id}") do
      expect(page).to have_content(ar("statuses.pending"))
      expect(page).to have_content(ar("old_pending_hint"))
      find("summary", text: ar("actions.cancel")).click
      fill_in ar("reason_label"), with: "سُجّلت من جديد"
      accept_confirm { click_button ar("actions.cancel_submit") }
    end

    expect(page).to have_content(ar("cancelled"))
    within("#advance-#{old.id}") { expect(page).to have_content(ar("statuses.cancelled")) }
    expect(balances).to eq([ 500, 200 ])
  end

  it "shows the amount due now on the receiving page (historical supplier-payment advance)" do
    request_record.update_column(:responsible_employee_id, nil) # a legacy request
    legacy_confirmed_advance(request: request_record, amount: 100, actor: confirmer)

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
