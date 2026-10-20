module Finance
  # Finance & Sales implementation of the Organization & Access
  # OrganizationAccess::BranchTerminalSettings contract (registered in
  # config/initializers/branch_terminal_settings.rb): stages the branch form's
  # POS terminal rows on the branch (Pilot 12 — POS terminals write boundary).
  # Nothing is written here — Branch's autosave association validates and saves
  # (or destroys) the staged terminals with the branch, in its transaction, and
  # puts terminal errors on the branch.
  #
  # Row rules (unchanged from the nested attributes this replaces, pinned by
  # spec/characterization/finance_sales/pos_terminal_branch_form_spec.rb):
  # * no id: a new terminal, unless the row is marked _destroy or its
  #   terminal_id is blank or missing;
  # * an id of one of this branch's terminals: ignored when its terminal_id is
  #   blank or missing (unless marked _destroy); otherwise its attributes are
  #   assigned and, with a truthy _destroy, it is marked for destruction;
  # * any other id (another branch's or business's terminal):
  #   ActiveRecord::RecordNotFound.
  module BranchPosTerminals
    module_function

    UNASSIGNABLE_KEYS = %w[id _destroy].freeze

    def assign(branch:, rows:)
      rows = normalize(rows)
      association = branch.association(:pos_terminals)
      existing    = existing_terminals(association, rows)

      rows.each do |row|
        if row["id"].blank?
          association.build(row.except(*UNASSIGNABLE_KEYS)) unless destroy?(row) || reject?(row)
        elsif (terminal = existing.detect { |t| t.id.to_s == row["id"].to_s })
          next if !destroy?(row) && reject?(row)

          terminal = in_target(association, terminal)
          terminal.assign_attributes(row.except(*UNASSIGNABLE_KEYS))
          terminal.mark_for_destruction if destroy?(row)
        else
          raise ActiveRecord::RecordNotFound.new(
            "Couldn't find PosTerminal with ID=#{row['id']} for Branch with ID=#{branch.id}", "PosTerminal", "id", row["id"]
          )
        end
      end
    end

    # An Array of rows, or a Hash keyed by row index (or a single row with an "id").
    def normalize(rows)
      rows = rows.to_h if rows.respond_to?(:permitted?)
      rows = rows.key?("id") || rows.key?(:id) ? [ rows ] : rows.values if rows.is_a?(Hash)
      raise ArgumentError, "Hash or Array expected for POS terminal rows, got #{rows.class.name}" unless rows.is_a?(Array)

      rows.map { |row| row.to_h.with_indifferent_access }
    end

    def existing_terminals(association, rows)
      return association.target if association.loaded?

      ids = rows.filter_map { |row| row["id"].presence }
      ids.empty? ? [] : association.scope.where(id: ids).to_a
    end

    # Operate on the record held by the association, adding it when not loaded.
    def in_target(association, terminal)
      association.target.detect { |t| t.id.to_s == terminal.id.to_s } ||
        terminal.tap { association.add_to_target(terminal, skip_callbacks: true) }
    end

    def destroy?(row) = ActiveModel::Type::Boolean.new.cast(row["_destroy"])

    # The rejection rule the branch form has always had: no terminal_id, no row.
    def reject?(row) = row["terminal_id"].blank?
  end
end
