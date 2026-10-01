class UserPolicy < ApplicationPolicy
  # ── Attribute tiers for the admin employee form (OA-S1/S3/S5) ─────────────
  # Self-service profile data any editor of the record may change.
  PROFILE_ATTRIBUTES = %i[
    first_name last_name phone_number email date_of_birth address
    identity_card_number identity_card_expiry_date
    emergency_contact_name emergency_contact_phone emergency_contact_relationship
    profile_photo national_id_front national_id_back
    remove_profile_photo remove_national_id_front remove_national_id_back
  ].freeze
  # Employment and protected attributes: managed by others, never self-edited.
  EMPLOYMENT_ATTRIBUTES = %i[
    employee_code job_title department_id hire_date employment_type
    allow_mobile_attendance allow_biometric_attendance requires_shift_assignment admin_notes
  ].freeze
  # Account status and access: never on self, never on the owner.
  ACCOUNT_ATTRIBUTES = [ :active, { assigned_warehouse_ids: [] } ].freeze
  # Role: requires manage_roles; the concrete change is further checked by
  # PermissionGrants.can_change_role? in the controller.
  ROLE_ATTRIBUTES = %i[permission_role_id].freeze
  # The owner's login identifiers are changed only by the owner.
  LOGIN_ATTRIBUTES = %i[email phone_number].freeze

  def index?          = can?(:view_employees)
  # Opening a profile respects the same scope as the employee list (Scope
  # below); anyone the actor may manage is also visible to them.
  def show?           = own_record? || (can?(:view_employees) && visible_employee?)
  def create?         = can?(:manage_employees)
  # Editing another employee requires them to be inside the actor's
  # employee-management scope (OA-S8).
  def update?         = own_record? || (can?(:manage_employees) && (record.new_record? || in_management_scope?))
  # Taking control of an account (OA-S4/S5/S8 + privilege hierarchy): the
  # target must be in scope and must not hold administrative authority beyond
  # the actor's. The owner is covered only by the owner.
  def destroy?        = controls_account?
  def reset_password? = controls_account?
  def transfer_ownership? = user.owner? && record != user
  def toggle_active?  = controls_account? && !own_record?
  # Issuing an account-claim invitation link (OA-S6).
  def invite?         = controls_account? && record.persisted? &&
                        record.active? && record.encrypted_password.blank?

  def permitted_attributes
    attributes = PROFILE_ATTRIBUTES.dup
    managing_other = can?(:manage_employees) && !own_record?

    attributes += EMPLOYMENT_ATTRIBUTES if managing_other || user.owner?
    attributes += ACCOUNT_ATTRIBUTES    if managing_other && controls_account?
    attributes += ROLE_ATTRIBUTES       if can?(:manage_roles) && !own_record? && controls_account?
    # Changing the login identifiers of a user the actor does not cover (the
    # owner, or a higher-privileged administrator) would hand over the account.
    attributes -= LOGIN_ATTRIBUTES      if !own_record? && record.persisted? && !PermissionGrants.covers?(user, record)
    attributes
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.can?(:view_employees)
        configured  = user.scope_for(:view_employees)
        base        = scope.where(business: user.business)
        managed_ids = EmployeeScope.new(user).relation.select(:id)
        if configured
          filter_by_data_scope(base, configured, user_id_column: :id)
        else
          base.where(id: user.id).or(base.where(id: managed_ids))
        end
      else
        scope.where(id: user.id)
      end
    end
  end

  private

  def own_record?
    record == user
  end

  # OA-S8: the target must be an employee the actor may manage — resolved by
  # EmployeeScope from the actor's configured scope (manage_employees first,
  # then view_employees), else the management hierarchy (branches/areas they
  # manage). Business-wide scope covers every user of the business. Always
  # within the actor's business. The owner manages everyone.
  def in_management_scope?
    return @in_management_scope if defined?(@in_management_scope)

    @in_management_scope = user.owner? ||
      EmployeeScope.new(user).for_permissions(:manage_employees, :view_employees).exists?(record.id)
  end

  def visible_employee?
    return true if user.owner?
    return false unless record.is_a?(User) && record.persisted?

    Scope.new(user, User).resolve.exists?(record.id) ||
      (can?(:manage_employees) && in_management_scope?)
  end

  def controls_account?
    return false unless can?(:manage_employees)
    return true if record.new_record?

    in_management_scope? && PermissionGrants.covers?(user, record)
  end
end
