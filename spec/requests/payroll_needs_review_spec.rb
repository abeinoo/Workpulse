require "rails_helper"

RSpec.describe "Payroll needs_review acknowledgement", type: :request do
  let(:business)   { create(:business) }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:employee)   { create(:user, business: business) }
  let(:no_perm)    { create(:user, business: business) }

  let(:period) { create(:payroll_period, business: business, status: :under_review) }
  let!(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee, needs_review: true)
  end

  describe "PATCH mark_reviewed" do
    it "clears the flag for an authorised user" do
      sign_in accountant
      patch mark_reviewed_payroll_period_payroll_entry_path(period, entry)

      expect(response).to redirect_to(payroll_period_payroll_entry_path(period, entry))
      expect(entry.reload.needs_review?).to be false
    end

    it "writes an audit log" do
      sign_in accountant
      expect {
        patch mark_reviewed_payroll_period_payroll_entry_path(period, entry)
      }.to change { PayrollAuditLog.where(action_type: "entry_review_cleared").count }.by(1)
    end

    it "forbids a user without complete_branch_review" do
      sign_in no_perm
      patch mark_reviewed_payroll_period_payroll_entry_path(period, entry)

      expect(entry.reload.needs_review?).to be true
    end
  end

  describe "PATCH mark_all_reviewed" do
    let!(:other_entry) do
      create(:payroll_entry, payroll_period: period, user: create(:user, business: business), needs_review: true)
    end

    it "clears every flagged entry in the period for an authorised user" do
      sign_in accountant
      patch mark_all_reviewed_payroll_period_path(period)

      expect(response).to redirect_to(payroll_period_path(period))
      expect(entry.reload.needs_review?).to be false
      expect(other_entry.reload.needs_review?).to be false
    end

    it "restricts to the given entry_ids when provided" do
      sign_in accountant
      patch mark_all_reviewed_payroll_period_path(period), params: { entry_ids: [ entry.id ] }

      expect(entry.reload.needs_review?).to be false
      expect(other_entry.reload.needs_review?).to be true
    end

    it "forbids a user without complete_branch_review" do
      sign_in no_perm
      patch mark_all_reviewed_payroll_period_path(period)

      expect(entry.reload.needs_review?).to be true
    end
  end
end
