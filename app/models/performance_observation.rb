class PerformanceObservation < ApplicationRecord
  belongs_to :business
  belongs_to :evaluation_criterion
  belongs_to :employee,    class_name: "User"
  belongs_to :observed_by, class_name: "User"

  TYPES = %w[positive negative neutral].freeze
  enum :observation_type,
       { positive: "positive", negative: "negative", neutral: "neutral" },
       prefix: :type

  validates :observation_date, presence: true
  validates :note, length: { maximum: 2000 }, allow_blank: true

  scope :for_business, ->(business) { where(business: business) }
  scope :for_employee, ->(employee) { where(employee: employee) }
  scope :recent_first, -> { order(observation_date: :desc, created_at: :desc) }

  # Observations dated within a calendar month — the window a monthly review
  # pulls in. Uses observation_date (a date), so it's timezone-agnostic.
  scope :for_month, ->(year, month) {
    start_date = Date.new(year, month, 1)
    where(observation_date: start_date..start_date.end_of_month)
  }
end
