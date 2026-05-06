class Employee < ApplicationRecord
  has_one :user

  enum :status, { active: 0, inactive: 1, on_leave: 2 }

  belongs_to :manager, class_name: "Employee", optional: true
  has_many :subordinates, class_name: "Employee", foreign_key: :manager_id, inverse_of: :manager

  before_validation :normalize_phone_number

  validates :phone_number, presence: true, uniqueness: true
  validates :email, uniqueness: true, allow_nil: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :employee_number, presence: true, uniqueness: true
  validates :full_name, presence: true

  private

  def normalize_phone_number
    return if phone_number.blank?
    digits = phone_number.gsub(/\D/, "")
    self.phone_number = phone_number.start_with?("+") ? "+#{digits}" : digits
  end
end
