defmodule ElixirSense.Providers.Suggestion.Reducers.TypeSpecs do
  @moduledoc false

  alias ElixirSense.Core.Binding
  alias ElixirSense.Core.Introspection
  alias ElixirSense.Core.Metadata
  alias ElixirSense.Core.Source
  alias ElixirSense.Core.State
  alias ElixirSense.Core.TypeInfo
  alias ElixirSense.Providers.Suggestion.Matcher

  @type type_spec :: %{
          type: :type_spec,
          name: String.t(),
          arity: non_neg_integer,
          origin: String.t() | nil,
          args_list: list(String.t()),
          spec: String.t(),
          doc: String.t(),
          signature: String.t(),
          metadata: map
        }

  @doc """
  A reducer that adds suggestions of type specs.
  """

  # We only list type specs when inside typespec scope
  def add_types(hint, env, file_metadata, %{at_module_body?: _}, acc) do
    if match?({:typespec, _, _}, env.scope) do
      %State.Env{
        aliases: aliases,
        module: module,
        scope: scope
      } = env

      %Metadata{mods_funs_to_positions: mods_funs, types: metadata_types} = file_metadata

      binding_env = Binding.from_env(env, file_metadata)

      {mod, hint} =
        hint
        |> Source.split_module_and_hint(module, aliases)
        |> expand(binding_env, aliases)

      list =
        find_typespecs_for_mod_and_hint(
          {mod, hint},
          aliases,
          module,
          scope,
          mods_funs,
          metadata_types
        )
        |> Kernel.++(find_builtin_types({mod, hint}))

      {:cont, %{acc | result: acc.result ++ list}}
    else
      {:cont, acc}
    end
  end

  def add_types(_hint, _env, _buffer_metadata, _context, acc) do
    {:cont, acc}
  end

  defp expand({{kind, _} = type, hint}, env, aliases) when kind in [:attribute, :variable] do
    case Binding.expand(env, type) do
      {:atom, module} -> {Introspection.expand_alias(module, aliases), hint}
      _ -> {nil, ""}
    end
  end

  defp expand({type, hint}, _env, _aliases) do
    {type, hint}
  end

  defp find_typespecs_for_mod_and_hint(
         {mod, hint},
         aliases,
         module,
         scope,
         mods_funs,
         metadata_types
       ) do
    case Introspection.actual_module(mod, aliases, module, scope, mods_funs) do
      {actual_mod, true} ->
        find_module_types(actual_mod, {mod, hint}, metadata_types, module)

      {nil, false} ->
        find_module_types(module, {mod, hint}, metadata_types, module)

      {_, false} ->
        []
    end
  end

  defp find_builtin_types({nil, hint}) do
    TypeInfo.find_all_builtin(&Matcher.match?("#{&1.name}", hint))
    |> Enum.map(&type_info_to_suggestion(&1, nil))
    |> Enum.sort_by(fn %{name: name, arity: arity} -> {name, arity} end)
  end

  defp find_builtin_types({_mod, _hint}), do: []

  defp find_module_types(actual_mod, {mod, hint}, metadata_types, module) do
    find_metadata_types(actual_mod, {mod, hint}, metadata_types, module)
    |> Kernel.++(TypeInfo.find_all(actual_mod, &Matcher.match?("#{&1.name}", hint)))
    |> Enum.map(&type_info_to_suggestion(&1, actual_mod))
    |> Enum.uniq_by(fn %{name: name, arity: arity} -> {name, arity} end)
    |> Enum.sort_by(fn %{name: name, arity: arity} -> {name, arity} end)
  end

  defp find_metadata_types(actual_mod, {mod, hint}, metadata_types, module) do
    # local types are hoisted, no need to check position
    include_private = mod == nil and actual_mod == module

    for {{^actual_mod, type, arity}, type_info} when is_integer(arity) <- metadata_types,
        type |> Atom.to_string() |> Matcher.match?(hint),
        include_private or type_info.kind != :typep,
        do: type_info
  end

  defp type_info_to_suggestion(type_info, module) do
    origin = if module, do: inspect(module)

    case type_info do
      %ElixirSense.Core.State.TypeInfo{args: [args]} ->
        args_stringified = Enum.join(args, ", ")

        spec =
          case type_info.kind do
            :opaque -> "@opaque #{type_info.name}(#{args_stringified})"
            _ -> List.last(type_info.specs)
          end

        %{
          type: :type_spec,
          name: type_info.name |> Atom.to_string(),
          arity: length(args),
          args_list: args,
          signature: "#{type_info.name}(#{args_stringified})",
          origin: origin,
          doc: "",
          spec: spec,
          # TODO extract doc and meta
          metadata: %{}
        }

      _ ->
        args_list =
          if type_info.signature do
            part =
              type_info.signature
              |> String.split("(")
              |> Enum.at(1)

            if part do
              part
              |> String.split(")")
              |> Enum.at(0)
              |> String.split(",")
              |> Enum.map(&String.trim/1)
            else
              []
            end
          else
            []
          end

        %{
          type: :type_spec,
          name: type_info.name |> Atom.to_string(),
          arity: type_info.arity,
          args_list: args_list,
          signature: type_info.signature,
          origin: origin,
          doc: type_info.doc,
          spec: type_info.spec,
          metadata: type_info.metadata
        }
    end
  end
end
