# Transfers in Transit / Receiving workspace (Stock Transfer redesign, D12):
# what waits for the current user to dispatch, receive or resolve, plus the
# goods on the road and the recently completed transfers they may see. Every
# list is Inventory::StockTransferQueues — the same relations as the dashboard's
# "Needs action" counts (it is opened from there, not from the navigation). Read-only: each action happens on the transfer's own page, through
# its service.
class Inventory::TransfersInTransitController < Inventory::BaseController
  TABS = %w[to_receive to_dispatch discrepancies in_transit completed].freeze
  LIMIT = 100

  def index
    authorize StockTransfer, :receiving?
    queues = Inventory::StockTransferQueues.for(current_user)
    @counts = {
      "to_dispatch"   => queues.to_dispatch.count,
      "to_receive"    => queues.to_receive.count,
      "discrepancies" => queues.discrepancies.count,
      "in_transit"    => queues.in_transit_visible.count
    }
    @tab = params[:tab].presence_in(TABS) || TABS.find { |tab| @counts[tab].to_i.positive? } || "in_transit"
    relation = case @tab
    when "to_dispatch"   then queues.to_dispatch.order(:approved_at, :id)
    when "to_receive"    then queues.to_receive.order(:dispatched_at, :id)
    when "discrepancies" then queues.discrepancies.order(:updated_at, :id)
    when "completed"     then completed(queues).order(received_at: :desc, id: :desc)
    else queues.in_transit_visible.order(:dispatched_at, :id)
    end
    @stock_transfers = relation.limit(LIMIT).includes({ source_warehouse: :branch }, { destination_warehouse: :branch },
                                                      :created_by, :approved_by, :dispatched_by, :items, :receipts).to_a
    @totals = Inventory::StockTransferProgress.totals_for(@stock_transfers)
  end

  private

  def completed(queues)
    base = queues.in_transit_visible.unscope(where: :status).where(status: "received")
    base.where(received_at: 30.days.ago..)
  end

  def admitted_without_inventory_view? = policy(StockTransfer).receiving?
end
