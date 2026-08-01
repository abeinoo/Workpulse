class SalesImport < ApplicationRecord
  include AuditLoggable

  has_one_attached :file

  belongs_to :business
  belongs_to :imported_by, class_name: "User"

  has_many :sales_transactions, dependent: :destroy

  STATUSES = %w[pending column_mapped imported failed].freeze

  validates :file_name, presence: true
  validates :status,    inclusion: { in: STATUSES }

  scope :ordered,  -> { order(created_at: :desc) }
  scope :imported, -> { where(status: "imported") }

  def pending?       = status == "pending"
  def column_mapped? = status == "column_mapped"
  def imported?      = status == "imported"
  def failed?        = status == "failed"

  # Branch-level totals for a specific DR: { "Cash" => BigDecimal, ... }
  # Called from the DR show page to get Sales comparison data.
  def sales_totals_for(daily_reconciliation)
    sales_transactions
      .where(daily_reconciliation: daily_reconciliation)
      .group(:payment_method_name)
      .sum(:amount)
  end

  # Per-cashier totals for a specific DR: { "Ahmed" => { "Cash" => BigDecimal } }
  def cashier_totals_for(daily_reconciliation)
    sales_transactions
      .where(daily_reconciliation: daily_reconciliation)
      .group(:cashier_name, :payment_method_name)
      .sum(:amount)
      .each_with_object({}) do |((cashier, method), total), hash|
        hash[cashier] ||= {}
        hash[cashier][method] = total
      end
  end
end
