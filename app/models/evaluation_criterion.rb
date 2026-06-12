class EvaluationCriterion < ApplicationRecord
  belongs_to :evaluation_template

  has_one  :department, through: :evaluation_template
  has_one  :business,   through: :evaluation_template

  # restrict_with_error preserves historical scores/observations. Retiring a
  # criterion is done with #active, never by deletion.
  has_many :performance_review_scores, dependent: :restrict_with_error
  has_many :performance_observations,  dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 150 }
  validates :sort_order, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :active,  -> { where(active: true) }
  scope :ordered, -> { order(:sort_order, :id) }

  def deactivate! = update!(active: false)
  def activate!   = update!(active: true)
end
