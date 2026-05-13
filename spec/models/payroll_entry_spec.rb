require "rails_helper"

RSpec.describe PayrollEntry, type: :model do
  subject { build(:payroll_entry) }

  describe "associations" do
    it { is_expected.to belong_to(:payroll_period) }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to have_many(:payroll_line_items).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:base_salary) }
    it { is_expected.to validate_presence_of(:net_salary) }

    it "requires working_days >= 0" do
      expect(build(:payroll_entry, working_days: -1)).not_to be_valid
      expect(build(:payroll_entry, working_days: 0)).to be_valid
    end

    it "requires days_worked >= 0" do
      expect(build(:payroll_entry, days_worked: -1)).not_to be_valid
      expect(build(:payroll_entry, days_worked: 0)).to be_valid
    end

    describe "uniqueness of user per payroll period" do
      it "rejects a duplicate entry for the same user in the same period" do
        existing = create(:payroll_entry)
        duplicate = build(:payroll_entry,
                          payroll_period: existing.payroll_period,
                          user:           existing.user)
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:user_id]).to be_present
      end

      it "allows the same user in a different period" do
        entry = create(:payroll_entry)
        other_period = create(:payroll_period, business: entry.payroll_period.business,
                              period_month: ((entry.payroll_period.period_month % 12) + 1))
        expect(build(:payroll_entry, payroll_period: other_period, user: entry.user)).to be_valid
      end
    end
  end

  describe "#gross_salary" do
    it "sums base_salary, total_overtime, and total_bonuses" do
      entry = build(:payroll_entry, base_salary: 5_000, total_overtime: 300, total_bonuses: 200)
      expect(entry.gross_salary).to eq(5_500.0)
    end
  end

  describe "#total_adjustments" do
    it "returns bonuses minus deductions minus advances" do
      entry = build(:payroll_entry,
                    total_bonuses:     200.0,
                    total_deductions:  100.0,
                    advances_deducted: 50.0)
      expect(entry.total_adjustments).to eq(50.0)
    end
  end
end
