module Adjustments
  # Validates and saves multiple PayrollAdjustment rows in a single transaction.
  # On any validation failure the whole batch is rejected (no partial saves).
  # All saved records share the same bulk_batch_id UUID for audit purposes.
  #
  # Security: every submitted user_id is validated against `allowed_user_ids`
  # (the creator's scoped employee set) server-side before processing. This is the
  # authoritative scope guard — it never trusts that the picker or CSV preview was
  # filtered, so a hand-crafted POST with an out-of-scope user_id is rejected.
  # `allowed_user_ids` is required precisely so a caller cannot silently bypass it.
  class BulkCreateService
    RowError = Struct.new(:index, :messages, keyword_init: true)

    Result = Struct.new(
      :success, :count, :batch_id, :row_errors,
      keyword_init: true
    ) do
      def success? = success
      def failed?  = !success
    end

    EMPTY_RESULT = Result.new(success: false, count: 0, batch_id: nil, row_errors: []).freeze

    def initialize(rows:, business:, created_by:, allowed_user_ids:, import_source: "manual")
      @rows             = Array(rows).reject { |r| row_blank?(r) }
      @business         = business
      @created_by       = created_by
      @allowed_user_ids = Array(allowed_user_ids).map(&:to_i).to_set
      @import_source    = import_source
    end

    def call
      return EMPTY_RESULT if @rows.empty?

      batch_id = SecureRandom.uuid

      # Bulk and CSV-imported adjustments always start Pending. The creator never
      # approves their own entries — a separate approver must review them.
      adjustments = @rows.each_with_index.map do |row, idx|
        build_adjustment(row, batch_id)
          .tap { |adj| adj.instance_variable_set(:@_row_index, idx) }
      end

      row_errors = collect_errors(adjustments)
      return Result.new(success: false, count: 0, batch_id: nil, row_errors: row_errors) if row_errors.any?

      saved_count = 0
      PayrollAdjustment.transaction do
        adjustments.each do |adj|
          adj.save!
          saved_count += 1
        end
      end

      Result.new(success: true, count: saved_count, batch_id: batch_id, row_errors: [])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, count: 0, batch_id: nil,
                 row_errors: [ RowError.new(index: nil, messages: [ e.message ]) ])
    end

    private

    def build_adjustment(row, batch_id)
      PayrollAdjustment.new(
        user_id:         row[:user_id].presence || row["user_id"],
        adjustment_type: row[:adjustment_type].presence || row["adjustment_type"],
        amount:          row[:amount].presence || row["amount"],
        reason:          (row[:reason].presence || row["reason"])&.strip,
        period_month:    row[:period_month].presence || row["period_month"],
        period_year:     row[:period_year].presence || row["period_year"],
        business:        @business,
        created_by:      @created_by,
        bulk_batch_id:   batch_id,
        import_source:   @import_source,
        review_status:   "pending_review"
      )
    end

    def collect_errors(adjustments)
      adjustments.filter_map.with_index do |adj, idx|
        row_idx  = adj.instance_variable_get(:@_row_index) || idx
        messages = []
        # Scope guard first: an out-of-scope (or missing) user_id is rejected
        # regardless of what the picker/CSV preview showed.
        if !in_scope?(adj.user_id)
          messages << I18n.t("bulk_adjustments.errors.out_of_scope")
        elsif !adj.valid?
          messages.concat(adj.errors.full_messages)
        end
        next if messages.empty?
        RowError.new(index: row_idx, messages: messages)
      end
    end

    def in_scope?(user_id)
      user_id.present? && @allowed_user_ids.include?(user_id.to_i)
    end

    def row_blank?(row)
      row[:user_id].blank? && row["user_id"].blank? &&
        row[:amount].blank? && row["amount"].blank?
    end
  end
end
