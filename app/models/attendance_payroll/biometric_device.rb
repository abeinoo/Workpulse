class BiometricDevice < ApplicationRecord
  belongs_to :business
  has_many :biometric_punch_logs, dependent: :nullify

  before_validation :generate_token, on: :create

  validates :name,  presence: true, uniqueness: { scope: :business_id, case_sensitive: false }
  validates :token, presence: true, uniqueness: true

  scope :active,        -> { where(active: true) }
  scope :for_business,  ->(business) { where(business: business) }

  def regenerate_token!
    update!(token: self.class.generate_secure_token)
  end

  def self.generate_secure_token
    SecureRandom.urlsafe_base64(32)
  end

  private

  def generate_token
    self.token = self.class.generate_secure_token
  end
end
