class PosTerminal < ApplicationRecord
  belongs_to :business
  belongs_to :branch

  # Managed entirely as a nested section of the Branch form — there is no
  # standalone Terminal configuration page. business_id is always derived
  # from the owning branch, never chosen directly.
  before_validation :default_business_from_branch

  validates :terminal_id, presence: true, uniqueness: { scope: :business_id }
  validate  :branch_in_same_business

  scope :active,  -> { where(active: true) }
  scope :ordered, -> { order(:terminal_id) }

  private

  def default_business_from_branch
    self.business_id ||= branch&.business_id
  end

  def branch_in_same_business
    return if branch.nil? || business_id.nil?

    errors.add(:branch, :invalid) if branch.business_id != business_id
  end
end
