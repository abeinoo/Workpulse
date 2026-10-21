require "rails_helper"

# S2 — Purchase Request advance writes (module-boundaries.md §14.2 #6): the
# Inventory & Purchasing contract Inventory::PurchaseRequestAdvanceEffects. The
# behaviour of the recorder, workflow and form stays pinned by
# spec/characterization/inventory_purchasing/purchase_request_advance_{payments,concurrency}_spec.rb.
RSpec.describe Inventory::PurchaseRequestAdvanceEffects do
  let(:actor)        { instance_double(User) }
  let(:advance)      { instance_double(PurchaseRequestAdvance) }
  let(:option)       { described_class::CustodyAccountOption.new(id: 3, holder_name: "Ahmed", balance: 50) }
  let(:confirmation) { described_class::Confirmation.new(status: :confirmed, settlement_id: 7) }
  let(:reversal)     { described_class::Reversal.new(settlement_id: 7, reversal_id: 8) }

  def handler_with(**results)
    defaults = { custody_account_options: [ option ], selectable_custody_account_id: 3,
                 advance_confirmed: confirmation, advance_reversed: reversal }
    double("handler", **defaults.merge(results))
  end

  # Swaps the registered handler for one example and always restores it.
  def with_handler(handler)
    original = described_class.instance_variable_get(:@handler)
    described_class.instance_variable_set(:@handler, handler)
    yield
  ensure
    described_class.instance_variable_set(:@handler, original)
  end

  def calls
    {
      custody_account_options:       -> { described_class.custody_account_options(actor: actor) },
      selectable_custody_account_id: -> { described_class.selectable_custody_account_id(actor: actor, custody_account_id: "3") },
      advance_confirmed:             -> { described_class.advance_confirmed(advance: advance, actor: actor) },
      advance_reversed:              -> { described_class.advance_reversed(advance: advance, actor: actor, reason: "refund") }
    }
  end

  describe "operations and value objects" do
    it "lists the four operations" do
      expect(described_class::OPERATIONS)
        .to eq(%i[custody_account_options selectable_custody_account_id advance_confirmed advance_reversed])
    end

    it "the value objects carry exactly what Inventory reads" do
      expect(described_class::CustodyAccountOption.members).to eq(%i[id holder_name balance])
      expect(described_class::Confirmation.members).to eq(%i[status settlement_id])
      expect(described_class::Reversal.members).to eq(%i[settlement_id reversal_id])
      expect(described_class::CONFIRMATION_STATUSES).to eq(%i[confirmed custody_account_inactive])
      expect(confirmation).to be_confirmed
      expect(described_class::Confirmation.new(status: :custody_account_inactive)).not_to be_confirmed
    end
  end

  describe "registration" do
    it "has the Finance & Sales implementation registered at boot" do
      expect(described_class.handler).to equal(Finance::PurchaseRequestAdvanceEffects)
    end

    it "rejects a handler that does not implement every operation, keeping the current one" do
      partial = Module.new { def self.advance_confirmed(**) = nil }

      with_handler(:current) do
        expect { described_class.register(partial) }
          .to raise_error(ArgumentError, /custody_account_options, selectable_custody_account_id, advance_reversed/)
        expect(described_class.handler).to eq(:current)
      end
    end

    it "raises NotRegistered for every operation when no handler is registered" do
      with_handler(nil) do
        calls.each_value { |call| expect { call.call }.to raise_error(described_class::NotRegistered) }
      end
    end
  end

  describe "dispatch" do
    it "passes every argument through and returns the handler's result" do
      handler = handler_with
      with_handler(handler) do
        expect(calls[:custody_account_options].call).to eq([ option ])
        expect(calls[:selectable_custody_account_id].call).to eq(3)
        expect(calls[:advance_confirmed].call).to equal(confirmation)
        expect(calls[:advance_reversed].call).to equal(reversal)
      end
      expect(handler).to have_received(:custody_account_options).with(actor: actor)
      expect(handler).to have_received(:selectable_custody_account_id).with(actor: actor, custody_account_id: "3")
      expect(handler).to have_received(:advance_confirmed).with(advance: advance, actor: actor)
      expect(handler).to have_received(:advance_reversed).with(advance: advance, actor: actor, reason: "refund")
    end

    it "accepts nil from selectable_custody_account_id and an inactive Confirmation without a settlement" do
      inactive = described_class::Confirmation.new(status: :custody_account_inactive)
      with_handler(handler_with(selectable_custody_account_id: nil, advance_confirmed: inactive)) do
        expect(calls[:selectable_custody_account_id].call).to be_nil
        expect(calls[:advance_confirmed].call).to equal(inactive)
      end
    end

    it "propagates a handler's RecordInvalid unchanged (the caller's transaction rolls back)" do
      error = ActiveRecord::RecordInvalid.new(FinancialSettlement.new)
      handler = handler_with
      allow(handler).to receive(:advance_confirmed).and_raise(error)
      with_handler(handler) { expect { calls[:advance_confirmed].call }.to raise_error(error) }
    end
  end

  describe "result checks" do
    {
      custody_account_options:       [ [ { id: 3 } ], "not an Array" ],
      selectable_custody_account_id: [ "3", 3.0 ],
      advance_confirmed:             [ nil, Struct.new(:status).new(:confirmed),
                                       Inventory::PurchaseRequestAdvanceEffects::Confirmation.new(status: :done, settlement_id: 7),
                                       Inventory::PurchaseRequestAdvanceEffects::Confirmation.new(status: :confirmed),
                                       Inventory::PurchaseRequestAdvanceEffects::Confirmation.new(status: :custody_account_inactive,
                                                                                                  settlement_id: 7) ],
      advance_reversed:              [ nil, Inventory::PurchaseRequestAdvanceEffects::Reversal.new(settlement_id: 7) ]
    }.each do |operation, bad_results|
      it "#{operation} refuses a result of the wrong shape" do
        bad_results.each do |bad|
          with_handler(handler_with(operation => bad)) do
            expect { calls[operation].call }.to raise_error(ArgumentError, /#{operation}/)
          end
        end
      end
    end
  end

  it "names nothing from Finance & Sales" do
    source = File.read(Rails.root.join("app/services/inventory/purchase_request_advance_effects.rb"))
    code   = source.lines.grep_v(/^\s*#/).join
    expect(code).not_to match(/\bFinance(::|Settlement)|\bCustody(Account|Transaction)(Policy)?\b|custody_transactions|refresh_balance/)
  end
end
