class TillHandover < ApplicationRecord
  include AuditLoggable

  belongs_to :daily_reconciliation, inverse_of: :till_handovers
  belongs_to :from_user, class_name: "User"
  belongs_to :to_user,   class_name: "User", optional: true

  has_many :amounts, class_name: "TillHandoverAmount", dependent: :destroy

  validates :to_user, presence: true, unless: :self_deposit?

  scope :pending,  -> { where(accepted_at: nil) }
  scope :accepted, -> { where.not(accepted_at: nil) }

  delegate :business, :branch, to: :daily_reconciliation

  def pending?  = accepted_at.nil?
  def accepted? = accepted_at.present?
end
