# Resolver for "which branches can this user access?" — the branch-based parallel
# to EmployeeScope (which answers the same question for employees). Financial
# records (expenses, custody, recurring expenses, branch revenue) are scoped by
# branch, so policies resolve their visibility through here.
#
# Branch access is management-based: a user accesses the branches they
# branch-manage (branch_manager_id) and/or area-manage (area_manager_id). There
# is no branch "membership" for managers — working in a branch grants nothing
# here. Owners access every branch in the business.
#
# Scope values are the shared PermissionRole::SCOPE_OPTIONS (also used by
# EmployeeScope); the policy layer decides which resolver applies per record type:
#   self     → no branches (own-created / own-held records are added at the policy
#              layer, mirroring EmployeeScope which excludes self by design)
#   branch   → branches where the user is branch_manager_id
#   area     → branches where the user is area_manager_id
#   business → every branch in the business
class BranchScope
  SCOPE_RESOLVERS = {
    "self"     => :none_ids,
    "branch"   => :managed_ids,
    "area"     => :area_ids,
    "business" => :business_ids,
    # legacy aliases, mirroring EmployeeScope
    "self_only"     => :none_ids,
    "branch_only"   => :managed_ids,
    "business_wide" => :business_ids
  }.freeze

  def initialize(user)
    @user = user
  end

  # The natural default when no explicit data scope is configured: the branches
  # the user manages or area-manages. Owners get every branch.
  def default_ids
    return business_ids if @user.owner?

    (managed_ids + area_ids).uniq
  end

  # Branch ids for a named scope. Unknown/blank falls back to the default,
  # matching EmployeeScope#for_scope.
  def for_scope(scope_name)
    method = SCOPE_RESOLVERS.fetch(scope_name.to_s, nil)
    method ? send(method) : default_ids
  end

  private

  def none_ids     = []
  def managed_ids  = @user.managed_branch_ids
  def area_ids     = @user.area_managed_branch_ids
  def business_ids = @user.business.branches.pluck(:id)
end
