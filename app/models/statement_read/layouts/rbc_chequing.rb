# frozen_string_literal: true

class StatementRead
  module Layouts
    # RBC personal chequing and savings ("Your RBC personal banking account
    # statement" / "Your RBC personal savings account statement"). Both print
    # the same table — date, description, withdrawals, deposits, balance — and
    # the same opening/deposits/withdrawals/closing summary. Read entirely from
    # the text layer:
    #
    #   * identity — "Your account number: 02941-5386719" (transit-account; the
    #     account's last four identify it), the period "From <date> to <date>";
    #   * totals — opening, total deposits, total withdrawals, closing;
    #   * rows — a date carries forward until the next one; a description runs
    #     over lines until the line carrying its amount; "$ 16.25ALDI" inside a
    #     description is the foreign original (a note, not a column); a balance
    #     printed "- 29.95" is negative;
    #   * direction — from the running balance alone (BalanceWalk); a group the
    #     balance cannot orient on its own is settled ONLY when exactly one
    #     candidate assignment also reproduces the printed deposit and
    #     withdrawal totals. When every candidate leaves those totals identical,
    #     the printed column may choose between them as a display tiebreak: the
    #     group's net, and therefore every printed total, is unchanged. A column
    #     is never proof of the money (review I1).
    #
    # Proven only when every group orients, and the rows' deposits, withdrawals
    # and opening-to-closing movement all equal the printed totals to the cent.
    class RbcChequing
      INSTITUTION = "Royal Bank of Canada"
      MONEY = /-?\d{1,3}(?:,\d{3})*\.\d{2}/
      LONG_DATE = /[A-Z][a-z]+ \d{1,2}, \d{4}/
      MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze
      ROW_DATE = /\A(\d{1,2}) (#{MONTHS.join('|')})\b\s*/
      FX_NOTE = /\$\s*(\d[\d,]*\.\d{2})(?=[A-Za-z])/
      NOISE = /\A(?:RBPDA|Date\s+Description|Details of your account activity|Your RBC personal (?:banking|savings)|From [A-Z]|\d+ of \d+\z|\d{5}\z)/

      def self.matches?(text)
        text.include?(INSTITUTION) &&
          text.match?(/Your RBC personal (?:banking|savings)/) &&
          text.include?("Opening Balance")
      end

      def self.call(text) = new(text).call

      def initialize(text)
        @text = text.to_s
      end

      def call
        totals = stated_totals
        walk = BalanceWalk.call(opening: totals["opening"], closing: totals["closing"], rows: parsed_rows)
        walk = resolve_against_totals(walk, totals)
        rows = walk.rows.map { |row| emit(row) }
        checks, figures = checks_for(walk, totals)
        verdict = verdict_for(walk, checks, rows)

        StatementRead::Result.new(
          rows: rows, stated_totals: totals.merge("new_balance" => totals["closing"]),
          deltas: figures.transform_values { |figure| figure[:read] - figure[:stated] },
          checks: checks, reconciled: verdict == :trusted, missing_date_rows: [], rejected_lines: [],
          source: :text_layer, verdict: verdict, figures: figures, rounding_delta: BigDecimal(0),
          identity: identity
        )
      end

      private
        # The balance walk leaves a group unverified when two sign assignments
        # move the balance the same way (a +45 rebate beside a -45 fee). The
        # printed deposits and withdrawals totals are independent evidence: if
        # exactly ONE combination of the candidates reproduces both, the group
        # is proven without guessing. No match stays unverified (drift or
        # unreconcilable); several matches fall through to the display tiebreak
        # below, which may only choose when the totals are identical.
        MAX_RESOLUTIONS = 64

        def resolve_against_totals(walk, totals)
          return walk if walk.ambiguities.empty?
          return walk unless totals["deposits"] && totals["withdrawals"]
          return walk if totals["deposits"].to_d.zero? && totals["withdrawals"].to_d.zero?

          candidates = walk.ambiguities.map { |ambiguity| ambiguity[:candidates] }
          return walk if candidates.reduce(1) { |product, list| product * list.size } > MAX_RESOLUTIONS

          combinations = candidates.shift.product(*candidates)
          matches = combinations.select do |combination|
            rows = resolved_rows(walk.rows, walk.ambiguities, combination)
            deposits, withdrawals = side_totals(rows)
            deposits == totals["deposits"] && withdrawals == totals["withdrawals"]
          end
          return build_resolved(walk, matches.first) if matches.one?

          # Two equal amounts with opposite signs (a +45 rebate beside a -45
          # fee) give every candidate the SAME deposit and withdrawal totals,
          # so the totals cannot choose between them and the row directions are
          # the only difference. The printed column is then a display tiebreak,
          # never a financial one: the group's net and every printed total stay
          # exactly as the candidates already proved them. Without a column for
          # every ambiguous row, refuse to guess (review I1).
          return walk unless invariant_totals?(combinations, walk)

          orient_by_columns(walk, totals) || walk
        end

        def build_resolved(walk, combination)
          BalanceWalk::Result.new(
            rows: resolved_rows(walk.rows, walk.ambiguities, combination),
            verified: true, ambiguous_groups: 0, ambiguities: []
          )
        end

        # Every candidate assignment produces the same deposit and withdrawal
        # totals, so choosing between them cannot change the statement's money.
        def invariant_totals?(combinations, walk)
          combinations.map do |combination|
            side_totals(resolved_rows(walk.rows, walk.ambiguities, combination))
          end.uniq.one?
        end

        def orient_by_columns(walk, totals)
          return nil unless walk.ambiguities.all? do |ambiguity|
            ambiguity[:group].all? { |row| row["column"].in?(%i[deposit withdrawal]) }
          end

          signs = walk.ambiguities.map do |ambiguity|
            ambiguity[:group].map { |row| row["column"] == :deposit ? 1 : -1 }
          end
          rows = resolved_rows(walk.rows, walk.ambiguities, signs)
          deposits, withdrawals = side_totals(rows)
          return nil unless deposits == totals["deposits"] && withdrawals == totals["withdrawals"]
          return nil unless totals["opening"].nil? ||
                            totals["opening"] + deposits - withdrawals == totals["closing"]

          BalanceWalk::Result.new(rows: rows, verified: true, ambiguous_groups: 0, ambiguities: [])
        end

        def resolved_rows(rows, ambiguities, combination)
          resolved = rows.dup
          ambiguities.each_with_index do |ambiguity, index|
            signs = combination[index]
            ambiguity[:group].each_with_index do |row, offset|
              resolved[ambiguity[:start] + offset] = row.merge("signed" => signs[offset] * row["amount"])
            end
          end
          resolved
        end

        def side_totals(rows)
          signed = rows.map { |row| row["signed"] }.compact
          deposits = signed.select(&:positive?).sum(BigDecimal(0))
          withdrawals = -signed.select(&:negative?).sum(BigDecimal(0))
          [ deposits, withdrawals ]
        end

        def identity
          account = @text.match(/Your account number:\s*\d+-(\d+)/)
          start_on, end_on = period
          Identity::Result.new(
            institution_name: INSTITUTION, account_last4: account && account[1].last(4), card_last4s: [],
            card_network: nil, period_start: start_on, period_end: end_on
          )
        end

        def period
          match = @text.match(/From (#{LONG_DATE}) to (#{LONG_DATE})/)
          match ? [ Date.parse(match[1]), Date.parse(match[2]) ] : [ nil, nil ]
        end

        def stated_totals
          {
            "opening" => money_after(/Your opening balance on #{LONG_DATE}\s+(-?)\s*\$?(#{MONEY})/),
            "deposits" => money_after(/Total deposits into your account\s+\+\s*()(#{MONEY})/),
            "withdrawals" => money_after(/Total withdrawals from your account\s+-\s*()(#{MONEY})/),
            "closing" => money_after(/Your closing balance on #{LONG_DATE}\s+=\s*(-?)\s*\$?(#{MONEY})/)
          }
        end

        def money_after(pattern)
          match = @text.match(pattern)
          return nil unless match

          value = to_money(match[2])
          match[1] == "-" ? -value : value
        end

        # The activity table: after the "Opening Balance" line, until "Closing
        # Balance". Each page's column header locates its Withdrawals/Deposits/
        # Balance columns, so an amount's column can witness its direction.
        def parsed_rows
          body = @text.split(/^.*Opening Balance.*$/, 2).last.to_s.split(/^.*Closing Balance.*$/, 2).first.to_s
          columns = header_columns(@text.lines.find { |line| line.include?("Withdrawals ($)") })
          rows = []
          pending = []
          date = nil
          between_pages = false

          body.each_line do |raw|
            line = raw.rstrip
            stripped = line.strip
            # A page's footer ("1 of 2") to the next page's column header is the
            # bank's own header block (address, statement title): never a row.
            if line.include?("Withdrawals ($)")
              columns = header_columns(line)
              between_pages = false
              next
            end
            between_pages = true if stripped.match?(/\A\d+ of \d+\z/)
            next if between_pages || stripped.empty? || stripped.match?(NOISE)

            if (match = stripped.match(ROW_DATE))
              date = row_date(match[1], match[2])
            end

            note = line[FX_NOTE, 1]
            scrubbed = line.sub(FX_NOTE, " " * line[FX_NOTE].to_s.length)
            scrubbed = scrubbed.gsub(/(^|\s)-\s+(?=#{MONEY}(?!\d))/) { "#{$1}-" }
            amounts = scrubbed.to_enum(:scan, MONEY).map { [ Regexp.last_match[0], Regexp.last_match.end(0) ] }
            description = scrubbed.gsub(MONEY, " ").strip.sub(ROW_DATE, "").squish

            if amounts.empty?
              pending << description if description.present?
              next
            end

            row = { "date" => date, "name" => [ *pending, description ].compact_blank.join(" "), "note" => note }
            pending = []
            amounts.each do |text_amount, right_edge|
              value = to_money(text_amount)
              side = column_at(columns, right_edge)
              if side == :balance
                row["balance"] = value
              else
                row["amount"] = value.abs
                # The rightmost non-balance amount is the real column amount; a
                # "$45.00" inside a description scans first and is overwritten.
                row["column"] = side
              end
            end
            rows << row if row["amount"]
          end
          rows
        end

        # The right edge of each amount column, from the header row's labels.
        def header_columns(line)
          return nil if line.nil?

          { withdrawal: line.index("Withdrawals ($)"), deposit: line.index("Deposits ($)"), balance: line.index("Balance ($)") }
            .compact.transform_values { |start| start + "Withdrawals ($)".length }
            .tap do |edges|
              edges[:deposit] = line.index("Deposits ($)") + "Deposits ($)".length if line.index("Deposits ($)")
              edges[:balance] = line.index("Balance ($)") + "Balance ($)".length if line.index("Balance ($)")
            end
        end

        # The nearest column by right edge; nil when the page gave no header.
        def column_at(columns, right_edge)
          return nil if columns.blank?

          columns.min_by { |_, edge| (edge - right_edge).abs }.first
        end

        # A "15 Sep" row date in the statement's own period, so a December-to-
        # January statement puts each row in its own year.
        def row_date(day, month)
          start_on, end_on = period
          return nil if end_on.nil?

          [ end_on.year, end_on.year - 1 ].filter_map do |year|
            Date.new(year, MONTHS.index(month) + 1, day.to_i)
          rescue Date::Error
            nil
          end.find { |candidate| candidate >= (start_on || end_on) - 7 && candidate <= end_on + 7 }
        end

        def emit(row)
          amount = row["signed"]
          {
            "date" => row["date"]&.iso8601, "name" => row["name"],
            "amount" => amount && format("%.2f", amount),
            "notes" => row["note"] && "foreign amount #{row['note']}", "source_page" => nil
          }
        end

        def checks_for(walk, totals)
          signed = walk.rows.map { |row| row["signed"] }.compact
          deposits = signed.select(&:positive?).sum(BigDecimal(0))
          withdrawals = -signed.select(&:negative?).sum(BigDecimal(0))
          figures = {}
          checks = { "row_parse" => walk.verified ? Reconciliation::PASS : Reconciliation::DRIFT }
          compare = lambda do |name, read, stated|
            if stated.nil?
              checks[name] = Reconciliation::SKIP
            else
              figures[name] = { read: read, stated: stated }
              checks[name] = read == stated ? Reconciliation::PASS : Reconciliation::DRIFT
            end
          end
          compare.call("credits_sum", deposits, totals["deposits"])
          compare.call("charges_identity", withdrawals, totals["withdrawals"])
          if totals["opening"] && totals["closing"]
            compare.call("balance_identity", totals["opening"] + deposits - withdrawals, totals["closing"])
          end
          [ checks, figures ]
        end

        def verdict_for(walk, checks, rows)
          return :empty_but_expected if rows.empty?
          return :drift if checks.value?(Reconciliation::DRIFT) && walk.ambiguous_groups.zero?
          return :unreconcilable unless walk.verified

          checks.values.all? { |state| state == Reconciliation::PASS } ? :trusted : :unreconcilable
        end

        def to_money(text) = BigDecimal(text.delete(","))
    end
  end
end
