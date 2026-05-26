class NotificationPolicy < ApplicationPolicy
  def index?  = true
  def show?   = own_notification?
  def update? = own_notification?  # mark read
  def destroy? = own_notification?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(user: user)
    end
  end

  private

  def own_notification?
    record.user_id == user.id
  end
end
