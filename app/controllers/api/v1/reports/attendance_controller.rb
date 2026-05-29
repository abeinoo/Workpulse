module Api
  module V1
    module Reports
      class AttendanceController < BaseController
        before_action :require_manager!

        def summary
          branch     = resolve_branch
          start_date = Date.parse(params[:start_date])
          end_date   = Date.parse(params[:end_date])

          result = ::Reports::AttendanceSummary.call(
            business:   current_business,
            branch:     branch,
            start_date: start_date,
            end_date:   end_date
          )
          render_success(result)
        rescue ArgumentError => e
          render_error("Invalid date parameter: #{e.message}")
        end

        private

        def resolve_branch
          return nil if params[:branch_id].blank?

          allowed_branches = current_user.can?(:view_attendance) ?
            current_business.branches :
            Branch.where(id: current_user.branch_ids)

          allowed_branches.find(params[:branch_id])
        end
      end
    end
  end
end
