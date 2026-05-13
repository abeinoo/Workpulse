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
  end

  protected

  def super_admin?
    user.super_admin?
  end

  def branch_manager?
    user.branch_manager?
  end

  def area_manager?
    user.area_manager?
  end

  def accountant?
    user.accountant?
  end

  def employee?
    user.employee?
  end

  # True for any role that manages branches or the whole business.
  def managing?
    super_admin? || area_manager? || branch_manager?
  end

  def same_business?(target = record)
    target.respond_to?(:business_id) && target.business_id == user.business_id
  end
end
