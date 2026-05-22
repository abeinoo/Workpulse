require "rails_helper"

RSpec.describe SalaryProfile, type: :model do
  subject { build(:salary_profile) }

  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:salary_type) }
    it { is_expected.to validate_presence_of(:base_amount) }
    it { is_expected.to validate_presence_of(:currency) }
    it { is_expected.to validate_presence_of(:effective_from) }

    it "requires base_amount to be greater than zero" do
      expect(build(:salary_profile, base_amount: 0)).not_to be_valid
      expect(build(:salary_profile, base_amount: -100)).not_to be_valid
      expect(build(:salary_profile, base_amount: 1)).to be_valid
    end

    it "validates salary_type is one of the allowed values" do
      expect(build(:salary_profile, salary_type: "monthly")).to be_valid
      expect(build(:salary_profile, salary_type: "daily")).to be_valid
    end

    describe "overtime_multiplier" do
      it "allows nil (field is optional)" do
        expect(build(:salary_profile, overtime_multiplier: nil)).to be_valid
      end

      it "rejects zero" do
        expect(build(:salary_profile, overtime_multiplier: 0)).not_to be_valid
      end

      it "rejects a value above 5" do
        expect(build(:salary_profile, overtime_multiplier: 5.01)).not_to be_valid
      end

      it "accepts 1.5" do
        expect(build(:salary_profile, overtime_multiplier: 1.5)).to be_valid
      end

      it "accepts the maximum value of 5" do
        expect(build(:salary_profile, overtime_multiplier: 5)).to be_valid
      end
    end
  end

  describe "single active profile enforcement" do
    let(:user) { create(:user) }

    it "deactivates the previous active profile when a new one is created" do
      old = create(:salary_profile, user: user, effective_from: 6.months.ago.to_date)
      expect(old.reload.active?).to be true

      _new_profile = create(:salary_profile, user: user, effective_from: 1.month.ago.to_date)
      expect(old.reload.active?).to be false
    end

    it "allows only one active profile at a time" do
      create(:salary_profile, user: user)
      create(:salary_profile, user: user)
      expect(user.salary_profiles.where(active: true).count).to eq(1)
    end
  end

  describe "immutability of historical profiles" do
    let(:user) { create(:user) }

    it "blocks updating a historical (inactive) profile" do
      old = create(:salary_profile, user: user, effective_from: 6.months.ago.to_date)
      create(:salary_profile, user: user, effective_from: 1.month.ago.to_date)
      old.reload

      old.base_amount = 9_999
      expect(old).not_to be_valid
      expect(old.errors[:base]).to include("Historical salary profiles cannot be modified")
    end

    it "allows updating the active profile" do
      profile = create(:salary_profile, user: user)
      profile.base_amount = 7_000
      expect(profile).to be_valid
    end
  end

  describe ".current_for" do
    let(:user) { create(:user) }

    it "returns the active profile with the most recent effective_from on or before today" do
      old = create(:salary_profile, user: user, effective_from: 2.years.ago.to_date, active: true)
      recent = create(:salary_profile, user: user, effective_from: 1.month.ago.to_date, active: true)

      expect(SalaryProfile.current_for(user)).to eq(recent)
    end

    it "ignores inactive profiles" do
      inactive = create(:salary_profile, user: user, effective_from: 1.month.ago.to_date, active: false)
      active   = create(:salary_profile, user: user, effective_from: 2.months.ago.to_date, active: true)

      expect(SalaryProfile.current_for(user)).to eq(active)
    end

    it "returns nil when the user has no active profile" do
      expect(SalaryProfile.current_for(user)).to be_nil
    end

    it "ignores profiles with a future effective_from" do
      create(:salary_profile, user: user, effective_from: 1.month.from_now.to_date, active: true)
      expect(SalaryProfile.current_for(user)).to be_nil
    end
  end

  describe "scopes" do
    describe ".active" do
      it "returns only active profiles" do
        active   = create(:salary_profile)
        inactive = create(:salary_profile, :inactive)
        expect(SalaryProfile.active).to include(active)
        expect(SalaryProfile.active).not_to include(inactive)
      end
    end
  end
end
