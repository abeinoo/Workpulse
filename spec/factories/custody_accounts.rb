FactoryBot.define do
  factory :custody_account do
    business { association :business }
    user { association :user, business: business }
    branch { nil }
    sequence(:name) { |n| "Float #{n}" }
    current_balance { 0 }
    active { true }
  end
end
