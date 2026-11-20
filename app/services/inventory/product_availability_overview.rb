module Inventory
  # Read-only: one product's availability across the warehouses a user can
  # reach — for the product Edit page's availability section (and its
  # standalone page) and the product page's "Manage availability" link.
  # Writes nothing: a sales branch without a row is shown as Included without
  # creating one.
  #
  # Warehouses come from WarehousePolicy::Scope and rows from
  # ProductWarehouseSettingPolicy::Scope (the single scope path), so a
  # warehouse-scoped user never sees another warehouse's pair. Listed:
  # every reachable warehouse a product is Included in by default
  # (Warehouse#availability_included_by_default?: active central
  # and active sales branch warehouses) — Included (no row, or Active) or Excluded
  # (Inactive row) — grouped for display only, plus any other reachable
  # warehouse that still has a row (an inactive or non-sales warehouse).
  class ProductAvailabilityOverview
    attr_reader :product, :user

    def initialize(product, user:)
      @product = product
      @user    = user
    end

    def pairs
      @pairs ||= begin
        rows = ProductWarehouseSettingPolicy::Scope.new(user, ProductWarehouseSetting).resolve
                                                   .where(product_id: product.id).includes(:status_changed_by)
                                                   .index_by(&:warehouse_id)
        warehouses = WarehousePolicy::Scope.new(user, Warehouse).resolve.includes(:branch)
                                           .where("warehouses.id IN (?) OR warehouses.status = 'active'", rows.keys.presence || [ 0 ])
                                           .ordered.to_a
                                           .select { |w| rows.key?(w.id) || w.availability_included_by_default? }
        AvailabilityFigures.build(warehouses.map { |w| [ product, w, rows[w.id] ] })
                           .sort_by { |pair| [ group_order(pair), pair.warehouse.name.downcase ] }
      end
    end

    # Display groups only — every included-by-default card works the same way.
    def branch_pairs  = pairs.select { |pair| pair.included_by_default? && pair.warehouse.kind_branch? }
    def central_pairs = pairs.select { |pair| pair.included_by_default? && pair.warehouse.kind_central? }
    def other_pairs   = pairs - branch_pairs - central_pairs

    # An archived product's cards are read-only (it is out of operations).
    def manageable?(warehouse)
      return false unless product.active?

      @manageable ||= {}
      @manageable.fetch(warehouse.id) do
        @manageable[warehouse.id] = ProductWarehouseSettingPolicy.new(user, warehouse).manage?
      end
    end

    def any_manageable? = pairs.any? { |pair| manageable?(pair.warehouse) }

    def product_active? = product.active?

    private

    def group_order(pair)
      return 0 if pair.included_by_default? && pair.warehouse.kind_branch?
      return 1 if pair.included_by_default? && pair.warehouse.kind_central?

      2
    end
  end
end
