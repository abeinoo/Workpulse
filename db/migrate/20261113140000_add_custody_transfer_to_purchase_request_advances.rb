# An "Employee Custody" advance now moves money from the purchasing employee's
# custody account to a recipient employee's custody account (a custody
# transfer), instead of paying the supplier. See PurchaseRequestAdvance.
#
#   recipient_custody_account_id  the account credited at confirmation
#   custody_transfer_id           the source-side "transfer" row posted at
#                                 confirmation; its transfer_counterparty is
#                                 the recipient-side credit
#   custody_transfer_reversal_id  the recipient-side "transfer" row posted at
#                                 reversal (recipient → source)
#
# All three are NULL on every existing advance, so history is untouched (a
# legacy custody advance keeps its supplier settlement). Reversible: down drops
# the columns.
class AddCustodyTransferToPurchaseRequestAdvances < ActiveRecord::Migration[8.1]
  def change
    add_reference :purchase_request_advances, :recipient_custody_account,
                  foreign_key: { to_table: :custody_accounts }, index: true
    add_reference :purchase_request_advances, :custody_transfer,
                  foreign_key: { to_table: :custody_transactions }, index: { unique: true }
    add_reference :purchase_request_advances, :custody_transfer_reversal,
                  foreign_key: { to_table: :custody_transactions }, index: { unique: true }

    add_check_constraint :purchase_request_advances,
                         "recipient_custody_account_id IS NULL OR recipient_custody_account_id <> custody_account_id",
                         name: "pr_advances_recipient_differs_from_source"
  end
end
