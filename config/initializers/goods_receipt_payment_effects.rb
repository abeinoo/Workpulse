# Composition root for the Inventory::GoodsReceiptPaymentEffects contract:
# Inventory & Purchasing defines it, Finance & Sales implements it. Wired here so
# neither domain names the other (module-boundaries.md §12.1). to_prepare
# re-registers after a code reload in development.
# See docs/architecture/inventory-finance-goods-receipt-payments-baseline-failures.txt (Batch S).
Rails.application.config.to_prepare do
  Inventory::GoodsReceiptPaymentEffects.register(Finance::GoodsReceiptPaymentEffects)
end
