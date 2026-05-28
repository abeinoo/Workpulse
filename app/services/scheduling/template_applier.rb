module Scheduling
  # Applies a ShiftTemplate to a set of employees by creating one
  # ShiftAssignment per (employee × entry) pair.
  #
  # Blocked rows are skipped. Warning rows proceed (manager confirmed preview).
  # Partial success is reported via the Result struct.
  class TemplateApplier
    Result = Struct.new(:created, :skipped, :row_errors, keyword_init: true) do
      def success?   = row_errors.empty?
      def total_rows = created + skipped + row_errors.size
    end

    RowError = Struct.new(:user_name, :entry_description, :reason, keyword_init: true)

    def self.call(template:, employees:, created_by:)
      new(template: template, employees: employees, created_by: created_by).call
    end

    def initialize(template:, employees:, created_by:)
      @template   = template
      @employees  = Array(employees)
      @created_by = created_by
    end

    def call
      preview_rows = TemplatePreviewer.call(
        template:  @template,
        employees: @employees
      )

      created    = 0
      skipped    = 0
      row_errors = []

      preview_rows.each do |row|
        if row.blocked?
          skipped += 1
          next
        end

        assignment = ShiftAssignment.new(
          user:            row.user,
          shift:           row.entry.shift,
          branch:          row.entry.branch,
          effective_from:  row.effective_from,
          effective_to:    row.effective_to,
          created_by:      @created_by,
          rule_profile:    row.entry.rule_profile,
          source_template: @template
        )

        if assignment.save
          created += 1
        else
          row_errors << RowError.new(
            user_name:         row.user.full_name,
            entry_description: "#{row.entry.shift_name} (#{row.effective_from} – #{row.effective_to})",
            reason:            assignment.errors.full_messages.join(", ")
          )
        end
      end

      Result.new(created: created, skipped: skipped, row_errors: row_errors)
    end
  end
end
