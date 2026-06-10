require "rails_helper"

RSpec.describe Requests::ReviewerResolver do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) } # owner ⇒ business-scope approver
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:branch)   { create(:branch, business: business) }

  let(:approver_role) do
    create(:permission_role, business: business, permissions: %w[view_requests approve_requests])
  end
  let(:branch_manager) do
    create(:user, business: business, permission_role: approver_role).tap do |u|
      branch.update_column(:branch_manager_id, u.id)
    end
  end

  describe ".for" do
    context "requester assigned to a branch that has a manager" do
      it "returns the inferred branch manager and does NOT use the fallback" do
        branch_manager
        employee = create(:user, business: business)
        create(:shift_assignment, user: employee, branch: branch, shift: shift)
        request = create(:employee_request, user: employee)

        result = described_class.for(request)
        expect(result).to include(branch_manager)
        expect(result).not_to include(owner)
      end
    end

    context "requester with NO active ShiftAssignment" do
      it "falls back to active business-scope approvers" do
        employee = create(:user, business: business)
        request  = create(:employee_request, user: employee)

        expect(described_class.for(request)).to include(owner)
      end

      it "excludes the requester even when they are themselves a business-scope approver" do
        biz_role = create(:permission_role, business: business,
                          permissions: %w[view_requests approve_requests],
                          permission_scopes: { "approve_requests" => "business" })
        self_approver = create(:user, business: business, permission_role: biz_role)
        request = create(:employee_request, user: self_approver)

        result = described_class.for(request)
        expect(result).not_to include(self_approver)
        expect(result).to include(owner)
      end

      it "excludes approvers who do not have business scope" do
        branch_role = create(:permission_role, business: business,
                             permissions: %w[view_requests approve_requests],
                             permission_scopes: { "approve_requests" => "branch" })
        branch_only_approver = create(:user, business: business, permission_role: branch_role)
        request = create(:employee_request, user: create(:user, business: business))

        result = described_class.for(request)
        expect(result).not_to include(branch_only_approver)
        expect(result).to include(owner)
      end

      it "excludes inactive business-scope approvers" do
        biz_role = create(:permission_role, business: business,
                          permissions: %w[view_requests approve_requests],
                          permission_scopes: { "approve_requests" => "business" })
        inactive = create(:user, business: business, permission_role: biz_role, active: false)
        request  = create(:employee_request, user: create(:user, business: business))

        expect(described_class.for(request)).not_to include(inactive)
      end
    end

    context "requester assigned to a branch with NO manager" do
      it "falls back to business-scope approvers" do
        no_mgr_branch = create(:branch, business: business)
        employee = create(:user, business: business)
        create(:shift_assignment, user: employee, branch: no_mgr_branch, shift: shift)
        request = create(:employee_request, user: employee)

        expect(described_class.for(request)).to include(owner)
      end
    end
  end
end
