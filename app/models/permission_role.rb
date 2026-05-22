class PermissionRole < ApplicationRecord
  belongs_to :business
  has_many   :users, dependent: :nullify

  PERMISSION_GROUPS = {
    employees:      %w[view_employees manage_employees manage_salary_profiles],
    attendance:     %w[view_attendance manage_attendance manage_devices],
    payroll:        %w[view_payroll manage_payroll finalize_payroll pay_advances],
    adjustments:    %w[manage_adjustments approve_adjustments],
    requests:       %w[view_requests approve_requests],
    shifts:         %w[view_shifts manage_shifts assign_shifts],
    reports:        %w[view_reports export_reports],
    settings:       %w[manage_settings manage_branches],
    obligations:    %w[manage_obligations],
    administration: %w[manage_roles]
  }.freeze

  ALL_PERMISSIONS = PERMISSION_GROUPS.values.flatten.freeze

  before_validation { self.permissions = Array(permissions).reject(&:blank?).uniq }

  validates :name, presence: true,
                   uniqueness: { scope: :business_id, case_sensitive: false },
                   length: { maximum: 80 }
  validates :business, presence: true
  validate  :permissions_are_valid

  scope :ordered, -> { order(:name) }

  def has_permission?(perm)
    permissions.include?(perm.to_s)
  end

  def user_count
    users.count
  end

  def permission_count
    permissions.size
  end

  private

  def permissions_are_valid
    invalid = Array(permissions) - ALL_PERMISSIONS
    errors.add(:permissions, "contains invalid values: #{invalid.join(', ')}") if invalid.any?
  end
end
