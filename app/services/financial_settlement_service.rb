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

  def self.create(settleable:, amount:, actor:, funding_source: nil, source_kind: nil, reference: nil,
                  notes: nil, settled_at: Time.current)
    new(settleable: settleable, actor: actor).create(
      funding_source: funding_source, source_kind: source_kind, reference: reference,
      amount: amount, notes: notes, settled_at: settled_at
    )
  end

  # Posts one reversing settlement for `settlement` — a new row with the
  # equal-and-opposite amount, linked via reverses_settlement — never modifying
  # the original. Refuses to reverse a reversal or an already-reversed row; the
  # unique index on reverses_settlement_id is the final guard under concurrency.
  def self.reverse(settlement:, actor:, notes: nil)
    new(settleable: settlement.settleable, actor: actor).reverse(settlement, notes: notes)
  end

  # Posts one reversing settlement per settlement still in effect on
  # `settleable` (originals not already individually reversed), each with the
  # equal-and-opposite amount of the original — never modifying the originals.
  # Used when a settleable document is voided/cancelled and its financial state
  # must fully unwind back to pending_settlement. Idempotent: a second call
  # finds nothing left to reverse.
  def self.reverse_all(settleable:, actor:, notes: nil)
    new(settleable: settleable, actor: actor).reverse_all(notes: notes)
  end

  def initialize(settleable:, actor:)
    @settleable = settleable
    @actor      = actor
  end

  def create(amount:, funding_source: nil, source_kind: nil, reference: nil, notes: nil,
             settled_at: Time.current, reverses_settlement: nil)
    settlement = @settleable.financial_settlements.new(
      funding_source:      funding_source,
      source_kind:         source_kind,
      reference:           reference,
      amount:              amount,
      settled_at:          settled_at,
      created_by:          @actor,
      notes:               notes,
      reverses_settlement: reverses_settlement
    )

    if settlement.save
      Result.new(ok: true, settlement: settlement)
    else
      Result.new(ok: false, settlement: settlement, error: settlement.errors.full_messages.to_sentence)
    end
  rescue ActiveRecord::RecordNotUnique
    settlement.errors.add(:reverses_settlement, :taken)
    Result.new(ok: false, settlement: settlement, error: I18n.t("financial_settlements.errors.already_reversed"))
  end

  def reverse(original, notes: nil)
    if original.reversal? || original.reversed?
      original.errors.add(:base, I18n.t("financial_settlements.errors.already_reversed"))
      return Result.new(ok: false, settlement: original, error: I18n.t("financial_settlements.errors.already_reversed"))
    end

    create(funding_source: original.funding_source, source_kind: original.source_kind,
           reference: original.reference, amount: -original.amount, notes: notes,
           reverses_settlement: original)
  end

  def reverse_all(notes: nil)
    @settleable.financial_settlements.unreversed.to_a.map { |original| reverse(original, notes: notes) }
  end
end
