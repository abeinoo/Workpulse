FactoryBot.define do
  factory :payroll_line_item do
    association :payroll_entry
    item_type     { :late_penalty }
    amount        { -50.0 }
    description   { "Late arrival on #{Date.current}" }
    review_status { :pending_review }

    trait :late_penalty do
      item_type     { :late_penalty }
      amount        { -50.0 }
      review_status { :pending_review }
    end

    trait :early_leave_penalty do
      item_type     { :early_leave_penalty }
      amount        { -80.0 }
      review_status { :pending_review }
    end

    trait :overtime do
      item_type     { :overtime }
      amount        { 200.0 }
      review_status { :approved }
    end

    trait :advance_deduction do
      item_type     { :advance_deduction }
      amount        { -500.0 }
      review_status { :approved }
    end

    trait :cash_incentive do
      item_type     { :cash_incentive }
      amount        { 300.0 }
      review_status { :approved }
    end

    trait :approved do
      review_status { :approved }
    end

    trait :rejected do
      review_status { :rejected }
    end

    trait :waived do
      review_status { :waived }
      review_notes  { "Excused by manager" }
    end

    # An approved manual deduction sourced from a PayrollAdjustment — the kind of
    # line item the payroll-level waiver layer operates on.
    trait :manual_deduction do
      item_type     { :manual_deduction }
      amount        { -100.0 }
      review_status { :approved }
      source_type   { "PayrollAdjustment" }
      sequence(:source_id) { |n| n }
    end

    # A manual deduction that has been waived at the payroll layer.
    trait :deduction_waived do
      deduction_waived        { true }
      deduction_waiver_reason { "Waived during review" }
      deduction_waived_at     { Time.current }
    end
  end
end
