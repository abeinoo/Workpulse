require "rails_helper"

RSpec.describe Branch, type: :model do
  subject { build(:branch) }

  describe "associations" do
    it { is_expected.to belong_to(:business) }
    # History is never deleted or detached with its branch (BUG-026).
    it { is_expected.to have_many(:attendance_records).dependent(:restrict_with_error) }
    it { is_expected.to have_many(:payroll_periods).dependent(:restrict_with_error) }
    it { is_expected.to have_many(:shift_assignments).dependent(:restrict_with_error) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:branch_type) }

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

  describe "branch_type" do
    it "defaults to sales" do
      expect(create(:branch).branch_type).to eq("sales")
    end

    it "supports a laundry branch without disturbing existing branch-based associations" do
      laundry = create(:branch, branch_type: "laundry")
      expect(laundry).to be_branch_type_laundry
      expect(laundry.shift_assignments).to eq([])
      expect(laundry.attendance_records).to eq([])
    end

    it "supports every documented branch type" do
      %w[sales laundry warehouse headquarters maintenance other].each do |type|
        expect(build(:branch, branch_type: type)).to be_valid
      end
    end

    it "rejects an unsupported branch_type string instead of silently accepting it" do
      expect {
        build(:branch, branch_type: "not_a_real_type")
      }.to raise_error(ArgumentError)
    end

    it "no longer accepts the old warehouse_ops value — it was renamed to warehouse" do
      expect(Branch.branch_types.keys).to include("warehouse")
      expect(Branch.branch_types.keys).not_to include("warehouse_ops")
    end
  end

  describe ".laundry_transfer_eligible" do
    let(:business) { create(:business) }
    let!(:sales_branch)       { create(:branch, business: business, branch_type: "sales") }
    let!(:laundry_branch)     { create(:branch, business: business, branch_type: "laundry") }
    let!(:warehouse_branch)   { create(:branch, business: business, branch_type: "warehouse") }
    let!(:headquarters_branch) { create(:branch, business: business, branch_type: "headquarters") }
    let!(:maintenance_branch) { create(:branch, business: business, branch_type: "maintenance") }
    let!(:other_branch)       { create(:branch, business: business, branch_type: "other") }

    it "includes only sales and laundry branches" do
      result = Branch.laundry_transfer_eligible

      expect(result).to include(sales_branch, laundry_branch)
      expect(result).not_to include(warehouse_branch, headquarters_branch, maintenance_branch, other_branch)
    end
  end
end
