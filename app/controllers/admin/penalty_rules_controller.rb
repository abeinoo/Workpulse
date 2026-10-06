class Admin::PenaltyRulesController < Admin::BaseController
  # Every action authorizes with PenaltyRulePolicy (manage_shifts) — SEC-M2-3.
  # Rules are only reachable through a shift of current_user's business.
  before_action :set_shift

  def new
    @rule = @shift.penalty_rules.build
    authorize @rule
  end

  def create
    @rule = @shift.penalty_rules.build(rule_params)
    authorize @rule
    if @rule.save
      redirect_to admin_shift_path(@shift), notice: t("flash.penalty_rule_added")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @rule = find_rule
    authorize @rule
  end

  def update
    @rule = find_rule
    authorize @rule
    if @rule.update(rule_params)
      redirect_to admin_shift_path(@shift), notice: t("flash.penalty_rule_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @rule = find_rule
    authorize @rule
    @rule.destroy
    redirect_to admin_shift_path(@shift), notice: t("flash.penalty_rule_removed")
  end

  private

  def set_shift
    @shift = Shift.find_by!(business_id: current_user.business_id, id: params[:shift_id])
  end

  def find_rule
    @shift.penalty_rules.find(params[:id])
  end

  def rule_params
    params.require(:penalty_rule).permit(:rule_type, :threshold_minutes, :deduction_type, :deduction_value)
  end
end
