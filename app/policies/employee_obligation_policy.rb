class EmployeeObligationPolicy < ApplicationPolicy
  def index?  = can?(:manage_obligations)
  def show?   = can?(:manage_obligations)
  def create? = can?(:manage_obligations)
  def update? = can?(:manage_obligations)
  def pause?  = can?(:manage_obligations)
  def resume? = can?(:manage_obligations)
  def cancel? = can?(:manage_obligations)
  def postpone? = can?(:manage_obligations)

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.can?(:manage_obligations)
        configured = user.scope_for(:manage_obligations)
        base       = scope.for_business(user.business)
        if configured
          filter_by_data_scope(base, configured)
        else
          base
        end
      else
        scope.none
      end
    end
  end
end
