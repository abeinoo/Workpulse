module Api
  # Allowlisted filtering, sorting and search for API collections
  # (see docs/api/conventions.md → "Filtering, sorting, search").
  #
  #   LIST_QUERY = Api::ListQuery.new(
  #     filters: {
  #       status:      { column: Advance.arel_table[:status],    type: :enum, values: %w[active fully_repaid] },
  #       issued_from: { column: Advance.arel_table[:issued_at], type: :date, operator: :gteq }
  #     },
  #     sorts:        { "issued_at" => Advance.arel_table[:issued_at] },
  #     default_sort: "-issued_at",
  #     tiebreaker:   Advance.arel_table[:id],
  #     search:       [ User.arel_table[:first_name] ]   # relation must already join these tables
  #   )
  #
  #   LIST_QUERY.apply(policy_scope(Advance), params)
  #
  # Query params: `filter[<name>]=value` (arrays allowed for eq filters),
  # `sort=-issued_at,total_amount`, `q=text`.
  #
  # Safety rules:
  # * Only configured filters/sorts/search columns are usable; anything else
  #   raises Api::Errors::BadRequest (never silently ignored, never
  #   interpolated). Columns are Arel attributes, values are bound parameters.
  # * `apply` only ever adds WHERE / ORDER BY to the relation it is given, so
  #   it can narrow but never widen a policy scope — the caller must always
  #   pass an already-scoped relation (policy_scope / current_business.…).
  # * No business rules live here: this is request-parameter plumbing only.
  class ListQuery
    FILTER_TYPES      = %i[enum integer date boolean string].freeze
    OPERATORS         = %i[eq gteq lteq].freeze
    MAX_SORT_FIELDS   = 3
    MAX_SEARCH_LENGTH = 100
    MAX_STRING_LENGTH = 255
    MAX_LIST_VALUES   = 50
    BOOLEAN_VALUES    = { "true" => true, "false" => false }.freeze

    attr_reader :filters, :sorts, :default_sort, :search_columns

    def initialize(tiebreaker:, filters: {}, sorts: {}, default_sort: nil, search: [])
      @filters        = filters.transform_keys(&:to_s).transform_values { |spec| normalize_filter_spec(spec) }.freeze
      @sorts          = sorts.transform_keys(&:to_s).freeze
      @tiebreaker     = tiebreaker
      @search_columns = Array(search).freeze
      @default_sort   = default_sort
      parse_sort(default_sort) if default_sort # fail fast on a misconfigured default
    end

    def apply(relation, params)
      relation = apply_filters(relation, params[:filter])
      relation = apply_search(relation, params[:q])
      apply_sort(relation, params[:sort])
    end

    private

    # ── Filters ──────────────────────────────────────────────────────────────

    def normalize_filter_spec(spec)
      type     = spec.fetch(:type)
      operator = spec.fetch(:operator, :eq)
      raise ArgumentError, "unknown filter type #{type.inspect}"         unless FILTER_TYPES.include?(type)
      raise ArgumentError, "unknown filter operator #{operator.inspect}" unless OPERATORS.include?(operator)
      raise ArgumentError, "enum filters need :values"                   if type == :enum && spec[:values].blank?

      spec.merge(operator: operator, values: Array(spec[:values]).map(&:to_s)).freeze
    end

    def apply_filters(relation, raw)
      return relation if raw.nil?

      unless raw.respond_to?(:to_unsafe_h) || raw.is_a?(Hash)
        raise bad_request("filter", "invalid", I18n.t("api.errors.invalid_filter_format"))
      end

      raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      raw.each do |name, value|
        spec = filters[name.to_s]
        raise bad_request("filter[#{name}]", "unknown_filter", I18n.t("api.errors.unknown_filter", name: name)) unless spec

        relation = relation.where(filter_condition(name, spec, value))
      end
      relation
    end

    def filter_condition(name, spec, value)
      column = spec[:column]

      if value.is_a?(Array)
        unless spec[:operator] == :eq && value.size.between?(1, MAX_LIST_VALUES)
          raise bad_request("filter[#{name}]", "invalid", I18n.t("api.errors.invalid_filter_value", name: name))
        end
        return column.in(value.map { |v| cast_filter_value(name, spec, v) })
      end

      column.public_send(spec[:operator], cast_filter_value(name, spec, value))
    end

    def cast_filter_value(name, spec, value)
      invalid = -> { raise bad_request("filter[#{name}]", "invalid", I18n.t("api.errors.invalid_filter_value", name: name)) }
      invalid.call if value.is_a?(Hash) || value.respond_to?(:to_unsafe_h)

      string = value.to_s.strip
      case spec[:type]
      when :enum    then spec[:values].include?(string) ? string : invalid.call
      when :integer then Integer(string, 10, exception: false) || invalid.call
      when :boolean then BOOLEAN_VALUES.fetch(string) { invalid.call }
      when :string  then string.present? && string.length <= MAX_STRING_LENGTH ? string : invalid.call
      when :date
        begin
          Date.iso8601(string)
        rescue ArgumentError, Date::Error
          invalid.call
        end
      end
    end

    # ── Search ───────────────────────────────────────────────────────────────

    def apply_search(relation, raw)
      return relation if raw.nil?

      term = raw.to_s.strip
      return relation if term.empty?

      raise bad_request("q", "unsupported", I18n.t("api.errors.search_not_supported")) if search_columns.empty?
      if term.length > MAX_SEARCH_LENGTH
        raise bad_request("q", "too_long", I18n.t("api.errors.search_too_long", count: MAX_SEARCH_LENGTH))
      end

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
      relation.where(search_columns.map { |column| column.matches(pattern) }.reduce(:or))
    end

    # ── Sorting ──────────────────────────────────────────────────────────────

    def apply_sort(relation, raw)
      raw = default_sort if raw.to_s.strip.empty?
      return relation if raw.nil?

      orders = parse_sort(raw)
      first_direction = orders.first&.last || :asc
      relation.reorder(*orders.map { |column, direction| column.public_send(direction) },
                       @tiebreaker.public_send(first_direction))
    end

    def parse_sort(raw)
      unless raw.is_a?(String)
        raise bad_request("sort", "invalid", I18n.t("api.errors.invalid_sort", name: raw.to_s))
      end

      fields = raw.split(",").map(&:strip).reject(&:empty?)
      if fields.size > MAX_SORT_FIELDS || fields.uniq { |f| f.delete_prefix("-") }.size != fields.size
        raise bad_request("sort", "invalid", I18n.t("api.errors.invalid_sort", name: raw))
      end

      fields.map do |field|
        key    = field.delete_prefix("-")
        column = sorts[key]
        raise bad_request("sort", "unknown_sort", I18n.t("api.errors.invalid_sort", name: key)) unless column

        [ column, field.start_with?("-") ? :desc : :asc ]
      end
    end

    def bad_request(field, code, message)
      Api::Errors::BadRequest.new(message, details: [ { field: field, code: code, message: message } ])
    end
  end
end
