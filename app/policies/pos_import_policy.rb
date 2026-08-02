class PosImportPolicy < ApplicationPolicy
  def index?          = can?(:manage_pos_import)
  def create?         = can?(:manage_pos_import)
  # Only a not-yet-confirmed (or failed/rolled-back) import may be deleted —
  # once confirmed, PosImport#deletable? is false and the model-level guard
  # (before_destroy :reject_destroy_unless_deletable) backs this up.
  def destroy?        = can?(:manage_pos_import) && (!record.is_a?(PosImport) || record.deletable?)
  def preview_import?  = can?(:manage_pos_import)
  def confirm_import?  = can?(:manage_pos_import)
  def ignore_row?      = can?(:manage_pos_import)

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(business: user.business)
    end
  end
end
