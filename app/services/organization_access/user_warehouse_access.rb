module OrganizationAccess
  # Organization & Access contract for the warehouse access edited on the
  # employee form (Batch W — warehouse access write boundary;
  # module-boundaries.md §12.1 / §14.2 #10).
  #
  # Warehouse assignments (WarehouseAssignment) are owned by Inventory &
  # Purchasing, which sits downstream of Organization & Access, so Organization
  # & Access must not write them. Organization & Access defines WHAT the
  # employee form needs here; Inventory & Purchasing implements it and registers
  # the implementation at boot (config/initializers/user_warehouse_access.rb).
  # This module names nothing from Inventory & Purchasing.
  #
  # The handler applies the submitted set with today's timing, unchanged
  # (pinned by spec/characterization/organization_access/user_warehouse_access_spec.rb):
  # for a persisted user the assignments are replaced immediately — not in the
  # user's later save, so a form that then fails validation keeps them — and
  # for a new user they are saved with it. Authorization stays with the caller
  # (UserPolicy#permitted_attributes, the account tier).
  #
  # A handler must respond to:
  #   assign(user:, warehouse_ids:, actor:)
  #     — actor is the user making the change (required; never implicit): every
  #       assignment created or removed is audited in that actor's name, in
  #       the same transaction as the change (Warehouse Architecture PR 5, D7).
  #     — warehouse_ids is the form's submitted list (blank values ignored); an
  #       empty list removes every assignment the actor may manage. An unknown
  #       id raises ActiveRecord::RecordNotFound; another business's warehouse
  #       raises ActiveRecord::RecordInvalid.
  #     — the actor must hold manage_warehouse_access, may not change their own
  #       access or that of a user they do not control, and may only add or
  #       remove warehouses they can reach themselves (active ones, for a new
  #       grant); assignments outside the actor's reach are left as they are.
  #       Any refusal raises Refused and changes nothing.
  #   revoke_branch_warehouse(user_id:, branch_id:, actor:)
  #     — the branch-manager lifecycle (OrganizationAccess::BranchManagerLifecycle):
  #       removes the user's EXPLICIT assignment to the given branch's own
  #       (kind "branch") warehouse, if there is one, audited in the actor's
  #       name in the caller's transaction. Nothing else is touched — no other
  #       assignment, no warehouse, no inventory record. Returns
  #       { user_id:, warehouse_id: } for a removed assignment, or nil.
  module UserWarehouseAccess
    OPERATIONS = %i[assign revoke_branch_warehouse].freeze

    # Raised when warehouse access is changed before any handler is registered —
    # submitted access is never silently dropped.
    class NotRegistered < StandardError; end

    # Raised by the handler when the actor may not make the requested change.
    # reason: :not_permitted, :own_access, :not_in_scope, :outside_reach,
    # :inactive_warehouse.
    class Refused < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("warehouse access change refused: #{reason}")
      end
    end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No OrganizationAccess::UserWarehouseAccess handler is registered")
      end

      def assign(user:, warehouse_ids:, actor:)
        handler.assign(user: user, warehouse_ids: warehouse_ids, actor: actor)
      end

      def revoke_branch_warehouse(user_id:, branch_id:, actor:)
        handler.revoke_branch_warehouse(user_id: user_id, branch_id: branch_id, actor: actor)
      end
    end
  end
end
