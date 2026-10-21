# Composition root for the Inventory::PurchaseRequestAdvanceEffects contract:
# Inventory & Purchasing defines it, Finance & Sales implements it. Wired here so
# neither domain names the other (module-boundaries.md §12.1). to_prepare
# re-registers after a code reload in development.
# See docs/architecture/inventory-finance-purchase-request-advances-baseline-failures.txt (S2).
Rails.application.config.to_prepare do
  Inventory::PurchaseRequestAdvanceEffects.register(Finance::PurchaseRequestAdvanceEffects)
end
