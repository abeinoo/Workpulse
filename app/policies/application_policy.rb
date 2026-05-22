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
