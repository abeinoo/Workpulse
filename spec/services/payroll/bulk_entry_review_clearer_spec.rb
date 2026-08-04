require "rails_helper"

RSpec.describe Payroll::BulkEntryReviewClearer do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :under_review) }
  let(:employee1) { create(:user, business: business) }
  let(:employee2) { create(:user, business: business) }
  let(:reviewer)  { create(:user, :accountant, business: business) }

  let!(:flagged_entry_1) { create(:payroll_entry, payroll_period: period, user: employee1, needs_review: true) }
  let!(:flagged_entry_2) { create(:payroll_entry, payroll_period: period, user: employee2, needs_review: true) }

  def run(actor: reviewer, entry_ids: nil)
    described_class.call(period: period, actor: actor, entry_ids: entry_ids)
  end

  it "clears every flagged entry in the period" do
    result = run
    expect(result.success?).to be true
    expect(result.cleared).to eq(2)
    expect(flagged_entry_1.reload.needs_review?).to be false
    expect(flagged_entry_2.reload.needs_review?).to be false
  end

  it "restricts to the given entry_ids when provided" do
    result = run(entry_ids: [ flagged_entry_1.id ])
    expect(result.cleared).to eq(1)
    expect(flagged_entry_1.reload.needs_review?).to be false
    expect(flagged_entry_2.reload.needs_review?).to be true
  end

  it "writes one audit log entry per cleared entry" do
    expect { run }.to change(PayrollAuditLog, :count).by(2)
    expect(PayrollAuditLog.last(2).map(&:action_type)).to all(eq("entry_review_cleared"))
  end

  it "does not write an audit log when nothing is flagged" do
    flagged_entry_1.update!(needs_review: false)
    flagged_entry_2.update!(needs_review: false)
    expect { run }.not_to change(PayrollAuditLog, :count)
  end

  it "rejects an actor without complete_branch_review" do
    other = create(:user, business: business)
    result = run(actor: other)
    expect(result.success?).to be false
    expect(flagged_entry_1.reload.needs_review?).to be true
  end

  it "rejects once the period is locked" do
    period.update_column(:status, "finalized")
    result = run
    expect(result.success?).to be false
  end
end
