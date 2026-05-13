require "rails_helper"

RSpec.describe PayrollPeriod, type: :model do
  subject { build(:payroll_period) }

  describe "associations" do
    it { is_expected.to belong_to(:business) }
    it { is_expected.to have_many(:payroll_entries).dependent(:destroy) }
    it { is_expected.to have_many(:payroll_period_branch_reviews).dependent(:destroy) }
    it { is_expected.to have_many(:payroll_adjustments).dependent(:nullify) }
    it { is_expected.to have_many(:payroll_audit_logs).dependent(:nullify) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:period_year) }
    it { is_expected.to validate_presence_of(:period_month) }
    it { is_expected.to validate_presence_of(:working_days) }

    it "requires period_year to be greater than 2000" do
      expect(build(:payroll_period, period_year: 2000)).not_to be_valid
      expect(build(:payroll_period, period_year: 2001)).to be_valid
    end

    it "requires period_month to be between 1 and 12" do
      expect(build(:payroll_period, period_month: 0)).not_to be_valid
      expect(build(:payroll_period, period_month: 13)).not_to be_valid
      expect(build(:payroll_period, period_month: 6)).to be_valid
    end

    it "requires working_days to be greater than zero" do
      expect(build(:payroll_period, working_days: 0)).not_to be_valid
      expect(build(:payroll_period, working_days: 22)).to be_valid
    end

    it "enforces one period per business per month" do
      business = create(:business)
      create(:payroll_period, business: business, period_year: 2025, period_month: 3)
      duplicate = build(:payroll_period, business: business, period_year: 2025, period_month: 3)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:period_year]).to be_present
    end

    it "allows the same month for different businesses" do
      create(:payroll_period, period_year: 2025, period_month: 3)
      other = build(:payroll_period, period_year: 2025, period_month: 3)
      expect(other).to be_valid
    end
  end

  describe "#period_label" do
    it "returns the month name and year" do
      period = build(:payroll_period, period_year: 2025, period_month: 4)
      expect(period.period_label).to eq("April 2025")
    end
  end

  describe "#period_start" do
    it "returns the first day of the period month" do
      period = build(:payroll_period, period_year: 2025, period_month: 3)
      expect(period.period_start).to eq(Date.new(2025, 3, 1))
    end
  end

  describe "#period_end" do
    it "returns the last day of the period month" do
      period = build(:payroll_period, period_year: 2025, period_month: 2)
      expect(period.period_end).to eq(Date.new(2025, 2, 28))
    end

    it "handles leap years correctly" do
      period = build(:payroll_period, period_year: 2024, period_month: 2)
      expect(period.period_end).to eq(Date.new(2024, 2, 29))
    end
  end

  describe "cascading destruction" do
    let(:business) { create(:business) }
    let(:branch)   { create(:branch, business: business) }
    let(:period)   { create(:payroll_period, business: business, branch: branch) }

    context "dependent: :destroy" do
      it "destroys payroll_entries when period is destroyed" do
        entry = create(:payroll_entry, payroll_period: period)
        expect { period.destroy! }.to change { PayrollEntry.count }.by(-1)
        expect(PayrollEntry.find_by(id: entry.id)).to be_nil
      end

      it "destroys payroll_line_items (via entries) when period is destroyed" do
        entry     = create(:payroll_entry, payroll_period: period)
        line_item = create(:payroll_line_item, payroll_entry: entry)
        expect { period.destroy! }.to change { PayrollLineItem.count }.by(-1)
        expect(PayrollLineItem.find_by(id: line_item.id)).to be_nil
      end

      it "destroys payroll_period_branch_reviews when period is destroyed" do
        reviewer = create(:user, :super_admin, business: business)
        review   = create(:payroll_period_branch_review,
                          payroll_period: period, branch: branch, reviewer: reviewer)
        expect { period.destroy! }.to change { PayrollPeriodBranchReview.count }.by(-1)
        expect(PayrollPeriodBranchReview.find_by(id: review.id)).to be_nil
      end
    end

    context "dependent: :nullify (preserves record, clears FK)" do
      it "nullifies payroll_adjustment.payroll_period_id but keeps the adjustment" do
        admin      = create(:user, :super_admin, business: business)
        employee   = create(:user, business: business)
        adjustment = create(:payroll_adjustment,
                            payroll_period: period,
                            user:           employee,
                            created_by:     admin)

        expect { period.destroy! }.not_to change { PayrollAdjustment.count }
        expect(adjustment.reload.payroll_period_id).to be_nil
      end

      it "nullifies payroll_audit_log.payroll_period_id but preserves the log" do
        actor = create(:user, :super_admin, business: business)
        log   = create(:payroll_audit_log, payroll_period: period, actor: actor)

        expect { period.destroy! }.not_to change { PayrollAuditLog.count }
        expect(log.reload.payroll_period_id).to be_nil
      end

      it "preserves the delete audit log created just before destroy" do
        actor = create(:user, :super_admin, business: business)
        log   = PayrollAuditLog.create!(
          payroll_period: period,
          actor:          actor,
          action_type:    :deleted,
          from_status:    period.status,
          to_status:      nil
        )

        period.destroy!

        surviving = PayrollAuditLog.find_by(id: log.id)
        expect(surviving).not_to be_nil
        expect(surviving.payroll_period_id).to be_nil
        expect(surviving.action_type).to eq("deleted")
      end
    end

    context "no orphan records after destroy" do
      it "leaves no PayrollEntry, PayrollLineItem, or PayrollPeriodBranchReview rows" do
        actor    = create(:user, :super_admin, business: business)
        reviewer = create(:user, :super_admin, business: business)
        employee = create(:user, business: business)

        entry     = create(:payroll_entry, payroll_period: period, user: employee)
        create(:payroll_line_item, payroll_entry: entry)
        create(:payroll_period_branch_review,
               payroll_period: period, branch: branch, reviewer: reviewer)
        create(:payroll_audit_log, payroll_period: period, actor: actor)
        create(:payroll_adjustment, payroll_period: period, user: employee, created_by: actor)

        period.destroy!

        expect(PayrollEntry.where(payroll_period_id: period.id)).to be_empty
        expect(PayrollLineItem.joins(:payroll_entry)
                              .where(payroll_entries: { payroll_period_id: period.id })).to be_empty
        expect(PayrollPeriodBranchReview.where(payroll_period_id: period.id)).to be_empty
      end
    end
  end

  describe "regeneration (PeriodGenerator idempotency)" do
    let(:business) { create(:business) }
    let(:branch)   { create(:branch, business: business) }
    let(:admin)    { create(:user, :super_admin, business: business) }
    let(:period)   { create(:payroll_period, business: business, branch: branch) }

    it "clears existing entries when regenerating a draft period" do
      employee = create(:user, business: business)
      entry    = create(:payroll_entry, payroll_period: period, user: employee)

      period.payroll_entries.destroy_all

      expect(PayrollEntry.find_by(id: entry.id)).to be_nil
    end

    it "adjustments survive entry destruction (payroll_period_id preserved during destroy_all)" do
      employee   = create(:user, business: business)
      adjustment = create(:payroll_adjustment,
                          payroll_period: period,
                          user:           employee,
                          created_by:     admin)

      period.payroll_entries.destroy_all

      expect(adjustment.reload.payroll_period_id).to eq(period.id)
    end
  end
end
