require "rails_helper"

RSpec.describe ObligationPostponement, type: :model do
  subject(:postponement) { build(:obligation_postponement) }

  describe "associations" do
    it { is_expected.to belong_to(:employee_obligation) }
    it { is_expected.to belong_to(:performed_by).class_name("User") }
  end

  describe "validations" do
    it { is_expected.to be_valid }

    it "rejects an invalid postponement_type" do
      expect { build(:obligation_postponement, postponement_type: "something_else") }.to raise_error(ArgumentError)
    end

    it "accepts both defined postponement types" do
      expect(build(:obligation_postponement, postponement_type: "next_month")).to be_valid
      expect(build(:obligation_postponement, postponement_type: "extend_loan")).to be_valid
    end

    it "rejects an out-of-range original_month" do
      expect(build(:obligation_postponement, original_month: 13)).not_to be_valid
    end

    it "rejects a non-positive amount" do
      expect(build(:obligation_postponement, amount: 0)).not_to be_valid
    end

    it "prevents postponing the same installment twice" do
      obligation = create(:employee_obligation)
      create(:obligation_postponement, employee_obligation: obligation,
             original_year: 2026, original_month: 8)
      duplicate = build(:obligation_postponement, employee_obligation: obligation,
                        original_year: 2026, original_month: 8)
      expect(duplicate).not_to be_valid
    end

    it "allows postponing a different installment on the same obligation" do
      obligation = create(:employee_obligation)
      create(:obligation_postponement, employee_obligation: obligation,
             original_year: 2026, original_month: 8)
      other = build(:obligation_postponement, employee_obligation: obligation,
                    original_year: 2026, original_month: 9, target_year: 2026, target_month: 10)
      expect(other).to be_valid
    end
  end

  describe "#original_label / #target_label" do
    it "formats the month and year" do
      postponement.original_month = 8
      postponement.original_year  = 2026
      postponement.target_month   = 9
      postponement.target_year    = 2026
      expect(postponement.original_label).to eq("#{I18n.t('date.month_names')[8]} 2026")
      expect(postponement.target_label).to eq("#{I18n.t('date.month_names')[9]} 2026")
    end
  end
end
