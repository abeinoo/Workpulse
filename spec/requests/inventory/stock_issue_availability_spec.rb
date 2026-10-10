require "rails_helper"

RSpec.describe "Inventory::StockIssues stock availability", type: :request do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:sugar)     { business.products.create!(name: "Sugar", sku: "SUG-1", initial_cost_price: 10, average_cost_price: 10) }

  let(:creator_role)   { create(:permission_role, business: business, permissions: %w[view_inventory manage_stock_issues]) }
  let(:creator)        { create(:user, business: business, permission_role: creator_role) }
  let(:approver_role)  { create(:permission_role, business: business, permissions: %w[view_inventory approve_stock_issues]) }
  let(:approver)       { create(:user, business: business, permission_role: approver_role) }
  let(:confirmer_role) { create(:permission_role, business: business, permissions: %w[view_inventory confirm_stock_issues]) }
  let(:confirmer)      { create(:user, business: business, permission_role: confirmer_role) }

  def receive!(qty)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: sugar, quantity: qty, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def pending_issue(qty)
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: creator)
    i.items.build(product: sugar, quantity: qty)
    i.status       = :pending_approval
    i.submitted_by = creator
    i.submitted_at = Time.current
    i.save!
    i
  end

  it "reserves on approval and refuses the third of three one-unit issues against two on hand" do
    receive!(2)
    issues = Array.new(3) { pending_issue(1) }

    sign_in approver
    issues.first(2).each do |issue|
      post approve_inventory_stock_issue_path(issue)
      expect(issue.reload).to be_approved
    end

    post approve_inventory_stock_issue_path(issues.last)
    expect(response).to redirect_to(inventory_stock_issue_path(issues.last))
    expect(flash[:alert]).to include("Other approved stock issues have already reserved 2 of the 2 on hand")
    expect(issues.last.reload).to be_pending_approval
  end

  it "shows physical, reserved, available and requested quantities and blocks approval when short" do
    receive!(2)
    2.times { Inventory::StockIssueApproval.new(stock_issue_id: pending_issue(1).id, actor: approver).approve! }
    blocked = pending_issue(1)

    sign_in approver
    get inventory_stock_issue_path(blocked)

    page = Nokogiri::HTML(response.body)
    row  = page.at_css("#stock-availability tr[data-product-id='#{sugar.id}']")
    expect(row.css("td").map { |td| td.text.strip }).to eq(
      [ "Sugar", "2", "2", "0", "1", I18n.t("inventory.stock_issues.availability.insufficient") ]
    )
    expect(page.at_css("#stock-shortage-alert").text).to include(I18n.t("inventory.stock_issues.availability.cannot_approve"))
    expect(page.at_css("#stock-shortage-alert").text).to include(I18n.t("inventory.stock_issues.availability.shortage_reserved"))
    expect(page.at_css("form[action='#{approve_inventory_stock_issue_path(blocked)}'] button[disabled]")).to be_present
  end

  it "shows the availability panel without a blocking alert when stock is sufficient" do
    receive!(5)
    issue = pending_issue(1)

    sign_in approver
    get inventory_stock_issue_path(issue)

    page = Nokogiri::HTML(response.body)
    expect(page.at_css("#stock-availability")).to be_present
    expect(page.at_css("#stock-shortage-alert")).to be_nil
    expect(page.at_css("form[action='#{approve_inventory_stock_issue_path(issue)}'] button[disabled]")).to be_nil
  end

  it "flags issues that can't currently be fulfilled on the index" do
    receive!(1)
    Inventory::StockIssueApproval.new(stock_issue_id: pending_issue(1).id, actor: approver).approve!
    blocked = pending_issue(1)

    sign_in approver
    get inventory_stock_issues_path

    page = Nokogiri::HTML(response.body)
    flagged = page.css("[data-testid='insufficient-stock-badge']")
    expect(flagged.size).to eq(1)
    expect(flagged.first.ancestors("tr").first["data-clickable-row-url-value"]).to eq(inventory_stock_issue_path(blocked))
  end

  it "keeps approval and confirmation behind their own permissions" do
    receive!(5)
    issue = pending_issue(1)

    sign_in confirmer
    post approve_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_pending_approval

    sign_in creator
    post approve_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_pending_approval

    sign_in approver
    post approve_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_approved
    post confirm_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_approved

    sign_in confirmer
    post confirm_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_issued
    expect(sugar.reload.current_stock).to eq(4)
  end
end
