class TillHandoverAmount < ApplicationRecord
  KINDS = %w[operational next_day].freeze

  belongs_to :till_handover
  belongs_to :payment_method

  validates :payment_method_name, presence: true
  validates :collected_amount, numericality: { greater_than_or_equal_to: 0 }
  validates :refund_amount,    numericality: { greater_than_or_equal_to: 0 }
  validates :kind, inclusion: { in: KINDS }

  scope :operational, -> { where(kind: "operational") }
  scope :next_day,    -> { where(kind: "next_day") }

  def net_amount
    collected_amount - refund_amount
  end
end
