# frozen_string_literal: true

# Cash-flow Sankey by account: income categories -> accounts -> expense
# categories, with the household's own transfers drawn between the accounts.
#
# Income lands in the account that received it. Confirmed transfers move money
# between those accounts (savings <-> chequing, a bank payment into a card, a
# bank payment into a loan). Each account then sends its own expense categories
# out, so a card's groceries and a chequing account's e-transfers stay forked
# apart instead of being merged into one category node.
#
# An account that pays out more than it takes in draws the difference from its
# balance: "From savings balance" for a card, "From <account> balance" for a
# bank. One that takes in more keeps the remainder, or reduces card/loan debt.
# A card's non-transfer credits (refunds and other negative charges) are money
# coming BACK to the card, so they enter it from "Refunds & credits" — never an
# outgoing "Card credits" flow, which read as if the card were paying them out.
# There is no Deficit/Surplus node: money moving between your own accounts is
# never income.
class IncomeStatement::AccountSankey
  ACCOUNT_COLOR = "#737373".freeze

  def initialize(statement, period:)
    @statement, @period = statement, period
  end

  def as_json(*)
    @nodes, @links, @node_index = [], [], {}
    flows = account_flows
    return empty_graph if flows.empty?

    transfers = acyclic_transfers(net_transfers(flows.map { |flow| flow[:account] }))
    stats = active_stats(build_stats(flows, transfers))
    return empty_graph if stats.empty?

    capacity = [
      stats.values.map { |stat| [ stat[:inflow], stat[:outflow] ].max }.max,
      flows.sum { |flow| flow[:income] },
      flows.sum { |flow| flow[:spending] }
    ].max.to_d
    return empty_graph if capacity.zero?

    account_indices = stats.to_h { |id, stat| [ id, add_account_node(stat[:account]) ] }
    stats.each_value { |stat| add_categories(stat[:flow], capacity) }
    transfers.each do |edge|
      add_link(account_indices.fetch(edge[:from_id]), account_indices.fetch(edge[:to_id]),
               edge[:amount], percentage(edge[:amount], capacity))
    end
    stats.each { |id, stat| add_balance_bridge(account_indices.fetch(id), stat, capacity) }

    { basis: "net_by_account",
      income: decimal(stats.values.sum { |stat| stat[:flow][:income] }),
      spending: decimal(stats.values.sum { |stat| stat[:flow][:spending] }),
      net_savings: decimal(stats.values.sum { |stat| stat[:flow][:income] - stat[:flow][:spending] }),
      nodes: @nodes.map { |node| serialize(node) },
      links: @links }
  end

  private
    def empty_graph
      { basis: "net_by_account", income: "0", spending: "0", net_savings: "0", nodes: [], links: [] }
    end

    def account_flows
      @account_flows ||= @statement.eligible_accounts.order(:name).map do |account|
        scoped = @statement.family.income_statement(user: @statement.user, accounts: Account.where(id: account.id))
        groups = IncomeStatement::CategoryNetting.new(scoped, period: @period).groups
        income = groups.sum { |group| side_total(group, :income) }.to_d
        spending = groups.sum { |group| side_total(group, :expense) }.to_d
        # A card/loan cannot earn income: negative non-transfer entries are
        # refunds/credits. Show them as a credits sink instead of income.
        credits = account.liability? ? income : 0.to_d
        income = 0.to_d if account.liability?
        { account: account, groups: groups, income: income, spending: spending, credits: credits }
      end
    end

    # Confirmed transfers whose both legs belong to the accounts on this chart,
    # with reciprocal movement between the same two accounts netted so the
    # graph has at most one edge per pair and no two-account cycle.
    def net_transfers(accounts)
      ids = accounts.map(&:id).to_set
      gross = Hash.new(0.to_d)

      Transfer.confirmed
              .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account })
              .each do |transfer|
        date = transfer.date
        next unless date && date.between?(@period.start_date, @period.end_date)

        from = transfer.from_account
        to = transfer.to_account
        next unless from && to && from.id != to.id && ids.include?(from.id) && ids.include?(to.id)

        amount = transfer.amount.to_d.abs
        amount = transfer.inflow_transaction.entry.amount.to_d.abs if amount.zero?
        next if amount.zero?

        gross[[ from.id, to.id ]] += amount
      end

      gross.keys.map(&:sort).uniq.filter_map do |from_id, to_id|
        net = gross[[ from_id, to_id ]] - gross[[ to_id, from_id ]]
        next if net.zero?

        net.positive? ? { from_id: from_id, to_id: to_id, amount: net } :
                        { from_id: to_id, to_id: from_id, amount: net.abs }
      end
    end

    # A three-account cycle cannot be drawn by d3-sankey. Keep the largest
    # edges and drop any edge that would close a cycle; the affected account's
    # balance bridge still balances its remaining flows.
    def acyclic_transfers(edges)
      adjacency = Hash.new { |hash, key| hash[key] = [] }
      edges.sort_by { |edge| -edge[:amount] }.each_with_object([]) do |edge, accepted|
        next if reaches?(adjacency, edge[:to_id], edge[:from_id])

        adjacency[edge[:from_id]] << edge[:to_id]
        accepted << edge
      end
    end

    def reaches?(adjacency, start, target)
      return true if start == target

      visited = Set.new
      stack = [ start ]
      until stack.empty?
        node = stack.pop
        next if visited.include?(node)

        visited << node
        return true if node == target

        stack.concat(adjacency[node])
      end
      false
    end

    def build_stats(flows, transfers)
      stats = flows.to_h do |flow|
        [ flow[:account].id, { account: flow[:account], flow: flow, transfer_in: 0.to_d, transfer_out: 0.to_d } ]
      end
      transfers.each do |edge|
        stats[edge[:from_id]][:transfer_out] += edge[:amount]
        stats[edge[:to_id]][:transfer_in] += edge[:amount]
      end
      stats.each_value do |stat|
        stat[:inflow] = stat[:flow][:income] + stat[:flow][:credits].to_d + stat[:transfer_in]
        stat[:outflow] = stat[:flow][:spending] + stat[:transfer_out]
      end
      stats
    end

    def active_stats(stats)
      stats.select { |_id, stat| stat[:inflow].positive? || stat[:outflow].positive? }
    end

    def add_account_node(account)
      node("account_#{account.id}", account.name, :account, color: ACCOUNT_COLOR)[:index]
    end

    def add_categories(flow, capacity)
      account = flow[:account]
      account_index = @node_index.fetch("account_#{account.id}")[:index]

      flow[:groups].each do |group|
        { income: flow[:income], expense: flow[:spending] }.each do |side, side_total|
          next if side == :income && flow[:credits].positive?
          amount = side_total(group, side)
          next if amount.zero?

          category = group[:category]
          root = node("#{side}_#{account.id}_#{category_key(category)}", category.name, side, category: category)
          root[:value] += amount
          root[:percentage] = percentage(root[:value], side_total)
          if side == :income
            add_link(root[:index], account_index, amount, percentage(amount, side_total))
          else
            add_link(account_index, root[:index], amount, percentage(amount, side_total))
          end

          group[:children].each do |child|
            value = side_amount(child[:net], side)
            next if value.zero?

            child_category = child[:category]
            sub = node("#{side}_sub_#{account.id}_#{child_category.id}", child_category.name, side,
                       category: child_category)
            sub[:value] += value
            sub[:percentage] = percentage(sub[:value], root[:value])
            if side == :income
              add_link(sub[:index], root[:index], value, percentage(value, root[:value]))
            else
              add_link(root[:index], sub[:index], value, percentage(value, root[:value]))
            end
          end
        end
      end

      add_credits_source(account_index, flow, capacity) if flow[:credits].positive?
    end

    # A card/loan's non-transfer credits are money returning to the account
    # (refunds, reversals). They feed the account from the left, beside income
    # and transfers; drawing them as an outgoing sink made the card look like it
    # was paying them out.
    def add_credits_source(account_index, flow, capacity)
      account = flow[:account]
      label = account.credit_card? ? "Refunds & credits" : "Loan credits"
      credits = node("credits_#{account.id}", label, :balance)
      credits[:value] += flow[:credits]
      credits[:percentage] = percentage(flow[:credits], capacity)
      add_link(credits[:index], account_index, flow[:credits], percentage(flow[:credits], capacity))
    end

    def add_balance_bridge(account_index, stat, capacity)
      inflow = stat[:inflow]
      outflow = stat[:outflow]

      if inflow < outflow
        shortfall = outflow - inflow
        label = stat[:account].liability? ? "From savings balance" : "From #{stat[:account].name} balance"
        balance = node("balance_from_#{stat[:account].id}", label, :balance)
        balance[:value] += shortfall
        balance[:percentage] = percentage(shortfall, capacity)
        add_link(balance[:index], account_index, shortfall, percentage(shortfall, capacity))
      elsif inflow > outflow
        excess = inflow - outflow
        label = stat[:account].liability? ? "Debt reduction" : "Remaining in #{stat[:account].name}"
        balance = node("balance_to_#{stat[:account].id}", label, :balance)
        balance[:value] += excess
        balance[:percentage] = percentage(excess, capacity)
        add_link(account_index, balance[:index], excess, percentage(excess, capacity))
      end

      account = @node_index.fetch("account_#{stat[:account].id}")
      account[:value] = [ inflow, outflow ].max
      account[:percentage] = percentage(account[:value], capacity)
    end

    def node(id, name, kind, category: nil, color: nil)
      @node_index[id] ||= begin
        @nodes << { id: id, index: @nodes.size, name: name, kind: kind.to_s, value: 0.to_d, percentage: 0,
                    category_id: category&.id,
                    filter_value: category && !category.other_investments? ? category.filter_value : nil,
                    color: color || category&.color }
        @nodes.last
      end
    end

    def add_link(source_index, target_index, value, percentage)
      @links << { source: source_index, target: target_index, value: decimal(value), percentage: decimal(percentage) }
    end

    def serialize(node)
      node.except(:index).merge(value: decimal(node[:value]), percentage: decimal(node[:percentage]))
    end

    def category_key(category) = IncomeStatement::CategoryNetting.key(category)
    def side_amount(net, side) = IncomeStatement::CategoryNetting.side_amount(net, side)
    def side_total(group, side) = IncomeStatement::CategoryNetting.side_total(group, side)

    def percentage(value, total)
      total.zero? ? 0 : (value.to_d / total * 100).round(1)
    end

    def decimal(value)
      value.to_d.to_s("F")
    end
end
