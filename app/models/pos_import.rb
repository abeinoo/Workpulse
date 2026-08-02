class PosImport < ApplicationRecord
  include AuditLoggable

  has_one_attached :file

  belongs_to :business
  belongs_to :imported_by, class_name: "User"

  has_many :pos_transactions, dependent: :destroy
  has_many :generated_expenses, class_name: "Expense",
                                foreign_key: :source_pos_import_id,
                                dependent: :restrict_with_error,
                                inverse_of: :source_pos_import
  has_many :pos_import_ignored_rows, dependent: :destroy

  STATUSES = %w[pending imported failed].freeze

  validates :file_name, presence: true
  validates :status,    inclusion: { in: STATUSES }

  scope :ordered, -> { order(created_at: :desc) }

  # Only a "pending" (uploaded, not yet confirmed) or "failed" (rolled back,
  # nothing persisted) import can be deleted — the same "posted or not" line
  # ImmutableDocument draws for GoodsReceipt/StockIssue/StockTransfer and
  # StockCount#reject_destroy_unless_draft draws for stock counts. Once
  # confirmed ("imported"), this document's PosTransaction rows may already
  # back Daily Reconciliation's POS Verification section, Bank Statement
  # matching (Finance::DepositVerification::MatchingEngine), and generated
  # Expenses — deleting it would silently erase that financial trail with no
  # way to detect or reverse it (see #reject_destroy_unless_deletable below).
  # Correct a bad import by re-uploading corrected/additional rows, never by
  # deleting a confirmed one.
  before_destroy :reject_destroy_unless_deletable, prepend: true

  def pending?  = status == "pending"
  def imported? = status == "imported"
  def failed?   = status == "failed"

  def deletable? = pending? || failed?

  # A Set for fast membership checks in the import pipeline (IgnoredRowsFilter).
  def ignored_row_numbers
    pos_import_ignored_rows.pluck(:row_number).to_set
  end

  private

  def reject_destroy_unless_deletable
    return if deletable?

    raise ImmutableDocument::DeletionNotAllowedError,
          "PosImport ##{id} has already been imported and cannot be deleted — its POS transactions " \
          "may back Daily Reconciliation, bank matching, or generated expenses. Re-upload corrected " \
          "or additional rows instead of deleting a confirmed import."
  end
end
