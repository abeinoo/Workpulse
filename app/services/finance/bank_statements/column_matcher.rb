module Finance
  module BankStatements
    # Pre-fills the column-mapping step by scoring every detected CSV/Excel
    # header against known Arabic/English synonyms for each WorkPulse field,
    # then greedily assigning the highest-scoring (field, header) pairs.
    #
    # Two invariants make the assignment 1:1 by construction:
    #   - once a FIELD is assigned, it is removed from further consideration
    #   - once a HEADER is assigned, it is removed from further consideration
    # so no header can ever be auto-assigned to two different fields (and no
    # field ever receives two headers).
    #
    # Matches below CONFIDENCE_THRESHOLD are dropped rather than guessed — the
    # caller sees no entry for that field and the mapping UI leaves it blank
    # for the user to pick manually.
    #
    # Usage:
    #   Finance::BankStatements::ColumnMatcher.match(detected_headers)
    #   # => { "transaction_date" => "تاريخ الحركة", "amount" => "Amount" }
    class ColumnMatcher
      # Confidence score (0–100) a (field, header) pair must clear to be
      # auto-assigned.
      CONFIDENCE_THRESHOLD = 60

      # F-beta weighting for the token-overlap score below. beta > 1 weights
      # recall (how much of the *header* the synonym explains) over precision
      # (how much of the *synonym* the header contains). This deliberately
      # downgrades short, generic synonyms — e.g. "Value" or "Date" alone —
      # that only explain a fragment of a longer, more specific header (e.g.
      # "Value Date", which in real bank exports names a settlement-date
      # column, not an amount column). Better to leave that for manual mapping
      # than to guess wrong.
      RECALL_WEIGHT = 2

      BOM = "﻿"

      # أ/إ/آ → ا, ة → ه, ى → ي — the common Arabic spelling variants that
      # differ only by how a document/keyboard renders the same letter.
      ARABIC_LETTER_NORMALIZATION = {
        "أ" => "ا", "إ" => "ا", "آ" => "ا",
        "ة" => "ه",
        "ى" => "ي"
      }.freeze

      FIELD_SYNONYMS = {
        "transaction_date" => [
          "تاريخ", "تاريخ الحركة", "تاريخ العملية", "تاريخ المعاملة",
          "Date", "Transaction Date", "Posting Date"
        ],
        "amount" => [
          "المبلغ", "القيمة", "المبلغ المدين", "المبلغ الدائن",
          "Amount", "Value"
        ],
        "reference_number" => [
          "المرجع", "رقم المرجع", "رقم العملية",
          "Reference", "Ref No"
        ],
        "description" => [
          "الوصف", "البيان", "التفاصيل",
          "Description", "Details"
        ],
        "transaction_type" => [
          "نوع الحركة", "نوع العملية",
          "Transaction Type", "Type"
        ]
      }.freeze
      # "Customer Identifier" (رقم الحساب / الحساب / Account Number) has no
      # corresponding field on BankStatementTransaction / RowParser::ALL_FIELDS
      # today, so it is intentionally omitted — those headers correctly stay
      # unmapped instead of being forced onto an unrelated field such as
      # external_transaction_id.

      def self.match(headers)
        new(headers).match
      end

      # Trim, strip BOM, ignore case, normalize Arabic letter variants, drop
      # punctuation, and collapse whitespace — so headers that differ only by
      # formatting compare equal.
      def self.normalize(header)
        s = header.to_s.delete(BOM).strip.downcase
        ARABIC_LETTER_NORMALIZATION.each { |from, to| s = s.gsub(from, to) }
        s = s.gsub(/[^\p{Alnum}\s]/, " ")
        s.gsub(/\s+/, " ").strip
      end

      def initialize(headers)
        @headers = headers.to_a.uniq
      end

      def match
        assign(build_candidates)
      end

      private

      # Every (field, header) pair whose score clears the confidence
      # threshold, sorted highest score first. Ties are broken by field
      # declaration order then header order, so the result is deterministic.
      def build_candidates
        field_rank  = FIELD_SYNONYMS.keys.each_with_index.to_h
        header_rank = @headers.each_with_index.to_h

        candidates = []
        FIELD_SYNONYMS.each_key do |field|
          @headers.each do |header|
            score = score_header(field, header)
            candidates << { field: field, header: header, score: score } if score >= CONFIDENCE_THRESHOLD
          end
        end

        candidates.sort_by { |c| [ -c[:score], field_rank[c[:field]], header_rank[c[:header]] ] }
      end

      # Walks candidates highest-score-first; skips any pair whose field or
      # header has already been claimed. This is what guarantees exclusivity:
      # a header removed from the pool after its first assignment can never
      # be picked up by a later, lower-scoring field.
      def assign(candidates)
        used_headers = Set.new
        used_fields   = Set.new
        mapping = {}

        candidates.each do |c|
          next if used_fields.include?(c[:field]) || used_headers.include?(c[:header])

          mapping[c[:field]] = c[:header]
          used_fields << c[:field]
          used_headers << c[:header]
        end

        mapping
      end

      def score_header(field, header)
        header_norm = self.class.normalize(header)
        return 0 if header_norm.blank?

        FIELD_SYNONYMS.fetch(field).map { |syn| score_pair(header_norm, self.class.normalize(syn)) }.max
      end

      def score_pair(header_norm, synonym_norm)
        return 0 if synonym_norm.blank?
        return 100 if header_norm == synonym_norm

        header_tokens  = header_norm.split(" ").to_set
        synonym_tokens = synonym_norm.split(" ").to_set
        overlap = (header_tokens & synonym_tokens).size
        return 0 if overlap.zero?

        precision = overlap.to_f / synonym_tokens.size
        recall    = overlap.to_f / header_tokens.size

        beta_sq = RECALL_WEIGHT**2
        f_beta  = (1 + beta_sq) * precision * recall / (beta_sq * precision + recall)
        (f_beta * 100).round
      end
    end
  end
end
