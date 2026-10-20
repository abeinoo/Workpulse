module OrganizationAccess
  # Organization & Access contract for the POS terminals edited on the Branch
  # form (Pilot 12 — POS terminals write boundary; module-boundaries.md §12.1 /
  # §14.2 #8).
  #
  # POS terminals are owned by Finance & Sales, which sits downstream of
  # Organization & Access, so Organization & Access must not write them.
  # Organization & Access defines WHAT the branch form needs here; Finance &
  # Sales implements it and registers the implementation at boot
  # (config/initializers/branch_terminal_settings.rb). This module names nothing
  # from Finance & Sales.
  #
  # The handler only stages the changes on the branch: they are validated and
  # persisted by the branch's own save, in the same transaction, so a failing
  # terminal leaves the branch and every terminal unchanged, and terminal errors
  # are reported on the branch. Authorization stays with the caller
  # (BranchPolicy, manage_branches).
  #
  # A handler must respond to:
  #   assign(branch:, rows:)
  #     — rows are the form's terminal rows (an Array, or a Hash keyed by row
  #       index) with the keys id, terminal_id, label, active and _destroy. A
  #       row with an id updates (or, with a truthy _destroy, removes) that
  #       terminal of this branch; a row without an id adds one; a row whose
  #       terminal_id is blank or missing is ignored unless it removes an
  #       existing terminal; an id that is not one of this branch's terminals
  #       raises ActiveRecord::RecordNotFound.
  module BranchTerminalSettings
    OPERATIONS = %i[assign].freeze

    # Raised when terminal changes are requested before any handler is
    # registered — submitted terminals are never silently dropped.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No OrganizationAccess::BranchTerminalSettings handler is registered")
      end

      def assign(branch:, rows:)
        handler.assign(branch: branch, rows: rows)
      end
    end
  end
end
