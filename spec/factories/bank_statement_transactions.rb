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

    trait :matched do
      association :matched_till_deposit, factory: :till_deposit
      match_method { "auto_reference" }
      matched_at   { Time.current }
      status       { "verified" }
    end
  end
end
