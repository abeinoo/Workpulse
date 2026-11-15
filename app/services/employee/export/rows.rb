module Employee
  module Export
    # The value rows of an Employee Data Export: one array per employee, in the
    # given employee order, with one value per field (String, Date, BigDecimal or
    # nil — nil for a missing value and for data the viewer may not see).
    #
    # Employees are read in batches of BATCH_SIZE. Each batch costs one query
    # for the employees and, only when a selected field needs it, one each for
    # departments, current branches, their managers, insurance profiles and
    # salaries — never one per employee.
    class Rows
      include Enumerable

      BATCH_SIZE = 1000

      BRANCH_FIELDS     = %w[branch direct_manager].freeze
      SALARY_FIELDS     = %w[basic_salary salary_type salary_currency].freeze
      INSURANCE_FIELDS  = %w[social_insurance_status social_insurance_number social_insurance_start_date
                             social_insurance_end_date social_insurance_employee_contribution
                             social_insurance_employer_contribution].freeze

      # Rows with a selected salary / insurance column left empty (no value in
      # force, or not visible to the viewer) — counts only, for the audit entry.
      attr_reader :rows_without_salary, :rows_without_insurance

      def initialize(viewer:, fields:, employee_ids:, batch_size: BATCH_SIZE)
        @viewer       = viewer
        @fields       = fields
        @keys         = fields.map(&:key)
        @employee_ids = employee_ids
        @batch_size   = batch_size
        @rows_without_salary    = 0
        @rows_without_insurance = 0
      end

      def each
        return enum_for(:each) unless block_given?

        @employee_ids.each_slice(@batch_size) do |ids|
          batch = load_batch(ids)
          ids.each do |id|
            employee = batch[:employees][id]
            next if employee.nil?

            count_empty(id, batch)
            yield @keys.map { |key| value(key, employee, batch) }
          end
        end
      end

      private

      def needs?(keys) = @keys.intersect?(keys)

      def business_id = @viewer.business_id

      def load_batch(ids)
        employees = User.where(business_id: business_id, id: ids)
        employees = employees.includes(:department) if needs?(%w[department])
        branches  = needs?(BRANCH_FIELDS) ? branches_for(ids) : {}

        {
          employees: employees.index_by(&:id),
          branches:  branches,
          managers:  needs?(%w[direct_manager]) ? manager_names(branches) : {},
          insurance: needs?(INSURANCE_FIELDS) ? insurance_for(ids) : {},
          salary:    needs?(SALARY_FIELDS) ? Employee::ExportColumns.salary_values(viewer: @viewer, employee_ids: ids) : {}
        }
      end

      # { employee_id => [[branch name, manager id], ...] } — the branches the
      # employee is assigned to today (BranchMembership's rule), by name.
      # The direct manager of a branch is its branch manager; for the branch
      # manager themselves, the area manager.
      def branches_for(ids)
        ShiftAssignment.current.where(user_id: ids).joins(:branch)
                       .where(branches: { business_id: business_id })
                       .distinct.order("branches.name")
                       .pluck(:user_id, "branches.name", "branches.branch_manager_id", "branches.area_manager_id")
                       .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(user_id, name, branch_manager_id, area_manager_id), map|
                         manager_id = [ branch_manager_id, area_manager_id ].compact.find { _1 != user_id }
                         map[user_id] << [ name, manager_id ]
                       end
      end

      def manager_names(branches)
        ids = branches.values.flatten(1).filter_map(&:last).uniq
        return {} if ids.empty?

        User.where(business_id: business_id, id: ids).pluck(:id, :first_name, :last_name)
            .to_h { |id, first, last| [ id, "#{first} #{last}".strip ] }
      end

      def insurance_for(ids)
        EmployeeInsuranceProfilePolicy::Scope.new(@viewer, EmployeeInsuranceProfile).resolve
                                             .where(user_id: ids).index_by(&:user_id)
      end

      def count_empty(id, batch)
        @rows_without_salary    += 1 if needs?(SALARY_FIELDS) && !batch[:salary].key?(id)
        @rows_without_insurance += 1 if needs?(INSURANCE_FIELDS) && !batch[:insurance].key?(id)
      end

      def joined(values) = values.uniq.presence&.join("; ")

      def value(key, employee, batch)
        salary    = batch[:salary][employee.id]
        insurance = batch[:insurance][employee.id]
        branches  = batch[:branches].fetch(employee.id, [])

        case key
        when "full_name"                   then employee.full_name.presence
        when "national_id"                 then employee.identity_card_number.presence
        when "date_of_birth"               then employee.date_of_birth
        when "address"                     then employee.address.presence
        when "phone_number"                then employee.phone_number.presence
        when "email"                       then employee.email.presence
        when "employee_code"               then employee.employee_code.presence
        when "branch"                      then joined(branches.map(&:first))
        when "job_title"                   then employee.job_title.presence
        when "department"                  then employee.department&.name
        when "hire_date"                   then employee.hire_date
        when "employment_type"             then employee.employment_type && I18n.t("admin.users.employment_types.#{employee.employment_type}")
        when "employment_status"           then I18n.t(employee.active? ? "admin.users.active" : "admin.users.inactive")
        when "employment_end_date"         then employee.employment_ended_on
        when "direct_manager"              then joined(branches.filter_map { |_, id| batch[:managers][id] })
        when "basic_salary"                then salary&.basic_salary
        when "salary_type"                 then salary&.salary_type
        when "salary_currency"             then salary&.currency
        when "social_insurance_status"     then insurance && I18n.t("admin.users.export.insured.#{insurance.insured?}")
        when "social_insurance_number"     then insurance&.insurance_number.presence
        when "social_insurance_start_date" then insurance&.insurance_start_date
        when "social_insurance_end_date"   then insurance&.insurance_end_date
        when "social_insurance_employee_contribution" then insurance&.employee_contribution_amount
        when "social_insurance_employer_contribution" then insurance&.employer_contribution_amount
        when "emergency_contact_name"      then employee.emergency_contact_name.presence
        when "emergency_contact_phone"     then employee.emergency_contact_phone.presence
        when "emergency_contact_relationship" then employee.emergency_contact_relationship.presence
        when "notes"                       then employee.admin_notes.presence
        else raise ArgumentError, "unknown export field #{key}"
        end
      end
    end
  end
end
