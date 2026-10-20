module Finance
  module Reports
    # تقرير تفاصيل المصروفات — a hierarchical drill-down into the same five
    # cost sources Finance::Reports::BranchProfitability sums into its single
    # "expenses" figure (see Finance::Reports::ExpenseSources, the shared
    # source of truth both classes call into). This report never recomputes a
    # cost differently than BranchProfitability does — it only exposes the
    # per-employee/per-product/per-expense-row detail behind each total.
    #
    # Returned shape is a plain struct tree (not Finance::Reports::Table,
    # which is strictly flat and cannot represent nested sections/groups/rows).
    class ExpenseDetails
      Result = Struct.new(:year, :month, :to_year, :to_month, :branch_filter, :expense_type_filter,
                          :sections, :reconciliation, :recurring_note, :payroll_restricted, keyword_init: true)
      Section = Struct.new(:key, :title, :total, :applies_type_filter, :groups, keyword_init: true)
      Group   = Struct.new(:label, :branch_id, :subtotal, :rows, keyword_init: true)
      Reconciliation = Struct.new(:report_total, :branch_profitability_total, keyword_init: true) do
        def matches? = (report_total.to_f - branch_profitability_total.to_f).abs < 0.01
      end
      RecurringNote = Struct.new(:generated_this_period_amount, keyword_init: true)

      # to_year/to_month default to year/month — every existing caller (specs,
      # the pre-range controller action) that passes only year/month keeps
      # resolving to the exact same single-month range as before.
      #
      # payroll_branch_ids (Finance::PayrollCostAccess#branch_ids) limits whose
      # payroll cost is shown: the payroll section keeps only those branches
      # (and is left out when none is in the report), its total and the
      # reconciliation count only them, and payroll_restricted says so. nil
      # (the default) = every branch.
      def initialize(business, year:, month:, to_year: nil, to_month: nil, branch_id: nil, expense_type_id: nil,
                     payroll_branch_ids: nil)
        @business         = business
        @year             = year
        @month            = month
        @to_year          = to_year || year
        @to_month         = to_month || month
        @months           = month_range(year, month, @to_year, @to_month)
        @start            = Date.new(@months.first.first, @months.first.last, 1)
        @end              = Date.new(@months.last.first, @months.last.last, 1).end_of_month
        @branch_id        = branch_id.presence
        @expense_type_id  = expense_type_id.presence
        @payroll_branch_ids = payroll_branch_ids
      end

      # Section keys whose totals are directly comparable to Branch
      # Profitability's own total (all sales-branch-attributed cost sources).
      # :other is deliberately excluded — see #other_section.
      RECONCILING_SECTION_KEYS = %i[payroll laundry inventory branch_expenses shared_expenses].freeze

      def call
        sections = [
          payroll_section, laundry_section, inventory_section,
          branch_expenses_section, shared_expenses_section, other_section
        ].compact

        Result.new(
          year: @year, month: @month, to_year: @to_year, to_month: @to_month,
          branch_filter: @branch_id, expense_type_filter: @expense_type_id,
          sections: sections,
          reconciliation: reconciliation(sections),
          recurring_note: RecurringNote.new(generated_this_period_amount: recurring_generated_amount),
          payroll_restricted: payroll_branches_in_scope.size < branches_in_scope.size
        )
      end

      private

      # Inclusive [year, month] pairs from (from_year, from_month) to
      # (to_year, to_month). Never empty — an inverted/invalid range (the
      # caller's responsibility to validate, see Finance::Reports::
      # PeriodResolver) falls back to the single from-month rather than
      # silently querying nothing.
      def month_range(from_year, from_month, to_year, to_month)
        from_date = Date.new(from_year, from_month, 1)
        to_date   = Date.new(to_year, to_month, 1)
        return [ [ from_year, from_month ] ] if from_date > to_date

        months = []
        cursor = from_date
        while cursor <= to_date
          months << [ cursor.year, cursor.month ]
          cursor = cursor.next_month
        end
        months
      end

      # One Finance::Reports::ExpenseSources per month in range — each is
      # exactly the same single-month query BranchProfitability itself would
      # run for that month, never a reinterpreted range query. Merged below
      # per cost source, so every figure is a real sum of real per-month
      # records, not a single month's value multiplied out.
      def sources_by_month
        @sources_by_month ||= @months.map { |y, m| Finance::Reports::ExpenseSources.new(@business, year: y, month: m) }
      end

      # Sums a {branch_id => amount} hash-returning ExpenseSources method
      # across every month in range.
      def merged_totals(method_name)
        sources_by_month.each_with_object(Hash.new(0)) do |src, totals|
          src.public_send(method_name).each { |branch_id, amount| totals[branch_id] += amount }
        end
      end

      # Concatenates a {branch_id => [records]} hash-returning ExpenseSources
      # method across every month in range — each month's real records,
      # never deduplicated/collapsed, so every row still traces to one
      # actual DB record.
      def merged_records(method_name)
        sources_by_month.each_with_object(Hash.new { |h, k| h[k] = [] }) do |src, all|
          src.public_send(method_name).each { |branch_id, records| all[branch_id].concat(records) }
        end
      end

      def sales_branches
        @sales_branches ||= @business.branches.active.where(branch_type: "sales").order(:name).to_a
      end

      def branches_in_scope
        @branch_id ? sales_branches.select { |b| b.id == @branch_id } : sales_branches
      end

      # The branches in the report whose payroll cost may be shown.
      def payroll_branches_in_scope
        return branches_in_scope if @payroll_branch_ids.nil?

        branches_in_scope.select { |b| @payroll_branch_ids.include?(b.id) }
      end

      # ── Section 1: الرواتب ──────────────────────────────────────────────────
      # Total is GROSS (base + overtime + bonus) — identical arithmetic to
      # ExpenseSources#payroll_costs, the figure BranchProfitability/reconciliation
      # use. Employee `net_salary` rows are informational detail only — their
      # sum will NOT equal this total (net is post-deduction/advance/obligation).
      def payroll_section
        return nil if payroll_branches_in_scope.empty?

        entries_by_branch = merged_records(:payroll_entries_by_branch)
        groups = payroll_branches_in_scope.filter_map do |branch|
          entries = entries_by_branch[branch.id]
          next if entries.blank?

          rows = entries.map do |entry|
            {
              payroll_entry_id:  entry.id, # lets the caller show only the entries the viewer may see
              employee_name:     entry.user.full_name,
              base_salary:       entry.base_salary,
              total_overtime:    entry.total_overtime,
              total_bonuses:     entry.total_bonuses,
              total_deductions:  entry.total_deductions,
              advances_deducted: entry.advances_deducted,
              obligations_deducted: entry.obligations_deducted,
              net_salary:        entry.net_salary,
              gross:             entry.base_salary + entry.total_overtime + entry.total_bonuses
            }
          end

          Group.new(label: branch.name, branch_id: branch.id, subtotal: rows.sum { |r| r[:gross] }, rows: rows)
        end

        Section.new(key: :payroll, title: I18n.t("finance.reports.expense_details.sections.payroll"),
                    total: section_total(merged_totals(:payroll_costs), payroll_branches_in_scope),
                    applies_type_filter: false, groups: groups)
      end

      # ── Section 2: المغسلة ──────────────────────────────────────────────────
      def laundry_section
        events_by_branch = merged_records(:laundry_events_by_branch)
        groups = branches_in_scope.filter_map do |branch|
          events = events_by_branch[branch.id]
          next if events.blank?

          rows = events.map do |event|
            {
              towel_type: event.towel_type&.name,
              received_at: event.received_at,
              confirmed_quantity: event.confirmed_quantity,
              rate: event.rate,
              line_total: event.line_total
            }
          end

          Group.new(label: branch.name, branch_id: branch.id, subtotal: rows.sum { |r| r[:line_total].to_f }, rows: rows)
        end

        Section.new(key: :laundry, title: I18n.t("finance.reports.expense_details.sections.laundry"),
                    total: section_total(merged_totals(:laundry_costs)), applies_type_filter: false, groups: groups)
      end

      # ── Section 3: المخزن ───────────────────────────────────────────────────
      def inventory_section
        rows_by_branch = merged_records(:inventory_movements_by_branch_product)
        groups = branches_in_scope.filter_map do |branch|
          rows = collapse_inventory_rows(rows_by_branch[branch.id])
          next if rows.blank?

          Group.new(label: branch.name, branch_id: branch.id, subtotal: rows.sum { |r| r[:total] }, rows: rows)
        end

        Section.new(key: :inventory, title: I18n.t("finance.reports.expense_details.sections.inventory"),
                    total: section_total(merged_totals(:inventory_costs)), applies_type_filter: false, groups: groups)
      end

      # Multi-month range: the same product can appear once per month
      # (concatenated by merged_records). Collapse those into one row per
      # product summing quantity/total (unit_cost re-derived as the blended
      # average), so a 3-month view doesn't show "Shampoo" three times. Pure
      # display grouping — every month's real row still contributes its exact
      # quantity/total to the sum, nothing is recomputed or estimated.
      def collapse_inventory_rows(rows)
        return [] if rows.blank?

        rows.group_by { |r| r[:product]&.id }.map do |_product_id, group|
          total    = group.sum { |r| r[:total] }
          quantity = group.sum { |r| r[:quantity] }
          {
            product: group.first[:product], category: group.first[:category],
            quantity: quantity, unit_cost: quantity.to_f.zero? ? 0 : total / quantity, total: total
          }
        end
      end

      # ── Section 4: مصروفات الفروع ───────────────────────────────────────────
      def branch_expenses_section
        records_by_branch = merged_records(:direct_expense_records_by_branch)
        groups = branches_in_scope.filter_map do |branch|
          records = records_by_branch[branch.id] || []
          records = records.select { |e| e.expense_type_id == @expense_type_id } if @expense_type_id
          next if records.blank?

          rows = records.map { |expense| expense_row(expense) }
          Group.new(label: branch.name, branch_id: branch.id, subtotal: rows.sum { |r| r[:amount] }, rows: rows)
        end

        total = @expense_type_id ? groups.sum(&:subtotal) : section_total(merged_totals(:direct_expenses))
        Section.new(key: :branch_expenses, title: I18n.t("finance.reports.expense_details.sections.branch_expenses"),
                    total: total, applies_type_filter: true, groups: groups)
      end

      # ── Section 5: المصروفات المشتركة ───────────────────────────────────────
      def shared_expenses_section
        records_by_branch = merged_records(:allocated_expense_records_by_branch)
        groups = branches_in_scope.filter_map do |branch|
          records = records_by_branch[branch.id] || []
          records = records.select { |a| a.expense.expense_type_id == @expense_type_id } if @expense_type_id
          next if records.blank?

          rows = records.map { |alloc| allocation_row(alloc) }
          Group.new(label: branch.name, branch_id: branch.id, subtotal: rows.sum { |r| r[:amount] }, rows: rows)
        end

        total = @expense_type_id ? groups.sum(&:subtotal) : section_total(merged_totals(:allocated_expenses))
        Section.new(key: :shared_expenses, title: I18n.t("finance.reports.expense_details.sections.shared_expenses"),
                    total: total, applies_type_filter: true, groups: groups)
      end

      # ── Section 6: مصروفات أخرى (غير مرتبطة بفرع) ───────────────────────────
      # By the model's own rule (Expense#normalize_branch_mode), every expense
      # is supposed to be either branch-direct or shared-with-allocations —
      # but that rule is only enforced going forward, not retroactively, so
      # rows written before it existed (or via a path that bypassed
      # validations) can sit in the DB with branch_id nil AND is_shared false.
      # These are real, approved money — not a rendering artifact — but they
      # are structurally unattributable to any branch, so Branch Profitability
      # (a per-*branch* report) can never include them. That's a legitimate,
      # documented exclusion, not a bug: see RECONCILING_SECTION_KEYS and
      # #reconciliation. This section makes that money visible rather than
      # silently dropping it, instead of guessing which branch it belongs to.
      def other_section
        records = @branch_id ? [] : unattributed_expenses_scope.includes(:expense_category, :expense_type).to_a
        rows = records.map { |expense| expense_row(expense) }

        groups = rows.present? ? [
          Group.new(label: I18n.t("finance.reports.expense_details.sections.unattributed_group"),
                    branch_id: nil, subtotal: rows.sum { |r| r[:amount] }, rows: rows)
        ] : []

        Section.new(key: :other, title: I18n.t("finance.reports.expense_details.sections.other"),
                    total: rows.sum { |r| r[:amount] }, applies_type_filter: true, groups: groups)
      end

      def unattributed_expenses_scope
        scope = @business.expenses.where(status: "approved", branch_id: nil, is_shared: false).in_period(@start, @end)
        scope = scope.where(expense_type_id: @expense_type_id) if @expense_type_id
        scope
      end

      def expense_row(expense)
        {
          reference: expense.reference_number,
          date: expense.expense_date,
          category: expense.expense_category&.name,
          type: expense.expense_type&.name,
          payment_source: expense.payment_source,
          status: expense.status,
          amount: expense.amount,
          system_generated: expense.system_generated?
        }
      end

      def allocation_row(alloc)
        expense = alloc.expense
        {
          reference: expense.reference_number,
          date: expense.expense_date,
          category: expense.expense_category&.name,
          type: expense.expense_type&.name,
          original_amount: expense.amount,
          allocation_method: expense.distribution_method,
          allocation_percentage: alloc.allocation_percentage,
          amount: alloc.allocated_amount,
          system_generated: expense.system_generated?
        }
      end

      # Restricted to branches_in_scope (sales branches, or the single
      # filtered branch) — the exact same restriction BranchProfitability's
      # own #call applies before summing. A raw ExpenseSources hash can carry
      # non-sales branch_ids (e.g. a laundry branch's own payroll/inventory/
      # direct-expense costs); summing those in would make this report's
      # total include money no group/row on the page ever displays, and would
      # silently drift from Branch Profitability's total, which excludes them
      # by design (see Finance::Reports::BranchProfitability's class comment).
      def section_total(hash, branches = branches_in_scope)
        branches.sum { |b| hash[b.id] || 0 }
      end

      # Recurring-sourced expenses already flow through branch_expenses_section
      # / shared_expenses_section as ordinary Expense rows — this is metadata
      # only, never added to any total, so the UI can say "X of the amount
      # above came from a recurring template" without double-counting it.
      def recurring_generated_amount
        scope = @business.expenses.where(status: "approved").in_period(@start, @end).where.not(source_recurring_expense_id: nil)
        scope = scope.where(branch_id: @branch_id).or(scope.where(is_shared: true)) if @branch_id
        scope.sum(:amount)
      end

      # Only sums RECONCILING_SECTION_KEYS — :other (unattributed expenses,
      # see #other_section) is deliberately excluded, since Branch
      # Profitability structurally cannot include money with no branch to
      # attribute it to. That's a documented exclusion, not a discrepancy.
      #
      # BranchProfitability itself is single-month only (untouched — see
      # Finance::Reports::BranchProfitability's own class comment) and stays
      # that way; for a multi-month range this calls it once per month in
      # @months and sums the results, rather than comparing a multi-month
      # total against a single month's figure.
      #
      # Only meaningful when no expense_type filter narrows the Expense-backed
      # sections — a type filter breaks correspondence to Branch Profitability
      # by definition, so the caller should suppress the reconciliation banner
      # in that mode (still computed here so the numbers are available if needed).
      def reconciliation(sections)
        report_total = sections.select { |s| RECONCILING_SECTION_KEYS.include?(s.key) }.sum(&:total)
        bp_total = @months.sum { |y, m| branch_profitability_total_for(y, m) }

        Reconciliation.new(report_total: report_total, branch_profitability_total: bp_total)
      end

      # The same branches as the report (one, under a branch filter; every sales
      # branch otherwise — the rows BranchProfitability returns), with payroll
      # counted only where this report shows it (nil there = not shown).
      def branch_profitability_total_for(year, month)
        table = Finance::Reports::BranchProfitability.new(@business, year: year, month: month,
                                                          payroll_branch_ids: @payroll_branch_ids).call
        names = branches_in_scope.map(&:name)
        table.rows.select { |r| names.include?(r[:branch]) }
             .sum { |r| (r[:payroll] || 0) + r[:inventory] + r[:expenses] }
      end
    end
  end
end
