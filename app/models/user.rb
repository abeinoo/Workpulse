class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :recoverable, :rememberable

  belongs_to :business
  belongs_to :manager,             class_name: "User", optional: true

  has_many :managed_employees,     class_name: "User", foreign_key: :manager_id, dependent: :nullify
  has_many :user_branches,         dependent: :destroy
  has_many :branches,              through: :user_branches
  has_many :salary_profiles,       dependent: :destroy
  has_one  :active_salary_profile,
           -> { active.order(effective_from: :desc) },
           class_name: "SalaryProfile"
  has_many :shift_assignments,     dependent: :destroy
  has_many :attendance_records,    dependent: :destroy
  has_many :employee_requests,     dependent: :destroy
  has_many :advances,              dependent: :destroy
  has_many :payroll_entries,       dependent: :destroy

  ROLES = %w[super_admin area_manager branch_manager accountant employee].freeze

  enum :role, {
    employee:      "employee",
    branch_manager: "branch_manager",
    area_manager:  "area_manager",
    super_admin:   "super_admin",
    accountant:    "accountant"
  }

  scope :active,        -> { where(active: true) }
  scope :inactive,      -> { where(active: false) }
  scope :staff,         -> { where(role: %w[employee branch_manager area_manager]) }

  normalizes :email,               with: ->(e) { e.blank? ? nil : e.strip.downcase }
  normalizes :phone_number,        with: ->(phone) {
    digits = phone.to_s.gsub(/\D/, "")
    phone.to_s.start_with?("+") ? "+#{digits}" : digits
  }
  normalizes :identity_card_number, with: ->(v) { v.strip.upcase }

  attr_accessor :login

  validates :preferred_locale, inclusion: { in: %w[en ar] }, allow_blank: true
  validates :phone_number,        uniqueness: true, allow_blank: true
  validates :identity_card_number, uniqueness: { case_sensitive: false },
                                   length: { minimum: 5, maximum: 30 },
                                   allow_blank: true
  validates :email, uniqueness: { case_sensitive: false }, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :first_name, :last_name, presence: true
  validates :role, presence: true, inclusion: { in: ROLES }
  validates :business, presence: true
  validates :password, length: { minimum: 6, maximum: 128 }, if: :password_required?
  validates_confirmation_of :password, if: :password_required?
  validate :phone_or_email_present
  validate :manager_must_be_branch_manager
  validate :no_self_management

  def self.find_for_database_authentication(warden_conditions)
    login = warden_conditions[:login].to_s.strip
    if login.include?("@")
      find_by("LOWER(email) = ?", login.downcase)
    else
      find_by(phone_number: login)
    end
  end

  def full_name
    "#{first_name} #{last_name}".strip
  end

  def managed_employee_ids
    managed_employees.pluck(:id)
  end

  private

  def phone_or_email_present
    errors.add(:base, "Phone number or email must be present") if phone_number.blank? && email.blank?
  end

  def password_required?
    password.present? || password_confirmation.present?
  end

  def manager_must_be_branch_manager
    return unless manager_id.present? && manager

    valid_manager_role =
      case role
      when "employee"      then manager.branch_manager? || manager.area_manager?
      when "branch_manager" then manager.area_manager?  || manager.super_admin?
      when "area_manager"  then manager.super_admin?
      else true
      end

    errors.add(:manager, "does not have the required role for this position") unless valid_manager_role
  end

  def no_self_management
    errors.add(:manager, "cannot be yourself") if manager_id.present? && manager_id == id
  end
end
