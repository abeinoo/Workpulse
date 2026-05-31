# Single authoritative resolver for "which employees can this user access?"
#
# Hierarchy (highest wins; levels are additive, not exclusive):
#
#   Owner          → every non-owner user in the business
#   Area manager   → employees in area-managed branches + their own direct reports
#   Branch manager → employees in managed branches + their own direct reports
#   Direct manager → employees where manager_id == user.id
#   Employee       → User.none  (self access is handled at the policy level, not here)
#
# Usage:
#   EmployeeScope.new(user).relation          # canonical "what does this manager see?"
#   EmployeeScope.new(user).for_scope("branch_only")  # explicit named-scope override
#   EmployeeScope.new(user).includes?(other_user_id)  # record-level guard
#
class EmployeeScope
  SCOPE_RESOLVERS = {
    "self_only"              => :self_only,
    "managed_employees_only" => :managed,
    "branch_only"            => :branch,
    "business_wide"          => :business_wide
  }.freeze

  def initialize(user)
    @user = user
  end

  # The canonical managed-employee relation for this user.
  # Follows the 5-tier hierarchy and returns an AR relation that can be
  # chained (.active, .select(:id), .exists?, etc.).
  def relation
    return business_wide if @user.owner?

    branch_ids = @user.managed_branch_ids + @user.area_managed_branch_ids

    if branch_ids.any?
      direct_cond  = User.arel_table[:manager_id].eq(@user.id)
      branch_subq  = UserBranch.where(branch_id: branch_ids).select(:user_id)
      base.where(User.arel_table[:id].in(branch_subq.arel).or(direct_cond))
    elsif @user.managed_employees.exists?
      base.where(manager_id: @user.id)
    else
      User.none
    end
  end

  # Resolve a named scope string to a concrete AR relation.
  # Called by policies when an explicit scope override is configured.
  def for_scope(scope_name)
    method_name = SCOPE_RESOLVERS.fetch(scope_name.to_s, :managed)
    send(method_name)
  end

  # Quick boolean check for record-level policy guards.
  def includes?(user_id)
    relation.exists?(user_id)
  end

  private

  def base
    @base ||= User.where(business: @user.business).where.not(id: @user.id)
  end

  def self_only
    User.where(id: @user.id)
  end

  def managed
    relation
  end

  # "Branch only" means every employee who shares a branch with this user —
  # the branches they manage / area-manage AND the branches they personally
  # belong to (user_branches). A plain branch member (not the formal manager)
  # must still see their branch colleagues.
  def branch
    ids = (@user.managed_branch_ids + @user.area_managed_branch_ids + @user.branch_ids).uniq
    return User.none unless ids.any?

    base.where(User.arel_table[:id].in(UserBranch.where(branch_id: ids).select(:user_id).arel))
  end

  def business_wide
    base
  end
end
