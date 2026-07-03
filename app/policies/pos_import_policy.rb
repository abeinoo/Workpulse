class PosImportPolicy < ApplicationPolicy
  def index?                 = can?(:manage_pos_import)
  def create?                = can?(:manage_pos_import)
  def destroy?               = can?(:manage_pos_import)
  def edit_column_mapping?   = can?(:manage_pos_import)
  def update_column_mapping? = can?(:manage_pos_import)
  def preview_import?        = can?(:manage_pos_import)
  def confirm_import?        = can?(:manage_pos_import)

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(business: user.business)
    end
  end
end
