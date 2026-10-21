require "rails_helper"

# Batch S — goods-receipt payment writes (module-boundaries.md §14.2 #6): the
# Inventory & Purchasing contract Inventory::GoodsReceiptPaymentEffects. The
# current behaviour of the four goods-receipt services stays pinned by
# spec/characterization/inventory_purchasing/goods_receipt_payments_spec.rb.
RSpec.describe Inventory::GoodsReceiptPaymentEffects do
  let(:receipt) { instance_double(GoodsReceipt) }
  let(:actor)   { instance_double(User) }
  let(:advance) { instance_double(PurchaseRequestAdvance) }
  let(:payment) { described_class::Payment.new(settlement: :opaque, settlement_id: 7, reference: "INV-9", custody_account_id: 3, employee_id: 4) }
  let(:reversal) do
    described_class::Reversal.new(status: :reversed, settlement: :opaque, settlement_id: 7, reversal_id: 8, amount: 80,
                                  source_kind: "employee_custody", funding_source_id: 3)
  end

  def handler_with(**results)
    defaults = { custody_account_active?: true, approval_payment: :ignored, advance_applied: :ignored,
                 payment_source_kind?: true, payer_custody_account_id: 3, record_settlement: payment,
                 reverse_settlement: reversal, reverse_all: :ignored }
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
      custody_account_active?:  -> { described_class.custody_account_active?(receipt: receipt) },
      approval_payment:         -> { described_class.approval_payment(receipt: receipt, amount: 150, actor: actor) },
      advance_applied:          lambda {
        described_class.advance_applied(receipt: receipt, advance: advance, amount: 100, actor: actor, reference: "PR-1", notes: "n")
      },
      payment_source_kind?:     -> { described_class.payment_source_kind?("company_cash") },
      payer_custody_account_id: -> { described_class.payer_custody_account_id(actor: actor) },
      record_settlement:        lambda {
        described_class.record_settlement(receipt: receipt, actor: actor, source_kind: "employee_custody", custody_account_id: 3,
                                          amount: 80, reference: "INV-9", notes: "part", settled_at: Date.new(2026, 10, 20))
      },
      reverse_settlement:       -> { described_class.reverse_settlement(receipt: receipt, settlement_id: 7, actor: actor, reason: "r") },
      reverse_all:              -> { described_class.reverse_all(receipt: receipt, actor: actor, notes: "n") }
    }
  end

  describe "operations and value objects" do
    it "lists the eight operations" do
      expect(described_class::OPERATIONS).to eq(
        %i[custody_account_active? approval_payment advance_applied payment_source_kind? payer_custody_account_id
           record_settlement reverse_settlement reverse_all]
      )
    end

    it "Payment and Reversal carry exactly what the Inventory services read" do
      expect(described_class::Payment.members).to eq(%i[settlement settlement_id reference custody_account_id employee_id])
      expect(described_class::Reversal.members)
        .to eq(%i[status settlement settlement_id reversal_id amount source_kind funding_source_id])
      expect(described_class::REVERSAL_STATUSES).to eq(%i[reversed already_reversed advance_application])
      expect(reversal).to be_reversed
      expect(described_class::Reversal.new(status: :already_reversed)).not_to be_reversed
    end
  end

  describe "registration" do
    it "has the Finance & Sales implementation registered at boot" do
      expect(described_class.handler).to equal(Finance::GoodsReceiptPaymentEffects)
    end

    it "rejects a handler that does not implement every operation, keeping the current one" do
      partial = Module.new { def self.approval_payment(**) = nil }

      with_handler(:current) do
        expect { described_class.register(partial) }.to raise_error(ArgumentError, /custody_account_active\?, advance_applied/)
        expect(described_class.handler).to eq(:current)
      end
    end

    it "accepts a complete handler" do
      handler = handler_with
      with_handler(nil) do
        described_class.register(handler)
        expect(described_class.handler).to equal(handler)
      end
    end

    it "raises NotRegistered for every operation when no handler is registered" do
      with_handler(nil) do
        calls.each { |operation, call| expect { call.call }.to raise_error(described_class::NotRegistered), operation.to_s }
      end
    end
  end

  describe "dispatch" do
    it "passes every argument through and returns the handler's results (nil for the write-only operations)" do
      handler = handler_with
      with_handler(handler) do
        expect(calls.transform_values(&:call)).to eq(
          custody_account_active?: true, approval_payment: nil, advance_applied: nil, payment_source_kind?: true,
          payer_custody_account_id: 3, record_settlement: payment, reverse_settlement: reversal, reverse_all: nil
        )
      end

      expect(handler).to have_received(:custody_account_active?).with(receipt: receipt)
      expect(handler).to have_received(:approval_payment).with(receipt: receipt, amount: 150, actor: actor)
      expect(handler).to have_received(:advance_applied)
        .with(receipt: receipt, advance: advance, amount: 100, actor: actor, reference: "PR-1", notes: "n")
      expect(handler).to have_received(:payment_source_kind?).with("company_cash")
      expect(handler).to have_received(:payer_custody_account_id).with(actor: actor)
      expect(handler).to have_received(:record_settlement)
        .with(receipt: receipt, actor: actor, source_kind: "employee_custody", custody_account_id: 3, amount: 80,
              reference: "INV-9", notes: "part", settled_at: Date.new(2026, 10, 20))
      expect(handler).to have_received(:reverse_settlement).with(receipt: receipt, settlement_id: 7, actor: actor, reason: "r")
      expect(handler).to have_received(:reverse_all).with(receipt: receipt, actor: actor, notes: "n")
    end

    it "accepts a nil payer custody account and every reversal status" do
      with_handler(handler_with(payer_custody_account_id: nil)) do
        expect(described_class.payer_custody_account_id(actor: actor)).to be_nil
      end
      described_class::REVERSAL_STATUSES.each do |status|
        refused = described_class::Reversal.new(status: status)
        with_handler(handler_with(reverse_settlement: refused)) do
          expect(described_class.reverse_settlement(receipt: receipt, settlement_id: 7, actor: actor, reason: "r")).to equal(refused)
        end
      end
    end

    it "rejects a result of the wrong type, naming the operation" do
      {
        custody_account_active?:  { custody_account_active?: nil },
        payment_source_kind?:     { payment_source_kind?: "yes" },
        payer_custody_account_id: { payer_custody_account_id: "3" },
        record_settlement:        { record_settlement: :settlement },
        reverse_settlement:       { reverse_settlement: described_class::Reversal.new(status: :done) }
      }.each do |operation, result|
        with_handler(handler_with(**result)) do
          expect { calls.fetch(operation).call }
            .to raise_error(ArgumentError, /\.#{Regexp.escape(operation.to_s)} returned/), operation.to_s
        end
      end
    end

    it "propagates a handler error (RecordInvalid rolls the caller back)" do
      handler = handler_with
      allow(handler).to receive(:approval_payment).and_raise(ActiveRecord::RecordInvalid.new(GoodsReceipt.new))
      allow(handler).to receive(:reverse_settlement).and_raise(ActiveRecord::RecordNotFound)

      with_handler(handler) do
        expect { calls.fetch(:approval_payment).call }.to raise_error(ActiveRecord::RecordInvalid)
        expect { calls.fetch(:reverse_settlement).call }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  it "names nothing from Finance & Sales (code only, comments excluded)" do
    code = File.readlines(Rails.root.join("app/services/inventory/goods_receipt_payment_effects.rb"))
               .reject { |line| line.lstrip.start_with?("#") }.join
    forbidden = /\bFinance::|\b(?:FinancialSettlement|FinancialSettlementService|CustodyAccount|CustodyTransaction)\b/
    expect(code.scan(forbidden)).to be_empty
  end
end
