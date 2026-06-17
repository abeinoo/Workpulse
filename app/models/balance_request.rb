class BalanceRequest < ApplicationRecord
  include AuditLoggable

  STATUSES = %w[draft pending_approval approved paid rejected].freeze

  belongs_to :business
  belongs_to :created_by,  class_name: "User"
  belongs_to :branch,      optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :paid_by,     class_name: "User", optional: true

  enum :status, {
    draft:            "draft",
    pending_approval: "pending_approval",
    approved:         "approved",
    paid:             "paid",
    rejected:         "rejected"
  }

  validates :amount,       presence: true, numericality: { greater_than: 0 }
  validates :request_date, presence: true
  validates :notes,        presence: true
  validates :status,       inclusion: { in: STATUSES }
  validate  :branch_in_same_business

  scope :for_business, ->(business) { where(business: business) }
  scope :with_status,  ->(s)        { s.present? ? where(status: s) : all }
  scope :pending,      -> { where(status: "pending_approval") }
  scope :recent,       -> { order(created_at: :desc) }

  private

  def branch_in_same_business
    return if branch.nil? || business_id.nil?

    errors.add(:branch, :invalid) if branch.business_id != business_id
  end
end
