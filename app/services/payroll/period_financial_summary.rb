module Payroll
  # Answers the three questions the Payroll Period page needs to answer, computed
  # entirely from PayrollLineItem — never from the cached aggregate columns on
  # PayrollEntry (total_bonuses, total_deductions, advances_deducted, ...). Any
  # new positive or negative PayrollLineItem type is picked up automatically by
  # both the totals and the category breakdown; nothing here is keyed to a
  # specific item_type.
  #
  #   Gross Payroll    = base_salary (the one component that is never a line
  #                       item — see EntryCalculator#base) + every financially
  #                       active line item with a positive amount.
  #   Total Deductions = every financially active line item with a negative
  #                       amount (abs), PLUS already-paid bonus amounts — an
  #                       already_paid bonus is a positive line item (counted
  #                       in Gross Payroll) that was disbursed outside this
  #                       payroll cycle, so it must also reduce what's still
  #                       payable. Folding it into Total Deductions here is
  #                       what keeps Gross - Deductions == entry.net_salary
  #                       exactly (see PayrollEntry#recalculate_totals!).
  #   Net Payroll      = Gross Payroll - Total Deductions.
  #
  # "Financially active" (PayrollLineItem.financially_active) is the same
  # approved-and-not-waived rule recalculate_totals! applies — a pending_review
  # or rejected item is informational only and never contributes.
  #
  # Aggregation strategy — read before touching this file:
  # `entries` (as handed to .new) may be an ActiveRecord::Relation carrying
  # `includes`/`eager_load`/`order` added by the caller for its own display
  # purposes (see PayrollPeriodsController#show). Calling `.sum`/`.pluck`
  # directly on a relation like that is dangerous: AR silently turns
  # `includes` into a LEFT OUTER JOIN once it needs to hit the database for an
  # aggregate, and joining a has_many (payroll_line_items) fans a PayrollEntry
  # row out once per associated line item — every SUM computed off that join
  # counts base_salary once per line item instead of once per entry. This is
  # exactly the bug that inflated Gross/Net Payroll in production.
  #
  # The rule enforced here: every monetary aggregate is computed from a scope
  # built fresh from `entry_ids` (see #entry_scope / #line_item_scope) —
  # never from `@entries` itself. PayrollEntry aggregates only ever query
  # PayrollEntry; PayrollLineItem aggregates only ever query PayrollLineItem.
  # The two never share a joined relation.
  class PeriodFinancialSummary
    Category = Struct.new(:item_type, :label, :amount, keyword_init: true)

    def initialize(entries)
      @entries = entries
    end

    def gross_payroll
      (base_salary_total + gross_line_items_total).round(2)
    end

    def total_deductions
      (deduction_line_items_total + already_paid_total).round(2)
    end

    def net_payroll
      (gross_payroll - total_deductions).round(2)
    end

    # Positive-amount categories for display, largest first, with Base Salary
    # pinned first since it is the foundation every other earning sits on top of.
    def gross_breakdown
      [ Category.new(item_type: "base_salary", label: I18n.t("payroll.base_salary"), amount: base_salary_total) ] +
        grouped_totals(">").sort_by { |c| -c.amount }
    end

    # Negative-amount categories for display, largest first, with the
    # already-paid offset (if any) shown as its own line.
    def deduction_breakdown
      breakdown = grouped_totals("<")
      breakdown << Category.new(
        item_type: "already_paid",
        label:     I18n.t("payroll.show.already_paid_deduction_label"),
        amount:    already_paid_total
      ) if already_paid_total.positive?

      breakdown.sort_by { |c| -c.amount }
    end

    private

    # --- PayrollEntry aggregates -------------------------------------------

    def base_salary_total
      @base_salary_total ||= (entry_scope.sum(:base_salary) || 0).round(2)
    end

    # A relation dedicated to aggregation: no includes, no eager_load, no
    # order — just the entries this summary covers, identified by id. Never
    # aggregate off @entries directly; always go through this.
    def entry_scope
      @entry_scope ||= PayrollEntry.where(id: entry_ids)
    end

    # --- PayrollLineItem aggregates ------------------------------------------

    def gross_line_items_total
      @gross_line_items_total ||= line_item_scope.where("amount > 0").sum(:amount).round(2)
    end

    def deduction_line_items_total
      @deduction_line_items_total ||= line_item_scope.where("amount < 0").sum(:amount).abs.round(2)
    end

    def already_paid_total
      @already_paid_total ||= line_item_scope.where(already_paid: true).where("amount > 0").sum(:amount).round(2)
    end

    def grouped_totals(comparator)
      line_item_scope
        .where("amount #{comparator} 0")
        .group(:item_type)
        .sum(:amount)
        .map do |item_type, total|
          Category.new(
            item_type: item_type,
            label:     I18n.t("payroll.entry.item_types.#{item_type}", default: item_type.humanize),
            amount:    total.abs.round(2)
          )
        end
    end

    # A relation dedicated to aggregation, scoped to this summary's entries by
    # id only — never joined to PayrollEntry, so it can never fan out.
    def line_item_scope
      @line_item_scope ||= PayrollLineItem.financially_active.where(payroll_entry_id: entry_ids)
    end

    # --- Shared -----------------------------------------------------------

    # The one place @entries is actually touched. Strips any includes/
    # eager_load/preload/order the caller's relation may carry before pulling
    # ids, so the id extraction itself can never trigger the join-fanout
    # behaviour described above — regardless of whether @entries is a fresh
    # relation, an already-loaded one, or a plain Array (e.g. the controller's
    # `@entries.select(&:needs_review?)` filter turns it into one).
    def entry_ids
      @entry_ids ||= if @entries.is_a?(ActiveRecord::Relation)
        @entries.unscope(:includes, :eager_load, :preload, :order).pluck(:id)
      else
        @entries.map(&:id)
      end
    end
  end
end
