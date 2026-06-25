class TillHandover < ApplicationRecord
  include AuditLoggable

  HANDOVER_TYPES = %w[transfer depositor].freeze

  enum :handover_type, { transfer: "transfer", depositor: "depositor" }

  belongs_to :business
  belongs_to :branch
  belongs_to :from_user,          class_name: "User"
  belongs_to :to_user,            class_name: "User", optional: true
  belongs_to :previous_handover,  class_name: "TillHandover", optional: true
  has_one    :next_handover,      class_name: "TillHandover",
                                  foreign_key: :previous_handover_id,
                                  inverse_of: :previous_handover,
                                  dependent: :restrict_with_error
  has_many   :lines,    class_name: "TillHandoverLine", dependent: :destroy
  has_many   :deposits, class_name: "TillDeposit",      dependent: :restrict_with_error

  validates :business_date,    presence: true
  validates :handover_type,    inclusion: { in: HANDOVER_TYPES }
  validates :to_user,          absence: true, if: :depositor?
  validates :to_user,          presence: true, if: :transfer?

  # Depositor handovers are self-accepted at creation; accepted_at must be set.
  validates :accepted_at, presence: true, if: :depositor?

  scope :for_branch_date, ->(branch, date) {
    where(branch: branch, business_date: date)
  }
  scope :pending,  -> { where(accepted_at: nil) }
  scope :accepted, -> { where.not(accepted_at: nil) }
  scope :for_business, ->(business) { where(business: business) }

  # The current holder is the tail of the chain: the accepted handover with
  # no successor. Returns nil if the day has no accepted handover yet.
  def self.current_holder_for(branch, date)
    for_branch_date(branch, date)
      .accepted
      .where.missing(:next_handover)
      .first
  end

  def pending?    = accepted_at.nil?
  def accepted?   = accepted_at.present?
  def chain_head? = previous_handover_id.nil?
  def chain_tail? = next_handover.nil?
end
