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
  #   assign(user:, warehouse_ids:)
  #     — warehouse_ids is the form's submitted list (blank values ignored); an
  #       empty list removes every assignment. An unknown id raises
  #       ActiveRecord::RecordNotFound; another business's warehouse raises
  #       ActiveRecord::RecordInvalid.
  module UserWarehouseAccess
    OPERATIONS = %i[assign].freeze

    # Raised when warehouse access is changed before any handler is registered —
    # submitted access is never silently dropped.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No OrganizationAccess::UserWarehouseAccess handler is registered")
      end

      def assign(user:, warehouse_ids:)
        handler.assign(user: user, warehouse_ids: warehouse_ids)
      end
    end
  end
end
