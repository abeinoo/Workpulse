class StockCountPolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory) || can?(:view_stock_count_reports)
  def show?    = index?

  # Creating / editing / deleting drafts.
  def create?  = can?(:manage_inventory) || can?(:manage_stock_counts)
  def new?     = create?
  def update?  = create? && draft_record?
  def edit?    = update?
  def destroy? = create? && draft_record?

  # Posting is a separate, higher-trust action (segregation of duties).
  def post?    = (can?(:manage_inventory) || can?(:post_stock_counts)) && draft_record?

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.for_business(user.business))
    end
  end

  private

  def draft_record?
    !record.respond_to?(:posted?) || record.draft?
  end
end
