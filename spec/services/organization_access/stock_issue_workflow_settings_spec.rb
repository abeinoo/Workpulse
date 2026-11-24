require "rails_helper"

# The Stock Issue workflow settings — independent per workflow, owner-only,
# audited fail-closed, and kept from every other save of the business.
RSpec.describe OrganizationAccess::StockIssueWorkflowSettings do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  def change(actor: owner, self_approval: "allowed", quick_issue_enabled: false)
    described_class.call(business: business, actor: actor, self_approval: self_approval, quick_issue_enabled: quick_issue_enabled)
  end

  it "defaults to today's behaviour: self-approval forbidden, Quick Issue enabled" do
    expect(business.stock_issue_self_approval).to eq("forbidden")
    expect(business.quick_issue_enabled?).to be true
  end

  it "changes each workflow's setting independently and audits before / after" do
    expect(change(self_approval: "allowed", quick_issue_enabled: true)).to be_ok
    expect(business.reload.stock_issue_self_approval_allowed?).to be true
    expect(business.quick_issue_enabled?).to be true

    expect(change(self_approval: "allowed", quick_issue_enabled: false)).to be_ok
    entry = AuditLog.where(auditable: business, action: "stock_issue_workflow_settings").order(:id).last
    expect(entry.actor_id).to eq(owner.id)
    expect(entry.changes_json).to eq("quick_issue_enabled" => [ true, false ])
  end

  it "is owner-only" do
    admin = create(:user, business: business,
                          permission_role: create(:permission_role, business: business, permissions: %w[manage_settings]))
    expect(change(actor: admin)).not_to be_ok
    expect(business.reload.stock_issue_self_approval).to eq("forbidden")
  end

  it "refuses unknown values" do
    expect(change(self_approval: "sometimes")).not_to be_ok
    expect(change(quick_issue_enabled: "maybe")).not_to be_ok
  end

  it "changes nothing when the audit entry cannot be written" do
    allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid, AuditLog.new)
    expect(change).not_to be_ok
    expect(business.reload.quick_issue_enabled?).to be true
  end

  it "keeps the settings from every other save of the business" do
    change(self_approval: "allowed", quick_issue_enabled: false)
    stale = Business.find(business.id)
    stale.settings = (stale.settings || {}).merge("stock_issue_self_approval" => "forbidden", "quick_issue_enabled" => true,
                                                  "finance_overdue_days" => 9)
    stale.save!

    business.reload
    expect(business.stock_issue_self_approval).to eq("allowed")
    expect(business.quick_issue_enabled?).to be false
    expect(business.settings["finance_overdue_days"]).to eq(9)
  end
end
