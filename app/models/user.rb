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
  belongs_to :permission_role,  optional: true
  # Additive: first-class department link (backfilled from the legacy string
  # column, which is kept for backward compatibility). New features use this.
  belongs_to :department,       optional: true

  has_many :warehouse_assignments, dependent: :destroy
  has_many :assigned_warehouses,   through: :warehouse_assignments, source: :warehouse
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
  has_one  :employee_insurance_profile, dependent: :destroy

  # Performance evaluation (new module). employee_id is the subject of reviews
  # and observations; reviewer_id / observed_by_id are tracked separately.
  has_many :performance_reviews,      dependent: :destroy, foreign_key: :employee_id
  has_many :performance_observations, dependent: :destroy, foreign_key: :employee_id

  # Custody (عهد) — any employee may hold one or more custody accounts. Restricted
  # on delete so a user with custody history can't be silently removed.
  has_many :custody_accounts, dependent: :restrict_with_error

  EMPLOYMENT_TYPES = %w[full_time part_time contract intern].freeze

  enum :employment_type, {
    full_time: "full_time",
    part_time: "part_time",
    contract:  "contract",
    intern:    "intern"
  }, prefix: :employment, validate: { allow_nil: true }

  scope :active,   -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :by_department, ->(dept) { where(department: dept) }

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


  # Auto-assign a numeric employee_code on creation when none was provided.
  # Runs inside the INSERT transaction (before_create) so the advisory lock it
  # takes is held until COMMIT — see #assign_employee_code.
  before_create :assign_employee_code, if: :generate_employee_code?

  # Arbitrary, app-wide namespace key for the employee_code advisory lock, so it
  # never clashes with locks taken elsewhere. Paired with business_id below.
  EMPLOYEE_CODE_LOCK_NAMESPACE = 0x4543

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

  PROFILE_COMPLETION_FIELDS = [
    :phone_number, :email, :job_title, :department,
    :hire_date, :employment_type,
    :emergency_contact_name, :emergency_contact_phone,
    :identity_card_number
  ].freeze

  def profile_completion_percentage
    filled = PROFILE_COMPLETION_FIELDS.count { |f| send(f).present? }
    photo_filled = profile_photo.attached? ? 1 : 0
    total = PROFILE_COMPLETION_FIELDS.size + 1
    ((filled + photo_filled) * 100.0 / total).round
  end

  def profile_completion_grade
    pct = profile_completion_percentage
    if pct >= 90 then :complete
    elsif pct >= 60 then :partial
    else :incomplete
    end
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

  # Single source of truth for "which ShiftAssignment applies to this user on
  # this date" — see Shifts::AssignmentResolver for why this can't simply be
  # `shift_assignments.current.first` once a user may hold a concurrent
  # temporary_coverage assignment alongside their regular one.
  def effective_shift_assignment_on(date = Date.current, time: nil)
    Shifts::AssignmentResolver.for(user: self, date: date, time: time)
  end

  # The branch this user is effectively working at on `date` — a
  # temporary_coverage assignment (if active) wins over the regular one,
  # never mutating either. nil when the user has no active assignment at all
  # (branchless/non-attendance-enabled employees).
  def effective_branch_on(date = Date.current, time: nil)
    effective_shift_assignment_on(date, time: time)&.branch
  end

  # Returns true when this user should see the management sidebar layout.
  # Owners always get the management sidebar. All other users are routed by
  # the workspace field on their PermissionRole — "management" → grouped
  # management sidebar; "employee" → flat personal sidebar. Adding new
  # permissions never requires touching this method.
  def management_sidebar?
    return true if owner?

    permission_role&.management_workspace? || false
  end

  def can?(permission)
    return true if owner?
    return false unless permission_role

    permission_role.has_permission?(permission)
  end

  # Warehouse-scoped inventory access.
  #
  # Returns nil when the user may see EVERY warehouse (owners, and anyone with no
  # explicit warehouse assignments — accountants, admins), or an array of the
  # warehouse ids they're restricted to. Assigning warehouses to a user narrows
  # their inventory visibility to exactly those.
  def inventory_warehouse_ids
    return nil if owner?
    ids = warehouse_assignments.pluck(:warehouse_id)
    ids.empty? ? nil : ids
  end

  def warehouse_scoped?
    !inventory_warehouse_ids.nil?
  end

  # Returns the explicitly configured data scope for a permission, or nil if unset.
  # nil signals "no override" — the caller falls back to the relationship hierarchy.
  # Owners are exempted: they always get business_wide regardless.
  def scope_for(permission)
    return "business" if owner?

    permission_role&.scope_for(permission)
  end

  private

  def generate_employee_code?
    employee_code.blank? && business_id.present?
  end

  # Race-safe employee_code generation.
  #
  # A transaction-level Postgres advisory lock (pg_advisory_xact_lock), keyed by
  # business, serializes concurrent creations within the same business: a second
  # creation blocks here until the first COMMITs, then reads the now-updated
  # maximum — so two employees created at the same time can never receive the
  # same code. The lock auto-releases at COMMIT/ROLLBACK. The per-business unique
  # index on lower(employee_code) is the final database-level backstop.
  def assign_employee_code
    self.class.connection.execute(
      "SELECT pg_advisory_xact_lock(#{EMPLOYEE_CODE_LOCK_NAMESPACE}, #{business_id.to_i})"
    )
    self.employee_code = business.next_employee_code.to_s
  end

  def phone_or_email_present
    errors.add(:base, "Phone number or email must be present") if phone_number.blank? && email.blank?
  end

  def password_required?
    password.present? || password_confirmation.present?
  end
end
