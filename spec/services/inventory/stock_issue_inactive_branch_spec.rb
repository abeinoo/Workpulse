require "rails_helper"

# BUG-029 (D3) — stock issues at an inactive branch, through the services and
# the StockIssue model under them (every creation path):
# * refused: creating one there, moving one there, submitting, approving
#   (including import-batch completion), and a direct importer call;
# * allowed: confirming an issue approved before the deactivation, rejecting,
#   cancelling, deleting a draft, voiding.
RSpec.describe "Stock issues at an inactive branch (BUG-029)", type: :model do
  let(:business)  { create(:business) }
  let(:requester) { create(:user, business: business) }
  let(:approver)  { create(:user, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  before do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def issue_in(status, at: branch)
    i = business.stock_issues.build(warehouse: warehouse, branch: at, issued_on: Date.current, created_by: requester)
    i.items.build(product: product, quantity: 2)
    i.status = status
    i.submitted_by = requester unless status == :draft
    i.approved_by  = approver if status == :approved
    i.save!
    i
  end

  def deactivate(record = branch) = record.update_column(:active, false)
  def inactive_error?(issue)      = issue.errors.where(:branch, :branch_inactive).present?

  describe "creating" do
    it "is refused at an inactive branch through the draft service" do
      deactivate
      issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: requester)
      issue.items.build(product: product, quantity: 1)

      expect { @result = Inventory::StockIssueDraftService.new(issue, actor: requester).call }
        .not_to change { [ StockIssue.count, AuditLog.where(auditable_type: "StockIssue").count ] }
      expect(@result).not_to be_ok
      expect(inactive_error?(issue)).to be(true)
    end
  end

  describe "editing" do
    it "refuses moving an issue to an inactive branch" do
      issue  = issue_in(:draft)
      closed = business.branches.create!(name: "Closed", active: true).tap { |b| deactivate(b) }

      result = Inventory::StockIssueEditor.new(stock_issue_id: issue.id, actor: requester,
                                               attributes: { branch_id: closed.id }).call

      expect(result).not_to be_ok
      expect(issue.reload.branch_id).to eq(branch.id)
    end

    it "still lets an existing draft there be edited without moving it" do
      issue = issue_in(:draft)
      deactivate

      result = Inventory::StockIssueEditor.new(stock_issue_id: issue.id, actor: requester,
                                               attributes: { notes: "corrected" }).call

      expect(result).to be_ok
      expect(issue.reload.notes).to eq("corrected")
    end
  end

  describe "submitting" do
    it "is refused at an inactive branch" do
      issue = issue_in(:draft)
      deactivate

      result = Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: requester).call

      expect(result).not_to be_ok
      expect(issue.reload).to be_draft
      expect(AuditLog.where(auditable: issue, action: "submit_for_approval")).to be_empty
    end
  end

  describe "approving" do
    it "is refused at an inactive branch, reserving nothing" do
      issue = issue_in(:pending_approval)
      deactivate

      result = Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!

      expect(result).not_to be_ok
      expect(issue.reload).to be_pending_approval
      expect(issue.approved_by).to be_nil
      expect(AuditLog.where(auditable: issue, action: "approve")).to be_empty
    end

    it "still allows rejecting it" do
      issue = issue_in(:pending_approval)
      deactivate

      result = Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).reject!(reason: "closed")

      expect(result).to be_ok
      expect(issue.reload).to be_rejected
    end
  end

  describe "an issue approved before the deactivation" do
    it "can still be confirmed, posting its stock movement" do
      issue = issue_in(:approved)
      deactivate

      result = Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver).call

      expect(result).to be_ok
      expect(issue.reload).to be_issued
      expect(issue.inventory_movements.count).to eq(1)
    end

    it "can still be cancelled" do
      issue = issue_in(:approved)
      deactivate

      result = Inventory::StockIssueCancellation.new(stock_issue_id: issue.id, actor: approver, reason: "closed").call

      expect(result).to be_ok
      expect(issue.reload).to be_cancelled
    end

    it "can be voided once issued" do
      issue = issue_in(:approved)
      Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver).call
      deactivate

      result = Inventory::DocumentVoider.new(issue.reload, user: approver, reason: "wrong branch").call

      expect(result).to be_ok
      expect(issue.reload).to be_voided
    end
  end

  it "lets a draft there be deleted" do
    issue = issue_in(:draft)
    deactivate

    issue.destroy

    expect(StockIssue.exists?(issue.id)).to be(false)
  end

  describe "CSV import" do
    let(:rows) { [ { row_number: 2, "sku" => "SH-1", "quantity" => "1" } ] }

    it "refuses a direct importer call for an inactive branch, writing nothing" do
      deactivate

      expect {
        Inventory::Imports::StockIssueImporter.new(business, rows, warehouse: warehouse, branch: branch, user: requester).call
      }.to raise_error(ActiveRecord::RecordInvalid, /#{I18n.t("activerecord.errors.messages.branch_inactive")}/)
      expect(StockIssue.count).to eq(0)
      expect(StockIssueImportBatch.count).to eq(0)
    end

    it "refuses completing an import batch once its branch is inactive" do
      mixed = rows + [ { row_number: 3, "sku" => "NOPE", "quantity" => "1" } ]
      batch = Inventory::Imports::StockIssueImporter.new(business, mixed, warehouse: warehouse, branch: branch,
                                                                          user: requester).call.batch
      Inventory::Imports::StockIssueImportRowResolver.new(business, batch.rows.first.id, skip: true).call
      deactivate

      result = Inventory::Imports::StockIssueImportBatchCompleter.new(business, batch.id, user: requester).call

      expect(result).not_to be_ok
      expect(batch.reload).not_to be_completed
      expect(batch.stock_issue.reload).to be_draft
    end

    it "still imports for an active branch" do
      result = Inventory::Imports::StockIssueImporter.new(business, rows, warehouse: warehouse, branch: branch,
                                                                          user: requester).call
      expect(result.issue).to be_pending_approval
    end
  end
end
