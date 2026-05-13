class ShiftAssignment < ApplicationRecord
  belongs_to :user
  belongs_to :shift
  belongs_to :branch, optional: true

  validates :effective_from, presence: true
  validate  :effective_to_after_effective_from
  validate  :no_overlapping_assignment

  scope :active_on, ->(date) {
    where("effective_from <= ?", date)
      .where("effective_to IS NULL OR effective_to >= ?", date)
  }
  scope :current, -> { active_on(Date.current) }
  scope :for_business, ->(business) {
    joins(:user).where(users: { business_id: business.id })
  }

  delegate :name, to: :shift,  prefix: true
  delegate :name, to: :branch, prefix: true, allow_nil: true

  private

  def effective_to_after_effective_from
    return unless effective_to.present? && effective_from.present?

    errors.add(:effective_to, "must be after start date") if effective_to <= effective_from
  end

  def no_overlapping_assignment
    return unless user_id && effective_from

    range_end  = effective_to || Date.new(9999, 12, 31)
    base_scope = ShiftAssignment.where(user_id: user_id).where.not(id: id)
    base_scope = branch_id ? base_scope.where(branch_id: branch_id)
                           : base_scope.where(branch_id: nil)

    overlap = base_scope
      .where("effective_from <= ?", range_end)
      .where("effective_to IS NULL OR effective_to >= ?", effective_from)
      .exists?

    msg = branch_id ? "Overlaps with an existing assignment for this user in this branch"
                    : "Overlaps with an existing unassigned shift for this user"
    errors.add(:base, msg) if overlap
  end
end
