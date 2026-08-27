FactoryBot.define do
  factory :biometric_punch_log do
    association :business
    biometric_device { nil }
    employee         { nil }
    action           { "check_in" }
    source           { "biometric" }
    punched_at       { Time.current }
    received_at      { Time.current }
    work_date        { Date.current }
  end
end
