class SalesImportPolicy < ApplicationPolicy
  def index?                 = can?(:manage_sales_import)
  def create?                = can?(:manage_sales_import)
  def destroy?               = can?(:manage_sales_import)
  def edit_column_mapping?   = can?(:manage_sales_import)
  def update_column_mapping? = can?(:manage_sales_import)
  def preview_import?        = can?(:manage_sales_import)
  def confirm_import?        = can?(:manage_sales_import)

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(business: user.business)
    end
  end
end
