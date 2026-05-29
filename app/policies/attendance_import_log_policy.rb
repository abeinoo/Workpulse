class AttendanceImportLogPolicy < ApplicationPolicy
  def new?         = can?(:manage_attendance)
  def create?      = can?(:manage_attendance)
  def template?    = can?(:manage_attendance)
  def show?        = can?(:manage_attendance) && same_business?
  def confirm?     = can?(:manage_attendance) && same_business?
  def failed_rows? = can?(:manage_attendance) && same_business?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(business_id: user.business_id)
    end
  end
end
