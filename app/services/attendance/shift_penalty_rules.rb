module Attendance
  # Attendance & Payroll implementation of the Workforce Shifts::PenaltyRuleSettings
  # contract (registered in config/initializers/shift_penalty_rule_settings.rb):
  # stages the shift form's rule rows on the shift. Nothing is written here —
  # Shift's autosave association validates and saves (or destroys) the staged
  # rules with the shift, in its transaction, and puts rule errors on the shift.
  #
  # Row rules (unchanged from the nested attributes this replaces):
  # * no id: a new rule, unless the row is all blank or marked _destroy;
  # * an id of one of this shift's rules: its attributes are assigned and, with a
  #   truthy _destroy, it is marked for destruction;
  # * any other id (another shift's or business's rule): ActiveRecord::RecordNotFound.
  module ShiftPenaltyRules
    module_function

    UNASSIGNABLE_KEYS = %w[id _destroy].freeze

    def assign(shift:, rows:)
      rows = normalize(rows)
      association = shift.association(:penalty_rules)
      existing    = existing_rules(association, rows)

      rows.each do |row|
        if row["id"].blank?
          association.build(row.except(*UNASSIGNABLE_KEYS)) unless destroy?(row) || all_blank?(row)
        elsif (rule = existing.detect { |r| r.id.to_s == row["id"].to_s })
          next if !destroy?(row) && all_blank?(row)

          rule = in_target(association, rule)
          rule.assign_attributes(row.except(*UNASSIGNABLE_KEYS))
          rule.mark_for_destruction if destroy?(row)
        else
          raise ActiveRecord::RecordNotFound.new(
            "Couldn't find PenaltyRule with ID=#{row['id']} for Shift with ID=#{shift.id}", "PenaltyRule", "id", row["id"]
          )
        end
      end
    end

    # An Array of rows, or a Hash keyed by row index (or a single row with an "id").
    def normalize(rows)
      rows = rows.to_h if rows.respond_to?(:permitted?)
      rows = rows.key?("id") || rows.key?(:id) ? [ rows ] : rows.values if rows.is_a?(Hash)
      raise ArgumentError, "Hash or Array expected for penalty rule rows, got #{rows.class.name}" unless rows.is_a?(Array)

      rows.map { |row| row.to_h.with_indifferent_access }
    end

    def existing_rules(association, rows)
      return association.target if association.loaded?

      ids = rows.filter_map { |row| row["id"].presence }
      ids.empty? ? [] : association.scope.where(id: ids).to_a
    end

    # Operate on the record held by the association, adding it when not loaded.
    def in_target(association, rule)
      association.target.detect { |r| r.id.to_s == rule.id.to_s } ||
        rule.tap { association.add_to_target(rule, skip_callbacks: true) }
    end

    def destroy?(row) = ActiveModel::Type::Boolean.new.cast(row["_destroy"])

    def all_blank?(row) = row.all? { |key, value| key == "_destroy" || value.blank? }
  end
end
