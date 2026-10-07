module Workforce
  # Workforce implementation of the Organization & Access
  # OrganizationAccess::MembershipProvider contract (registered in
  # config/initializers/organization_access_membership_provider.rb). Branch
  # membership is derived from active shift assignments by BranchMembership;
  # this is the contract surface only and delegates unchanged.
  module MembershipProvider
    module_function

    def current_branch_ids(user)
      BranchMembership.current_branch_ids(user)
    end

    def current_member_ids(branch_ids)
      BranchMembership.current_member_ids(branch_ids)
    end
  end
end
