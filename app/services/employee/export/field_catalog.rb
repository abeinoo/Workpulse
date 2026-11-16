module Employee
  module Export
    # The fields an Employee Data Export may contain — the single allow-list the
    # export dialog renders and the exporter validates against. Only data that
    # exists is listed (no gender, marital status, bank account, transport
    # allowance or education: WorkPulse stores none of them).
    #
    # Each field names its group (the dialog's sections, in order), its cell type
    # (:string, :date or :decimal) and, for sensitive data, the access rule that
    # must hold for the viewer — on top of export_employees, which every field
    # needs:
    #   :identity           — National ID: export_employee_identity (UserPolicy#export_identity?)
    #   :salary             — view_payroll; each row then only within the viewer's
    #                          salary visibility (Employee::ExportColumns)
    #   :insurance          — view_employee_insurance or manage_employee_insurance;
    #                          each row then only within EmployeeInsuranceProfilePolicy::Scope
    #   :insurance_employer — the employer contribution, confidential company cost:
    #                          EmployeeInsuranceProfilePolicy#view_employer_contribution?
    #
    # A future saved template is an ordered list of these keys.
    module FieldCatalog
      module_function

      Field = Struct.new(:key, :group, :type, :rule, keyword_init: true) do
        def label = I18n.t("admin.users.export.fields.#{key}")
      end

      GROUPS = %i[personal employment financial additional].freeze

      FIELDS = [
        Field.new(key: "full_name",                              group: :personal,   type: :string),
        Field.new(key: "national_id",                            group: :personal,   type: :string,  rule: :identity),
        Field.new(key: "date_of_birth",                          group: :personal,   type: :date),
        Field.new(key: "address",                                group: :personal,   type: :string),
        Field.new(key: "phone_number",                           group: :personal,   type: :string),
        Field.new(key: "email",                                  group: :personal,   type: :string),
        Field.new(key: "employee_code",                          group: :employment, type: :string),
        Field.new(key: "branch",                                 group: :employment, type: :string),
        Field.new(key: "job_title",                              group: :employment, type: :string),
        Field.new(key: "department",                             group: :employment, type: :string),
        Field.new(key: "hire_date",                              group: :employment, type: :date),
        Field.new(key: "employment_type",                        group: :employment, type: :string),
        Field.new(key: "employment_status",                      group: :employment, type: :string),
        Field.new(key: "employment_end_date",                    group: :employment, type: :date),
        Field.new(key: "direct_manager",                         group: :employment, type: :string),
        Field.new(key: "basic_salary",                           group: :financial,  type: :decimal, rule: :salary),
        Field.new(key: "salary_type",                            group: :financial,  type: :string,  rule: :salary),
        Field.new(key: "salary_currency",                        group: :financial,  type: :string,  rule: :salary),
        Field.new(key: "social_insurance_status",                group: :financial,  type: :string,  rule: :insurance),
        Field.new(key: "social_insurance_number",                group: :financial,  type: :string,  rule: :insurance),
        Field.new(key: "social_insurance_start_date",            group: :financial,  type: :date,    rule: :insurance),
        Field.new(key: "social_insurance_end_date",              group: :financial,  type: :date,    rule: :insurance),
        Field.new(key: "social_insurance_employee_contribution", group: :financial,  type: :decimal, rule: :insurance),
        Field.new(key: "social_insurance_employer_contribution", group: :financial,  type: :decimal, rule: :insurance_employer),
        Field.new(key: "emergency_contact_name",                 group: :additional, type: :string),
        Field.new(key: "emergency_contact_phone",                group: :additional, type: :string),
        Field.new(key: "emergency_contact_relationship",         group: :additional, type: :string),
        Field.new(key: "notes",                                  group: :additional, type: :string)
      ].freeze

      BY_KEY = FIELDS.index_by(&:key).freeze

      # The fields `viewer` may export, in catalogue order (empty without
      # export_employees).
      def permitted_fields(viewer)
        return [] unless UserPolicy.new(viewer, User).export?

        FIELDS.select { |field| rule_holds?(field.rule, viewer) }
      end

      def permitted_keys(viewer) = permitted_fields(viewer).map(&:key)

      # The requested fields, in the requested order — or Refused when the
      # list is empty, repeats a key, or names any field that is unknown or not
      # permitted to `viewer`. Never drops a field silently.
      def resolve!(viewer, keys)
        keys = Array(keys).map(&:to_s)
        raise Refused, "no_fields" if keys.empty?
        raise Refused, "duplicate_fields" if keys.uniq.size != keys.size

        permitted = permitted_keys(viewer)
        raise Refused, "unauthorized_fields" unless (keys - permitted).empty?

        keys.map { BY_KEY.fetch(_1) }
      end

      def rule_holds?(rule, viewer)
        case rule
        when nil                 then true
        when :identity           then UserPolicy.new(viewer, User).export_identity?
        when :salary             then viewer.can?(:view_payroll)
        when :insurance          then viewer.can?(:view_employee_insurance) || viewer.can?(:manage_employee_insurance)
        when :insurance_employer then EmployeeInsuranceProfilePolicy.new(viewer, EmployeeInsuranceProfile)
                                                                    .view_employer_contribution?
        else raise ArgumentError, "unknown field rule #{rule}"
        end
      end
    end
  end
end
