# One failed row from a stock-issue CSV import, held for inline resolution.
# `sku`/`quantity` start out as the raw CSV values and are overwritten as the
# user edits them; `product_id` is set once the row resolves to a real product.
# `stock_issue_item` is the line this row appended to the batch's draft
# StockIssue once resolved — tracked so a later edit or reopen can update or
# remove that exact item instead of leaving a stale duplicate on the draft.
class StockIssueImportRow < ApplicationRecord
  belongs_to :batch, class_name: "StockIssueImportBatch"
  belongs_to :product, optional: true
  belongs_to :stock_issue_item, optional: true

  enum :status, { pending: "pending", resolved: "resolved", skipped: "skipped", imported: "imported" }
  enum :failure_reason, {
    invalid_row:       "invalid_row",
    unknown_sku:        "unknown_sku",
    insufficient_stock: "insufficient_stock"
  }, prefix: true, validate: { allow_nil: true }

  validates :row_number, presence: true
  validates :status, inclusion: { in: statuses.keys }

  scope :ordered, -> { order(:row_number) }
end
