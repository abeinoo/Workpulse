class AddSourceKindReferenceAndReversalLinkToFinancialSettlements < ActiveRecord::Migration[8.0]
  # source_kind: WHERE the money came from (employee_custody / company_cash /
  # bank_account) — needed because only employee custody is backed by a
  # trackable account (funding_source); company cash and bank payments carry a
  # NULL funding_source and would otherwise be indistinguishable.
  #
  # reference: free-text external reference (bank transfer #, cash voucher #).
  #
  # reverses_settlement_id: links a reversing row to the exact original it
  # undoes. The unique index guarantees a settlement can be reversed at most
  # once, even under concurrent requests.
  def up
    add_column :financial_settlements, :source_kind, :string
    add_column :financial_settlements, :reference, :string
    add_reference :financial_settlements, :reverses_settlement,
                  foreign_key: { to_table: :financial_settlements },
                  index: { unique: true }

    # Every existing custody-funded row (originals and their reversals) came
    # from an employee custody account. NULL-funded rows (untracked expense
    # payments) keep a NULL source_kind — we don't know if they were cash or bank.
    execute <<~SQL
      UPDATE financial_settlements
         SET source_kind = 'employee_custody'
       WHERE funding_source_type = 'CustodyAccount'
    SQL

    # Link historical reversals (posted by reverse_all on void/cancel) to their
    # originals: the nth reversal of a given (document, funding source, amount)
    # pairs with the nth original of the same key, in id order.
    execute <<~SQL
      WITH originals AS (
        SELECT id, settleable_type, settleable_id, funding_source_type, funding_source_id, amount,
               ROW_NUMBER() OVER (PARTITION BY settleable_type, settleable_id, funding_source_type,
                                               funding_source_id, amount ORDER BY id) AS rn
          FROM financial_settlements
         WHERE amount > 0
      ),
      reversals AS (
        SELECT id, settleable_type, settleable_id, funding_source_type, funding_source_id, -amount AS amount,
               ROW_NUMBER() OVER (PARTITION BY settleable_type, settleable_id, funding_source_type,
                                               funding_source_id, amount ORDER BY id) AS rn
          FROM financial_settlements
         WHERE amount < 0
      )
      UPDATE financial_settlements fs
         SET reverses_settlement_id = o.id
        FROM reversals r
        JOIN originals o
          ON o.settleable_type = r.settleable_type
         AND o.settleable_id   = r.settleable_id
         AND o.funding_source_type IS NOT DISTINCT FROM r.funding_source_type
         AND o.funding_source_id   IS NOT DISTINCT FROM r.funding_source_id
         AND o.amount = r.amount
         AND o.rn     = r.rn
       WHERE fs.id = r.id
    SQL
  end

  def down
    remove_reference :financial_settlements, :reverses_settlement,
                     foreign_key: { to_table: :financial_settlements }, index: { unique: true }
    remove_column :financial_settlements, :reference
    remove_column :financial_settlements, :source_kind
  end
end
