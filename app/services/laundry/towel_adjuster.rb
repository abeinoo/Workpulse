module Laundry
  # Posts an explicit manual correction: creates a TowelAdjustment record (the
  # audit trail — original value, signed delta, reason, actor) and one or more
  # matching TowelLedgerEntry rows. Never edits an existing ledger row.
  class TowelAdjuster
    include AuditLoggable

    Result = Struct.new(:ok, :adjustment, :error, keyword_init: true) { def ok? = ok }

    # adjustment_type => the ledger reason its tracking-bucket entry posts as
    # (reuses TowelLedgerEntry::REASONS — no schema change needed).
    LOSS_LEDGER_REASONS = { "lost" => "loss", "damaged" => "damage" }.freeze

    def initialize(actor:)
      @actor = actor
    end

    # Free-form manual correction of a single ledger bucket (clean, dirty,
    # damaged, disposed, or lost) — the general-purpose path, unrelated to
    # the guided loss/damage flow below. Always adjustment_type: "correction".
    def call(towel_type:, branch:, status:, adjustment_quantity:, reason:)
      current = TowelBalances.new(towel_type).at_branch(branch, status)

      adjustment = TowelAdjustment.new(
        business:             @actor.business,
        towel_type:           towel_type,
        branch:               branch,
        status:               status,
        adjustment_type:      "correction",
        original_quantity:    current,
        adjustment_quantity:  adjustment_quantity,
        reason:               reason,
        created_by:           @actor
      )

      unless adjustment.valid?
        return Result.new(ok: false, adjustment: adjustment, error: adjustment.errors.full_messages.to_sentence)
      end

      ActiveRecord::Base.transaction do
        adjustment.save!

        entry = TowelLedgerEntry.create!(
          business:    @actor.business,
          towel_type:  towel_type,
          branch:      branch,
          status:      status,
          direction:   adjustment_quantity.to_d.positive? ? :in : :out,
          reason:      "adjustment",
          quantity:    adjustment_quantity.to_d.abs,
          occurred_at: Time.current,
          source:      adjustment,
          created_by:  @actor
        )

        log_audit(actor: @actor, auditable: adjustment, action: "adjust",
                  metadata: { towel_type_id: towel_type.id, branch_id: branch.id, status: status,
                             original_quantity: current.to_s, adjustment_quantity: adjustment_quantity.to_s,
                             ledger_entry_id: entry.id, reason: reason })
      end

      Result.new(ok: true, adjustment: adjustment)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    # The guided loss/damage path (TowelTransfer no longer records loss —
    # see TowelTransfer's class docs). `quantity` is an unsigned "how many
    # were lost/damaged" count. Always reduces the branch's OPERATIONAL
    # balance directly (dirty at the laundry, clean at a sales branch — see
    # TowelBalances#operational) and records the same quantity into the
    # lost/damaged tracking bucket used by the Towel Balances dashboard — one
    # auditable TowelAdjustment, two ledger entries, posted atomically.
    def record_loss(towel_type:, branch:, adjustment_type:, quantity:, reason:)
      operational_status = branch.branch_type_laundry? ? "dirty" : "clean"
      qty = quantity.to_d.abs
      current = TowelBalances.new(towel_type).at_branch(branch, operational_status)

      adjustment = TowelAdjustment.new(
        business:             @actor.business,
        towel_type:           towel_type,
        branch:               branch,
        status:               operational_status,
        adjustment_type:      adjustment_type,
        original_quantity:    current,
        adjustment_quantity:  -qty,
        reason:               reason,
        created_by:           @actor
      )

      unless adjustment.valid?
        return Result.new(ok: false, adjustment: adjustment, error: adjustment.errors.full_messages.to_sentence)
      end

      ActiveRecord::Base.transaction do
        adjustment.save!

        TowelLedgerEntry.create!(
          business: @actor.business, towel_type: towel_type, branch: branch,
          status: operational_status, direction: :out, reason: "adjustment",
          quantity: qty, occurred_at: Time.current, source: adjustment, created_by: @actor
        )

        TowelLedgerEntry.create!(
          business: @actor.business, towel_type: towel_type, branch: branch,
          status: adjustment_type, direction: :in, reason: LOSS_LEDGER_REASONS.fetch(adjustment_type),
          quantity: qty, occurred_at: Time.current, source: adjustment, created_by: @actor
        )

        log_audit(actor: @actor, auditable: adjustment, action: "adjust",
                  metadata: { towel_type_id: towel_type.id, branch_id: branch.id,
                             adjustment_type: adjustment_type, operational_status: operational_status,
                             original_quantity: current.to_s, quantity: qty.to_s, reason: reason })
      end

      Result.new(ok: true, adjustment: adjustment)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
