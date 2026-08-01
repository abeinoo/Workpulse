FactoryBot.define do
  factory :pos_transaction do
    association :business
    pos_import { association :pos_import, business: business }
    branch     { association :branch, business: business }
    sequence(:transaction_id) { |n| "TXN-#{n}" }
    amount               { 100.0 }
    payment_method       { "Card" }
    status               { "Success" }
    transaction_date     { Time.current }
    terminal_id          { "TERM-1" }
    fees                 { 0 }
    administrative_fees  { 0 }
  end
end
