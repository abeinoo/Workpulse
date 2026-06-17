class AddCustodyAccountToExpenses < ActiveRecord::Migration[8.1]
  # An expense can be tied to the custody account the money was spent FROM, chosen
  # at creation. A custody-backed expense represents an already-incurred spend, so
  # approval settles it in one step (posts the deduction + marks paid) — there is
  # no separate payment workflow for these.
  def change
    add_reference :expenses, :custody_account, foreign_key: true, index: true
  end
end
