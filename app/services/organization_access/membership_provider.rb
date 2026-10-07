module OrganizationAccess
  # Organization & Access contract for branch membership (Pilot 5 — membership
  # contract, M2; module-boundaries.md §12.1 / §4 item 14).
  #
  # Access scopes (EmployeeScope, BranchScope) need to know which branches a
  # user currently belongs to and who currently belongs to given branches.
  # Membership is Workforce data, and Workforce sits downstream, so
  # Organization & Access defines WHAT it needs here and Workforce implements
  # it, registered at boot (config/initializers/organization_access_membership_provider.rb).
  # This module names nothing from Workforce.
  #
  # The contract carries today's membership semantics unchanged (pinned by
  # spec/characterization/organization_access/branch_membership_spec.rb): no
  # business filtering, no authorization decision, the current calendar day.
  #
  # A provider must respond to:
  #   current_branch_ids(user)
  #     — Array of the branch ids the user currently belongs to.
  #   current_member_ids(branch_ids)
  #     — a chainable ActiveRecord::Relation selecting the user ids currently
  #       belonging to any of branch_ids, usable as `WHERE id IN (subquery)`;
  #       never materialized into an Array.
  module MembershipProvider
    OPERATIONS = %i[current_branch_ids current_member_ids].freeze

    # Raised when membership is requested before any provider is registered —
    # access scopes must never silently resolve to "no members".
    class NotRegistered < StandardError; end

    class << self
      def register(provider)
        missing = OPERATIONS.reject { |operation| provider.respond_to?(operation) }
        raise ArgumentError, "#{provider} does not implement #{missing.join(', ')}" if missing.any?

        @provider = provider
      end

      def provider
        @provider || raise(NotRegistered, "No OrganizationAccess::MembershipProvider is registered")
      end

      def current_branch_ids(user)
        provider.current_branch_ids(user)
      end

      def current_member_ids(branch_ids)
        provider.current_member_ids(branch_ids)
      end
    end
  end
end
