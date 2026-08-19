FactoryBot.define do
  factory :bank_statement_transaction do
    association :bank_statement
    association :business

    transaction_date { Date.current }
    amount           { 500.00 }
    status           { "pending" }
    raw_data         { {} }

    trait :verified do
      status { "verified" }
    end

    trait :unexpected do
      status { "unexpected" }
    end

    trait :amount_mismatch do
      status { "amount_mismatch" }
    end

    trait :date_mismatch do
      status { "date_mismatch" }
    end

    trait :ignored do
      status { "ignored" }
    end

    trait :with_reference do
      sequence(:reference_number) { |n| "REF-#{format('%06d', n)}" }
    end

    # Builds a minimal, valid TillDeposit (business -> branch -> DR -> till
    # session -> cash payment method) to match against, mirroring the manual
    # setup used throughout spec/services/finance/till_deposit_*_spec.rb —
    # there is no standalone :till_deposit factory in this codebase.
    trait :matched do
      match_method { "auto_reference" }
      status       { "verified" }

      after(:create) do |txn|
        branch = FactoryBot.create(:branch, business: txn.business)
        actor  = FactoryBot.create(:user, business: txn.business)
        pm     = PaymentMethod.create!(business: txn.business, name: "Cash #{SecureRandom.hex(3)}",
                                       settlement_type: "cash", active: true)
        dr = DailyReconciliation.create!(
          branch: branch, business: txn.business, state: "closed",
          opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
        )
        TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id)
        deposit = TillDeposit.create!(
          daily_reconciliation: dr, payment_method: pm, deposited_by: actor,
          amount: txn.amount, deposited_at: Time.current
        )
        DepositMatch.create_for!(till_deposit: deposit, bank_statement_transaction: txn)
      end
    end
  end
end
