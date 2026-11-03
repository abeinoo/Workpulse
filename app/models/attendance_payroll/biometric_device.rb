class BiometricDevice < ApplicationRecord
  belongs_to :business
  # The branch the device physically stands at: every punch it sends is logged
  # with this branch (BiometricPunchLog#branch_id, copied at receipt — moving
  # the device later never rewrites past logs). Optional while existing devices
  # are unassigned; never inferred from name or location_note.
  belongs_to :branch, optional: true
  has_many :biometric_punch_logs, dependent: :nullify

  before_validation :generate_token, on: :create

  validates :name,  presence: true, uniqueness: { scope: :business_id, case_sensitive: false }
  validates :token, presence: true, uniqueness: true
  validate  :branch_in_same_business
  validate  :branch_active, if: :will_save_change_to_branch_id?

  scope :active,        -> { where(active: true) }
  scope :for_business,  ->(business) { where(business: business) }
  scope :without_branch, -> { where(branch_id: nil) }

  def regenerate_token!
    update!(token: self.class.generate_secure_token)
  end

  def self.generate_secure_token
    SecureRandom.urlsafe_base64(32)
  end

  private

  def branch_in_same_business
    errors.add(:branch, :other_business) if branch && branch.business_id != business_id
  end

  # Only when the branch is (re)assigned: a device whose branch is deactivated
  # later can still be renamed, deactivated or moved to an active branch.
  def branch_active
    errors.add(:branch, :branch_inactive) if branch && !branch.active?
  end

  def generate_token
    self.token = self.class.generate_secure_token
  end
end
