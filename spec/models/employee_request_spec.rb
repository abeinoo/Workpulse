require "rails_helper"

RSpec.describe EmployeeRequest, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:reviewed_by).class_name("User").optional }
    it { is_expected.to have_one(:advance).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:employee_request) }

    it { is_expected.to validate_presence_of(:request_type) }
    it { is_expected.to validate_presence_of(:requested_for_date) }
    it { is_expected.to validate_presence_of(:reason) }

    context "salary_advance requires amount" do
      it "is invalid without amount" do
        req = build(:employee_request, :salary_advance, amount: nil)
        expect(req).not_to be_valid
        expect(req.errors[:amount]).to be_present
      end

      it "is invalid with non-positive amount" do
        req = build(:employee_request, :salary_advance, amount: 0)
        expect(req).not_to be_valid
      end

      it "is valid with a positive amount" do
        expect(build(:employee_request, :salary_advance)).to be_valid
      end
    end

    context "non-salary_advance does not require amount" do
      it "is valid without amount" do
        expect(build(:employee_request, :late_permission)).to be_valid
      end
    end
  end

  describe "affects_payroll derivation" do
    it "is false for salary_advance" do
      req = create(:employee_request, :salary_advance)
      expect(req.affects_payroll).to be false
    end

    it "is true for late_permission" do
      req = create(:employee_request, :late_permission)
      expect(req.affects_payroll).to be true
    end

    it "is true for early_leave" do
      req = create(:employee_request, :early_leave)
      expect(req.affects_payroll).to be true
    end
  end

  describe ".exempts?" do
    let(:business) { create(:business) }
    let(:user)     { create(:user, business: business) }
    let(:date)     { Date.current + 1.day }

    it "returns true for an approved request that affects_payroll" do
      create(:employee_request, :late_permission, :approved,
             user: user, requested_for_date: date)
      expect(EmployeeRequest.exempts?(user: user, date: date, type: "late_permission")).to be true
    end

    it "returns false for a pending request" do
      create(:employee_request, :late_permission,
             user: user, requested_for_date: date)
      expect(EmployeeRequest.exempts?(user: user, date: date, type: "late_permission")).to be false
    end

    it "returns false when the date does not match" do
      create(:employee_request, :late_permission, :approved,
             user: user, requested_for_date: date)
      expect(EmployeeRequest.exempts?(user: user, date: date + 1.day, type: "late_permission")).to be false
    end

    it "returns false for salary_advance (affects_payroll is false)" do
      create(:employee_request, :salary_advance, :approved,
             user: user, requested_for_date: date)
      expect(EmployeeRequest.exempts?(user: user, date: date, type: "salary_advance")).to be false
    end
  end

  describe "scopes" do
    let(:business)        { create(:business) }
    let(:branch)          { create(:branch, business: business) }
    let(:branch_employee) { create(:user, business: business) }
    let!(:pending)  { create(:employee_request, user: branch_employee) }
    let!(:approved) { create(:employee_request, :approved, user: branch_employee) }
    let!(:other)    { create(:employee_request) }

    before { create(:user_branch, user: branch_employee, branch: branch) }

    describe ".pending_for_branch" do
      it "returns pending requests for the given branch ids via user_branches" do
        result = EmployeeRequest.pending_for_branch([branch.id])
        expect(result).to include(pending)
        expect(result).not_to include(approved, other)
      end
    end

    describe ".for_business" do
      it "returns requests whose user belongs to the business" do
        result = EmployeeRequest.for_business(business)
        expect(result).to include(pending, approved)
        expect(result).not_to include(other)
      end
    end
  end
end
