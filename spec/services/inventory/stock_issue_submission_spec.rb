require "rails_helper"

RSpec.describe Inventory::StockIssueSubmission, type: :model do
  let(:business)  { create(:business) }
  let(:requester) { create(:user, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }

  def draft_issue
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: requester)
    i.items.build(product: product, quantity: 1)
    i.status = :draft
    i.save!
    i
  end

  def submit(issue, actor: requester)
    described_class.new(stock_issue_id: issue.id, actor: actor).call
  end

  it "moves draft to pending_approval, records submitted_by/at, and logs it" do
    issue = draft_issue
    result = submit(issue)

    expect(result.ok?).to be(true)
    issue.reload
    expect(issue).to be_pending_approval
    expect(issue.submitted_by).to eq(requester)
    expect(issue.submitted_at).to be_present

    log = AuditLog.for_auditable(issue).find_by(action: "submit_for_approval")
    expect(log).to be_present
    expect(log.actor).to eq(requester)
    expect(log.changes_json["status"]).to eq(%w[draft pending_approval])
  end

  it "never posts inventory movements" do
    issue = draft_issue
    submit(issue)
    expect(issue.inventory_movements.count).to eq(0)
  end

  it "refuses to submit an already-pending issue" do
    issue = draft_issue
    issue.update_column(:status, "pending_approval")

    result = submit(issue)
    expect(result.ok?).to be(false)
    expect(issue.reload).to be_pending_approval
  end

  it "refuses to submit an issued issue" do
    issue = draft_issue
    issue.update_column(:status, "issued")

    result = submit(issue)
    expect(result.ok?).to be(false)
  end
end
