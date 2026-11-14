require "rails_helper"

# S2 — Purchase Request advance writes (module-boundaries.md §14.2 #6): the
# Inventory & Purchasing contract Inventory::PurchaseRequestAdvanceEffects.
# Since 2026-11-13 an advance FUNDS the request's responsible employee's custody
# (advance_funded / advance_funding_reversed); advance_reversed remains for
# legacy supplier-payment advances. The behaviour through the services is
# pinned by purchase_request_advance_funding_spec.rb and the S2 characterization.
RSpec.describe Inventory::PurchaseRequestAdvanceEffects do
  let(:actor)    { instance_double(User) }
  let(:advance)  { instance_double(PurchaseRequestAdvance) }
  let(:option)   { described_class::CustodyAccountOption.new(id: 3, holder_name: "Ahmed", balance: 50) }
  let(:employee) { described_class::ResponsibleEmployeeOption.new(user_id: 9, name: "Mona", custody_account_id: 4, balance: 10) }
  let(:funding)  { described_class::Funding.new(status: :confirmed, transaction_id: 11, counterparty_id: 12) }
  let(:company)  { described_class::Funding.new(status: :confirmed, transaction_id: 13) }
  let(:reversal) { described_class::Reversal.new(settlement_id: 7, reversal_id: 8) }

  def handler_with(**results)
    defaults = { custody_account_options: [ option ], selectable_custody_account_id: 3,
                 responsible_employee_options: [ employee ], responsible_custody_account_id: 4,
                 lock_funding_accounts: nil, advance_funded: funding, advance_funding_reversed: company, advance_reversed: reversal }
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
      custody_account_options:        -> { described_class.custody_account_options(actor: actor) },
      selectable_custody_account_id:  -> { described_class.selectable_custody_account_id(actor: actor, custody_account_id: "3") },
      responsible_employee_options:   -> { described_class.responsible_employee_options(actor: actor) },
      responsible_custody_account_id: -> { described_class.responsible_custody_account_id(business_id: 1, user_id: 9) },
      lock_funding_accounts:          -> { described_class.lock_funding_accounts(business_id: 1, custody_account_ids: [ 3, 4 ]) },
      advance_funded:                 -> { described_class.advance_funded(advance: advance, actor: actor) },
      advance_funding_reversed:       -> { described_class.advance_funding_reversed(advance: advance, actor: actor, reason: "refund") },
      advance_reversed:               -> { described_class.advance_reversed(advance: advance, actor: actor, reason: "refund") }
    }
  end

  describe "operations and value objects" do
    it "lists the operations" do
      expect(described_class::OPERATIONS)
        .to eq(%i[custody_account_options selectable_custody_account_id
                  responsible_employee_options responsible_custody_account_id
                  lock_funding_accounts advance_funded advance_funding_reversed advance_reversed])
    end

    it "the value objects carry exactly what Inventory reads" do
      expect(described_class::CustodyAccountOption.members).to eq(%i[id holder_name balance])
      expect(described_class::ResponsibleEmployeeOption.members).to eq(%i[user_id name custody_account_id balance])
      expect(described_class::Funding.members).to eq(%i[status transaction_id counterparty_id])
      expect(described_class::Reversal.members).to eq(%i[settlement_id reversal_id])
      expect(described_class::FUNDING_STATUSES).to eq(%i[confirmed custody_account_inactive employee_ineligible])
      expect(funding).to be_confirmed
      expect(described_class::Funding.new(status: :employee_ineligible)).not_to be_confirmed
    end
  end

  describe "registration" do
    it "has the Finance & Sales implementation registered at boot" do
      expect(described_class.handler).to equal(Finance::PurchaseRequestAdvanceEffects)
    end

    it "rejects a handler that does not implement every operation, keeping the current one" do
      partial = Module.new { def self.advance_funded(**) = nil }

      with_handler(:current) do
        expect { described_class.register(partial) }
          .to raise_error(ArgumentError, /custody_account_options, selectable_custody_account_id, responsible_employee_options/)
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
        expect(calls[:responsible_employee_options].call).to eq([ employee ])
        expect(calls[:responsible_custody_account_id].call).to eq(4)
        expect(calls[:advance_funded].call).to equal(funding)
        expect(calls[:advance_funding_reversed].call).to equal(company)
        expect(calls[:advance_reversed].call).to equal(reversal)
      end
      expect(handler).to have_received(:selectable_custody_account_id).with(actor: actor, custody_account_id: "3")
      expect(handler).to have_received(:responsible_custody_account_id).with(business_id: 1, user_id: 9)
      expect(handler).to have_received(:advance_funded).with(advance: advance, actor: actor)
      expect(handler).to have_received(:advance_funding_reversed).with(advance: advance, actor: actor, reason: "refund")
      expect(handler).to have_received(:advance_reversed).with(advance: advance, actor: actor, reason: "refund")
    end

    it "accepts nil ids and a refusal Funding without rows" do
      refusal = described_class::Funding.new(status: :custody_account_inactive)
      with_handler(handler_with(selectable_custody_account_id: nil, responsible_custody_account_id: nil,
                                advance_funded: refusal)) do
        expect(calls[:selectable_custody_account_id].call).to be_nil
        expect(calls[:responsible_custody_account_id].call).to be_nil
        expect(calls[:advance_funded].call).to equal(refusal)
      end
    end

    it "propagates a handler's RecordInvalid unchanged (the caller's transaction rolls back)" do
      error = ActiveRecord::RecordInvalid.new(CustodyTransaction.new)
      handler = handler_with
      allow(handler).to receive(:advance_funded).and_raise(error)
      with_handler(handler) { expect { calls[:advance_funded].call }.to raise_error(error) }
    end
  end

  describe "result checks" do
    funding = Inventory::PurchaseRequestAdvanceEffects::Funding
    {
      custody_account_options:        [ [ { id: 3 } ], "not an Array" ],
      selectable_custody_account_id:  [ "3", 3.0 ],
      responsible_employee_options:   [ [ Inventory::PurchaseRequestAdvanceEffects::CustodyAccountOption.new(id: 1) ], nil ],
      responsible_custody_account_id: [ "4", 4.0 ],
      advance_funded:           [ nil, Struct.new(:status).new(:confirmed), funding.new(status: :done, transaction_id: 1),
                                  funding.new(status: :confirmed), funding.new(status: :confirmed, transaction_id: 1, counterparty_id: "2"),
                                  funding.new(status: :employee_ineligible, transaction_id: 1) ],
      advance_funding_reversed: [ nil, funding.new(status: :custody_account_inactive), funding.new(status: :confirmed) ],
      advance_reversed:         [ nil, Inventory::PurchaseRequestAdvanceEffects::Reversal.new(settlement_id: 7) ]
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
