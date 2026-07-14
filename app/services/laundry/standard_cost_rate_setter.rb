module Laundry
  # Single entry point for changing the standard laundry-service cost per
  # towel — set independently for each towel type. Always INSERTS a new
  # LaundryStandardCostRate row scoped to that towel type — existing rows are
  # never edited or deleted, so historical branch-consumption reports keep
  # resolving to whatever rate was effective for that towel type at the time
  # (see LaundryStandardCostRate.effective_for).
  class StandardCostRateSetter
    include AuditLoggable

    Result = Struct.new(:ok, :rate, :error, keyword_init: true) { def ok? = ok }

    def self.call(actor:, towel_type:, cost_per_towel:, effective_from: Time.current)
      rate = actor.business.laundry_standard_cost_rates.new(
        towel_type: towel_type,
        cost_per_towel: cost_per_towel,
        effective_from: effective_from,
        created_by: actor
      )

      if rate.save
        new.log_audit(actor: actor, auditable: rate, action: "set_rate",
                      metadata: { towel_type_id: towel_type.id, cost_per_towel: rate.cost_per_towel.to_s,
                                 effective_from: rate.effective_from })
        Result.new(ok: true, rate: rate)
      else
        Result.new(ok: false, rate: rate, error: rate.errors.full_messages.to_sentence)
      end
    end
  end
end
