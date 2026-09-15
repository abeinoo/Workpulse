# The single entry point for creating or reversing FinancialSettlement
# records. Callers never build FinancialSettlement rows directly — a
# settleable document "requests" a settlement and this service owns the
# record's validation and the reversing-entry pattern used to undo it.
#
# What this service does NOT own: actually moving money on the funding
# source's own ledger (e.g. posting a CustodyTransaction). That stays with
# whichever domain service orchestrates the workflow (e.g.
# Inventory::GoodsReceiptConfirmationService), since only that domain knows
# the correct transaction type/semantics for its funding source. This service
# is purely the settleable-side ledger: which document, which funding source,
# how much, when.
class FinancialSettlementService
  Result = Struct.new(:ok, :settlement, :error, keyword_init: true) do
    def ok? = ok
  end

  def self.create(settleable:, amount:, actor:, funding_source: nil, notes: nil, settled_at: Time.current)
    new(settleable: settleable, actor: actor).create(
      funding_source: funding_source, amount: amount, notes: notes, settled_at: settled_at
    )
  end

  # Posts one reversing settlement per settlement currently on `settleable`,
  # each with the equal-and-opposite amount of the original — never modifying
  # the originals. Used when a settleable document is voided/cancelled and its
  # financial state must fully unwind back to pending_settlement.
  def self.reverse_all(settleable:, actor:, notes: nil)
    new(settleable: settleable, actor: actor).reverse_all(notes: notes)
  end

  def initialize(settleable:, actor:)
    @settleable = settleable
    @actor      = actor
  end

  def create(amount:, funding_source: nil, notes: nil, settled_at: Time.current)
    settlement = @settleable.financial_settlements.new(
      funding_source: funding_source,
      amount:         amount,
      settled_at:     settled_at,
      created_by:     @actor,
      notes:          notes
    )

    if settlement.save
      Result.new(ok: true, settlement: settlement)
    else
      Result.new(ok: false, settlement: settlement, error: settlement.errors.full_messages.to_sentence)
    end
  end

  def reverse_all(notes: nil)
    @settleable.financial_settlements.to_a.map do |original|
      create(funding_source: original.funding_source, amount: -original.amount, notes: notes)
    end
  end
end
