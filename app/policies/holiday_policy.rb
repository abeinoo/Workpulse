# Holiday Calendar (R6; attendance plan revision 19, D3): one business-wide
# calendar, managed with the business-level manage_holidays permission (owners
# implicitly). Not scopable: a holiday belongs to the whole business.
class HolidayPolicy < ApplicationPolicy
  def index?   = can?(:manage_holidays)
  def create?  = can?(:manage_holidays)
  def update?  = can?(:manage_holidays) && same_business?
  def destroy? = update?

  private

  def same_business? = record.is_a?(Class) || record.business_id == user.business_id

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
