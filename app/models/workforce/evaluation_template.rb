class EvaluationTemplate < ApplicationRecord
  belongs_to :business
  belongs_to :department

  has_many :evaluation_criteria, dependent: :destroy
  accepts_nested_attributes_for :evaluation_criteria, allow_destroy: true,
                                reject_if: ->(attrs) { attrs[:name].blank? }

  validates :name, presence: true, length: { maximum: 150 }
  # The department must belong to the template's business; a request-supplied
  # id is never trusted just because the record exists (SEC-P3-1).
  validate :department_in_same_business, if: :will_save_change_to_department_id?

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

  private

  def department_in_same_business
    errors.add(:department, :invalid) if department && department.business_id != business_id
  end
end
