FactoryBot.define do
  factory :bank_statement do
    association :business
    association :imported_by, factory: :user

    sequence(:file_name) { |n| "bank_statement_#{n}.csv" }
    statement_from { 1.month.ago.to_date }
    statement_to   { Date.current }
    status         { "completed" }
    column_mapping do
      {
        "transaction_date" => "Value Date",
        "amount"           => "Credit Amount",
        "reference_number" => "Reference"
      }
    end
    total_rows    { 10 }
    matched_rows  { 8 }
    unmatched_rows { 2 }
    failed_rows   { 0 }

    trait :pending do
      status { "pending" }
      total_rows    { 0 }
      matched_rows  { 0 }
      unmatched_rows { 0 }
    end

    trait :failed do
      status { "failed" }
    end

    trait :for_branch do
      association :branch
    end
  end
end
