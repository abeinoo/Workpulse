class StockCountPolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory) || can?(:view_stock_count_reports)
  def show?    = index?

  # Creating sessions and editing counts (draft / in_progress only).
  def create?  = can?(:manage_inventory) || can?(:manage_stock_counts)
  def new?     = create?
  def update?  = create? && record.editable_counts?
  def edit?    = update?
  def destroy? = create? && record.draft?

  # Submitting a finished count for approval.
  def complete? = create? && record.in_progress?

  # Approval / send-back are higher-trust actions (segregation of duties):
  # an employee with only counting rights cannot approve.
  def approve? = approver? && record.completed?
  def reopen?  = approver? && record.completed?

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.for_business(user.business))
    end
  end

  private

  def approver?
    can?(:manage_inventory) || can?(:post_stock_counts)
  end
end
