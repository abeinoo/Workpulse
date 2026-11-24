require "rails_helper"

# Pins the Stock Issue authorization boundaries:
# * the Quick Issue authorization context is created and passed ONLY by
#   Inventory::StockIssueQuickIssue — no controller, job or other service may
#   hand a context to the Stock Issue workflow services;
# * Stock Issues are authorized by WAREHOUSE access (Inventory::IssueWarehouseReach):
#   no consuming-branch access or branch-to-warehouse resolution in Inventory;
# * Inventory never reads shift assignments itself.
RSpec.describe "Stock Issue authorization boundaries" do
  def app_files(glob) = Dir[Rails.root.join(glob)].map { |f| Pathname(f).relative_path_from(Rails.root).to_s }

  it "lets only the Quick Issue service pass a workflow context" do
    offenders = app_files("app/**/*.rb").reject { |f| f == "app/services/inventory/stock_issue_quick_issue.rb" }.select do |file|
      File.read(Rails.root.join(file)).match?(/context:\s*CONTEXT|StockIssueQuickIssue::CONTEXT/)
    end
    expect(offenders).to be_empty
  end

  it "never passes a context: from a controller to the Stock Issue services" do
    offenders = app_files("app/controllers/**/*.rb").select do |file|
      File.read(Rails.root.join(file)).match?(/StockIssue(DraftService|Submission|Approval|ConfirmationService)\.new\([^)]*context:/m)
    end
    expect(offenders).to be_empty
  end

  it "keeps Inventory off shift assignments" do
    offenders = app_files("app/{services,controllers,policies,views}/inventory/**/*.{rb,erb}").select do |file|
      File.read(Rails.root.join(file)).match?(/\b(ShiftAssignment|Shifts::AssignmentResolver|BranchMembership)\b/)
    end
    expect(offenders).to be_empty
  end

  it "has retired the Stock Issue branch-assignment feature completely" do
    %w[OrganizationAccess::StockIssueBranchAccess StockIssueBranchAssignment OrganizationAccess::PrimaryBranchProvider
       Workforce::PrimaryBranchProvider Admin::UserStockIssueBranchesController].each do |name|
      expect(name.safe_constantize).to be_nil, name
    end
    expect(Rails.application.routes.url_helpers).not_to respond_to(:admin_user_stock_issue_branches_path)
    expect(UserPolicy.instance_methods).not_to include(:manage_stock_issue_branches?)
    offenders = app_files("{app,config}/**/*.{rb,erb,yml}").select do |file|
      File.read(Rails.root.join(file)).match?(/StockIssueBranch(Access|Assignment)|manage_branch_access|PrimaryBranchProvider/)
    end
    expect(offenders).to be_empty
  end

  it "authorizes Stock Issues by warehouse only — no branch access or branch-to-warehouse resolver" do
    expect(defined?(Inventory::IssueBranchReach)).to be_nil
    expect(defined?(Inventory::BranchWarehouseResolver)).to be_nil
    offenders = app_files("app/{services,controllers,policies,views}/inventory/**/*.{rb,erb}").select do |file|
      File.read(Rails.root.join(file)).match?(/IssueBranchReach|BranchWarehouseResolver/)
    end
    expect(offenders).to be_empty

    %w[stock_issue_draft_service stock_issue_editor stock_issue_approval stock_issue_confirmation_service
       stock_issue_quick_issue imports/stock_issue_importer].each do |service|
      expect(File.read(Rails.root.join("app/services/inventory/#{service}.rb"))).to include("IssueWarehouseReach"), service
    end
  end

  it "serves Quick Issue from its one route (no nested product route)" do
    expect(Rails.application.routes.url_helpers).not_to respond_to(:new_inventory_product_quick_issue_path)
  end

  it "keeps Quick Issue single-product: no multi-line view, contract or merging" do
    expect(Rails.root.join("app/views/inventory/quick_issues/_line_fields.html.erb")).not_to exist
    views = Dir[Rails.root.join("app/views/inventory/quick_issues/*.erb")].map { |f| File.read(f) }.join
    expect(views).not_to match(/items_attributes|line-items|fields_for/)

    service = File.read(Rails.root.join("app/services/inventory/stock_issue_quick_issue.rb"))
    expect(service).not_to match(/\blines:|normalized_lines|merged/)
    expect(Inventory::StockIssueQuickIssue.instance_method(:initialize).parameters)
      .to include([ :keyreq, :product_id ], [ :keyreq, :quantity ])
      .and(satisfy { |params| params.none? { |_, name| name == :lines } })
  end
end
