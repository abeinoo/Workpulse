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

    # Applies an explicit scope string to a user_id-based relation.
    # scope_type must be a non-nil string from PermissionRole::SCOPE_OPTIONS.
    # Never call this with nil — use EmployeeScope.new(user).relation for the
    # hierarchy-based default when no explicit scope is configured.
    def filter_by_data_scope(relation, scope_type, user_id_column: :user_id)
      employee_ids = EmployeeScope.new(user).for_scope(scope_type).select(:id)
      relation.where(user_id_column => employee_ids)
    end
  end

  protected

  def owner?          = user.owner?
  def manages_area?   = user.manages_area?
  def manages_branch? = user.manages_branch?

  def can?(permission) = user.can?(permission)

  def managing?
    owner? || manages_area? || manages_branch?
  end

  def same_business?(target = record)
    target.respond_to?(:business_id) && target.business_id == user.business_id
  end
end
