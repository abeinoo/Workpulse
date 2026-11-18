module OrganizationAccess
  # Organization & Access contract for what a branch needs from downstream
  # domains when it becomes a sales branch (Warehouse Architecture — PR 3;
  # module-boundaries.md §12.1).
  #
  # Every sales branch has exactly one branch warehouse. Warehouses are owned
  # by Inventory & Purchasing, which sits downstream of Organization &
  # Access, so Organization & Access must not create them. Organization &
  # Access defines WHEN provisioning happens (a sales branch is created, or a
  # branch becomes a sales branch — OrganizationAccess::CreateBranch /
  # OrganizationAccess::UpdateBranch); Inventory & Purchasing implements WHAT
  # is provisioned and registers the implementation at boot
  # (config/initializers/organization_access_branch_provisioning.rb). This
  # module names nothing from Inventory & Purchasing.
  #
  # Called inside the caller's transaction, after the caller has locked
  # business -> branch: whatever the handler writes commits or rolls back with
  # the branch change. The handler does not open its own outer transaction or
  # take a business/branch lock. Authorization stays with the caller
  # (BranchPolicy, manage_branches).
  #
  # A handler must respond to:
  #   provision!(branch:, actor:)
  #     — branch is the persisted, locked sales branch; actor is the user
  #       making the branch change (audit attribution). Idempotent: a branch
  #       already provisioned is left as it is. Raises
  #       OrganizationAccess::BranchProvisioning::Failed (with a translated
  #       message) when provisioning is refused; the caller rolls back.
  module BranchProvisioning
    OPERATIONS = %i[provision!].freeze

    # Raised when a branch needs provisioning before any handler is registered
    # — a sales branch is never committed without it.
    class NotRegistered < StandardError; end

    # Raised by the handler when provisioning is refused.
    class Failed < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No OrganizationAccess::BranchProvisioning handler is registered")
      end

      def provision!(branch:, actor:)
        handler.provision!(branch: branch, actor: actor)
      end
    end
  end
end
