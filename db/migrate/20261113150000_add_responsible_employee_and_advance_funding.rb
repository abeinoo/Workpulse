# Purchase Request responsible employee and advance FUNDING — the approved
# replacement of the custody-transfer design that 20261113140000 introduced.
# 20261113140000 stays exactly as it was applied (development ran it); this
# migration moves its shape to the funding one:
#
#   purchase_requests.responsible_employee_id (new)
#       the employee accountable for purchasing and receiving; every advance on
#       the request funds this employee's custody. NULL on every existing
#       request — never back-filled (no employee is assigned automatically).
#
#   purchase_request_advances.custody_transfer_id → funding_transaction_id
#       the custody CREDIT posted at confirmation (for an employee transfer,
#       the responsible leg; its transfer_counterparty is the source debit).
#   purchase_request_advances.custody_transfer_reversal_id → funding_reversal_transaction_id
#       the custody DEBIT posted at reversal.
#   Renamed in place: PostgreSQL keeps their foreign keys to custody_transactions
#   and their unique indexes (renamed with them). recipient_custody_account_id
#   and the pr_advances_recipient_differs_from_source check are unchanged.
#
# No row is written (both renamed columns are NULL wherever 20261113140000 ran).
# Reversible: down drops responsible_employee_id and renames the columns back.
class AddResponsibleEmployeeAndAdvanceFunding < ActiveRecord::Migration[8.1]
  def change
    add_reference :purchase_requests, :responsible_employee, foreign_key: { to_table: :users }, index: true

    rename_column :purchase_request_advances, :custody_transfer_id, :funding_transaction_id
    rename_column :purchase_request_advances, :custody_transfer_reversal_id, :funding_reversal_transaction_id
  end
end
