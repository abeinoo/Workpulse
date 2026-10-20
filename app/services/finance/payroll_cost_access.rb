module Finance
  # Which branches' payroll cost a user may see in Finance reports and the
  # Finance dashboard (decision of 2026-10-19): the branches of the user's
  # view_payroll scope — PayrollEntryPolicy.visible_branch_ids (none without
  # view_payroll; BranchScope of the configured scope, else managed +
  # area-managed; every branch for the owner). Payroll cost is never shown for
  # any other branch, nor any figure derived from it (net profit, margin, a
  # total including it).
  #
  # The report services take #branch_ids as `payroll_branch_ids:` (nil there
  # means unrestricted — console, jobs and specs that compute the full figures).
  class PayrollCostAccess
    def initialize(user)
      @user = user
    end

    # The rule lives with payroll (PayrollEntryPolicy.visible_branch_ids — the
    # same definition Payroll analytics use); Finance reads it.
    def branch_ids
      @branch_ids ||= PayrollEntryPolicy.visible_branch_ids(@user)
    end

    def branch?(branch_id) = branch_ids.include?(branch_id)
  end
end
