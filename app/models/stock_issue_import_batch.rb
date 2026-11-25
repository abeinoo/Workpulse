# Staging area for a stock-issue CSV import. `stock_issue` is the single draft
# StockIssue for this import's entire lifecycle: structurally-valid rows are
# added to it as items immediately; whatever's left over is held here as
# `rows` for the user to fix inline (without re-uploading the file), and each
# resolved row appends its item to that SAME draft. "Complete Import" submits
# it for approval (it never posts stock) — there is never a second issue for
# one import.
class StockIssueImportBatch < ApplicationRecord
  include RequiresActiveWarehouse
  belongs_to :business
  belongs_to :warehouse
  include OperationalWarehouseReference
  operational_warehouse :warehouse # never the system transit warehouse
  # Cost attribution copied from the import's StockIssue (nil for a
  # non-branch warehouse — allowed once the pending migration
  # 20261124110000 relaxes the column). Not a user input.
  belongs_to :branch, optional: true
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :stock_issue

  has_many :rows, class_name: "StockIssueImportRow", foreign_key: :batch_id, dependent: :destroy

  enum :status, { draft: "draft", completed: "completed" }

  validates :status, inclusion: { in: statuses.keys }
  requires_active_warehouse :warehouse

  scope :for_business, ->(business) { where(business: business) }
end
