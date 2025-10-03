defmodule Ash.DataLayer.Mnesia.Transformers.DefineRecords do
  @moduledoc """
  Generates Erlang record definitions for Mnesia resources at compile time.

  This transformer reads the resource's attributes and creates an Erlang record
  definition using Record.defrecord, making Mnesia operations more efficient and
  enabling pattern matching on records.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @doc false
  def transform(dsl_state) do
    resource = Transformer.get_persisted(dsl_state, :module)
    attributes = Ash.Resource.Info.attributes(dsl_state)
    primary_key = Ash.Resource.Info.primary_key(dsl_state)

    # Get table name from mnesia configuration or default to resource name
    table = get_table_name(dsl_state, resource)

    # Build field list with defaults for the record
    fields = build_field_list(attributes)

    # Inject the record definition and helper functions
    dsl_state = inject_record_code(dsl_state, table, fields, attributes, primary_key)

    {:ok, dsl_state}
  end

  defp get_table_name(dsl_state, resource) do
    # Try to get configured table name from mnesia DSL
    case Ash.DataLayer.Mnesia.Info.table(dsl_state) do
      table when is_atom(table) ->
        table

      _ ->
        resource
    end
  end

  defp build_field_list(attributes) do
    # Create field list with sensible defaults
    Enum.map(attributes, fn attr ->
      default = get_default_value(attr)
      {attr.name, default}
    end)
  end

  defp get_default_value(%{default: default}) when not is_nil(default) do
    default
  end

  defp get_default_value(%{allow_nil?: false, type: type}) do
    # Provide non-nil defaults for required fields based on type
    case type do
      :string -> ""
      :integer -> 0
      :float -> 0.0
      :boolean -> false
      :atom -> :undefined
      _ -> nil
    end
  end

  defp get_default_value(_), do: nil

  defp inject_record_code(dsl_state, table, fields, attributes, primary_key) do
    field_names = Enum.map(attributes, & &1.name)
    field_map = Map.new(fields)

    field_assignments =
      Enum.map(field_names, fn field ->
        default_value = field_map[field]

        # Check at compile time if it's a function. I was trying to do this
        # logic in the `quote` below, but it causes issues during runtime with
        # typing because we know what the value is and the `case` or `if`
        # statements don't like that.
        resolved_default =
          case default_value do
            fun when is_function(fun, 0) ->
              quote(do: unquote(fun).())

            value ->
              quote(do: unquote(value))
          end

        {field, quote(do: Map.get(attrs, unquote(field), unquote(resolved_default)))}
      end)

    Transformer.eval(
      dsl_state,
      [
        table: table,
        fields: fields,
        field_names: field_names,
        primary_key: primary_key,
        field_map: field_map,
        field_assignments: field_assignments
      ],
      quote do
        require Record

        Record.defrecordp(unquote(table), unquote(fields))

        # Store field defaults as module attribute
        @field_defaults unquote(Macro.escape(field_map))

        @doc """
        Creates a new #{unquote(table)} record from a map or keyword list.

        ## Examples

            iex> #{inspect(__MODULE__)}.to_ex_record(id: 1, name: "Alice")
            {#{inspect(unquote(table))}, 1, "Alice", ...}

            iex> #{inspect(__MODULE__)}.to_ex_record(%{id: 1, name: "Alice"})
            {#{inspect(unquote(table))}, 1, "Alice", ...}
        """

        def to_ex_record(attrs \\ [])

        def to_ex_record(attrs) when is_list(attrs) do
          to_ex_record(Map.new(attrs))
        end

        def to_ex_record(attrs) when is_map(attrs) do
          unquote(table)(unquote(field_assignments))
        end

        @doc """
        Converts a #{unquote(table)} record to a map.

        ## Examples

            iex> record = #{inspect(__MODULE__)}.to_ex_record(id: 1, name: "Alice")
            iex> #{inspect(__MODULE__)}.record_to_map(record)
            %{id: 1, name: "Alice", ...}
        """
        def record_to_map(record) when is_tuple(record) do
          # Skip the first element (record tag)
          [_tag | values] = Tuple.to_list(record)
          field_names = unquote(field_names)

          field_names
          |> Enum.zip(values)
          |> Enum.into(%{})
        end

        @doc """
        Converts a #{unquote(table)} record to an Ash Resource struct.

        ## Examples

            iex> record = #{inspect(__MODULE__)}.to_ex_record(id: 1, name: "Alice")
            iex> #{inspect(__MODULE__)}.from_ex_record(record)
            %#{inspect(__MODULE__)}{id: 1, name: "Alice", ...}
        """
        def from_ex_record(record) when is_tuple(record) do
          record
          |> record_to_map()
          |> then(&struct(__MODULE__, &1))
        end

        @doc """
        Gets the value of a field from a #{unquote(table)} record.

        ## Examples

            iex> record = #{inspect(__MODULE__)}.to_ex_record(id: 1, name: "Alice")
            iex> #{inspect(__MODULE__)}.get_field(record, :name)
            "Alice"
        """
        def get_field(record, field) when is_atom(field) do
          field_names = unquote(field_names)

          case Enum.find_index(field_names, &(&1 == field)) do
            nil ->
              raise ArgumentError, "field #{inspect(field)} not found in record"

            index ->
              # Add 1 to skip the record tag at position 0
              elem(record, index + 1)
          end
        end
      end
    )
  end
end
