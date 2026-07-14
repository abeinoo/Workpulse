# Rate history is append-only — index/new/create only, never edited or
# destroyed (mirrors TowelAdjustmentPolicy). Business-wide (not branch-scoped)
# since there is one rate list per business.
class LaundryStandardCostRatePolicy < ApplicationPolicy
  def index? = can?(:manage_laundry_cost_settings) || can?(:view_laundry_cost_reports)
  def show?  = index? && same_business?

  # Blank form (record is the class, or an unsaved instance) — only the
  # permission matters.
  def new? = can?(:manage_laundry_cost_settings)
  def create? = can?(:manage_laundry_cost_settings) && same_business?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user.can?(:manage_laundry_cost_settings) || user.can?(:view_laundry_cost_reports)

      scope.for_business(user.business)
    end
  end
end
