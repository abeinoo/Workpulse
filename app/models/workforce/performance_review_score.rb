class PerformanceReviewScore < ApplicationRecord
  belongs_to :performance_review
  belongs_to :evaluation_criterion

  MIN_SCORE = 1
  MAX_SCORE = 5

  validates :score, inclusion: { in: MIN_SCORE..MAX_SCORE }
  # The criterion must come from a template of the review's business (SEC-P3-1).
  validate :criterion_in_same_business, if: :will_save_change_to_evaluation_criterion_id?
  validates :evaluation_criterion_id,
            uniqueness: { scope: :performance_review_id }

  private

  def criterion_in_same_business
    template_business_id = evaluation_criterion&.evaluation_template&.business_id
    return if template_business_id.nil? || performance_review.nil?

    errors.add(:evaluation_criterion, :invalid) if template_business_id != performance_review.business_id
  end
end
