class AttendanceRecordPolicy < ApplicationPolicy
  def index?   = true  # scope handles isolation
  def show?    = can?(:view_attendance) || owner? || manages_subject? || own_record?
  def create?  = false  # created only via CheckInService
  def update?  = can?(:manage_attendance) || owner? || direct_manager_can_edit?
  def destroy? = owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner? || user.can?(:view_attendance)
        scope.for_business(user.business)
      elsif user.manages_area?
        scope.for_business(user.business)
             .where(
               AttendanceRecord.arel_table[:user_id].eq(user.id)
               .or(AttendanceRecord.arel_table[:branch_id].in(user.area_managed_branch_ids))
             )
      elsif user.manages_branch?
        scope.for_business(user.business)
             .where(
               AttendanceRecord.arel_table[:user_id].eq(user.id)
               .or(AttendanceRecord.arel_table[:branch_id].in(user.managed_branch_ids))
             )
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def direct_manager_can_edit?
    record.user.manager_id == user.id &&
      !record.user.owner? &&
      user.managed_branch_ids.include?(record.branch_id)
  end

  def manages_subject?
    if manages_area?
      user.area_managed_branch_ids.include?(record.branch_id)
    elsif manages_branch?
      user.managed_branch_ids.include?(record.branch_id)
    else
      false
    end
  end

  def own_record?
    record.user_id == user.id
  end
end
