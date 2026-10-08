require "rails_helper"

RSpec.describe EmployeeRequestPolicy, type: :model do
  let(:business)    { create(:business) }
  let(:branch)      { create(:branch, business: business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }
  let(:manager)     { create(:user, :branch_manager, business: business) }
  let(:employee)    { create(:user, business: business) }
  let(:request)     { create(:employee_request, user: employee) }
  let(:shift)       { create(:shift, :fixed_time, business: business) }

  before do
    # Branch membership is shift-driven; make `manager` the branch_manager of
    # `branch` and assign `employee` to it.
    branch.update_column(:branch_manager_id, manager.id)
    create(:shift_assignment, user: employee, branch: branch, shift: shift)
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

    it "permits any user with view_requests at the policy level — scope handles isolation" do
      other_manager = create(:user, :branch_manager, business: business)
      expect(subject).to permit(other_manager, request)
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

    it "permits a business-wide approver to create for any business employee" do
      role = create(:permission_role, business: business,
                    permissions: %w[view_requests approve_requests],
                    permission_scopes: { "approve_requests" => "business_wide" })
      wide_approver = create(:user, business: business, permission_role: role)
      unmanaged     = create(:user, business: business) # not a report of wide_approver
      new_req       = build(:employee_request, user: unmanaged)
      expect(subject).to permit(wide_approver, new_req)
    end

    it "denies a branch-scoped approver creating for an employee outside their branch" do
      role = create(:permission_role, business: business,
                    permissions: %w[view_requests approve_requests],
                    permission_scopes: { "approve_requests" => "branch" })
      restricted = create(:user, business: business, permission_role: role)
      unmanaged  = create(:user, business: business)
      new_req    = build(:employee_request, user: unmanaged)
      expect(subject).not_to permit(restricted, new_req)
    end
  end

  describe "approve?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, request).approve?).to be true
    end

    it "permits the direct manager of the requester" do
      expect(subject.new(manager, request).approve?).to be true
    end

    # SEC-P9-1: the requester must be inside the approver's scope (approve_requests
    # → view_requests → view_employees, else the manager hierarchy).
    it "denies an approver whose scope does not include the requester (another branch's manager)" do
      other_manager = create(:user, :branch_manager, business: business)
      expect(subject.new(other_manager, request).approve?).to be false
      expect(subject.new(other_manager, request).reject?).to be false
    end

    it "denies employee" do
      expect(subject.new(employee, request).approve?).to be false
    end

    it "denies an approver approving their OWN request (no self-approval)" do
      own_request = create(:employee_request, user: manager)
      expect(subject.new(manager, own_request).approve?).to be false
    end

    it "still permits another approver (with the requester in scope) to approve that request" do
      own_request = create(:employee_request, user: manager)
      role = create(:permission_role, business: business, permissions: %w[view_requests approve_requests],
                                      permission_scopes: { "approve_requests" => "business" })
      other_approver = create(:user, business: business, permission_role: role)
      expect(subject.new(other_approver, own_request).approve?).to be true
    end
  end

  describe "review_details?" do
    it "permits an approver of someone else's request" do
      expect(subject.new(manager, request).review_details?).to be true
    end

    it "stays permitted after the request is reviewed (status-independent)" do
      request.update!(status: "approved", reviewed_at: Time.current)
      expect(subject.new(manager, request).review_details?).to be true
    end

    it "denies the requesting employee" do
      expect(subject.new(employee, request).review_details?).to be false
    end

    it "denies a view-only user who cannot approve" do
      viewer = create(:user, business: business,
                      permission_role: create(:permission_role, business: business, permissions: %w[view_requests]))
      expect(subject.new(viewer, request).review_details?).to be false
    end

    it "denies an approver viewing their OWN request (they are the requester there)" do
      own_request = create(:employee_request, user: manager)
      expect(subject.new(manager, own_request).review_details?).to be false
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

    it "denies an approver rejecting their OWN request (no self-approval)" do
      own_request = create(:employee_request, user: manager)
      expect(subject.new(manager, own_request).reject?).to be false
    end
  end

  describe "cancel?" do
    it "permits the owner to cancel their own PENDING request" do
      expect(subject.new(employee, request).cancel?).to be true
    end

    it "does NOT permit another employee to cancel someone else's pending request" do
      other = create(:user, business: business)
      expect(subject.new(other, request).cancel?).to be false
    end

    it "does NOT permit the owner to cancel their own APPROVED request without approve_requests/pay_advances" do
      approved = create(:employee_request, :approved, user: employee)
      expect(subject.new(employee, approved).cancel?).to be false
    end

    it "permits an approver (approve_requests) to cancel an approved request of an employee in scope" do
      approved = create(:employee_request, :approved, user: employee)
      expect(subject.new(manager, approved).cancel?).to be true
    end

    it "permits a pay_advances holder to cancel an approved request" do
      accountant = create(:user, :accountant, business: business)
      approved = create(:employee_request, :approved, user: employee)
      expect(subject.new(accountant, approved).cancel?).to be true
    end

    it "does NOT permit cancelling a rejected request" do
      rejected = create(:employee_request, :rejected, user: employee)
      expect(subject.new(employee, rejected).cancel?).to be false
      expect(subject.new(manager, rejected).cancel?).to be false
    end

    it "does NOT permit cancelling a paid request" do
      paid = create(:employee_request, :salary_advance, :approved, user: employee)
      Requests::Approver.pay(request: paid, paid_by: manager)
      expect(subject.new(employee, paid.reload).cancel?).to be false
      expect(subject.new(manager, paid.reload).cancel?).to be false
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
      it "returns requests from employees assigned to the managed branch" do
        scope = described_class::Scope.new(manager, EmployeeRequest).resolve
        expect(scope).to include(my_request)
        expect(scope).not_to include(other_request)
      end

      it "excludes requests from employees assigned to a different branch" do
        other_branch  = create(:branch, business: business)
        unmanaged_emp = create(:user, business: business)
        create(:shift_assignment, user: unmanaged_emp, branch: other_branch, shift: shift)
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
