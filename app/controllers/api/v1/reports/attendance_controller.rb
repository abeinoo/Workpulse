module Api
  module V1
    module Reports
      class AttendanceController < BaseController
        # Branch visibility for this report follows the caller's configured data
        # scope, most specific first (mirrors ShiftAssignmentsController's
        # scope resolution for employee pickers).
        SCOPE_PERMISSIONS = %i[view_attendance view_employees].freeze

        before_action :require_manager!

        def summary
          branch     = resolve_branch
          start_date = Date.parse(params[:start_date])
          end_date   = Date.parse(params[:end_date])

          result = ::Reports::AttendanceSummary.call(
            business:   current_business,
            branch:     branch,
            branch_ids: branch ? nil : authorized_branch_ids,
            start_date: start_date,
            end_date:   end_date
          )
          render_success(result)
        rescue ArgumentError => e
          render_error("Invalid date parameter: #{e.message}")
        end

        private

        # A requested branch must be in the caller's business AND within their
        # authorized branches; anything else is a 404. business_id is never
        # read from params — the business is always current_business.
        def resolve_branch
          return nil if params[:branch_id].blank?

          branches = current_business.branches
          branches = branches.where(id: authorized_branch_ids) unless authorized_branch_ids.nil?
          # to_s: a non-scalar branch_id (e.g. branch_id[]=…) is a 404, never a multi-branch find.
          branches.find(params[:branch_id].to_s)
        end

        # nil when the caller has business-wide authority (owner, or a
        # configured "business" scope) — they keep the existing business-wide
        # report. Otherwise the branch ids BranchScope grants for the caller's
        # configured scope (default: branches they branch- or area-manage).
        def authorized_branch_ids
          return @authorized_branch_ids if defined?(@authorized_branch_ids)

          scope_type = SCOPE_PERMISSIONS.filter_map { |permission| current_user.scope_for(permission) }.first
          @authorized_branch_ids =
            scope_type == "business" ? nil : BranchScope.new(current_user).for_scope(scope_type)
        end
      end
    end
  end
end
