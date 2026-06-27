class TillSessionAmount < ApplicationRecord
  belongs_to :daily_reconciliation
  belongs_to :payment_method

  validates :payment_method_name, presence: true
  validates :collected_amount,    numericality: { greater_than_or_equal_to: 0 }
  validates :refund_amount,       numericality: { greater_than_or_equal_to: 0 }

  def net_amount
    collected_amount - refund_amount
  end

  def self.upsert_by_payment_method(pm, collected_amount:, refund_amount:)
    record = find_or_initialize_by(payment_method: pm)
    record.assign_attributes(
      payment_method_name: pm.display_name,
      collected_amount:    collected_amount,
      refund_amount:       refund_amount
    )
    record.save!
    record
  end
end
