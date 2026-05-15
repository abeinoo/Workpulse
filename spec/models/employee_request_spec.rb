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

  describe "shift type compatibility" do
    let(:business) { create(:business) }
    let(:user)     { create(:user, business: business) }
    let(:date)     { Date.current + 1.day }

    context "employee on a fixed_time shift" do
      before do
        shift = create(:shift, :fixed_time, business: business)
        create(:shift_assignment, user: user, shift: shift, effective_from: 1.month.ago.to_date)
      end

      it "allows late_permission requests" do
        req = build(:employee_request, :late_permission, user: user, requested_for_date: date)
        expect(req).to be_valid
      end

      it "allows early_leave requests" do
        req = build(:employee_request, :early_leave, user: user, requested_for_date: date)
        expect(req).to be_valid
      end
    end

    context "employee on an hour_based shift" do
      before do
        shift = create(:shift, :hour_based, business: business)
        create(:shift_assignment, user: user, shift: shift, effective_from: 1.month.ago.to_date)
      end

      it "rejects late_permission requests" do
        req = build(:employee_request, :late_permission, user: user, requested_for_date: date)
        expect(req).not_to be_valid
        expect(req.errors[:request_type]).to be_present
      end

      it "still allows early_leave requests" do
        req = build(:employee_request, :early_leave, user: user, requested_for_date: date)
        expect(req).to be_valid
      end

      it "still allows salary_advance requests" do
        req = build(:employee_request, :salary_advance, user: user, requested_for_date: date)
        expect(req).to be_valid
      end
    end

    context "employee with no active shift assignment" do
      it "does not block any request type" do
        req = build(:employee_request, :late_permission, user: user, requested_for_date: date)
        expect(req).to be_valid
      end
    end
  end

  describe ".approved_minutes" do
    let(:business) { create(:business) }
    let(:user)     { create(:user, business: business) }
    let(:date)     { Date.current + 1.day }

    it "returns duration_minutes for an approved late_permission" do
      create(:employee_request, :late_permission, :approved,
             user: user, requested_for_date: date, duration_minutes: 45)
      expect(EmployeeRequest.approved_minutes(user: user, date: date, type: "late_permission")).to eq(45)
    end

    it "returns 0 for a pending request" do
      create(:employee_request, :late_permission,
             user: user, requested_for_date: date, duration_minutes: 30)
      expect(EmployeeRequest.approved_minutes(user: user, date: date, type: "late_permission")).to eq(0)
    end

    it "returns 0 when the date does not match" do
      create(:employee_request, :late_permission, :approved,
             user: user, requested_for_date: date, duration_minutes: 30)
      expect(EmployeeRequest.approved_minutes(user: user, date: date + 1.day, type: "late_permission")).to eq(0)
    end

    it "returns 0 for salary_advance (affects_payroll is false)" do
      create(:employee_request, :salary_advance, :approved,
             user: user, requested_for_date: date)
      expect(EmployeeRequest.approved_minutes(user: user, date: date, type: "salary_advance")).to eq(0)
    end

    it "returns duration_minutes for an approved early_leave request" do
      create(:employee_request, :early_leave, :approved,
             user: user, requested_for_date: date, duration_minutes: 60)
      expect(EmployeeRequest.approved_minutes(user: user, date: date, type: "early_leave")).to eq(60)
    end
  end

  describe "monthly permission limit" do
    let(:business) { create(:business, max_late_permission_minutes: 120) }
    let(:user)     { create(:user, business: business) }
    let(:date)     { Date.current.beginning_of_month + 5.days }

    it "is valid when duration is within the remaining limit" do
      req = build(:employee_request, :late_permission, user: user,
                  requested_for_date: date, duration_minutes: 60)
      expect(req).to be_valid
    end

    it "is invalid when duration exceeds the remaining limit" do
      create(:employee_request, :late_permission, :approved, user: user,
             requested_for_date: date, duration_minutes: 100)
      req = build(:employee_request, :late_permission, user: user,
                  requested_for_date: date + 1.day, duration_minutes: 30)
      expect(req).not_to be_valid
      expect(req.errors[:duration_minutes]).to be_present
    end

    it "is valid when no limit is configured (nil)" do
      business.update!(max_late_permission_minutes: nil)
      req = build(:employee_request, :late_permission, user: user,
                  requested_for_date: date, duration_minutes: 9999)
      expect(req).to be_valid
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
