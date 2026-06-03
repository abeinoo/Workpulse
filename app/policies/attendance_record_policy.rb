class AttendanceRecordPolicy < ApplicationPolicy
  def index?   = true  # scope handles isolation
  def show?    = can?(:view_attendance) || own_record?
  def create?  = can?(:manage_attendance)  # manual entry by authorized users
  def update?  = can?(:manage_attendance)
  def destroy? = can?(:manage_attendance)

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.can?(:view_attendance)
        configured  = user.scope_for(:view_attendance)
        base        = scope.for_business(user.business)
        if configured
          filter_by_data_scope(base, configured)
        else
          managed_ids = EmployeeScope.new(user).relation.select(:id)
          base.where(user_id: user.id).or(base.where(user_id: managed_ids))
        end
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def own_record?
    record.user_id == user.id
  end
end
