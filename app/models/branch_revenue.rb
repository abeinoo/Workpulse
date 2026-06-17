class BranchRevenue < ApplicationRecord
  belongs_to :business
  belongs_to :branch
  belongs_to :created_by, class_name: "User", optional: true

  validates :amount, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :period_month, presence: true
  validates :period_month, uniqueness: { scope: :branch_id }
  validate  :branch_in_same_business

  before_validation :normalize_period_month

  scope :for_business, ->(business)  { where(business: business) }
  scope :for_branch,   ->(branch_id) { where(branch_id: branch_id) if branch_id.present? }
  scope :in_period,    ->(from, to)  { where(period_month: from.beginning_of_month..to.beginning_of_month) }
  scope :recent,       -> { order(period_month: :desc) }

  private

  # Store revenue against the first day of its month so one row = one branch-month.
  def normalize_period_month
    self.period_month = period_month.beginning_of_month if period_month.present?
  end

  def branch_in_same_business
    return if branch.nil? || business_id.nil?

    errors.add(:branch, :invalid) if branch.business_id != business_id
  end
end
