module Finance
  module PosImports
    # Generates ONE aggregate "Payment Gateway Fees" Expense per branch that
    # has nonzero fees on a given PosImport — never one expense per
    # transaction. Branches with zero total fees get no expense. Called only
    # from Importer, inside its transaction, so any failure here rolls back
    # the whole import.
    class ExpenseGenerator
      include AuditLoggable

      CATEGORY_NAME = "Payment Gateway Fees".freeze

      Result = Struct.new(:ok, :expenses, :reason, keyword_init: true) { def ok? = ok }

      def self.call(pos_import_id, actor:)
        new(pos_import_id, actor: actor).call
      end

      def initialize(pos_import_id, actor:)
        @pos_import_id = pos_import_id
        @actor         = actor
      end

      def call
        pos_import = PosImport.where(business: @actor.business).find(@pos_import_id)
        business   = pos_import.business

        fees_by_branch = pos_import.pos_transactions
                                   .group(:branch_id)
                                   .sum("fees + administrative_fees")
                                   .select { |_branch_id, total| total.to_d > 0 }

        return Result.new(ok: true, expenses: []) if fees_by_branch.empty?

        category = business.expense_categories.find_or_create_by!(name: CATEGORY_NAME) do |c|
          c.active = true
        end

        expenses = fees_by_branch.map do |branch_id, total|
          expense = business.expenses.build(
            branch_id:           branch_id,
            expense_category:    category,
            deduct_from_balance: false,
            amount:              total,
            expense_date:        Date.current,
            status:              "pending_approval",
            created_by:          @actor,
            source_pos_import:   pos_import
          )
          expense.reference_number = Finance::NumberSequencer.new(business, :expense).next_number
          expense.save!

          log_audit(actor: @actor, auditable: expense, action: "pos_import_expense_generated",
                    metadata: { pos_import_id: pos_import.id, branch_id: branch_id, total_fees: total.to_s })
          expense
        end

        Result.new(ok: true, expenses: expenses)
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, reason: e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
