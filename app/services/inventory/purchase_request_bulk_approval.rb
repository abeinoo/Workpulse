module Inventory
  # "اعتماد الطلبات المحددة" — approves several pending Purchase Requests as
  # ONE all-or-nothing operation. Each request still goes through
  # Inventory::PurchaseRequestApproval#approve! (same transition, self-approval
  # rule and audit entry as a single approval); this service only adds the
  # batch guarantees:
  #
  #   - every id must be one of the actor's business's requests;
  #   - the rows are locked (FOR UPDATE, in id order to avoid deadlocks) and
  #     every request must STILL be pending_approval once locked — a request
  #     another approver handled after the page loaded fails the whole batch
  #     instead of being silently skipped;
  #   - any failure rolls back every approval in the batch.
  #
  # A supplier is never required (a request says what to buy, not who from).
  class PurchaseRequestBulkApproval
    MAX_REQUESTS = 100

    Result = Struct.new(:ok, :approved_count, :total_amount, :purchase_requests, :error, keyword_init: true) do
      def ok? = ok
    end

    class BatchError < StandardError; end

    def initialize(purchase_request_ids:, actor:)
      @ids   = Array(purchase_request_ids).map(&:to_s).reject(&:blank?).uniq
      @actor = actor
    end

    def call
      return error(:bulk_none_selected) if @ids.empty?
      return error(:bulk_too_many, max: MAX_REQUESTS) if @ids.size > MAX_REQUESTS

      approved = []
      ActiveRecord::Base.transaction do
        requests = PurchaseRequest.where(business_id: @actor.business_id, id: @ids).order(:id).lock.to_a
        raise BatchError, message(:bulk_unavailable) if requests.size != @ids.size

        stale = requests.reject(&:pending_approval?)
        raise BatchError, message(:bulk_stale, numbers: numbers(stale)) if stale.any?

        own = requests.select { |r| PurchaseRequestApproval.self_approval?(r, @actor) }
        raise BatchError, message(:bulk_self_approval, numbers: numbers(own)) if own.any?

        requests.each do |request|
          result = PurchaseRequestApproval.new(purchase_request_id: request.id, actor: @actor)
                                          .approve!(metadata: { bulk_approval: true, batch_size: requests.size })
          raise BatchError, "#{request.request_number}: #{result.error}" unless result.ok?

          approved << result.purchase_request
        end
      end

      Result.new(ok: true, approved_count: approved.size, purchase_requests: approved,
                 total_amount: PurchaseRequestItem.where(purchase_request_id: approved.map(&:id)).sum(:total_cost))
    rescue BatchError => e
      Result.new(ok: false, approved_count: 0, total_amount: 0, purchase_requests: [], error: e.message)
    end

    private

    def numbers(requests) = requests.map(&:request_number).join("، ")

    def message(key, **args)
      I18n.t("inventory.purchase_requests.errors.#{key}", **args)
    end

    def error(key, **args)
      Result.new(ok: false, approved_count: 0, total_amount: 0, purchase_requests: [], error: message(key, **args))
    end
  end
end
