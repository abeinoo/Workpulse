module Inventory
  # Warehouse Architecture PR 5 (Phase 4): read-only impact report for the
  # fail-closed switch. For every user of each business it compares
  #
  #   old — today's effective access: User#inventory_warehouse_ids, unchanged
  #         (nil = every warehouse of the business — the fail-open rule);
  #   new — what Inventory::WarehouseAccess would return once activated
  #         (nil = every warehouse; [] = none).
  #
  # IDs only — no names or contact data. Nothing is written: no audit entry, no
  # permission, no assignment, no warehouse. Run it through
  # `bin/rails inventory:warehouse_access_report`, which also wraps it in a
  # READ ONLY database transaction so any write would be refused.
  class WarehouseAccessReport
    Row = Struct.new(:user_id, :business_id, :active, :owner, :role_id, :role_type, :inventory_permissions,
                     :old_ids, :new_ids, :flags, keyword_init: true) do
      def lost      = old_ids - new_ids
      def gained    = new_ids - old_ids
      def changed?  = lost.any? || gained.any?
    end

    # rows: users who hold an inventory permission, are owners, have
    # assignments or manage a branch with a linked warehouse. quiet_user_ids:
    # everyone else — no inventory permission, so no inventory page either way.
    # mode: "legacy" or "fail_closed" (Business#warehouse_access_fail_closed?) — in
    # fail-closed mode old and new coincide and FAIL_OPEN no longer applies.
    Section = Struct.new(:business_id, :mode, :warehouse_ids, :rows, :quiet_user_ids, keyword_init: true)

    def initialize(business_ids: nil)
      @business_ids = business_ids
    end

    def sections
      businesses = Business.order(:id)
      businesses = businesses.where(id: @business_ids) if @business_ids
      businesses.map { |business| section_for(business) }
    end

    private

    def inventory_permissions = @inventory_permissions ||= OrganizationAccess::PermissionCatalog.group(:inventory)

    def section_for(business)
      warehouse_ids = Warehouse.where(business_id: business.id).order(:id).pluck(:id)
      users = User.includes(:permission_role, :business).where(business_id: business.id).order(:id).to_a
      role_types = OrganizationAccess::PermissionCatalog.role_types(users.filter_map(&:permission_role_id).uniq)
      assigned   = WarehouseAssignment.where(user_id: users.map(&:id)).group(:user_id).pluck(:user_id, Arel.sql("ARRAY_AGG(warehouse_id ORDER BY warehouse_id)")).to_h
      branches   = Branch.where(business_id: business.id).pluck(:id, :branch_manager_id, :area_manager_id)
      linked     = Warehouse.where(business_id: business.id, kind: "branch").pluck(:branch_id).to_set

      rows, quiet = users.map { |user| row_for(user, warehouse_ids, role_types, assigned, branches, linked) }
                         .partition { |row| relevant?(row) }
      Section.new(business_id: business.id, mode: business.warehouse_access_fail_closed? ? "fail_closed" : "legacy",
                  warehouse_ids: warehouse_ids, rows: rows, quiet_user_ids: quiet.map(&:user_id))
    end

    def row_for(user, warehouse_ids, role_types, assigned, branches, linked)
      old = expand(user.inventory_warehouse_ids, warehouse_ids)
      new = expand(Inventory::WarehouseAccess.new(user).warehouse_ids, warehouse_ids)
      owner = user.owner?
      perms = owner ? [ "(owner: all)" ] : inventory_permissions.select { |permission| user.can?(permission) }
      role_type = role_types[user.permission_role_id]

      company_wide = owner || user.can?(:access_all_warehouses)
      flags = []
      flags << "OWNER" if owner
      flags << "INACTIVE_USER" unless user.active?
      flags << "ACCESS_ALL" if !owner && user.can?(:access_all_warehouses)
      flags << "ACCOUNTANT" if role_type == "accountant"
      flags << "FAIL_OPEN" if !owner && !user.business.warehouse_access_fail_closed? && user.inventory_warehouse_ids.nil?
      flags << "ASSIGNED" if assigned.key?(user.id)
      flags << "CROSS_BUSINESS_ASSIGNMENT" if (Array(assigned[user.id]) - warehouse_ids).any?
      flags << "BRANCH_MANAGER" if branches.any? { |id, manager, _| manager == user.id && linked.include?(id) }
      flags << "AREA_MANAGER" if branches.any? { |_, _, area| area == user.id }
      flags << "NO_INVENTORY_PERMISSION" if perms.empty?
      # Company-wide access over a business with no warehouse is not "zero access".
      flags << "ZERO_AFTER" if new.empty? && !company_wide
      flags << "LOSES" if (old - new).any?
      flags << "GAINS" if (new - old).any?

      Row.new(user_id: user.id, business_id: user.business_id, active: user.active?, owner: owner,
              role_id: user.permission_role_id, role_type: role_type, inventory_permissions: perms,
              old_ids: old, new_ids: new, flags: flags)
    end

    # nil (every warehouse of the business) as the explicit id list.
    def expand(ids, warehouse_ids) = ids.nil? ? warehouse_ids : ids.uniq.sort

    def relevant?(row)
      row.owner || row.inventory_permissions.any? || row.flags.include?("ASSIGNED") || row.flags.include?("BRANCH_MANAGER")
    end
  end
end
