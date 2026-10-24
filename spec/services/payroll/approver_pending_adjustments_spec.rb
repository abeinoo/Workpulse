require "rails_helper"

# Payroll::Approver — the only path to finalized / paid — refuses both
# transitions while the period still has adjustments pending review: review-time
# adjustments linked to the period AND standalone ones for its business + month.
RSpec.describe Payroll::Approver, "pending-adjustment guard" do
  let(:business) { create(:business) }
  let(:admin)    { create(:user, :accountant, business: business) }
  let(:creator)  { create(:user, :accountant, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:period)   { create(:payroll_period, :branch_review_completed, business: business, period_year: 2026, period_month: 6) }

  def linked(status: "pending_review", period: self.period)
    create(:payroll_adjustment, :cash_incentive, payroll_period: period, business: period.business,
           user: create(:user, business: period.business), created_by: creator, review_status: status)
  end

  # Standalone (no payroll_period_id) adjustments are only created while their
  # month is still a draft (or has no period yet) — the model refuses them later.
  def standalone(business: self.business, year: 2026, month: 6, status: "pending_review")
    target = PayrollPeriod.find_by(business: business, period_year: year, period_month: month)
    saved  = target&.status
    target&.update_column(:status, "draft")
    create(:payroll_adjustment, :cash_incentive, payroll_period: nil, business: business,
           period_year: year, period_month: month, user: create(:user, business: business),
           created_by: create(:user, business: business), review_status: status)
  ensure
    target&.update_column(:status, saved) if saved
  end

  def advance = described_class.advance(period: PayrollPeriod.find(period.id), by: admin)

  def finalize_error(count) = I18n.t("payroll.errors.pending_adjustments_finalize", count: count)
  def pay_error(count)      = I18n.t("payroll.errors.pending_adjustments_pay", count: count)

  describe "finalize" do
    it "finalizes as before when nothing is pending (approved/rejected adjustments don't count)" do
      linked(status: "approved")
      linked(status: "rejected")
      standalone(status: "approved")

      result = advance

      expect(result).to be_success
      expect(period.reload).to have_attributes(status: "finalized", finalized_by_id: admin.id)
      expect(PayrollAuditLog.where(payroll_period: period, action_type: "finalized").count).to eq(1)
    end

    it "refuses with one pending linked adjustment — no status change, no audit log" do
      linked

      result = advance

      expect(result).not_to be_success
      expect(result.error).to eq(finalize_error(1))
      expect(period.reload).to have_attributes(status: "branch_review_completed", finalized_by_id: nil)
      expect(PayrollAuditLog.where(payroll_period: period, action_type: "finalized")).to be_empty
    end

    it "counts every pending adjustment once — linked, standalone, and one also materialised as a line item" do
      materialised = linked
      entry = create(:payroll_entry, payroll_period: period, user: materialised.user)
      create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive", amount: 500.0,
             source_type: "PayrollAdjustment", source_id: materialised.id, review_status: "pending_review")
      linked
      standalone
      standalone

      expect(advance.error).to eq(finalize_error(4))
    end

    it "refuses for a standalone pending adjustment of the period's month (no line item yet)" do
      standalone

      expect(advance.error).to eq(finalize_error(1))
      expect(period.reload.status).to eq("branch_review_completed")
    end

    it "ignores pending adjustments of other businesses and other months" do
      other_business = create(:business)
      standalone(business: other_business)                    # same month, other business
      standalone(month: 7)                                    # same business, next month
      standalone(year: 2025)                                  # same month, other year
      other_period = create(:payroll_period, :under_review, business: business, period_year: 2026, period_month: 5)
      linked(period: other_period)                            # linked to another period

      expect(advance).to be_success
    end

    it "counts pending adjustments for employees of every branch (periods are business-wide)" do
      branch_a = create(:branch, business: business)
      branch_b = create(:branch, business: business)
      shift    = create(:shift, :fixed_time, business: business)
      [ branch_a, branch_b ].each do |branch|
        adj = linked
        create(:shift_assignment, user: adj.user, branch: branch, shift: shift)
      end

      expect(advance.error).to eq(finalize_error(2))
    end

    it "applies to the under_review → finalized override path too" do
      period.update_column(:status, "under_review")
      linked

      expect(advance.error).to eq(finalize_error(1))
      expect(period.reload.status).to eq("under_review")
    end

    it "finalizes once the pending adjustment has been reviewed" do
      adj = linked
      expect(advance).not_to be_success

      adj.reject_by!(admin, notes: "Not justified")

      expect(advance).to be_success
      expect(period.reload.status).to eq("finalized")
    end
  end

  describe "mark paid" do
    # Legacy state: a pending adjustment left in a period finalized before this
    # guard existed (reviews are refused in locked periods, so it stays pending).
    before do
      linked
      period.update_column(:status, "finalized")
    end

    it "refuses with the payment-specific message and settles nothing" do
      result = advance

      expect(result).not_to be_success
      expect(result.error).to eq(pay_error(1))
      expect(period.reload.status).to eq("finalized")
      expect(PayrollAuditLog.where(payroll_period: period, action_type: "paid")).to be_empty
    end

    it "pays as before once nothing is pending" do
      PayrollAdjustment.where(payroll_period: period).update_all(review_status: "rejected")

      expect(advance).to be_success
      expect(period.reload.status).to eq("paid")
    end
  end
end
