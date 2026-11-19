# Composition root for the OrganizationAccess::WarehouseAccessProvider contract:
# Organization & Access defines it, Inventory & Purchasing implements it. Wired
# here so neither domain names the other (module-boundaries.md §12.1).
# to_prepare re-registers after a code reload in development.
#
# Registering the provider changes nothing by itself: User#inventory_warehouse_ids
# consults the contract only for a business switched to fail-closed by
# OrganizationAccess::WarehouseAccessMode (gradual activation).
Rails.application.config.to_prepare do
  OrganizationAccess::WarehouseAccessProvider.register(Inventory::WarehouseAccess)
end
