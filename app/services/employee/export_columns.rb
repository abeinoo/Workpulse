module Employee
  # Workforce contract for the Employee Data Export (admin/users#export,
  # Employee::Export::Exporter): the salary columns of the file are
  # Attendance & Payroll's — their visibility rule (SalaryProfilePolicy, never
  # because the employee row itself is exportable, SEC-M2-5), the profile in
  # force on the business day and the per-employee salary-view audit. Workforce
  # asks for the values and writes what it is given; it never reads salary data.
  # Attendance & Payroll implements the contract and registers it at boot
  # (config/initializers/employee_export_columns.rb). This module names nothing
  # from Attendance & Payroll (module-boundaries.md §12.1).
  #
  # A handler must respond to:
  #   salary_values(viewer:, employee_ids:)
  #     — { employee_id => SalaryValues } for the employees among
  #       `employee_ids` whose current salary `viewer` may see; an employee the
  #       viewer may not see, or with no salary in force, is absent. Records
  #       one salary view per employee returned (source employee_export). One
  #       call per batch of employees, so it must not query per employee.
  module ExportColumns
    OPERATIONS = %i[salary_values].freeze

    # basic_salary: BigDecimal; salary_type: display label; currency: ISO code.
    SalaryValues = Struct.new(:basic_salary, :salary_type, :currency, keyword_init: true)

    # Raised when an export runs before any handler is registered.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No Employee::ExportColumns handler is registered")
      end

      def salary_values(viewer:, employee_ids:)
        values = handler.salary_values(viewer: viewer, employee_ids: employee_ids)
        asked  = employee_ids.to_set
        unless values.is_a?(Hash) && values.all? { |id, v| asked.include?(id) && v.is_a?(SalaryValues) }
          raise ArgumentError, "#{handler}.salary_values returned an unexpected shape"
        end

        values
      end
    end
  end
end
