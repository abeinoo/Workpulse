# Composition root for the OrganizationAccess::WarehouseAccessProvider contract:
# Organization & Access defines it, Inventory & Purchasing implements it. Wired
# here so neither domain names the other (module-boundaries.md §12.1).
# to_prepare re-registers after a code reload in development.
#
# Registering the provider changes nothing by itself: User#inventory_warehouse_ids
# does not consult the contract until the fail-closed activation step is
# separately approved (Warehouse Architecture PR 5).
Rails.application.config.to_prepare do
  OrganizationAccess::WarehouseAccessProvider.register(Inventory::WarehouseAccess)
end
