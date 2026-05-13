class AttendanceRecordPolicy < ApplicationPolicy
  def index?   = super_admin? || branch_manager? || accountant? || employee?
  def show?    = super_admin? || accountant_sees_record? || branch_sees_record? || own_record?
  def create?  = false  # created only via CheckInService
  def update?  = super_admin? || direct_manager_can_edit?
  def destroy? = super_admin?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.super_admin? || user.accountant?
        scope.for_business(user.business)
      elsif user.branch_manager?
        # Index view: own records + records for all branch employees (read-only overview)
        scope.for_business(user.business)
             .where(
               AttendanceRecord.arel_table[:user_id].eq(user.id)
               .or(AttendanceRecord.arel_table[:branch_id].in(user.branch_ids))
             )
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  # Edit gate: manager is ONLY allowed to edit records belonging to
  # their directly assigned employees, and only in branches they manage.
  # Never super_admins, never self.
  def direct_manager_can_edit?
    branch_manager? &&
      record.user.manager_id == user.id &&
      !record.user.super_admin? &&
      user.branch_ids.include?(record.branch_id)
  end

  # View gate: accountant can see all attendance records for their business
  def accountant_sees_record?
    accountant? && same_business?(record.user)
  end

  # View gate: branch manager can see any record in their managed branches
  def branch_sees_record?
    branch_manager? && user.branch_ids.include?(record.branch_id)
  end

  def own_record?
    record.user_id == user.id
  end
end
