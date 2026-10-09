require "rails_helper"

# Browser behaviour of "اعتماد الطلبات المحددة" on the Purchase Requests
# index: eligible-only selection, live count/total, select-all (current page,
# indeterminate), clearing on page/filter change, the confirmation dialog, and
# the all-or-nothing server outcome.
RSpec.describe "Purchase Requests bulk approval", type: :system do
  let(:business)  { create(:business) }
  let(:requester) { create(:user, business: business) }
  let(:approver) do
    role = business.permission_roles.create!(name: "PR Approver", permissions: %w[view_inventory approve_purchase_requests])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end
  let(:product) { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 1) }

  def request_with(total:, status: "pending_approval")
    pr = business.purchase_requests.build(supplier: nil, created_by: requester)
    pr.items.build(product: product, quantity: 1, unit_price: total)
    pr.save!
    pr.update_columns(status: status, submitted_by_id: requester.id)
    pr
  end

  def row_box(pr) = find(".pr-bulk-check-row[value='#{pr.id}']")
  def master      = find(".pr-bulk-check-all")
  def bar         = find("[data-purchase-request-bulk-approve-target='actionBar']", visible: :all)

  it "selects, totals exactly, confirms and approves (supplier-less requests included)" do
    a = request_with(total: 2200)
    b = request_with(total: 242)
    c = request_with(total: 600)
    draft = request_with(total: 999, status: "draft")
    sign_in approver
    visit inventory_purchase_requests_path

    expect(bar).not_to be_visible
    expect(row_box(draft)).to be_disabled

    row_box(a).check
    row_box(b).check
    expect(bar).to be_visible
    within(bar) do
      expect(page).to have_css("[data-purchase-request-bulk-approve-target='countBadge']", text: "2")
      expect(page).to have_text("SAR 2,442.00")
    end
    expect(master.evaluate_script("this.indeterminate")).to be(true)

    row_box(c).check
    within(bar) { expect(page).to have_text("SAR 3,042.00") }
    expect(master).to be_checked

    click_button I18n.t("inventory.purchase_requests.bulk.approve")
    expect(page).to have_text(I18n.t("inventory.purchase_requests.bulk.modal_body", count: 3, total: "SAR 3,042.00"))

    expect {
      click_button I18n.t("inventory.purchase_requests.bulk.confirm")
      expect(page).to have_text(I18n.t("inventory.purchase_requests.bulk_approved", count: 3, total: "SAR 3,042.00"))
    }.to change { PurchaseRequest.approved.count }.by(3)

    expect([ a, b, c ].map { |pr| pr.reload.status }).to all(eq("approved"))
    expect(draft.reload).to be_draft
    expect(bar).not_to be_visible # selection cleared on the refreshed list
  end

  it "select-all picks only eligible rows on the current page and toggles off again" do
    eligible = Array.new(2) { |i| request_with(total: 10 + i) }
    request_with(total: 5, status: "approved")
    sign_in approver
    visit inventory_purchase_requests_path

    master.check
    eligible.each { |pr| expect(row_box(pr)).to be_checked }
    expect(all(".pr-bulk-check-row:checked").size).to eq(2)
    within(bar) { expect(page).to have_text("SAR 21.00") }

    master.uncheck
    expect(all(".pr-bulk-check-row:checked")).to be_empty
    expect(bar).not_to be_visible
  end

  it "clears the selection when the page or the filters change, and on browser back" do
    Array.new(Inventory::PurchaseRequestsController::PER_PAGE + 1) { |i| request_with(total: 1 + i) }
    sign_in approver
    visit inventory_purchase_requests_path

    master.check
    expect(all(".pr-bulk-check-row:checked").size).to eq(Inventory::PurchaseRequestsController::PER_PAGE)

    click_link I18n.t("common.next")
    expect(page).to have_text(I18n.t("common.page_of", page: 2, total: 2))
    expect(all(".pr-bulk-check-row:checked")).to be_empty
    expect(bar).not_to be_visible

    page.go_back
    expect(page).to have_text(I18n.t("common.page_of", page: 1, total: 2))
    expect(all(".pr-bulk-check-row:checked")).to be_empty

    first(".pr-bulk-check-row").check
    select I18n.t("inventory.purchase_requests.statuses.pending_approval"), from: "status"
    click_button I18n.t("common.search")
    expect(page).to have_current_path(/status=pending_approval/)
    expect(all(".pr-bulk-check-row:checked")).to be_empty
  end

  it "fails as a whole when another approver handled a selected request meanwhile" do
    a = request_with(total: 100)
    b = request_with(total: 200)
    sign_in approver
    visit inventory_purchase_requests_path

    row_box(a).check
    row_box(b).check
    click_button I18n.t("inventory.purchase_requests.bulk.approve")

    b.update_columns(status: "approved") # approved by someone else after the page loaded

    click_button I18n.t("inventory.purchase_requests.bulk.confirm")
    expect(page).to have_text(b.request_number)
    expect(page).to have_text(I18n.t("inventory.purchase_requests.errors.bulk_stale", numbers: b.request_number))
    expect(a.reload).to be_pending_approval
    expect(row_box(b)).to be_disabled # refreshed list reflects the new state
  end

  it "AR: shows the Arabic bar, dialog and success message" do
    a = request_with(total: 2200)
    approver.update!(preferred_locale: "ar")
    sign_in approver
    visit inventory_purchase_requests_path

    row_box(a).check
    within(bar) { expect(page).to have_text("إجمالي قيمة الطلبات المحددة") }
    click_button "اعتماد الطلبات المحددة"
    expect(page).to have_text("اعتماد طلبات الشراء")
    click_button "تأكيد الاعتماد"
    expect(page).to have_text("تم اعتماد طلب شراء واحد بإجمالي")
    expect(a.reload).to be_approved
  end
end
