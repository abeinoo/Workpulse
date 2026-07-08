# Staging area for a stock-issue CSV import. `stock_issue` is the single draft
# StockIssue for this import's entire lifecycle: structurally-valid rows are
# added to it as items immediately; whatever's left over is held here as
# `rows` for the user to fix inline (without re-uploading the file), and each
# resolved row appends its item to that SAME draft. "Complete Import" simply
# posts it — there is never a second issue for one import.
class StockIssueImportBatch < ApplicationRecord
  belongs_to :business
  belongs_to :warehouse
  belongs_to :branch
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :stock_issue

  has_many :rows, class_name: "StockIssueImportRow", foreign_key: :batch_id, dependent: :destroy

  enum :status, { draft: "draft", completed: "completed" }

  validates :status, inclusion: { in: statuses.keys }

  scope :for_business, ->(business) { where(business: business) }
end
