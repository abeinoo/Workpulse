# Towel balances across every branch — the "Branch Dashboard" from the plan:
# filtering to a single branch (which is all a branch-scoped user can see,
# since branches are enforced via assignable_branches) answers "how many clean
# towels do I have, how many are dirty, in transit, etc." for that branch.
class Laundry::TowelBalancesController < Laundry::BaseController
  def index
    unless current_user.can?(:view_towel_balances)
      return redirect_to root_path, alert: t("flash.not_authorized")
    end

    @towel_type = current_user.business.towel_types.active.find_by(id: params[:towel_type_id]) ||
                  current_user.business.towel_types.active.first
    @branches = assignable_branches
    @towel_types = laundry_towel_types

    if @towel_type
      balances = Laundry::TowelBalances.new(@towel_type)
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
      @rows = []
    end

    @can_view_details = current_user.owner? || current_user.can?(:adjust_towel_balances)
  end
end
