module Finance
  # Finance & Sales implementation of the Payroll::FinalizationEffects contract
  # (registered in config/initializers/payroll_finalization_effects.rb): the
  # Social Insurance expense a finalized payroll period produces, and its void
  # when the period is reopened (FS-D1).
  #
  # Milestone 2 — Finance & Sales Expenses, M2: delegates to the existing
  # implementation, Payroll::InsuranceExpenseGenerator, unchanged (no rule is
  # copied here). M3 routes Payroll::Approver / Payroll::Reopener through the
  # contract; M4 moves the expense-building and void code into Finance.
  module PayrollFinalizationEffects
    module_function

    def period_finalized(period:, actor:)
      Payroll::InsuranceExpenseGenerator.call(period: period, actor: actor)
    end

    def period_reopened(period:, actor:, reason:)
      Payroll::InsuranceExpenseGenerator.void_for(period: period, actor: actor, reason: reason)
    end
  end
end
