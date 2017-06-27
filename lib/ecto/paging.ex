defmodule Ecto.Paging do
  @moduledoc """
  This module provides a easy way to apply cursor-based pagination to your Ecto Queries.

  ## Usage:
  1. Add macro to your repo

      defmodule MyRepo do
        use Ecto.Repo, otp_app: :my_app
        use Ecto.Pagging.Repo # This string adds `paginate/2` method.
      end

  2. Paginate!

      query = from p in Ecto.Paging.Schema

      query
      |> Ecto.Paging.TestRepo.paginate(%Ecto.Paging{limit: 150})
      |> Ecto.Paging.TestRepo.all

  ## Limitations:
    * Right now it works only with schemas that have `:inserted_at` field with auto-generated value.
    * You need to be careful with order-by's in your queries, since this feature is not tested yet.
    * It doesn't construct `paginate` struct with `has_more` and `size` counts (TODO: add this helpers).
    * When both `starting_after` and `ending_before` is set, only `starting_after` is used.
  """
  import Ecto.Query

  @type t :: %{limit: number, cursors: Ecto.Paging.Cursors.t, has_more: number, size: number}

  @doc """
  This struct defines pagination rules.
  It can be used in your response API.
  """
  defstruct limit: 50,
            cursors: %Ecto.Paging.Cursors{},
            has_more: nil,
            size: nil

  @doc """
  Convert map into `Ecto.Paging` struct.
  """
  def from_map(%Ecto.Paging{cursors: %Ecto.Paging.Cursors{}} = paging), do: paging

  def from_map(%{cursors: %Ecto.Paging.Cursors{} = cursors} = paging) do
    Ecto.Paging
    |> struct(paging)
    |> Map.put(:cursors, cursors)
  end

  def from_map(%{cursors: cursors} = paging) when is_map(cursors) do
    cursors = struct(Ecto.Paging.Cursors, cursors)
    from_map(%{paging | cursors: cursors})
  end

  def from_map(paging) when is_map(paging) do
    Ecto.Paging
    |> struct(paging)
    |> from_map()
  end

  @doc """
  Convert `Ecto.Paging` struct into map and drop all nil values and `cursors` property if it's empty.
  """
  def to_map(%Ecto.Paging{cursors: cursors} = paging) do
    cursors = cursors
    |> Map.delete(:__struct__)
    |> Enum.filter(fn {_, v} -> v end)
    |> Enum.into(%{})

    paging
    |> Map.delete(:__struct__)
    |> Map.put(:cursors, cursors)
    |> Enum.filter(fn {_, v} -> is_map(v) && v != %{} or not is_map(v) and v end)
    |> Enum.into(%{})
  end

  @doc """
  Apply pagination to a `Ecto.Query`.
  It can accept either `Ecto.Paging` struct or map that can be converted to it via `from_map/1`.
  """
  def paginate(%Ecto.Query{} = query,
               %Ecto.Paging{limit: limit, cursors: %Ecto.Paging.Cursors{} = cursors},
               [repo: _, chronological_field: _] = opts)
      when is_integer(limit) do
    pk = get_primary_key(query)

    query
    |> limit(^limit)
    |> filter_by_cursors(cursors, pk, opts)
  end

  def paginate(%Ecto.Query{} = query, %Ecto.Paging{}, _opts) do
    query
  end

  def paginate(%Ecto.Query{} = query, paging, opts) when is_map(paging) do
    paginate(query, Ecto.Paging.from_map(paging), opts)
  end

  def paginate(queriable, paging, opts) when is_atom(queriable) do
    queriable
    |> Ecto.Queryable.to_query()
    |> paginate(paging, opts)
  end

  @doc """
  Build a `%Ecto.Paging{}` struct to fetch next page results based on previous `Ecto.Repo.all` result
  and previous paging struct.
  """
  def get_next_paging(query_result, %Ecto.Paging{limit: nil} = paging) do
    get_next_paging(query_result, %{paging | limit: length(query_result)})
  end

  def get_next_paging(query_result, %Ecto.Paging{limit: limit, cursors: cursors}) when is_list(query_result) do
    has_more = length(query_result) >= limit
    %Ecto.Paging{
      limit: limit,
      has_more: has_more,
      cursors: get_next_cursors(query_result, cursors, has_more)
    }
  end

  def get_next_paging(query_result, paging) when is_map(paging) do
    get_next_paging(query_result, Ecto.Paging.from_map(paging))
  end

  defp get_next_cursors([], _, _) do
      %Ecto.Paging.Cursors{starting_after: nil, ending_before: nil}
  end
  defp get_next_cursors(query_result, _, false) do
    %Ecto.Paging.Cursors{starting_after: List.last(query_result).id,
                          ending_before: nil}
  end
  defp get_next_cursors(query_result, _, true) do
      %Ecto.Paging.Cursors{starting_after: List.last(query_result).id,
                           ending_before: List.first(query_result).id}
  end

  defp filter_by_cursors(%Ecto.Query{from: {table, schema}} = query, %{starting_after: starting_after}, pk,
                        [repo: repo, chronological_field: chronological_field])
       when not is_nil(starting_after) do
    pk_type = schema.__schema__(:type, pk)

    case extract_timestamp(repo, table, {pk_type, pk}, starting_after, chronological_field) do
      {:ok, ts} ->
        query
        |> where([c], field(c, ^chronological_field) > ^ts)
        |> set_default_order(pk_type, pk, chronological_field)
      {:error, :not_found} ->
        query
        |> where([c], false)
    end
  end

  defp filter_by_cursors(%Ecto.Query{from: {table, schema}} = query, %{ending_before: ending_before}, pk,
                        [repo: repo, chronological_field: chronological_field])
       when not is_nil(ending_before) do
    pk_type = schema.__schema__(:type, pk)
    case extract_timestamp(repo, table, {pk_type, pk}, ending_before, chronological_field) do
      {:ok, ts} ->
        {rev_order, q} = query
        |> find_where_order(chronological_field, ts)
        |> flip_orders(pk, pk_type, chronological_field)
        restore_query_order(rev_order, pk_type, pk, q, chronological_field)
      {:error, :not_found} ->
        query
        |> where([c], false)
    end
  end

  defp filter_by_cursors(query, %{ending_before: nil, starting_after: nil}, _pk, _opts), do: query

  defp extract_timestamp(repo, table, {pk_type, pk}, pk_value, chronological_field) do
    start_timestamp_native =
      repo.one from r in table,
        where: field(r, ^pk) == type(^pk_value, ^pk_type),
        select: field(r, ^chronological_field)

    case start_timestamp_native do
      nil ->
        {:error, :not_found}
      timestamp ->
        {:ok, start_timestamp} = Ecto.DateTime.load(timestamp)
        {:ok, Ecto.DateTime.to_string(start_timestamp)}
    end
  end

  def find_where_order(%Ecto.Query{order_bys: order_bys} = query, chronological_field, timestamp)
      when is_list(order_bys) and length(order_bys) > 0 do
    case get_order_from_expression(order_bys) do
      :asc  -> query |> where([c], field(c, ^chronological_field) < ^timestamp)
      :desc -> query |> where([c], field(c, ^chronological_field) > ^timestamp)
    end
  end

  def find_where_order(%Ecto.Query{} = query, chronological_field, timestamp) do
    query |> where([c], field(c, ^chronological_field) < ^timestamp)
  end

  defp flip_orders(%Ecto.Query{order_bys: order_bys} = query, _pk, _pk_type, chronological_field)
       when is_list(order_bys) and length(order_bys) > 0 do
    order = get_order_from_expression(order_bys)
    query = case order do
      :asc -> query |> exclude(:order_by) |> order_by([c], desc: field(c, ^chronological_field))
      :desc -> query |> exclude(:order_by)
    end
    {order, query}
  end

  defp flip_orders(%Ecto.Query{} = query, _pk, :string, chronological_field) do
    {:asc, query |> order_by([c], desc: field(c, ^chronological_field))}
  end

  defp flip_orders(%Ecto.Query{} = query, pk, :binary_id, chronological_field) do
    {:asc, query |> order_by([c], desc: field(c, ^chronological_field))}
  end

  defp flip_orders(%Ecto.Query{} = query, pk, _pk_type, _chronological_field) do
    {:asc, query |> order_by([c], desc: field(c, ^pk))}
  end

  defp restore_query_order(order, :binary_id, _pk, query, chronological_field) do
    from e in subquery(query), order_by: [{^order, ^chronological_field}]
  end

  defp restore_query_order(order, :string, _pk, query, chronological_field) do
    from e in subquery(query), order_by: [{^order, ^chronological_field}]
  end

  defp restore_query_order(order, _pk_type, pk, query, _chronological_field) do
    from e in subquery(query), order_by: [{^order, ^pk}]
  end

  defp set_default_order(query, :binary_id, _pk, chronological_field) do
    query |> order_by([c], asc: field(c, ^chronological_field))
  end

  defp set_default_order(query, :string, _pk, chronological_field) do
    query |> order_by([c], asc: field(c, ^chronological_field))
  end

  defp set_default_order(query, _, pk, _chronological_field) do
    query |> order_by([c], asc: field(c, ^pk))
  end

  defp get_primary_key(%Ecto.Query{from: {_, model}}) do
    :primary_key
    |> model.__schema__
    |> List.first
  end

  defp get_order_from_expression(expression) do
    [%Ecto.Query.QueryExpr{expr: expr} | _t] = expression
    Keyword.keys(expr) |> Enum.at(0)
  end
end
