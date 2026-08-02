class ExpensePolicy < ApplicationPolicy
  def index?  = can?(:view_expenses) || can?(:create_expenses)
  def show?   = (can?(:view_expenses) && same_business?) || own_expense?

  # new? (blank form) only needs the permission; the branch isn't chosen yet.
  def new?    = can?(:create_expenses)
  def create? = can?(:create_expenses) && same_business? &&
                branches_writable?(:create_expenses, :view_expenses)

  # Editable while not yet committed (draft / pending / rejected). Once approved
  # an expense is locked. Editors may edit; creators may edit their own draft.
  # The target branch(es) must also be within the writer's scope.
  def update?
    return false if record.system_generated?
    return false unless same_business? && editable_status?
    return false unless can?(:edit_expenses) || (own_expense? && record.draft?)

    branches_writable?(:edit_expenses, :view_expenses)
  end

  def destroy?
    return false if record.system_generated?

    same_business? && record.draft? && (can?(:edit_expenses) || own_expense?) &&
      branches_writable?(:edit_expenses, :view_expenses)
  end

  # draft → pending_approval. Creator (or an editor) submits for approval.
  def submit?
    same_business? && record.draft? && (can?(:create_expenses) || can?(:edit_expenses)) &&
      branches_writable?(:create_expenses, :edit_expenses, :view_expenses)
  end

  # Self-approval is blocked: the person who created an expense may not approve or
  # reject it — segregation of duties (mirrors EmployeeRequestPolicy / SelfApproval).
  # Business owners are exempt (small-business / sole-proprietor exception).
  def approve? = can?(:approve_expenses) && same_business? && record.pending_approval? &&
                 (user.owner? || !own_expense?)
  def reject?  = approve?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user.can?(:view_expenses) || user.can?(:create_expenses)

      base = scope.for_business(user.business)
      return base if user.owner?

      scope_type = user.scope_for(:view_expenses) || :default
      return base if scope_type.to_s == "business"

      # Branch-owned expenses in scope (or created by the user), PLUS shared
      # expenses whose allocations touch any of the user's branches.
      branch_ids = BranchScope.new(user).for_scope(scope_type)
      filter_by_branch_scope(base, scope_type)
        .or(base.where(id: ExpenseAllocation.where(branch_id: branch_ids).select(:expense_id)))
    end
  end

  private

  def own_expense?
    record.respond_to?(:created_by_id) && record.created_by_id == user.id
  end

  # Statuses in which an expense may still be edited.
  def editable_status?
    record.draft? || record.pending_approval? || record.rejected?
  end

  # The branch(es) this expense is attributed to, for write-scope checks:
  # a shared expense → its allocation branches; a single-branch expense → that
  # branch; a business-level expense → [] (no branch attribution).
  def write_branch_ids
    allocs = record.effective_allocations
    return allocs.map(&:branch_id) if allocs.any?

    record.branch_id ? [ record.branch_id ] : []
  end

  # A record IS writable when it attributes to no branch (a business-level /
  # reimbursement request — allowed for anyone with the permission, since it's a
  # pending request and attributes cost to no branch). When it DOES name branches,
  # every one must be within the user's scope (you can't file against a branch you
  # don't manage). This is what lets owners, branch managers, and plain employees
  # all raise expense requests while still preventing cross-branch attribution.
  def branches_writable?(*permissions)
    ids = write_branch_ids
    ids.empty? || branches_within_scope?(ids, *permissions)
  end
end
