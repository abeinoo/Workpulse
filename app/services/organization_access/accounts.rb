module OrganizationAccess
  # The Organization & Access account-management interface (decision D1,
  # 2026-10-22; module-boundaries.md §3.2 and §14.2 #7).
  #
  # One users table holds both the account (Organization & Access) and the
  # employee profile (Workforce, column stewardship §3.2). Every write of an
  # ACCOUNT field from outside Organization & Access goes through this module:
  #
  #   build                — a new account row: its business membership and login
  #                          identifiers (employee form, onboarding approval);
  #   stage                — account status / login identifiers submitted with the
  #                          combined employee form, assigned on the record and
  #                          saved with the rest of the form (one transaction);
  #   stage_role           — a requested role change, decided by
  #                          OrganizationAccess::RoleAssignmentRule and staged;
  #   toggle_active!       — the account status toggle;
  #   transfer_ownership!  — the business ownership transfer.
  #
  # Authorization is unchanged and stays where it was: which fields an actor may
  # submit is decided by UserPolicy#permitted_attributes (OA-S1/S3/S5, with
  # OrganizationAccess::PermissionGrants.covers?), which accounts may be toggled /
  # transferred by UserPolicy#toggle_active? / #transfer_ownership?. This module
  # adds the account-level invariants every caller relies on — the same business,
  # only account fields, never the owner's status — and raises instead of
  # writing when one is broken. No audit is written (none was before; adding one
  # is a behaviour change outside D1).
  module Accounts
    # users columns this interface owns (module-boundaries.md §3.2, OA rows).
    STATUS_FIELDS = %w[active].freeze
    LOGIN_FIELDS  = %w[email phone_number].freeze
    FIELDS        = (STATUS_FIELDS + LOGIN_FIELDS).freeze

    # A broken account-level invariant (a caller bug, never a user input error).
    class Refused < ArgumentError; end

    RoleChange = Struct.new(:allowed, keyword_init: true) { def allowed? = allowed }

    module_function

    # A new, unsaved account row in `business_id`, with its login identifiers.
    # The caller assigns its own (non-account) attributes and saves the record.
    def build(business_id:, login: {})
      login = stringify(login)
      refuse!("not a login field: #{(login.keys - LOGIN_FIELDS).join(', ')}") unless (login.keys - LOGIN_FIELDS).empty?
      refuse!("an account needs a business") if business_id.blank?

      User.new(login.merge("business_id" => business_id))
    end

    # Assigns submitted account fields (already permitted by UserPolicy) on the
    # record; the caller's save persists them with the rest of the form.
    def stage(actor:, user:, attributes:)
      attributes = stringify(attributes)
      return user if attributes.empty?

      refuse!("not an account field: #{(attributes.keys - FIELDS).join(', ')}") unless (attributes.keys - FIELDS).empty?
      same_business!(actor, user)
      refuse!("the owner's account status cannot change") if attributes.key?("active") && user.persisted? && user.owner?

      user.assign_attributes(attributes)
      user
    end

    # A requested role change on the (possibly unsaved) record, decided by the
    # role-assignment rule and staged for the caller's save. An unchanged value
    # is a no-op (allowed).
    def stage_role(actor:, user:, role_id:)
      same_business!(actor, user)
      requested_id = role_id.presence&.to_i
      return RoleChange.new(allowed: true) if requested_id == user.permission_role_id

      decision = RoleAssignmentRule.decide(actor: actor, user: user, role_id: requested_id)
      return RoleChange.new(allowed: false) unless decision.allowed?

      user.permission_role = decision.role
      RoleChange.new(allowed: true)
    end

    # Flips the account status. Returns the new status.
    def toggle_active!(actor:, user:)
      same_business!(actor, user)
      refuse!("the owner's account status cannot change") if user.owner?

      user.update!(active: !user.active?)
      user.active?
    end

    # Makes `user` the owner of the actor's business.
    def transfer_ownership!(actor:, user:)
      same_business!(actor, user)
      actor.business.update!(owner: user)
      user
    end

    def same_business!(actor, user)
      refuse!("account outside the actor's business") unless user.business_id.present? && user.business_id == actor.business_id
    end

    def refuse!(message) = raise(Refused, message)

    def stringify(hash) = hash.to_h.transform_keys(&:to_s)

    private_class_method :same_business!, :refuse!, :stringify
  end
end
