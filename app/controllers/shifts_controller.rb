class ShiftsController < ApplicationController
  before_action :authenticate_user!

  def show
    @shift = Shift.for_business(current_user.business).find(params[:id])
    authorize @shift
    @penalty_rules = @shift.penalty_rules.ordered_by_threshold
  end
end
