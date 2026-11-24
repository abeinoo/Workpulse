module Inventory
  # The single writer of products.average_cost_price (product-level moving
  # average across all warehouses), with posting-order semantics (W2):
  #
  #   inflow   (goods receipt, opening balance) at posting:
  #            new = (on_hand × avg + qty × unit_cost) / (on_hand + qty)
  #   reversal of such an inflow (its void), at the void's posting time:
  #            new = (on_hand × avg − qty × unit_cost) / (on_hand − qty)
  #            — the average is left unchanged when no stock remains, or when
  #            the result would be negative (the void still posts)
  #
  # Nothing is ever replayed from history, so a back-dated or voided document
  # never silently re-costs earlier stock. Every change of the stored average
  # writes an InventoryAverageCostChange row in the same transaction (and an
  # AuditLog entry when an actor is known — the actor, else the business
  # owner, the Payroll::AutoGenerator system-actor convention); when either
  # cannot be written the change and the operation that caused it roll back
  # (Decision 17). Callers hold the product row lock (StockAvailability.lock_products!).
  class AverageCost
    include AuditLoggable

    AUDIT_ACTION = "average_cost_changed".freeze

    Outcome = Data.define(:previous, :average, :changed, :note)

    # owner: the system actor when no actor is given (pass it when posting
    # many lines, to read it once); current_average: the average as read
    # under the product lock by the caller (saves a read per line).
    def initialize(product, actor: nil, operation_ref: nil, owner: :lookup, current_average: nil)
      @product         = product
      @actor           = actor
      @operation_ref   = operation_ref
      @owner           = owner
      @current_average = current_average
    end

    # on_hand_before: the product's total on-hand before this inflow's movement.
    def apply_inflow!(quantity:, unit_cost:, on_hand_before:, trigger:, source: nil, movement: nil, last_purchase: false)
      quantity  = quantity.to_d
      unit_cost = unit_cost.to_d
      previous  = stored_average
      return unchanged(previous) unless quantity.positive?

      prior     = on_hand_before.to_d
      new_total = prior + quantity
      average   = new_total.positive? ? ((prior * previous) + (quantity * unit_cost)) / new_total : previous
      write!(previous: previous, average: average, trigger: trigger, source: source, movement: movement,
             on_hand_before: prior, quantity: quantity, unit_cost: unit_cost,
             last_purchase_price: (last_purchase ? unit_cost : nil))
    end

    # on_hand_before: the product's total on-hand before the reversal movement.
    def reverse_inflow!(quantity:, unit_cost:, on_hand_before:, source: nil, movement: nil)
      quantity  = quantity.to_d
      unit_cost = unit_cost.to_d
      previous  = stored_average
      remaining = on_hand_before.to_d - quantity
      return unchanged(previous, :no_stock_left) unless remaining.positive?

      average = ((on_hand_before.to_d * previous) - (quantity * unit_cost)) / remaining
      return unchanged(previous, :would_be_negative) if average.negative?

      write!(previous: previous, average: average, trigger: "document_voided", source: source, movement: movement,
             on_hand_before: on_hand_before.to_d, quantity: -quantity, unit_cost: unit_cost)
    end

    # A recalculated value (Inventory::ProductCostRecalculator).
    def replace!(average:, trigger:, metadata: {})
      write!(previous: stored_average, average: average, trigger: trigger, metadata: metadata)
    end

    private

    def stored_average
      return @current_average.to_d unless @current_average.nil?

      Product.where(id: @product.id).pick(:average_cost_price).to_d
    end

    def system_actor
      @owner == :lookup ? Business.find(@product.business_id).owner : @owner
    end

    def unchanged(previous, note = nil) = Outcome.new(previous: previous, average: previous, changed: false, note: note)

    def write!(previous:, average:, trigger:, source: nil, movement: nil, on_hand_before: nil, quantity: nil,
               unit_cost: nil, last_purchase_price: nil, metadata: {})
      average = average.round(8)
      attrs = {}
      attrs[:average_cost_price]  = average if average != previous
      attrs[:last_purchase_price] = last_purchase_price unless last_purchase_price.nil?
      return unchanged(previous) if attrs.empty?

      attrs[:updated_at] = Time.current
      @product.update_columns(attrs)
      return unchanged(previous) unless attrs.key?(:average_cost_price)

      actor = @actor || system_actor
      change = InventoryAverageCostChange.create!(
        business_id: @product.business_id, product_id: @product.id,
        previous_average_cost: previous, new_average_cost: average,
        on_hand_before: on_hand_before, quantity: quantity, unit_cost: unit_cost,
        trigger: trigger, source: source, inventory_movement: movement,
        operation_ref: @operation_ref || (source && "#{source.class.name}##{source.id}"),
        actor: actor, system: @actor.nil?, metadata: metadata
      )
      if actor
        log_audit!(actor: actor, auditable: @product, action: AUDIT_ACTION,
                   changes: { average_cost_price: [ previous.to_s("F"), average.to_s("F") ] },
                   metadata: { trigger: trigger, system: @actor.nil?, average_cost_change_id: change.id,
                               source_type: source&.class&.name, source_id: source&.id,
                               operation_ref: change.operation_ref }.merge(metadata).compact)
      end
      Outcome.new(previous: previous, average: average, changed: true, note: nil)
    end
  end
end
