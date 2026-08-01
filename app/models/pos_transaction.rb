class PosTransaction < ApplicationRecord
  belongs_to :pos_import
  belongs_to :business
  belongs_to :branch

  validates :transaction_id,    presence: true, uniqueness: { scope: :business_id }
  validates :amount,            presence: true, numericality: { greater_than: 0 }
  validates :status,            presence: true
  validates :transaction_date,  presence: true
  validates :terminal_id,       presence: true

  scope :ordered, -> { order(:transaction_date) }

  # Every transaction for a branch whose Paid At timestamp falls on the given
  # CALENDAR date, in the business's own timezone (midnight to midnight —
  # never business.business_day_start_hour). POS transactions are external
  # financial records (payment-terminal exports) and are reconciled against
  # their actual transaction timestamp, not the salon's operational business
  # day — business_day_start_hour rollover applies only to appointments,
  # sales sessions, and cash reconciliation. A transaction paid at 00:30
  # belongs to that calendar date, full stop; see
  # Finance::PosVerification::Comparator's caller in
  # DailyReconciliationsController for where this is used.
  def self.for_calendar_date(branch:, date:, business:)
    range_start = business.timezone_object.local(date.year, date.month, date.day)
    where(branch: branch, transaction_date: range_start...(range_start + 1.day))
  end

  def total_fees
    fees.to_d + administrative_fees.to_d
  end
end
