class Advance < ApplicationRecord
  belongs_to :user
  belongs_to :employee_request

  enum :status, { active: "active", fully_repaid: "fully_repaid" }

  validates :total_amount, :remaining_amount, presence: true,
            numericality: { greater_than_or_equal_to: 0 }
  validates :issued_at, presence: true

  scope :active,   -> { where(status: "active") }
  scope :for_user, ->(user) { where(user: user) }

  # Called by the payroll generator when deducting an instalment.
  def repay!(amount)
    new_remaining = [ remaining_amount - amount.to_f, 0 ].max
    update!(
      remaining_amount: new_remaining,
      status:           new_remaining <= 0 ? "fully_repaid" : "active"
    )
  end

  def repaid_amount
    total_amount - remaining_amount
  end
end
