module Employee
  # Workforce UI-composition contract for the employee page
  # (module-boundaries.md §12.1: "AP contributes the salary panel
  # (infrastructure-level view composition), WF does not read AP"; SAL).
  #
  # The employee page (Admin::UsersController#show, app/views/admin/users/show.html.erb)
  # is Workforce's; the salary shown on it — its visibility rule
  # (SalaryProfilePolicy), the current profile, the salary-view audit and the card
  # markup — is Attendance & Payroll's. Workforce asks for the panel and renders
  # what it is given; it never reads salary data. Attendance & Payroll implements
  # the contract and registers it at boot (config/initializers/employee_profile_panels.rb).
  # This module names nothing from Attendance & Payroll.
  #
  # A handler must respond to:
  #   salary_panel(viewer:, employee:)
  #     — the salary card for `employee` as `viewer` may see it: a Panel (a
  #       partial path and its locals) or nil when the viewer may neither see nor
  #       manage that salary. Called once per page render; it may record the
  #       salary view (an audit row) exactly as the page always did.
  module ProfilePanels
    OPERATIONS = %i[salary_panel].freeze

    Panel = Struct.new(:partial, :locals, keyword_init: true)

    # Raised when the page is rendered before any handler is registered.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No Employee::ProfilePanels handler is registered")
      end

      def salary_panel(viewer:, employee:)
        panel = handler.salary_panel(viewer: viewer, employee: employee)
        return panel if panel.nil?
        return panel if panel.is_a?(Panel) && panel.partial.is_a?(String) && panel.locals.is_a?(Hash)

        raise ArgumentError, "#{handler}.salary_panel returned #{panel.inspect}, expected a #{Panel} or nil"
      end
    end
  end
end
