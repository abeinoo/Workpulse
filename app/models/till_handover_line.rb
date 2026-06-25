class TillHandoverLine < ApplicationRecord
  belongs_to :till_handover
  belongs_to :payment_method

  validates :collected_amount, numericality: { greater_than_or_equal_to: 0 }
  validates :refund_amount,    numericality: { greater_than_or_equal_to: 0 }

  def net_amount
    collected_amount - refund_amount
  end
end
