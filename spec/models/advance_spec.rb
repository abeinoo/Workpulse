require "rails_helper"

RSpec.describe Advance, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:employee_request) }
  end

  describe "validations" do
    subject { build(:advance) }

    it { is_expected.to validate_presence_of(:total_amount) }
    it { is_expected.to validate_presence_of(:remaining_amount) }
    it { is_expected.to validate_presence_of(:issued_at) }

    it "requires total_amount >= 0" do
      expect(build(:advance, total_amount: -1)).not_to be_valid
    end

    it "requires remaining_amount >= 0" do
      expect(build(:advance, remaining_amount: -1)).not_to be_valid
    end
  end

  describe "#repay!" do
    subject(:advance) { create(:advance, total_amount: 1_000, remaining_amount: 1_000) }

    it "reduces remaining_amount by the payment" do
      advance.repay!(400)
      expect(advance.remaining_amount).to eq(600.0)
    end

    it "stays active when some amount remains" do
      advance.repay!(400)
      expect(advance.status).to eq("active")
    end

    it "marks status as fully_repaid when payment covers remaining balance" do
      advance.repay!(1_000)
      expect(advance.status).to eq("fully_repaid")
      expect(advance.remaining_amount).to eq(0.0)
    end

    it "does not reduce remaining_amount below zero" do
      advance.repay!(5_000)
      expect(advance.remaining_amount).to eq(0.0)
      expect(advance.status).to eq("fully_repaid")
    end

    it "persists the changes to the database" do
      advance.repay!(500)
      expect(advance.reload.remaining_amount).to eq(500.0)
    end
  end

  describe "#repaid_amount" do
    it "returns the difference between total and remaining" do
      advance = build(:advance, total_amount: 1_000, remaining_amount: 600)
      expect(advance.repaid_amount).to eq(400.0)
    end

    it "returns 0.0 when nothing has been repaid" do
      advance = build(:advance, total_amount: 1_000, remaining_amount: 1_000)
      expect(advance.repaid_amount).to eq(0.0)
    end
  end
end
