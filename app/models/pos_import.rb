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

  def pending?  = status == "pending"
  def imported? = status == "imported"
  def failed?   = status == "failed"

  # A Set for fast membership checks in the import pipeline (IgnoredRowsFilter).
  def ignored_row_numbers
    pos_import_ignored_rows.pluck(:row_number).to_set
  end
end
