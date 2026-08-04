class PerformanceReview < ApplicationRecord
  belongs_to :business
  belongs_to :department
  belongs_to :employee, class_name: "User"
  belongs_to :reviewer, class_name: "User"
  belongs_to :branch, optional: true

  has_many :performance_review_scores, dependent: :destroy
  accepts_nested_attributes_for :performance_review_scores, allow_destroy: true,
                                reject_if: ->(attrs) { attrs[:score].blank? }

  STATUSES = %w[draft submitted finalized].freeze
  enum :status, { draft: "draft", submitted: "submitted", finalized: "finalized" },
       default: "draft"

  validates :review_month, inclusion: { in: 1..12 }
  validates :review_year,  numericality: { only_integer: true, greater_than: 2000, less_than: 3000 }
  validates :review_period, length: { maximum: 60 }, allow_blank: true

  # Average is derived from the entered scores and stored for fast reporting.
  before_save :recalculate_average

  # branch_id/department_id are historical snapshots, captured once at creation
  # so a later employee transfer never rewrites past analytics. Only fills in
  # blanks (||=) — a caller (e.g. the review form) may already have set
  # department_id explicitly. branch_id comes from the employee's current
  # ShiftAssignment at the moment the review is created (see BranchMembership)
  # — nil when the employee has no active assignment, which read paths must
  # handle nil-safely.
  before_validation :snapshot_branch_and_department, on: :create

  scope :for_business, ->(business) { where(business: business) }
  scope :finalized_reviews, -> { where(status: "finalized") }
  scope :for_period, ->(year, month) { where(review_year: year, review_month: month) }
  scope :recent_first, -> { order(review_year: :desc, review_month: :desc, created_at: :desc) }

  def recalculate_average
    scores = performance_review_scores.reject(&:marked_for_destruction?)
                                      .map(&:score).compact
    self.average_score = scores.any? ? (scores.sum.to_f / scores.size).round(2) : nil
  end

  # Localized "Month Year" label. Uses I18n.l (not strftime, which is not
  # locale-aware) so Arabic screens show Arabic month names.
  def period_label
    I18n.l(Date.new(review_year, review_month, 1), format: "%B %Y")
  end

  def finalize!(at: Time.current)
    update!(status: "finalized", finalized_at: at)
  end

  private

  def snapshot_branch_and_department
    return unless employee

    self.department_id ||= employee.department_id
    self.branch_id     ||= BranchMembership.current_branch_ids(employee).first
  end
end
