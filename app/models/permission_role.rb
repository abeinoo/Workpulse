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

  # Permissions where "which employees?" matters — these support data scopes.
  # Global-operation permissions (settings, reports, admin) have no scope.
  SCOPABLE_PERMISSIONS = (
    PERMISSION_GROUPS.slice(:employees, :attendance, :payroll, :adjustments, :requests, :shifts)
                     .values.flatten - %w[finalize_payroll approve_adjustments manage_devices manage_shifts]
  ).freeze

  SCOPE_OPTIONS = %w[self_only managed_employees_only branch_only business_wide].freeze

  # Permissions that require other permissions to be meaningful.
  # Granting a permission without its dependencies creates hidden authorization gaps
  # (e.g. manage_attendance without view_attendance means the user can edit but
  # can't see what they're editing). Keys are the "action" permission; values are
  # the required "view" prerequisites.
  PERMISSION_DEPENDENCIES = {
    "manage_attendance"      => %w[view_attendance],
    "manage_employees"       => %w[view_employees],
    "manage_salary_profiles" => %w[view_employees],
    "manage_payroll"         => %w[view_payroll],
    "finalize_payroll"       => %w[view_payroll],
    "pay_advances"           => %w[view_requests],
    "manage_adjustments"     => %w[view_payroll],
    "approve_adjustments"    => %w[view_payroll],
    "approve_requests"       => %w[view_requests],
    "assign_shifts"          => %w[view_shifts],
    "manage_obligations"     => %w[view_employees]
  }.freeze

  # Reverse index: given a permission, which permissions depend on it?
  PERMISSION_DEPENDENTS = PERMISSION_DEPENDENCIES
    .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(perm, deps), index|
      deps.each { |dep| index[dep] << perm }
    end.freeze

  before_validation do
    self.permissions      = Array(permissions).reject(&:blank?).uniq
    self.permission_scopes = (permission_scopes || {}).select { |k, _| has_permission?(k) }
  end

  validates :name, presence: true,
                   uniqueness: { scope: :business_id, case_sensitive: false },
                   length: { maximum: 80 }
  validates :business, presence: true
  validate  :permissions_are_valid
  validate  :scopes_are_valid
  validate  :dependencies_satisfied

  scope :ordered, -> { order(:name) }

  def has_permission?(perm)
    permissions.include?(perm.to_s)
  end

  # Returns the explicitly configured scope for a permission, or nil if none is set.
  # nil means "no override — fall back to the caller's hierarchy-based default."
  # This is intentionally not defaulted to business_wide: callers must handle nil
  # explicitly so that unconfigured permissions never silently grant broader access
  # than intended.
  # Returns the full set of permissions that must accompany `permission`.
  def required_permissions_for(permission)
    PERMISSION_DEPENDENCIES.fetch(permission.to_s, [])
  end

  def scope_for(permission)
    (permission_scopes || {})[permission.to_s].presence
  end

  def user_count
    users.size
  end

  def permission_count
    permissions.size
  end

  private

  def permissions_are_valid
    invalid = Array(permissions) - ALL_PERMISSIONS
    errors.add(:permissions, "contains invalid values: #{invalid.join(', ')}") if invalid.any?
  end

  def dependencies_satisfied
    Array(permissions).each do |perm|
      missing = PERMISSION_DEPENDENCIES.fetch(perm, []) - permissions
      missing.each do |dep|
        errors.add(
          :permissions,
          "'#{perm}' requires '#{dep}' — please enable '#{dep}' as well"
        )
      end
    end
  end

  def scopes_are_valid
    return unless permission_scopes.is_a?(Hash)

    permission_scopes.each do |perm, scope_val|
      next if scope_val.blank?
      unless SCOPE_OPTIONS.include?(scope_val.to_s)
        errors.add(:permission_scopes, "invalid scope '#{scope_val}' for #{perm}")
      end
    end
  end
end
