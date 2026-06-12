class PerformanceReviewScore < ApplicationRecord
  belongs_to :performance_review
  belongs_to :evaluation_criterion

  MIN_SCORE = 1
  MAX_SCORE = 5

  validates :score, inclusion: { in: MIN_SCORE..MAX_SCORE }
  validates :evaluation_criterion_id,
            uniqueness: { scope: :performance_review_id }
end
