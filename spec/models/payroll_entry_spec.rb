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

  describe "#recalculate_totals!" do
    let(:entry) { create(:payroll_entry, base_salary: 8_800.0, net_salary: 8_800.0) }

    context "with an already_paid cash incentive" do
      before do
        create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive",
               amount: 500.0, review_status: "approved", already_paid: true)
      end

      it "includes the incentive in total_bonuses" do
        entry.recalculate_totals!
        expect(entry.reload.total_bonuses).to eq(500.0)
      end

      it "records it in already_paid_total" do
        entry.recalculate_totals!
        expect(entry.reload.already_paid_total).to eq(500.0)
      end

      it "does not increase net_salary" do
        entry.recalculate_totals!
        expect(entry.reload.net_salary).to eq(8_800.0)
      end
    end

    context "with an unpaid cash incentive" do
      before do
        create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive",
               amount: 500.0, review_status: "approved", already_paid: false)
      end

      it "adds the incentive to net_salary" do
        entry.recalculate_totals!
        expect(entry.reload.net_salary).to eq(9_300.0)
      end

      it "keeps already_paid_total at zero" do
        entry.recalculate_totals!
        expect(entry.reload.already_paid_total).to eq(0.0)
      end
    end

    context "after removing an already_paid adjustment" do
      let!(:li) do
        create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive",
               amount: 500.0, review_status: "approved", already_paid: true)
      end

      before { entry.recalculate_totals! }

      it "zeroes out already_paid_total after the item is destroyed" do
        li.destroy!
        entry.recalculate_totals!
        expect(entry.reload.already_paid_total).to eq(0.0)
        expect(entry.reload.total_bonuses).to eq(0.0)
        expect(entry.reload.net_salary).to eq(8_800.0)
      end
    end

    context "with a mix of paid and unpaid incentives" do
      before do
        create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive",
               amount: 300.0, review_status: "approved", already_paid: true)
        create(:payroll_line_item, payroll_entry: entry, item_type: "commission",
               amount: 200.0, review_status: "approved", already_paid: false)
      end

      it "sums both into total_bonuses" do
        entry.recalculate_totals!
        expect(entry.reload.total_bonuses).to eq(500.0)
      end

      it "only tracks the paid one in already_paid_total" do
        entry.recalculate_totals!
        expect(entry.reload.already_paid_total).to eq(300.0)
      end

      it "adds only the unpaid amount to net_salary" do
        entry.recalculate_totals!
        expect(entry.reload.net_salary).to eq(9_000.0)  # 8800 + 200
      end
    end

    context "with a rejected already_paid item" do
      before do
        create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive",
               amount: 500.0, review_status: "rejected", already_paid: true)
      end

      it "excludes rejected items from all totals" do
        entry.recalculate_totals!
        expect(entry.reload.total_bonuses).to eq(0.0)
        expect(entry.reload.already_paid_total).to eq(0.0)
        expect(entry.reload.net_salary).to eq(8_800.0)
      end
    end
  end
end
