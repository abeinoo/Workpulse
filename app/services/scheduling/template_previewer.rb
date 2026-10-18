module Scheduling
  # Generates a dry-run preview of what ShiftAssignments would be created
  # when applying a ShiftTemplate to a set of employees.
  #
  # Date-based mode: each entry carries its own starts_on / ends_on, so no
  # external date range is needed. One PreviewRow is produced per
  # (employee × entry) pair. No records are persisted.
  #
  # The branch is chosen once when the template is applied (entries carry no
  # branch): every row is checked — and later created — against that branch.
  # The caller resolves it from the branches the actor may assign to.
  class TemplatePreviewer
    PreviewRow = Struct.new(
      :user, :entry, :effective_from, :effective_to, :conflict,
      keyword_init: true
    ) do
      def status
        return :blocked if conflict&.blocked?
        return :warning if conflict&.warning?
        :valid
      end

      def valid?   = status == :valid
      def warning? = status == :warning
      def blocked? = status == :blocked
    end

    def self.call(template:, employees:, branch:)
      new(template: template, employees: employees, branch: branch).call
    end

    def initialize(template:, employees:, branch:)
      raise ArgumentError, "branch is required" if branch.nil?

      @template  = template
      @employees = Array(employees)
      @branch    = branch
    end

    def call
      entries = @template.entries.includes(:shift).order(:starts_on)
      rows    = []

      @employees.each do |employee|
        entries.each do |entry|
          conflict = ConflictDetector.call(
            user:           employee,
            shift:          entry.shift,
            branch:         @branch,
            effective_from: entry.starts_on,
            effective_to:   entry.effective_ends_on
          )

          rows << PreviewRow.new(
            user:           employee,
            entry:          entry,
            effective_from: entry.starts_on,
            effective_to:   entry.effective_ends_on,
            conflict:       conflict.valid? ? nil : conflict
          )
        end
      end

      rows
    end
  end
end
