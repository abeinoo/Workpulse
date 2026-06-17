module Finance
  # Runs daily via Solid Queue. Generates pending expenses for every recurring
  # template that has come due, catching up multiple missed periods in one pass
  # (capped) so a downtime gap doesn't silently skip months. Each template is
  # isolated — a failure in one never blocks the others.
  class GenerateDueRecurringExpensesJob < ApplicationJob
    queue_as :background

    # Safety cap on catch-up iterations per template (e.g. ~2 years of monthly).
    MAX_CATCHUP = 24

    def perform(on: Date.current)
      RecurringExpense.due_on(on).find_each do |recurring|
        generate_catchup(recurring, on)
      rescue StandardError => e
        Rails.logger.error "[RecurringExpense] Error for ##{recurring.id}: #{e.message}"
      end
    end

    private

    def generate_catchup(recurring, on)
      MAX_CATCHUP.times do
        break unless recurring.active? &&
                     recurring.next_run_on <= on &&
                     !recurring.ended_on?(recurring.next_run_on)

        result = Finance::RecurringExpenseGenerator.new(recurring).call
        unless result.ok?
          Rails.logger.warn "[RecurringExpense] Stopped ##{recurring.id}: #{result.reason}"
          break
        end
        Rails.logger.info "[RecurringExpense] Generated #{result.expense.reference_number} from ##{recurring.id}"
        recurring.reload
      end
    end
  end
end
