require "rails_helper"

# Authorization matrix for Employee Add Requests: one explicit permission per
# action, submitter-based scope, never deciding on your own request.
RSpec.describe EmployeeDataRequestPolicy do
  let(:business) { create(:business).tap { |b| seed_job_titles(b) } }
  let(:requester) { edr_manager(business: business) }
  let(:request)   { create(:employee_data_request, business: business, submitted_by: requester) }

  def user_with(*perms, scopes: { view_all_employee_requests: "business" })
    edr_user_with(*perms, business: business, scopes: scopes.slice(*perms))
  end

  def policy(user, record = request) = described_class.new(user, record)

  let(:view_all) { %i[view_employee_requests view_all_employee_requests] }

  describe "creating" do
    it "requires create_employee_requests" do # 1, 2
      expect(policy(user_with(:view_employee_requests), EmployeeDataRequest).create?).to be(false)
      expect(policy(create(:user, business: business), EmployeeDataRequest).create?).to be(false)
      expect(policy(requester, EmployeeDataRequest).create?).to be(true)
    end

    it "is not granted by employee-management permissions" do
      hr = user_with(:view_employees, :manage_employees)
      expect(policy(hr, EmployeeDataRequest).create?).to be(false)
      expect(policy(hr, EmployeeDataRequest).index?).to be(false)
      expect(policy(hr).show?).to be(false)
    end
  end

  describe "requester" do
    it "sees their own request and its status, but nobody else's" do # 3, 4
      expect(policy(requester).show?).to be(true)
      expect(policy(requester).document?).to be(true)
      other = create(:employee_data_request, business: business, submitted_by: edr_manager(business: business))
      expect(policy(requester, other).show?).to be(false)
      expect(policy(requester, other).document?).to be(false)
    end

    it "gets no reviewer-only access or decisions on their own request" do # 5
      expect(policy(requester).review?).to be(false)
      expect(policy(requester).review_details?).to be(false)
      expect(policy(requester).correct?).to be(false)
      expect(policy(requester).approve?).to be(false)
      expect(policy(requester).reject?).to be(false)
      expect(policy(requester).request_changes?).to be(false)
    end

    it "can edit/resubmit only after changes were requested" do # 12
      expect(policy(requester).update?).to be(false)
      request.update_column(:status, "changes_requested")
      expect(policy(requester).update?).to be(true)
      viewer_only = user_with(:view_employee_requests)
      own = create(:employee_data_request, business: business, submitted_by: viewer_only, status: "changes_requested")
      expect(policy(viewer_only, own).update?).to be(false) # needs create_employee_requests
    end
  end

  describe "reviewer" do
    let(:reviewer) { user_with(*view_all, :review_employee_requests) }

    it "views and reviews requests within scope, including documents and reviewer details" do # 6
      expect(policy(reviewer).show?).to be(true)
      expect(policy(reviewer).review?).to be(true)
      expect(policy(reviewer).review_details?).to be(true)
      expect(policy(reviewer).correct?).to be(true)
      expect(policy(reviewer).document?).to be(true)
    end

    it "cannot approve, reject or return with review permission alone" do # 8
      expect(policy(reviewer).approve?).to be(false)
      expect(policy(reviewer).reject?).to be(false)
      expect(policy(reviewer).request_changes?).to be(false)
    end

    it "view_all alone shows the request but no reviewer mode or documents" do
      viewer = user_with(*view_all)
      expect(policy(viewer).show?).to be(true)
      expect(policy(viewer).review_details?).to be(false)
      expect(policy(viewer).document?).to be(false)
    end
  end

  describe "scope" do # 7
    let(:branch) { create(:branch, business: business) }
    let(:branch_manager) do
      user_with(*view_all, :review_employee_requests, :approve_employee_requests,
                scopes: { view_all_employee_requests: "branch" })
        .tap { |u| branch.update_column(:branch_manager_id, u.id) }
    end
    let(:branch_requester) do
      edr_manager(business: business).tap do |u|
        create(:shift_assignment, business: business, user: u, branch: branch, effective_from: Date.current - 30)
      end
    end
    let(:in_branch)  { create(:employee_data_request, business: business, submitted_by: branch_requester) }
    let(:outside)    { request } # submitted by a requester outside the branch

    it "limits a branch-scoped reviewer to requests submitted from their branch" do
      expect(policy(branch_manager, in_branch).show?).to be(true)
      expect(policy(branch_manager, in_branch).approve?).to be(true)
      expect(policy(branch_manager, outside).show?).to be(false)
      expect(policy(branch_manager, outside).review?).to be(false)
      expect(policy(branch_manager, outside).approve?).to be(false)
      expect(described_class::Scope.new(branch_manager, EmployeeDataRequest).resolve).to contain_exactly(in_branch)
    end

    it "never crosses businesses" do
      foreign = user_with(*EmployeeDataRequestHelpers::EDR_REVIEWER_PERMISSIONS)
      foreign.update_columns(business_id: create(:business).id)
      expect(policy(foreign).show?).to be(false)
      expect(described_class::Scope.new(foreign, EmployeeDataRequest).resolve).to be_empty
    end

    it "gives a requester only their own requests" do
      other = create(:employee_data_request, business: business, submitted_by: edr_manager(business: business))
      expect(described_class::Scope.new(requester, EmployeeDataRequest).resolve).to contain_exactly(request)
      expect(described_class::Scope.new(create(:user, business: business), EmployeeDataRequest).resolve).to be_empty
      expect(other).to be_persisted
    end
  end

  describe "decisions" do
    it "approval needs approve_employee_requests and never applies to your own request" do # 9
      approver = user_with(*view_all, :approve_employee_requests, :create_employee_requests)
      expect(policy(approver).approve?).to be(true)
      own = create(:employee_data_request, business: business, submitted_by: approver)
      expect(policy(approver, own).approve?).to be(false)
      expect(policy(approver).correct?).to be(false) # approval doesn't grant reviewing/correcting
    end

    it "rejecting needs reject_employee_requests" do # 10
      expect(policy(user_with(*view_all, :review_employee_requests, :approve_employee_requests)).reject?).to be(false)
      expect(policy(user_with(*view_all, :reject_employee_requests)).reject?).to be(true)
    end

    it "returning for changes needs request_employee_changes" do # 11
      expect(policy(user_with(*view_all, :review_employee_requests, :reject_employee_requests)).request_changes?).to be(false)
      expect(policy(user_with(*view_all, :request_employee_changes)).request_changes?).to be(true)
    end

    it "only applies while pending review" do
      approver = user_with(*view_all, :approve_employee_requests)
      request.update_column(:status, "approved")
      expect(policy(approver).approve?).to be(false)
    end
  end

  describe "super admin (business owner)" do # 13
    let(:owner) { create(:user, business: business).tap { |u| business.update!(owner: u) } }

    it "has every permission business-wide" do
      expect(policy(owner, EmployeeDataRequest).create?).to be(true)
      %i[show? document? review? review_details? correct? approve? reject? request_changes?].each do |action|
        expect(policy(owner).public_send(action)).to be(true), "owner denied #{action}"
      end
      expect(described_class::Scope.new(owner, EmployeeDataRequest).resolve).to include(request)
    end

    it "still cannot decide on a request they submitted" do
      own = create(:employee_data_request, business: business, submitted_by: owner)
      expect(policy(owner, own).show?).to be(true)
      expect(policy(owner, own).approve?).to be(false)
    end
  end

  it "adds none of the unrelated employee/payroll/attendance/settings permissions" do
    everything = user_with(*PermissionRole::PERMISSION_GROUPS[:employee_onboarding])
    %i[view_employees manage_employees manage_salary_profiles manage_branches manage_roles
       view_payroll view_attendance manage_attendance assign_shifts].each do |perm|
      expect(everything.can?(perm)).to be(false), "granted #{perm}"
    end
  end
end
