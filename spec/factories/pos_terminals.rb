FactoryBot.define do
  factory :pos_terminal do
    association :business
    branch { association :branch, business: business }
    sequence(:terminal_id) { |n| "TERM-#{n}" }
    active { true }
  end
end
