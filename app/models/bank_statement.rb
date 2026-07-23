class BankStatement < ApplicationRecord
  include AuditLoggable

  has_one_attached :file

  belongs_to :business
  belongs_to :branch,     optional: true
  belongs_to :imported_by, class_name: "User"
  belongs_to :deleted_by,  class_name: "User", optional: true

  has_many :bank_statement_transactions, dependent: :destroy

  STATUSES = %w[pending processing completed failed].freeze

  validates :file_name,      presence: true
  validates :statement_from, presence: true
  validates :statement_to,   presence: true
  validates :status,         inclusion: { in: STATUSES }
  validate  :date_range_must_be_valid

  scope :for_business, ->(business) { where(business: business) }
  scope :active,       -> { where(deleted_at: nil) }
  scope :completed,    -> { where(status: "completed") }
  scope :ordered,      -> { order(created_at: :desc) }

  def pending?    = status == "pending"
  def processing? = status == "processing"
  def completed?  = status == "completed"
  def failed?     = status == "failed"
  def deleted?    = deleted_at.present?

  # Soft-delete: preserves the record and all child transactions for audit
  # purposes. The policy scope filters deleted statements from normal queries.
  def soft_destroy!(actor:, notes: nil)
    raise ActiveRecord::RecordNotDestroyed, "Already deleted" if deleted?

    update_columns(
      deleted_at:     Time.current,
      deleted_by_id:  actor.id,
      deletion_notes: notes
    )

    log_audit(
      actor:     actor,
      auditable: self,
      action:    :bank_statement_deleted,
      metadata:  {
        file_name:      file_name,
        statement_from: statement_from.to_s,
        statement_to:   statement_to.to_s,
        total_rows:     total_rows,
        matched_rows:   matched_rows,
        notes:          notes
      }
    )
  end

  # Denotes what fraction of imported rows were matched. Uses matched_rows /
  # total_rows because the index page shows this before ignores are known.
  # For per-statement accuracy, use build_statement_stats in the controller.
  def verification_rate
    return 0 if total_rows.zero?

    (matched_rows.to_f / total_rows * 100).round(1)
  end

  def covers_date?(date)
    date.between?(statement_from, statement_to)
  end

  CANONICAL_FIELDS = %w[transaction_date amount reference_number description external_transaction_id transaction_type].freeze

  def detected_csv_headers
    return [] if column_mapping.blank?

    column_mapping.values.compact
  end

  private

  def date_range_must_be_valid
    return unless statement_from && statement_to

    errors.add(:statement_to, :before_start) if statement_to < statement_from
  end
end
