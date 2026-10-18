# frozen_string_literal: true

# The viewer's walk over a filtered list (P1.12). The caller supplies its list
# order as keyset keys — SQL expression plus direction, ending in a unique
# tie-break — so the two neighbours are found with two LIMIT 1 queries instead
# of materialising every matching id. The predicates mirror the order: after
# the current tuple is `>` for an ascending key and `<` for a descending one;
# before it is the reverse. Every earlier key must match, so ties resolve by
# the next key, exactly as the ORDER BY does.
class DocumentBrowser::Neighbours
  def self.call(relation, record, keys)
    new(relation, record, keys).call
  end

  def initialize(relation, record, keys)
    @relation = relation
    @record = record
    @keys = keys
  end

  # [previous, next] in list order. Both nil when the record is not in the
  # filtered relation, and the missing end is nil on the first/last row.
  def call
    values = current_values
    return [ nil, nil ] unless values

    [ neighbour(values, before: true), neighbour(values, before: false) ]
  end

  private
    attr_reader :relation, :record, :keys

    # The record's own sort tuple, read through the same expressions the order
    # uses. nil when no row of the filtered relation has this id.
    def current_values
      relation.unscope(:order)
              .where(primary_key => record.id)
              .pick(*keys.map { |key| Arel.sql(key.fetch(:sql)) })
    end

    def neighbour(values, before:)
      sql, binds = predicate(values, before: before)
      relation.unscope(:order)
              .where(sql, *binds)
              .reorder(Arel.sql(order_sql(before: before)))
              .limit(1)
              .first
    end

    def predicate(values, before:)
      clauses = []
      binds = []
      keys.each_index do |index|
        clause = keys[0...index].each_with_index.map do |key, earlier|
          binds << values[earlier]
          "#{key.fetch(:sql)} = ?"
        end
        binds << values[index]
        clause << "#{keys[index].fetch(:sql)} #{comparison_for(keys[index].fetch(:direction), before: before)} ?"
        clauses << "(#{clause.join(" AND ")})"
      end
      [ clauses.join(" OR "), binds ]
    end

    def comparison_for(direction, before:)
      ascending = direction.to_sym == :asc
      if before
        ascending ? "<" : ">"
      else
        ascending ? ">" : "<"
      end
    end

    def order_sql(before:)
      keys.map do |key|
        direction = key.fetch(:direction).to_sym
        direction = direction == :asc ? :desc : :asc if before
        "#{key.fetch(:sql)} #{direction.to_s.upcase}"
      end.join(", ")
    end

    def primary_key = relation.klass.primary_key
end
