module OrganizationAccess
  # Organization & Access contract for which warehouses a user may reach
  # (Warehouse Architecture PR 5 — decision D1; module-boundaries.md §12.1).
  #
  # User#inventory_warehouse_ids (Organization & Access) answers "which
  # warehouses may this user reach?" for every inventory policy, scope and
  # page. The answer depends on warehouses, assignments and branch warehouses —
  # Inventory & Purchasing data downstream of Organization & Access — so
  # Organization & Access defines WHAT it needs here and Inventory & Purchasing
  # implements it, registered at boot
  # (config/initializers/organization_access_warehouse_access_provider.rb).
  # This module names nothing from Inventory & Purchasing.
  #
  # NOT YET IN THE LIVE PATH: User#inventory_warehouse_ids still applies
  # today's rule (no assignment = every warehouse). Routing it through this
  # contract switches inventory authorization to fail-closed and is a separate,
  # explicitly approved activation step — nothing calls warehouse_ids_for in
  # application code until then (pinned by
  # spec/architecture/organization_access_outbound_boundary_spec.rb).
  #
  # A provider must respond to:
  #   warehouse_ids_for(user)
  #     — nil when the user may reach every warehouse of their own business;
  #       otherwise an Array (possibly empty — fail-closed) of warehouse ids of
  #       their own business. The same nil / Array convention every caller of
  #       User#inventory_warehouse_ids already handles.
  module WarehouseAccessProvider
    OPERATIONS = %i[warehouse_ids_for].freeze

    # Raised when access is requested before any provider is registered —
    # warehouse access must never silently resolve to "everything".
    class NotRegistered < StandardError; end

    class << self
      def register(provider)
        missing = OPERATIONS.reject { |operation| provider.respond_to?(operation) }
        raise ArgumentError, "#{provider} does not implement #{missing.join(', ')}" if missing.any?

        @provider = provider
      end

      def provider
        @provider || raise(NotRegistered, "No OrganizationAccess::WarehouseAccessProvider is registered")
      end

      def warehouse_ids_for(user)
        provider.warehouse_ids_for(user)
      end
    end
  end
end
