module Api
  module V1
    # Pilot endpoint for the standard API contract (docs/api/conventions.md).
    #
    # Backward compatible with the legacy contract: `success` / `data` and the
    # per-advance field set are unchanged (AdvanceSerializer reproduces the old
    # advance_json exactly), the full list is still returned unless the client
    # sends `page` / `per_page`, and error bodies keep the legacy `message` /
    # `errors` keys alongside the new `error` object.
    class AdvancesController < BaseController
      standard_api_contract!

      LIST_QUERY = Api::ListQuery.new(
        filters: {
          status: { column: Advance.arel_table[:status], type: :enum, values: Advance.statuses.keys }
        },
        sorts: {
          "issued_at"        => Advance.arel_table[:issued_at],
          "total_amount"     => Advance.arel_table[:total_amount],
          "remaining_amount" => Advance.arel_table[:remaining_amount]
        },
        default_sort: "-issued_at",
        tiebreaker:   Advance.arel_table[:id]
      )

      before_action :set_advance, only: [ :show ]

      def index
        authorize Advance
        advances = LIST_QUERY.apply(policy_scope(Advance).includes(:user, :employee_request), params)
        advances, pagination = paginate_if_requested(advances)

        render_api_success(AdvanceSerializer.many(advances), meta: pagination ? { pagination: pagination } : {})
      end

      def show
        authorize @advance
        render_api_success(AdvanceSerializer.one(@advance))
      end

      private

      def set_advance
        @advance = policy_scope(Advance).find(params[:id])
      end
    end
  end
end
