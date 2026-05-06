class User < ApplicationRecord
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable

  belongs_to :employee, optional: true

  enum :role, { employee: 0, admin: 1 }

  delegate :phone_number, :email, to: :employee, allow_nil: true

  validates :password, length: { minimum: 6, maximum: 128 }, confirmation: true, if: :password_required?

  attr_writer :login

  def login
    @login || phone_number || email
  end

  private

  def password_required?
    new_record? || changes[:encrypted_password].present?
  end

  def self.find_for_database_authentication(warden_conditions)
    login = warden_conditions[:login].to_s.strip
    return nil if login.blank?

    employee = Employee.find_by(phone_number: login) ||
               Employee.find_by(email: login.downcase)
    employee&.user
  end
end
