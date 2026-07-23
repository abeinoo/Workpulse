# Towel balances across every branch — the "Branch Dashboard" from the plan:
# filtering to a single branch (which is all a branch-scoped user can see,
# since branches are enforced via assignable_branches) answers "how many clean
# towels do I have, how many are dirty, in transit, etc." for that branch.
#
# Default view (no towel_type_id) is "All towel types" — one section per type,
# batched in two aggregate queries via Laundry::TowelBalances.batch_rows_for
# rather than looping the single-type calculator per towel type.
class Laundry::TowelBalancesController < Laundry::BaseController
  def index
    unless current_user.can?(:view_towel_balances)
      return redirect_to root_path, alert: t("flash.not_authorized")
    end

    @branches = assignable_branches
    @towel_types = laundry_towel_types
    @selected_towel_type = @towel_types.find_by(id: params[:towel_type_id]) if params[:towel_type_id].present?
    @can_view_details = current_user.owner? || current_user.can?(:adjust_towel_balances)

    if @selected_towel_type
      balances = Laundry::TowelBalances.new(@selected_towel_type)
      @rows = @branches.map do |branch|
        by_status = balances.by_status_for_branch(branch)
        { branch: branch,
          operational: balances.operational(branch),
          clean: by_status["clean"] || 0, dirty: by_status["dirty"] || 0,
          damaged: by_status["damaged"] || 0, disposed: by_status["disposed"] || 0,
          lost: by_status["lost"] || 0,
          in_transit_out: balances.in_transit(branch: branch.id) }
      end
    else
      @rows_by_towel_type = Laundry::TowelBalances.batch_rows_for(@towel_types, @branches)
    end
  end
end
