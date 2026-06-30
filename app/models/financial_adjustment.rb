class FinancialAdjustment < ApplicationRecord
  include AuditLoggable

  ADJUSTABLE_TYPES = %w[
    TillHandover
    TillDeposit
    RemainingDepositBalance
    TillSessionAmount
    DailyReconciliation
  ].freeze

  belongs_to :adjustable, polymorphic: true
  belongs_to :business
  belongs_to :actor,       class_name: "User"
  belongs_to :approved_by, class_name: "User", optional: true

  validates :reason_code,     presence: true
  validates :notes,           presence: true, length: { minimum: 10 }
  validates :before_data,     presence: true
  validates :after_data,      presence: true
  validates :adjustable_type, inclusion: { in: ADJUSTABLE_TYPES }

  scope :for_business,     ->(b) { where(business: b) }
  scope :approved,         -> { where.not(approved_at: nil) }
  scope :pending_approval, -> { where(approved_at: nil) }
  scope :for_adjustable,   ->(type, id) { where(adjustable_type: type, adjustable_id: id) }
  scope :ordered,          -> { order(created_at: :desc) }

  before_update  { raise ActiveRecord::ReadOnlyRecord, "FinancialAdjustment records are immutable after creation." }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "FinancialAdjustment records cannot be deleted." }
end
