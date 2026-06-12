class EvaluationTemplate < ApplicationRecord
  belongs_to :business
  belongs_to :department

  has_many :evaluation_criteria, dependent: :destroy
  accepts_nested_attributes_for :evaluation_criteria, allow_destroy: true,
                                reject_if: ->(attrs) { attrs[:name].blank? }

  validates :name, presence: true, length: { maximum: 150 }

  scope :active,  -> { where(active: true) }
  scope :ordered, -> { order(:name) }
  scope :for_business, ->(business) { where(business: business) }

  # Criteria shown when composing a review / recording an observation: active
  # only, in display order. Deactivated criteria stay attached to historical
  # scores and observations but never appear in new selections.
  def active_criteria
    evaluation_criteria.active.ordered
  end

  def deactivate! = update!(active: false)
  def activate!   = update!(active: true)
end
