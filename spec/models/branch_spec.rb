require "rails_helper"

RSpec.describe Branch, type: :model do
  subject { build(:branch) }

  describe "associations" do
    it { is_expected.to belong_to(:business) }
    it { is_expected.to have_many(:attendance_records).dependent(:destroy) }
    it { is_expected.to have_many(:payroll_periods).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }

    context "when geolocation_enabled is true" do
      subject { build(:branch, :with_geolocation) }

      it { is_expected.to validate_presence_of(:latitude) }
      it { is_expected.to validate_presence_of(:longitude) }
      it { is_expected.to validate_presence_of(:radius_meters) }

      it "is invalid without latitude" do
        branch = build(:branch, :with_geolocation, latitude: nil)
        expect(branch).not_to be_valid
      end

      it "validates latitude is in range -90..90" do
        expect(build(:branch, :with_geolocation, latitude: 91)).not_to be_valid
        expect(build(:branch, :with_geolocation, latitude: -91)).not_to be_valid
        expect(build(:branch, :with_geolocation, latitude: 45)).to be_valid
      end

      it "validates longitude is in range -180..180" do
        expect(build(:branch, :with_geolocation, longitude: 181)).not_to be_valid
        expect(build(:branch, :with_geolocation, longitude: -181)).not_to be_valid
        expect(build(:branch, :with_geolocation, longitude: 90)).to be_valid
      end

      it "validates radius_meters is positive" do
        expect(build(:branch, :with_geolocation, radius_meters: 0)).not_to be_valid
        expect(build(:branch, :with_geolocation, radius_meters: -1)).not_to be_valid
        expect(build(:branch, :with_geolocation, radius_meters: 100)).to be_valid
      end
    end

    context "when geolocation_enabled is false" do
      it "does not require latitude, longitude, or radius" do
        expect(build(:branch, geolocation_enabled: false, latitude: nil,
                     longitude: nil, radius_meters: nil)).to be_valid
      end
    end
  end

  describe "scopes" do
    let(:business) { create(:business) }
    let!(:active_branch)   { create(:branch, business: business) }
    let!(:inactive_branch) { create(:branch, :inactive, business: business) }
    let!(:other_business_branch) { create(:branch) }

    describe ".active" do
      it "returns only active branches" do
        expect(Branch.active).to include(active_branch)
        expect(Branch.active).not_to include(inactive_branch)
      end
    end

    describe ".for_business" do
      it "returns only branches belonging to the given business" do
        expect(Branch.for_business(business)).to include(active_branch, inactive_branch)
        expect(Branch.for_business(business)).not_to include(other_business_branch)
      end
    end
  end
end
