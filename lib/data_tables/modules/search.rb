module DataTables
  module Modules
    class Search
      MissingSerializationContextError = Class.new(KeyError)

      attr_reader :collection, :context

      def initialize(collection, adapter_options)
        @collection = collection
        @adapter_options = adapter_options
        @context = adapter_options.fetch(:serialization_context) do
          fail MissingSerializationContextError, <<-EOF.freeze
  Datatables::Search requires a ActiveModelSerializers::SerializationContext.
  Please pass a ':serialization_context' option or
  override CollectionSerializer#searchable? to return 'false'.
           EOF
        end
      end

      def search
        default_search = request_parameters.dig(:search, :value)

        model = @collection.try(:model) || @collection
        arel_table = model.arel_table
        columns = searchable_columns(default_search)

        searches = DataTables.flat_keys_to_nested columns

        search_by = build_search(model, searches)

        @collection.where(search_by.reduce(:and))
      end

      def build_search(model, searches)
        # join_type = Arel::Nodes::OuterJoin
        join_type = Arel::Nodes::InnerJoin

        searches.inject([]) do |queries, junk|
          column, query = junk
          case query
          when Hash
            assoc = model.reflect_on_association(column)
            assoc_klass = assoc.klass

            outer_join = join_type.new(assoc_klass.arel_table,
              Arel::Nodes::On.new(
                model.arel_table[assoc.foreign_key].eq(assoc_klass.arel_table[assoc.active_record_primary_key])
            ))
            @collection = @collection.joins(outer_join)
            queries << build_search(assoc_klass, query).reduce(:and)
          else
            col_s = column.to_s
            case (k = model.columns.find(nil) { |c| c.name == col_s })&.type
            when :string
              # I'm pretty sure this is safe from SQL Injection
              queries << model.arel_table[k.name].matches("%#{query}%")
            when :integer
              if value = query&.to_i
                queries << model.arel_table[k.name].eq(value)
              end
            when :datetime
              datetime = Time.parse(query)
              range = (datetime-1.second)..(datetime+1.second)
              queries << model.arel_table[k.name].between(range)
            end
          end

          queries
        end
      end

      protected

      def searchable_columns(default_search)
        @searchable_columns = {}
        request_parameters[:columns]&.inject(@searchable_columns) do |a, b|
          if (b[:searchable] && b[:data].present?)
            if ((value = b.dig(:search, :value).present? ? b.dig(:search, :value) : default_search).present?)
              a[b[:data]] = value
            end
          end
          a
        end

        @searchable_columns
      end

      private

      def request_parameters
        @request_parameters ||= context.request_parameters
      end

    end
  end
end
