class RemainingDepositBalance < ApplicationRecord
  include AuditLoggable

  STATUSES = %w[open settled written_off].freeze

  enum :status, { open: "open", settled: "settled", written_off: "written_off" }

  # ── Aggregate root ──────────────────────────────────────────────────────────
  belongs_to :daily_reconciliation, inverse_of: :remaining_deposit_balances
  belongs_to :till_deposit,         optional: true
  belongs_to :responsible_user,     class_name: "User"
  belongs_to :created_by,           class_name: "User"
  belongs_to :business
  belongs_to :branch

  # ── Append-only ledger of every financial event on this balance ─────────────
  has_many :balance_transactions,
           class_name:  "RemainingDepositBalanceTransaction",
           dependent:   :destroy,
           inverse_of:  :remaining_deposit_balance

  # ── Validations ─────────────────────────────────────────────────────────────
  validates :amount,           presence: true, numericality: { greater_than: 0 }
  validates :remaining_amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :status,           inclusion: { in: STATUSES }
  validates :closed_at,        presence: true, if: -> { settled? || written_off? }

  # ── Scopes ───────────────────────────────────────────────────────────────────
  scope :for_business, ->(b) { where(business: b) }
  scope :for_branch,   ->(b) { where(branch: b) }
  scope :ordered,      ->    { order(created_at: :desc) }
  scope :unsettled,    ->    { open }
  scope :overdue,      ->(days: 3) { open.where("remaining_deposit_balances.created_at < ?", days.days.ago) }

  def closed? = settled? || written_off?

  # Who closed this balance — derived from the last closure transaction.
  def closed_by
    balance_transactions
      .where(transaction_type: %w[settlement write_off])
      .order(:created_at).last&.performed_by
  end

  # ── Aging helpers ─────────────────────────────────────────────────────────────
  def age_hours = ((Time.current - created_at) / 1.hour).to_i

  def age_display
    h = age_hours
    return "< 1h" if h < 1
    return "#{h}h" if h < 24
    "#{h / 24}d"
  end

  # CSS custom-property color keyed on age of open balance.
  def age_color
    return nil unless open?
    h = age_hours
    return "var(--success,#16a34a)" if h < 24
    return "var(--warning,#ca8a04)" if h < 72
    return "var(--orange,#ea580c)"  if h < 168
    "var(--danger,#dc2626)"
  end
end
