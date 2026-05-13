require "rails_helper"

RSpec.describe EmployeeRequestPolicy, type: :model do
  let(:business)    { create(:business) }
  let(:branch)      { create(:branch, business: business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }
  let(:manager)     { create(:user, :branch_manager, business: business) }
  let(:employee)    { create(:user, business: business, manager: manager) }
  let(:request)     { create(:employee_request, user: employee) }

  before do
    create(:user_branch, user: manager, branch: branch)
    create(:user_branch, user: employee, branch: branch)
  end

  subject { described_class }

  describe "index?" do
    it "permits everyone" do
      [ super_admin, manager, employee ].each do |user|
        expect(subject).to permit(user, request)
      end
    end
  end

  describe "show?" do
    it "permits the owner" do
      expect(subject).to permit(employee, request)
    end

    it "permits super_admin" do
      expect(subject).to permit(super_admin, request)
    end

    it "permits the direct manager of the requester" do
      expect(subject).to permit(manager, request)
    end

    it "denies a manager who is NOT the direct manager" do
      other_manager = create(:user, :branch_manager, business: business)
      create(:user_branch, user: other_manager, branch: branch)
      expect(subject).not_to permit(other_manager, request)
    end

    it "denies another employee" do
      other = create(:user, business: business)
      expect(subject).not_to permit(other, request)
    end
  end

  describe "create?" do
    it "permits an employee in the same business" do
      new_req = build(:employee_request, user: employee)
      expect(subject).to permit(employee, new_req)
    end

    it "denies an employee from a different business" do
      other_user = create(:user)
      new_req = build(:employee_request, user: other_user)
      expect(subject).not_to permit(employee, new_req)
    end
  end

  describe "approve?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, request).approve?).to be true
    end

    it "permits the direct manager of the requester" do
      expect(subject.new(manager, request).approve?).to be true
    end

    it "denies a manager who is NOT the direct manager" do
      other_manager = create(:user, :branch_manager, business: business)
      expect(subject.new(other_manager, request).approve?).to be false
    end

    it "denies employee" do
      expect(subject.new(employee, request).approve?).to be false
    end
  end

  describe "reject?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, request).reject?).to be true
    end

    it "permits the direct manager of the requester" do
      expect(subject.new(manager, request).reject?).to be true
    end

    it "denies employee" do
      expect(subject.new(employee, request).reject?).to be false
    end
  end

  describe "Scope" do
    let!(:my_request)    { create(:employee_request, user: employee) }
    let!(:other_request) { create(:employee_request) }

    describe "super_admin scope" do
      it "returns all requests for the business" do
        scope = described_class::Scope.new(super_admin, EmployeeRequest).resolve
        expect(scope).to include(my_request)
        expect(scope).not_to include(other_request)
      end
    end

    describe "branch_manager scope" do
      it "returns requests from directly managed employees" do
        scope = described_class::Scope.new(manager, EmployeeRequest).resolve
        expect(scope).to include(my_request)
        expect(scope).not_to include(other_request)
      end

      it "excludes requests from employees with a different manager" do
        other_manager = create(:user, :branch_manager, business: business)
        unmanaged_emp = create(:user, business: business, manager: other_manager)
        unmanaged_req = create(:employee_request, user: unmanaged_emp)
        scope = described_class::Scope.new(manager, EmployeeRequest).resolve
        expect(scope).not_to include(unmanaged_req)
      end

      it "includes the manager's own requests" do
        mgr_request = create(:employee_request, user: manager)
        scope = described_class::Scope.new(manager, EmployeeRequest).resolve
        expect(scope).to include(mgr_request)
      end
    end

    describe "employee scope" do
      it "returns only own requests" do
        scope = described_class::Scope.new(employee, EmployeeRequest).resolve
        expect(scope).to include(my_request)
        expect(scope).not_to include(other_request)
      end
    end
  end
end
