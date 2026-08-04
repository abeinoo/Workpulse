require "rails_helper"

RSpec.describe Payroll::EntryReviewClearer do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :under_review) }
  let(:employee) { create(:user, business: business) }
  let(:reviewer) { create(:user, :accountant, business: business) }
  let(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee, needs_review: true)
  end

  def run(actor: reviewer)
    described_class.call(entry: entry, actor: actor)
  end

  it "clears the needs_review flag" do
    result = run
    expect(result.success?).to be true
    expect(entry.reload.needs_review?).to be false
  end

  it "writes a PayrollAuditLog entry" do
    expect { run }.to change(PayrollAuditLog, :count).by(1)
    log = PayrollAuditLog.last
    expect(log.action_type).to eq("entry_review_cleared")
    expect(log.actor).to eq(reviewer)
  end

  it "rejects an actor without complete_branch_review" do
    other = create(:user, business: business)
    result = run(actor: other)
    expect(result.success?).to be false
    expect(entry.reload.needs_review?).to be true
  end

  it "rejects clearing an entry that is not flagged" do
    entry.update!(needs_review: false)
    result = run
    expect(result.success?).to be false
  end

  it "rejects clearing once the period is locked" do
    period.update_column(:status, "finalized")
    result = run
    expect(result.success?).to be false
    expect(entry.reload.needs_review?).to be true
  end

  it "still allows clearing during branch_review_completed" do
    period.update_column(:status, "branch_review_completed")
    result = run
    expect(result.success?).to be true
    expect(entry.reload.needs_review?).to be false
  end
end
