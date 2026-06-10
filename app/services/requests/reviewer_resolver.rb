module Requests
  # Resolves who should be NOTIFIED to review an employee request.
  #
  # Primary: the branch/area managers of the branches the requester is currently
  # assigned to (inferred through active ShiftAssignments), limited to users who
  # hold approve_requests. Requester excluded, de-duplicated.
  #
  # Fallback (notification routing only): when no manager can be inferred — e.g.
  # the requester has no active ShiftAssignment, or their branch has no
  # branch_manager_id / area_manager_id — notify every active user who has the
  # approve_requests permission with a business data scope (owners always qualify).
  #
  # This affects notification targeting ONLY. Visibility and approval authority
  # are unchanged: business-scope approvers can already see and approve these
  # requests through the policy scope.
  module ReviewerResolver
    module_function

    # Returns an array of active User reviewers to notify for the given request.
    def for(request)
      requester = request.user

      inferred = inferred_reviewers(requester)
      inferred.presence || business_scope_approvers(requester)
    end

    # Branch/area managers (with approve_requests) of the requester's currently
    # assigned branches.
    def inferred_reviewers(requester)
      candidate_ids = BranchMembership.manager_ids(requester)
      return [] if candidate_ids.empty?

      User.where(id: candidate_ids, active: true)
          .select { |u| u.can?(:approve_requests) }
    end

    # Active users in the same business (excluding the requester) who hold
    # approve_requests with a business data scope.
    def business_scope_approvers(requester)
      requester.business.users
               .where(active: true)
               .where.not(id: requester.id)
               .select { |u| u.can?(:approve_requests) && u.scope_for(:approve_requests) == "business" }
    end
  end
end
