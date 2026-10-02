# Advance payments / deposits paid to a supplier against a Purchase Request
# before (or between) receipts. This table holds only the LIFECYCLE
# (pending → confirmed → reversed, or pending → cancelled) and who did what;
# the money itself lives in the existing ledgers:
#   - confirmation posts one FinancialSettlement on the Purchase Request
#     (financial_settlement_id) and, for employee custody, the linked
#     CustodyTransaction debit;
#   - receiving applies it to Goods Receipts as FinancialSettlement rows whose
#     funding_source is this advance.
class CreatePurchaseRequestAdvances < ActiveRecord::Migration[8.1]
  def change
    create_table :purchase_request_advances do |t|
      t.references :business,         null: false, foreign_key: true
      t.references :purchase_request, null: false, foreign_key: true
      t.decimal    :amount, precision: 12, scale: 2, null: false
      t.string     :source_kind, null: false
      t.references :custody_account, foreign_key: true
      t.date       :paid_on, null: false
      t.string     :reference
      t.text       :notes
      t.string     :status, null: false, default: "pending"
      t.string     :idempotency_key

      t.references :created_by,   foreign_key: { to_table: :users }
      t.references :confirmed_by, foreign_key: { to_table: :users }
      t.datetime   :confirmed_at
      t.references :cancelled_by, foreign_key: { to_table: :users }
      t.datetime   :cancelled_at
      t.text       :cancellation_reason
      t.references :reversed_by,  foreign_key: { to_table: :users }
      t.datetime   :reversed_at
      t.text       :reversal_reason

      # The PR-side settlement posted at confirmation (the advance's money row).
      t.references :financial_settlement, foreign_key: true, index: { unique: true }

      t.timestamps
    end

    add_index :purchase_request_advances, %i[business_id idempotency_key], unique: true,
              where: "idempotency_key IS NOT NULL", name: "index_pr_advances_on_business_and_idempotency_key"
    add_index :purchase_request_advances, %i[purchase_request_id status]
    add_check_constraint :purchase_request_advances, "amount > 0", name: "pr_advances_amount_positive"
  end
end
