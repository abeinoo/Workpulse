class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    raise Pundit::NotAuthorizedError, "must be logged in" unless user

    @user   = user
    @record = record
  end

  def index?   = false
  def show?    = false
  def create?  = false
  def update?  = false
  def destroy? = false
  def new?     = create?
  def edit?    = update?

  class Scope
    def initialize(user, scope)
      @user  = user
      @scope = scope
    end

    def resolve
      raise NotImplementedError, "#{self.class}#resolve is not implemented"
    end

    private

    attr_reader :user, :scope

    # Restricts an inventory relation to the warehouses the user may see.
    # nil from inventory_warehouse_ids means "all warehouses" — the relation
    # passes through unchanged. Pass the relevant column (e.g. :warehouse_id, :id).
    def for_accessible_warehouses(relation, column: :warehouse_id)
      ids = user.inventory_warehouse_ids
      return relation if ids.nil?

      relation.where(column => ids)
    end

    # Applies an explicit scope string to a user_id-based relation.
    # scope_type must be a non-nil string from PermissionRole::SCOPE_OPTIONS.
    # Never call this with nil — use EmployeeScope.new(user).relation for the
    # hierarchy-based default when no explicit scope is configured.
    #
    # The current user's own records are always included: EmployeeScope excludes
    # self by design ("employees I manage"), but a user must still see their own
    # data under every scope — matching the hierarchy-based default path.
    def filter_by_data_scope(relation, scope_type, user_id_column: :user_id)
      employee_ids = EmployeeScope.new(user).for_scope(scope_type).select(:id)
      relation.where(user_id_column => employee_ids)
              .or(relation.where(user_id_column => user.id))
    end

    # Branch-based equivalent of #filter_by_data_scope, for financial records
    # scoped by branch (expenses, custody, recurring, revenue). Resolves the
    # branch ids for `scope_type` via BranchScope and restricts `relation` to
    # them. The user's own records are always included (own_column, e.g.
    # :created_by_id for expenses or :user_id for custody) — matching the
    # data-scope path where a user always sees their own data.
    #
    # scope_type must be a string from PermissionRole::SCOPE_OPTIONS or :default;
    # "business" short-circuits to the unrestricted relation so business-level
    # (NULL-branch) records remain visible. Pass own_column: nil to skip the
    # own-records union.
    def filter_by_branch_scope(relation, scope_type, branch_column: :branch_id, own_column: :created_by_id)
      return relation if scope_type.to_s == "business"

      branch_ids = BranchScope.new(user).for_scope(scope_type)
      filtered   = relation.where(branch_column => branch_ids)

      if own_column && relation.klass.column_names.include?(own_column.to_s)
        filtered = filtered.or(relation.where(own_column => user.id))
      end
      filtered
    end
  end

  protected

  # Kept for use in Scope subclasses only — never use these in action methods.
  def owner?          = user.owner?
  def manages_area?   = user.manages_area?
  def manages_branch? = user.manages_branch?

  def can?(permission) = user.can?(permission)

  def same_business?(target = record)
    if target.respond_to?(:business_id) && target.business_id.present?
      target.business_id == user.business_id
    else
      # Class-level or unsaved records with no business_id: owners always pass.
      user.owner?
    end
  end

  # ── Branch write-scope enforcement (shared by financial policies) ──────────
  # The Scope classes limit what a user can SEE; these limit what a user can
  # WRITE. A branch manager must not create/edit a record attributed to a branch
  # outside their scope, even though the permission flag is set.
  #
  # `permissions` is an ordered, most-specific-first list of permission names; the
  # first one with an explicitly configured data scope wins, else the user's
  # hierarchy default applies (mirrors EmployeeScope#for_permissions). Owners and
  # a business-wide scope authorize any branch.

  # Single-branch records (branch_revenue, single-branch expense, custody
  # account). allow_nil: true treats a NULL branch as unrestricted (e.g. a
  # user-held custody account with no branch); otherwise NULL needs business scope.
  def branch_within_scope?(branch_id, *permissions, allow_nil: false)
    scope_type = resolved_branch_scope(*permissions)
    return true  if scope_type == :business
    return allow_nil if branch_id.nil?

    BranchScope.new(user).for_scope(scope_type).include?(branch_id)
  end

  # Multi-branch records (shared expense / recurring expense with allocations).
  # Every attributed branch must be in scope; an empty set is only allowed under
  # business scope (used to gate business-level, branch-less records).
  def branches_within_scope?(branch_ids, *permissions)
    scope_type = resolved_branch_scope(*permissions)
    return true if scope_type == :business

    branch_ids = Array(branch_ids).compact
    return false if branch_ids.empty?

    (branch_ids - BranchScope.new(user).for_scope(scope_type)).empty?
  end

  # Resolves the effective scope value, returning :business for owners and the
  # business-wide setting so callers can short-circuit.
  def resolved_branch_scope(*permissions)
    return :business if user.owner?

    configured = permissions.filter_map { |p| user.scope_for(p) }.first || "default"
    configured.to_s == "business" ? :business : configured
  end
end
