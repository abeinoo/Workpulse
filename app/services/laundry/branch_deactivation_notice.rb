module Laundry
  # Implements OrganizationAccess::BranchDeactivationNotices (registered in
  # config/initializers/branch_deactivation_notices.rb): what the towel ledger
  # and the laundry documents still record at a branch about to be deactivated
  # (BUG-029). Read-only — it posts nothing and changes no balance.
  #
  # * Recorded on-hand per towel type for clean, dirty and damaged, from the
  #   ledger (TowelBalances.totals_for). Disposed and lost are write-off buckets,
  #   not stock, and are left out. A non-zero balance is shown as recorded, even
  #   a negative one.
  # * Transfers dispatched from / to the branch and not yet received or
  #   cancelled — towels in transit are in neither branch's ledger balance.
  # * Laundry batches in progress at the branch — their dirty input has left the
  #   ledger balance and their output is not posted until completion.
  #
  # Draft transfers and draft batches have no ledger effect and are not counted.
  # One notice, or none when nothing is recorded.
  module BranchDeactivationNotice
    module_function

    STATUSES = %w[clean dirty damaged].freeze

    def notices_for(branch:)
      business = branch.business
      lines    = balance_lines(business, branch) + document_lines(business, branch)
      return [] if lines.empty?

      [ OrganizationAccess::BranchDeactivationNotices::Notice.new(
        title:   I18n.t("laundry.deactivation_notice.title"),
        summary: I18n.t("laundry.deactivation_notice.summary"),
        lines:   lines
      ) ]
    end

    def balance_lines(business, branch)
      totals = TowelBalances.totals_for(business, branch_id: branch.id)
                            .select { |(_, status), quantity| STATUSES.include?(status) && !quantity.zero? }
      return [] if totals.empty?

      names = business.towel_types.where(id: totals.keys.map(&:first)).pluck(:id, :name).to_h
      totals.sort_by { |(type_id, status), _| [ names[type_id].to_s, STATUSES.index(status) ] }.map do |(type_id, status), quantity|
        line(I18n.t("laundry.deactivation_notice.balance", towel_type: names[type_id],
                                                           status: I18n.t("laundry.common.towel_statuses.#{status}")), quantity)
      end
    end

    def document_lines(business, branch)
      in_transit = business.towel_transfers.dispatched
      {
        "transfers_out"       => in_transit.where(source_branch_id: branch.id).count,
        "transfers_in"        => in_transit.where(destination_branch_id: branch.id).count,
        "batches_in_progress" => business.laundry_batches.in_progress.where(laundry_branch_id: branch.id).count
      }.reject { |_, count| count.zero? }.map { |key, count| line(I18n.t("laundry.deactivation_notice.#{key}"), count) }
    end

    def line(label, value) = OrganizationAccess::BranchDeactivationNotices::Line.new(label: label, value: value)
  end
end
