require "rails_helper"

# Pilot 12 — POS terminals write boundary: the Organization & Access contract
# OrganizationAccess::BranchTerminalSettings and its Finance & Sales
# implementation Finance::BranchPosTerminals (staging rows on the branch; the
# branch's own save persists them). The form behaviour and markup stay pinned by
# spec/characterization/finance_sales/pos_terminal_branch_form{,_markup}_spec.rb.
RSpec.describe OrganizationAccess::BranchTerminalSettings do
  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business) }
  let!(:terminal) { create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-A", label: "Front") }

  # Swaps the registered handler for one example and always restores it.
  def with_handler(handler)
    original = described_class.instance_variable_get(:@handler)
    described_class.instance_variable_set(:@handler, handler)
    yield
  ensure
    described_class.instance_variable_set(:@handler, original)
  end

  describe "registration" do
    it "has the Finance & Sales implementation registered at boot" do
      expect(described_class.handler).to equal(Finance::BranchPosTerminals)
    end

    it "rejects a handler that does not implement every operation, keeping the current one" do
      expect { described_class.register(Module.new) }.to raise_error(ArgumentError, /assign/)
      expect(described_class.handler).to equal(Finance::BranchPosTerminals)
    end

    it "raises NotRegistered instead of silently dropping terminals when no handler is registered" do
      with_handler(nil) do
        expect { described_class.assign(branch: branch, rows: [ { "terminal_id" => "TERM-B" } ]) }
          .to raise_error(described_class::NotRegistered)
      end
    end
  end

  describe "dispatch" do
    let(:handler) { double("handler", assign: :assigned) }
    let(:rows)    { [ { "terminal_id" => "TERM-B" } ] }

    it "passes the branch and rows to the handler and returns its result" do
      with_handler(handler) { expect(described_class.assign(branch: branch, rows: rows)).to eq(:assigned) }

      expect(handler).to have_received(:assign).with(branch: branch, rows: rows)
    end
  end

  describe "Finance::BranchPosTerminals (staging only)" do
    it "stages without writing; the branch's save persists, in one save" do
      expect {
        described_class.assign(branch: branch, rows: [ { "id" => terminal.id, "terminal_id" => "TERM-A", "label" => "Desk" },
                                                       { "terminal_id" => "TERM-B" } ])
      }.not_to(change { PosTerminal.order(:id).pluck(:terminal_id, :label) })

      expect(branch.save).to be(true)
      expect(branch.pos_terminals.reload.order(:terminal_id).pluck(:business_id, :terminal_id, :label))
        .to eq([ [ business.id, "TERM-A", "Desk" ], [ business.id, "TERM-B", nil ] ])
    end

    it "accepts an index-keyed Hash in submitted order, and a single row with an id" do
      described_class.assign(branch: branch, rows: { "1" => { "terminal_id" => "TERM-C" }, "0" => { "terminal_id" => "TERM-B" } })
      expect(branch.pos_terminals.reject(&:persisted?).map(&:terminal_id)).to eq(%w[TERM-C TERM-B])

      other = create(:branch, business: business)
      kept  = create(:pos_terminal, business: business, branch: other, terminal_id: "TERM-K")
      described_class.assign(branch: other, rows: { "id" => kept.id, "terminal_id" => "TERM-K", "_destroy" => "1" })
      expect(other.pos_terminals.detect { |t| t.id == kept.id }).to be_marked_for_destruction
    end

    it "raises ActiveRecord::RecordNotFound for another branch's terminal id" do
      other = create(:pos_terminal, business: business, terminal_id: "TERM-X")

      expect { described_class.assign(branch: branch, rows: [ { "id" => other.id, "terminal_id" => "HIJACK" } ]) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises ArgumentError for rows that are neither a Hash nor an Array" do
      expect { described_class.assign(branch: branch, rows: "nonsense") }.to raise_error(ArgumentError, /Hash or Array/)
    end
  end
end
