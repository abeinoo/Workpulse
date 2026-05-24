class User < ApplicationRecord
  include Attachable

  devise :database_authenticatable, :registerable, :recoverable, :rememberable

  has_one_attached :avatar
  has_one_attached :id_card
  has_one_attached :profile_photo
  has_one_attached :national_id_front
  has_one_attached :national_id_back

  validates_attachment :avatar,
    content_types: Attachable::IMAGE_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_MAX_SIZE

  validates_attachment :id_card,
    content_types: Attachable::DOCUMENT_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_DOCUMENT_SIZE

  validates_attachment :profile_photo,
    content_types: Attachable::IMAGE_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_MAX_SIZE

  validates_attachment :national_id_front,
    content_types: Attachable::DOCUMENT_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_DOCUMENT_SIZE

  validates_attachment :national_id_back,
    content_types: Attachable::DOCUMENT_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_DOCUMENT_SIZE

  belongs_to :business
  belongs_to :manager,          class_name: "User", optional: true
  belongs_to :permission_role,  optional: true

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
  has_many :employee_obligations,  dependent: :destroy, foreign_key: :user_id

  scope :active,   -> { where(active: true) }
  scope :inactive, -> { where(active: false) }

  # Thin delegate to EmployeeScope — kept for backward compatibility with existing
  # callers. New code should use EmployeeScope.new(manager).relation directly.
  def self.managed_by(manager)
    EmployeeScope.new(manager).relation
  end

  normalizes :email,               with: ->(e) { e.blank? ? nil : e.strip.downcase }
  normalizes :phone_number,        with: ->(phone) {
    digits = phone.to_s.gsub(/\D/, "")
    phone.to_s.start_with?("+") ? "+#{digits}" : digits
  }
  normalizes :identity_card_number,     with: ->(v) { v.strip.upcase }
  normalizes :employee_code,            with: ->(v) { v.blank? ? nil : v.strip }
  normalizes :emergency_contact_phone,  with: ->(phone) {
    next nil if phone.blank?
    digits = phone.to_s.gsub(/\D/, "")
    phone.to_s.start_with?("+") ? "+#{digits}" : digits
  }

  attr_accessor :login

  validates :preferred_locale, inclusion: { in: %w[en ar] }, allow_blank: true
  validates :employee_code,            uniqueness: { scope: :business_id, case_sensitive: false },
                                       allow_blank: true
  validates :phone_number,             uniqueness: true, allow_blank: true
  validates :emergency_contact_phone,  length: { minimum: 5, maximum: 20 }, allow_blank: true
  validates :identity_card_number, uniqueness: { case_sensitive: false },
                                   length: { minimum: 5, maximum: 30 },
                                   allow_blank: true
  validates :email, uniqueness: { case_sensitive: false }, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :first_name, :last_name, presence: true
  validates :business, presence: true
  validates :password, length: { minimum: 6, maximum: 128 }, if: :password_required?
  validates_confirmation_of :password, if: :password_required?
  validate :phone_or_email_present
  validate :validate_manager_in_same_business
  validate :no_self_management

  def self.find_for_database_authentication(warden_conditions)
    login = warden_conditions[:login].to_s.strip
    if login.include?("@")
      find_by("LOWER(email) = ?", login.downcase)
    else
      find_by(phone_number: login)
    end
  end

  def active_for_authentication?
    super && active?
  end

  def inactive_message
    active? ? super : :inactive
  end

  def full_name
    "#{first_name} #{last_name}".strip
  end

  def managed_employee_ids
    managed_employees.pluck(:id)
  end

  def owner?
    business.owner_id == id
  end

  def manages_area?
    Branch.where(area_manager_id: id).exists?
  end

  def manages_branch?
    Branch.where(branch_manager_id: id).exists?
  end

  def managed_branch_ids
    Branch.where(branch_manager_id: id).pluck(:id)
  end

  def area_managed_branch_ids
    Branch.where(area_manager_id: id).pluck(:id)
  end

  def management_access?
    owner? || manages_area? || manages_branch? || managed_employees.exists? ||
      can?(:view_attendance) || can?(:view_payroll) || can?(:approve_requests) ||
      can?(:assign_shifts) || can?(:view_employees) || can?(:manage_employees)
  end

  def can?(permission)
    return true if owner?
    return false unless permission_role

    permission_role.has_permission?(permission)
  end

  # Returns the explicitly configured data scope for a permission, or nil if unset.
  # nil signals "no override" — the caller falls back to the relationship hierarchy.
  # Owners are exempted: they always get business_wide regardless.
  def scope_for(permission)
    return "business_wide" if owner?

    permission_role&.scope_for(permission)
  end

  private

  def phone_or_email_present
    errors.add(:base, "Phone number or email must be present") if phone_number.blank? && email.blank?
  end

  def password_required?
    password.present? || password_confirmation.present?
  end

  def validate_manager_in_same_business
    return unless manager_id.present? && manager
    errors.add(:manager, "must belong to the same business") unless manager.business_id == business_id
  end

  def no_self_management
    errors.add(:manager, "cannot be yourself") if manager_id.present? && manager_id == id
  end
end
