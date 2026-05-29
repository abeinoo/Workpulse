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

  describe "punch_correction validations" do
    it "is valid with all required fields" do
      req = build(:employee_request, :punch_correction)
      expect(req).to be_valid
    end

    it "is invalid without correction_type" do
      req = build(:employee_request, :punch_correction, correction_type: nil)
      expect(req).not_to be_valid
      expect(req.errors[:correction_type]).to be_present
    end

    it "is invalid without proposed_time" do
      req = build(:employee_request, :punch_correction, proposed_time: nil)
      expect(req).not_to be_valid
      expect(req.errors[:proposed_time]).to be_present
    end

    it "is invalid without reason" do
      req = build(:employee_request, :punch_correction, reason: nil)
      expect(req).not_to be_valid
      expect(req.errors[:reason]).to be_present
    end

    it "is invalid without requested_for_date" do
      req = build(:employee_request, :punch_correction, requested_for_date: nil)
      expect(req).not_to be_valid
      expect(req.errors[:requested_for_date]).to be_present
    end

    it "does not require duration_minutes" do
      req = build(:employee_request, :punch_correction, duration_minutes: nil)
      expect(req).to be_valid
    end

    it "does not require amount" do
      req = build(:employee_request, :punch_correction, amount: nil)
      expect(req).to be_valid
    end

    it "accepts all four correction_type values" do
      EmployeeRequest::CORRECTION_TYPES.each do |ct|
        req = build(:employee_request, :punch_correction, correction_type: ct)
        expect(req).to be_valid, "expected #{ct} to be valid"
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

    it "is false for punch_correction" do
      req = create(:employee_request, :punch_correction)
      expect(req.affects_payroll).to be false
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
    let(:business) { create(:business) }
    let(:user)     { create(:user, business: business) }
    let(:branch)   { create(:branch, business: business) }
    let(:date)     { Date.current.beginning_of_month + 5.days }
    let(:shift)    { create(:shift, :fixed_time, business: business,
                            max_late_permission_minutes: 120,
                            max_early_leave_permission_minutes: 60) }

    before do
      create(:shift_assignment, user: user, shift: shift, branch: branch,
             effective_from: date.beginning_of_month, effective_to: nil)
    end

    it "is valid when duration is within the shift's monthly limit" do
      req = build(:employee_request, :late_permission, user: user,
                  requested_for_date: date, duration_minutes: 60)
      expect(req).to be_valid
    end

    it "is invalid when duration exceeds the shift's remaining monthly limit" do
      create(:employee_request, :late_permission, :approved, user: user,
             requested_for_date: date, duration_minutes: 100)
      req = build(:employee_request, :late_permission, user: user,
                  requested_for_date: date + 1.day, duration_minutes: 30)
      expect(req).not_to be_valid
      expect(req.errors[:duration_minutes]).to be_present
    end

    it "is valid when the shift has no limit configured (nil)" do
      shift.update!(max_late_permission_minutes: nil)
      req = build(:employee_request, :late_permission, user: user,
                  requested_for_date: date, duration_minutes: 9999)
      expect(req).to be_valid
    end

    context "business-level fallback when shift has no limit" do
      before { shift.update!(max_late_permission_minutes: nil) }

      it "enforces the business limit when the shift limit is nil" do
        business.update!(max_late_permission_minutes: 30)
        req = build(:employee_request, :late_permission, user: user,
                    requested_for_date: date, duration_minutes: 50)
        expect(req).not_to be_valid
        expect(req.errors[:duration_minutes]).to be_present
      end

      it "skips enforcement when both shift and business limits are nil" do
        business.update!(max_late_permission_minutes: nil)
        req = build(:employee_request, :late_permission, user: user,
                    requested_for_date: date, duration_minutes: 9999)
        expect(req).to be_valid
      end
    end

    context "employee without a shift assignment" do
      before { ShiftAssignment.where(user: user).delete_all }

      it "falls back to the business limit when no shift is assigned" do
        business.update!(max_late_permission_minutes: 30)
        req = build(:employee_request, :late_permission, user: user,
                    requested_for_date: date, duration_minutes: 50)
        expect(req).not_to be_valid
      end

      it "is valid when neither shift nor business has a limit" do
        req = build(:employee_request, :late_permission, user: user,
                    requested_for_date: date, duration_minutes: 9999)
        expect(req).to be_valid
      end
    end
  end

  describe "within_advance_limit" do
    let(:business) { create(:business, max_salary_advance_percentage: 50) }
    let(:user)     { create(:user, business: business) }

    before { create(:salary_profile, :monthly, user: user, base_amount: 4_000) }

    it "is valid when amount is within the available limit" do
      req = build(:employee_request, :salary_advance, user: user, amount: 1_000)
      expect(req).to be_valid
    end

    it "is invalid when amount exceeds the available limit" do
      req = build(:employee_request, :salary_advance, user: user, amount: 2_500)
      expect(req).not_to be_valid
      expect(req.errors[:amount]).to be_present
    end

    it "is valid when business has no advance percentage configured" do
      business.update!(max_salary_advance_percentage: nil)
      req = build(:employee_request, :salary_advance, user: user, amount: 99_999)
      expect(req).to be_valid
    end

    it "is valid when user has no salary profile" do
      SalaryProfile.where(user: user).delete_all
      req = build(:employee_request, :salary_advance, user: user, amount: 99_999)
      expect(req).to be_valid
    end

    it "deducts outstanding advances before checking limit" do
      existing = create(:employee_request, :salary_advance, :approved, user: user, amount: 1_500)
      advance  = create(:advance, user: user, remaining_amount: 1_500, employee_request: existing)
      existing.update!(status: "paid")
      # max = 2_000; outstanding = 1_500; available = 500 → 600 should fail
      req = build(:employee_request, :salary_advance, user: user, amount: 600)
      expect(req).not_to be_valid
      expect(req.errors[:amount]).to be_present
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
