module Finance
  # Finance & Sales implementation of the Payroll::FinalizationEffects contract
  # (registered in config/initializers/payroll_finalization_effects.rb). The
  # contract surface only: the Social Insurance expense itself is owned by
  # Finance::PayrollInsuranceExpense.
  module PayrollFinalizationEffects
    module_function

    def period_finalized(period:, actor:, employer_insurance_total:, employer_insurance_by_branch:)
      Finance::PayrollInsuranceExpense.record(period: period, actor: actor,
                                              total: employer_insurance_total,
                                              by_branch: employer_insurance_by_branch)
    end

    def period_reopened(period:, actor:, reason:)
      Finance::PayrollInsuranceExpense.void_for(period: period, actor: actor, reason: reason)
    end
  end
end
