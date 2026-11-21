module Inventory
  # Inventory & Purchasing implementation of the Organization & Access
  # OrganizationAccess::WarehouseAccessProvider contract (registered in
  # config/initializers/organization_access_warehouse_access_provider.rb):
  # which warehouses a user may reach (Warehouse Architecture PR 5).
  #
  #   business owner                  -> nil (every warehouse of the business)
  #   access_all_warehouses           -> nil (explicit permission; in no default role)
  #   otherwise, the union of
  #     explicit WarehouseAssignments -> those warehouses, of the user's business only
  #     branch manager of a branch    -> the branch warehouse linked to THAT
  #       (branches.branch_manager_id)   branch (kind "branch", same business)
  #   nothing applicable              -> [] — fail-closed, never "every warehouse"
  #
  # Historical access (D3): the linked branch warehouse stays reachable when
  # the branch is deactivated or changes from sales to another type — a
  # branch warehouse is only ever provisioned for a sales branch and is never
  # detached, so the link itself is what counts. A branch with no linked
  # warehouse (a non-sales branch that never was sales) gives nothing, and an
  # area-manager link grants nothing (D2). This resolves warehouse REACH only —
  # the inventory permissions still decide which pages and actions a user has.
  #
  # LIVE PER BUSINESS: User#inventory_warehouse_ids consults this (through the
  # provider contract) only for a business switched to fail-closed by
  # OrganizationAccess::WarehouseAccessMode; every other business keeps the
  # legacy fail-open rule.
  #
  # One query for a non-owner (none for an owner / access_all_warehouses);
  # an instance memoizes its answer.
  class WarehouseAccess
    def self.warehouse_ids_for(user) = new(user).warehouse_ids

    def initialize(user)
      @user = user
    end

    # nil = every warehouse of the user's business; otherwise a sorted Array.
    def warehouse_ids
      return @warehouse_ids if defined?(@warehouse_ids)

      @warehouse_ids = resolve
    end

    private

    def resolve
      return nil if @user.owner? || @user.can?(:access_all_warehouses)

      business_id = @user.business_id
      return [] if business_id.nil?

      own = Warehouse.where(business_id: business_id)
      assigned = own.where(id: WarehouseAssignment.where(user_id: @user.id).select(:warehouse_id))
      managed  = own.where(kind: "branch",
                           branch_id: Branch.where(business_id: business_id, branch_manager_id: @user.id).select(:id))
      assigned.or(managed).order(:id).pluck(:id)
    end
  end
end
