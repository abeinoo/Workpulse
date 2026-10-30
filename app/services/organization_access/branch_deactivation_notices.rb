module OrganizationAccess
  # Organization & Access contract for what another domain still records at a
  # branch about to be deactivated (BUG-029), shown in the deactivation dialog.
  #
  # Deactivation never moves, closes or zeroes anything another domain records
  # at the branch (towels, open transfers, …); those records stay attached to it.
  # The dialog warns about them so they are not lost from view. The domains that
  # own the data sit downstream of Organization & Access, so Organization &
  # Access must not read them: it defines WHAT the dialog needs here, the owning
  # domain implements it and registers the implementation at boot
  # (config/initializers/branch_deactivation_notices.rb). This module names
  # nothing from any other domain.
  #
  # Notices are informational only: they never prevent deactivation and the
  # provider must not write anything.
  #
  # A provider must respond to:
  #   notices_for(branch:)
  #     — an Array of Notice (possibly empty) for the branch. Every string is
  #       already translated; every Line value is a Numeric. Called once per
  #       render of the branch page while the branch is active.
  module BranchDeactivationNotices
    OPERATIONS = %i[notices_for].freeze

    Notice = Struct.new(:title, :summary, :lines, keyword_init: true)
    Line   = Struct.new(:label, :value, keyword_init: true)

    # Raised when notices are requested before any provider is registered —
    # what is still recorded at a branch is never silently hidden.
    class NotRegistered < StandardError; end

    class << self
      def register(provider)
        missing = OPERATIONS.reject { |operation| provider.respond_to?(operation) }
        raise ArgumentError, "#{provider} does not implement #{missing.join(', ')}" if missing.any?

        @provider = provider
      end

      def provider
        @provider || raise(NotRegistered, "No OrganizationAccess::BranchDeactivationNotices provider is registered")
      end

      def notices_for(branch:)
        notices = provider.notices_for(branch: branch)
        return notices if notices.is_a?(Array) && notices.all? { |notice| valid_notice?(notice) }

        raise ArgumentError, "#{provider}.notices_for returned #{notices.inspect}, expected an Array of #{Notice}"
      end

      private

      def valid_notice?(notice)
        notice.is_a?(Notice) && notice.title.is_a?(String) && notice.lines.is_a?(Array) &&
          notice.lines.all? { |line| line.is_a?(Line) && line.label.is_a?(String) && line.value.is_a?(Numeric) }
      end
    end
  end
end
