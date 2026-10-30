require "rails_helper"

# BUG-029 — the Laundry implementation of the deactivation notice: recorded
# ledger balances (clean, dirty, damaged — never disposed or lost) and the open
# documents (dispatched transfers, in-progress batches), read-only.
RSpec.describe Laundry::BranchDeactivationNotice, type: :model do
  let(:business) { create(:business) }
  let(:actor)    { create(:user, business: business) }
  let(:sales)    { create(:branch, business: business, branch_type: "sales", name: "Sales") }
  let(:laundry)  { create(:branch, business: business, branch_type: "laundry", name: "Laundry") }
  let(:bath)     { business.towel_types.create!(name: "Bath Towel") }
  let(:hand)     { business.towel_types.create!(name: "Hand Towel") }

  def fund(branch, status, quantity, type: bath)
    result = Laundry::TowelAdjuster.new(actor: actor).call(towel_type: type, branch: branch, status: status,
                                                           adjustment_quantity: quantity, reason: "setup")
    raise result.error unless result.ok?
  end

  def transfer(source:, destination:, dispatch: true)
    t = Laundry::TowelTransferCreator.create(actor: actor, params: {
      source_branch_id: source.id, destination_branch_id: destination.id,
      towel_status: TowelTransfer.infer_towel_status(source, destination),
      items_attributes: [ { towel_type_id: bath.id, declared_quantity: 1 } ]
    }).transfer
    Laundry::TowelTransferCreator.new(t).dispatch(actor: actor) if dispatch
    t
  end

  def lines_for(branch)
    notices = described_class.notices_for(branch: branch)
    notices.first&.lines.to_a.to_h { |line| [ line.label, line.value ] }
  end

  def balance_label(type, status)
    I18n.t("laundry.deactivation_notice.balance", towel_type: type.name,
                                                  status: I18n.t("laundry.common.towel_statuses.#{status}"))
  end

  it "returns no notice for a branch with nothing recorded" do
    expect(described_class.notices_for(branch: sales)).to eq([])
  end

  it "lists clean, dirty and damaged per towel type, leaving out disposed, lost and zero balances" do
    fund(sales, "clean", 12)
    fund(sales, "dirty", 3)
    fund(sales, "damaged", 2)
    fund(sales, "disposed", 4)
    fund(sales, "lost", 5)
    fund(sales, "clean", 6, type: hand)
    fund(sales, "clean", -6, type: hand)

    notice = described_class.notices_for(branch: sales).sole

    expect(notice.title).to eq(I18n.t("laundry.deactivation_notice.title"))
    expect(notice.summary).to eq(I18n.t("laundry.deactivation_notice.summary"))
    expect(notice.lines.map(&:label)).to eq([ balance_label(bath, "clean"), balance_label(bath, "dirty"),
                                              balance_label(bath, "damaged") ])
    expect(notice.lines.map(&:value)).to eq([ 12, 3, 2 ])
  end

  it "counts transfers dispatched from and to the branch, not drafts or received ones" do
    fund(sales, "clean", 10)
    fund(laundry, "dirty", 10)
    other = create(:branch, business: business, branch_type: "sales", name: "Other")
    2.times { transfer(source: sales, destination: laundry) }
    transfer(source: laundry, destination: sales)
    transfer(source: sales, destination: laundry, dispatch: false)
    received = transfer(source: sales, destination: laundry)
    Laundry::TowelTransferCreator.new(received).receive(actor: actor, confirmed_quantities: { received.items.first.id => 1 })
    transfer(source: laundry, destination: other)

    lines = lines_for(sales)

    expect(lines[I18n.t("laundry.deactivation_notice.transfers_out")]).to eq(2)
    expect(lines[I18n.t("laundry.deactivation_notice.transfers_in")]).to eq(1)
  end

  it "counts batches in progress at the laundry, not drafts" do
    fund(laundry, "dirty", 10)
    started = Laundry::LaundryBatchService.create(actor: actor, laundry_branch_id: laundry.id, towel_type_id: bath.id).batch
    Laundry::LaundryBatchService.new(started).start(actor: actor, input_quantity: 4)
    Laundry::LaundryBatchService.create(actor: actor, laundry_branch_id: laundry.id, towel_type_id: bath.id)

    lines = lines_for(laundry)

    expect(lines[I18n.t("laundry.deactivation_notice.batches_in_progress")]).to eq(1)
    expect(lines[balance_label(bath, "dirty")]).to eq(6)
  end

  it "keeps reporting a branch that is already inactive" do
    fund(sales, "clean", 7)
    sales.update_column(:active, false)

    expect(lines_for(sales)).to eq(balance_label(bath, "clean") => 7)
  end

  it "reads only its own business and branch" do
    fund(laundry, "clean", 9)
    foreign_business = create(:business)
    foreign_branch   = create(:branch, business: foreign_business)
    foreign_actor    = create(:user, business: foreign_business)
    Laundry::TowelAdjuster.new(actor: foreign_actor).call(
      towel_type: foreign_business.towel_types.create!(name: "Bath Towel"), branch: foreign_branch,
      status: "clean", adjustment_quantity: 8, reason: "setup"
    )

    expect(described_class.notices_for(branch: sales)).to eq([])
  end

  it "runs a fixed number of queries, however many towel types are recorded" do
    count_queries = lambda do
      queries = 0
      counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        described_class.notices_for(branch: Branch.find(sales.id))
      end
      queries
    end

    fund(sales, "clean", 1)
    one_type = count_queries.call
    %w[Hand Face Pool].each { |name| fund(sales, "clean", 1, type: business.towel_types.create!(name: name)) }

    expect(count_queries.call).to eq(one_type)
  end

  it "writes nothing" do
    fund(sales, "clean", 5)

    expect { described_class.notices_for(branch: sales) }
      .not_to change { [ TowelLedgerEntry.count, TowelAdjustment.count, AuditLog.count ] }
  end
end
