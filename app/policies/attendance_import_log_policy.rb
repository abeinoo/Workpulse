class AttendanceImportLogPolicy < ApplicationPolicy
  # Class-level actions (new/create/template): only the role check matters
  def new?         = can_import?
  def create?      = can_import?
  def template?    = can_import?

  # Record-level actions: role check + same-business guard (from ApplicationPolicy)
  def show?        = can_import? && same_business?
  def confirm?     = can_import? && same_business?
  def failed_rows? = can_import? && same_business?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(business_id: user.business_id)
    end
  end

  private

  def can_import?
    owner? || can?(:manage_attendance)
  end
end
