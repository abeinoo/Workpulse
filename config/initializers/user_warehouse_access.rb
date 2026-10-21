# Composition root for the OrganizationAccess::UserWarehouseAccess contract:
# Organization & Access defines it, Inventory & Purchasing implements it. Wired
# here so neither domain names the other (module-boundaries.md §12.1).
# to_prepare re-registers after a code reload in development.
# See docs/architecture/next-pilot-selection.md (Batch W — warehouse access write boundary, §28).
Rails.application.config.to_prepare do
  OrganizationAccess::UserWarehouseAccess.register(Inventory::UserWarehouseAssignments)
end
