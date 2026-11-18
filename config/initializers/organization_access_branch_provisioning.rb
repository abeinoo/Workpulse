# Composition root for the OrganizationAccess::BranchProvisioning contract:
# Organization & Access defines it, Inventory & Purchasing implements it (the
# branch warehouse of every sales branch). Wired here so neither domain names
# the other (module-boundaries.md §12.1). to_prepare re-registers after a code
# reload in development.
Rails.application.config.to_prepare do
  OrganizationAccess::BranchProvisioning.register(Inventory::BranchWarehouseProvisioning)
end
