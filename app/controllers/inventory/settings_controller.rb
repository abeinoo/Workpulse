# Inventory Settings hub — a landing page for the workspace's configuration
# screens (product categories, brands). Holds no settings of its own; each
# linked page keeps its own policy checks.
class Inventory::SettingsController < Inventory::BaseController
  def show
    raise Pundit::NotAuthorizedError unless policy(ProductCategory).index? || policy(Brand).index?
  end
end
