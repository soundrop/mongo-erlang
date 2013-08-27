-module(bson).
-export([
	encode/1,
	decode/1,
	decode/2
]).

-export([
	lookup/2,
	lookup/3,
	at/2
]).

-export([
	update/3,
	merge/2
]).

-export([
	object_id/4,
	object_id/3
]).

-export_type([
	document/0,
	object_id/0
]).

-define(INT8(B), (B):8/little).
-define(INT32(I), (I):32/little-signed).
-define(INT64(I), (I):64/little-signed).
-define(DOUBLE(D), (D):64/little-float).
-define(CSTRING(S), (S)/binary, ?NULL).
-define(NULL, ?INT8(0)).

-type document() :: [{}] | [field()].
-type field()    :: {label(), value()}.
-type label()    :: atom() | utf8().
-type value()    :: float() |
		utf8() |
		document() |
		list(value()) |
		data() |
		undefined |
		object_id() |
		boolean() |
		datetime() |
		null |
		regex() |
		pointer() |
		javascript() |
		atom() |
		integer() |
		timestamp() |
		min_key |
		max_key.

-type utf8()       :: unicode:unicode_binary().
-type data()       :: {data, data_type(), binary()}.
-type data_type()  :: binary | function | uuid | md5 | user.
-type object_id()  :: {object_id, <<_:96>>}.
-type datetime()   :: erlang:timestamp().
-type regex()      :: {regex, utf8(), utf8()}.
-type pointer()    :: {pointer, utf8(), utf8()}.
-type javascript() :: {javascript, document(), utf8()}.
-type timestamp()  :: {timestamp, integer(), integer()}.


-spec encode(document()) -> binary().
encode([{}]) ->
	<<?INT32(5), ?NULL>>;
encode(Document) when is_tuple(hd(Document)) ->
	Encoded = encode(Document, <<>>),
	<<?INT32(byte_size(Encoded) + 5), Encoded/binary, ?NULL>>.

-spec decode(binary()) -> {document(), binary()}.
decode(Data) ->
	decode(Data, []).

-spec decode(binary(), [decode_option()]) -> {document(), binary()}.
-type decode_option() :: {label, binary | atom | existing_atom}.
decode(<<?INT32(N), Payload/binary>> = Data, Options) ->
	Size = N - 5,
	case Payload of
		<<Doc:Size/binary, ?NULL, Rest/binary>> ->
			{decode(Doc, Options, []), Rest};
		_ ->
			{[{}], Data}
	end.

-spec lookup(lookup_path(), document()) -> undefined | {ok, value()}.
-type lookup_path() :: label() | pos_integer() | [label() | pos_integer()].
lookup([], Document) ->
	{ok, Document};
lookup([Label | Rest], Document) when not is_integer(Label) ->
	case lookup_i(Label, Document) of
		{_, Value} -> lookup(Rest, Value);
		undefined -> undefined
	end;
lookup([Index | Rest], Document) ->
	case catch lists:nth(Index, Document) of
		{'EXIT', _} -> undefined;
		Value -> lookup(Rest, Value)
	end;
lookup(Label, Document) when is_atom(Label); is_binary(Label); is_integer(Label) ->
	lookup([Label], Document).

-spec lookup(lookup_path(), document(), Default) -> value() | Default when Default::term().
lookup(Path, Document, Default) ->
	case lookup(Path, Document) of
		undefined -> Default;
		{ok, Value} -> Value
	end.

-spec at(lookup_path(), document()) -> value().
at(Path, Document) ->
	case lookup(Path, Document) of
		{ok, Value} -> Value;
		undefined -> erlang:error(missing_field)
	end.

-spec update(lookup_path(), value(), document()) -> document().
% TODO: support full paths when updating
update(Label, Value, [{}]) when is_atom(Label); is_binary(Label) ->
	[{Label, Value}];
update(Label, Value, Document) when is_atom(Label); is_binary(Label) ->
	case lookup_i(Label, Document) of
		{Label1, _} -> lists:keyreplace(Label1, 1, Document, {Label1, Value});
		undefined -> [{Label, Value} | Document]
	end;
update([Label], Value, Document) ->
	update(Label, Value, Document).

-spec merge(bson:document(), bson:document()) -> bson:document().
merge(Doc1, [{}]) ->
	Doc1;
merge([{}], Doc2) ->
	Doc2;
merge(Doc1, Doc2) ->
	lists:foldl(fun ({Key, Value}, Acc) ->
		update(Key, Value, Acc)
	end, Doc2, Doc1).

-spec object_id(integer() | erlang:timestamp(), integer(), integer(), integer()) -> object_id().
object_id(Timestamp, MachineId, ProcessId, Counter) ->
	object_id(Timestamp, <<MachineId:24/big, ProcessId:16/big>>, Counter).

-spec object_id(integer() | erlang:timestamp(), binary(), integer()) -> object_id().
object_id({Mega, Sec, _Micro}, MachineProcId, Counter) ->
	object_id(Mega * 1000000 + Sec, MachineProcId, Counter);
object_id(Timestamp, MachineProcId, Counter) ->
	{object_id, <<Timestamp:32/big, MachineProcId/binary, Counter:24/big>>}.

%% @private
encode([], Acc) ->
	Acc;
encode([{Label, Value} | Rest], Acc) ->
	{Type, Payload} = case Value of
		V when is_float(V) ->
			{1, <<?DOUBLE(V)>>};
		V when is_binary(V) ->
			{2, <<?INT32(byte_size(Value) + 1), ?CSTRING(Value)>>};
		Document when is_tuple(hd(Document)) ->
			{3, encode(Value)};
		V when is_list(V) ->
			{4, encode(case V of
				[] -> [{}];
				_ -> lists:zip(lists:seq(0, length(Value) - 1), Value)
			end)};
		{data, SubType, Data} when is_binary(Data) ->
			{5, <<?INT32(byte_size(Data)), ?INT8(case SubType of
				binary -> 0;
				function -> 1;
				uuid -> 3;
				md5 -> 5;
				user -> 128
			end), Data/binary>>};
		undefined ->
			{6, <<>>};
		{object_id, <<_:96>> = Id} ->
			{7, Id};
		false ->
			{8, <<?INT8(0)>>};
		true ->
			{8, <<?INT8(1)>>};
		{Mega, Sec, Micro} when is_integer(Mega), is_integer(Sec), is_integer(Micro) ->
			{9, <<?INT64(Mega * 1000000000 + Sec * 1000 + Micro div 1000)>>};
		null ->
			{10, <<>>};
		{regex, Pattern, Options} ->
			{11, <<?CSTRING(unicode:characters_to_binary(Pattern)), ?CSTRING(unicode:characters_to_binary(Options))>>};
		{pointer, Collection, <<_:96>> = Id} ->
			{12, <<?CSTRING(Collection), Id/binary>>};
		{javascript, [{}], Code} when is_binary(Code) ->
			{13, <<?CSTRING(Code)>>};
		V when is_atom(V), V =/= min_key, V =/= max_key ->
			{14, <<?CSTRING(atom_to_binary(V, utf8))>>};
		{javascript, Scope, Code} when is_tuple(hd(Scope)), is_binary(Code) ->
			Encoded = <<?CSTRING(Code), (encode(Scope))/binary>>,
			{15, <<?INT32(byte_size(Encoded) + 4), Encoded/binary>>};
		V when is_integer(V), -16#80000000 =< V, V =< 16#7fffffff ->
			{16, <<?INT32(V)>>};
		{timestamp, Inc, Time} ->
			{17, <<?INT32(Inc), ?INT32(Time)>>};
		V when is_integer(V), -16#8000000000000000 =< V, V =< 16#7fffffffffffffff ->
			{18, <<?INT64(V)>>};
		V when is_integer(V) ->
			erlang:error(integer_too_large, [Label, V]);
		max_key ->
			{127, <<>>};
		min_key ->
			{255, <<>>}
	end,
	encode(Rest, <<Acc/binary, ?INT8(Type), ?CSTRING(encode_label(Label)), Payload/binary>>).

%% @private
encode_label(Label) when is_atom(Label) ->
	atom_to_binary(Label, utf8);
encode_label(Label) when is_integer(Label) ->
	list_to_binary(integer_to_list(Label));
encode_label(Label) ->
	unicode:characters_to_binary(Label).

%% @private
decode(<<>>, _Options, []) ->
	[{}];
decode(<<>>, _Options, Acc) ->
	lists:reverse(Acc);
decode(Data, Options, Acc) ->
	{Label, Value, Rest} = decode_field(Data, Options),
	decode(Rest, Options, [{decode_label(Label, Options), Value} | Acc]).

%% @private
decode_field(<<?INT8(Type), Payload/binary>>, Options) ->
	{Label, Data} = decode_cstring(Payload, <<>>),
	{Value, Rest} = case Type of
		1 ->
			<<?DOUBLE(V), R/binary>> = Data,
			{V, R};
		2 ->
			<<?INT32(L), V0:L/binary, R/binary>> = Data,
			{binary:part(V0, 0, L - 1), R};
		3 ->
			decode(Data, Options);
		4 ->
			<<?INT32(L), R/binary>> = Data,
			Size = L - 5,
			<<ArrayBin:Size/binary, ?NULL, R1/binary>> = R,
			{decode_array(ArrayBin, Options), R1};
		5 ->
			<<?INT32(L), ?INT8(SubType), D:L/binary, R/binary>> = Data,
			{{data, case SubType of
				0 -> binary;
				1 -> function;
				3 -> uuid;
				4 -> uuid;
				5 -> md5;
				128 -> user
			end, D}, R};
		6 ->
			{undefined, Data};
		7 ->
			<<V:96/bits, R/binary>> = Data,
			{{object_id, V}, R};
		8 ->
			<<?INT8(V), R/binary>> = Data,
			{case V of 0 -> false; _ -> true end, R};
		9 ->
			<<?INT64(V), R/binary>> = Data,
			{{V div 1000000000, (V div 1000) rem 1000000, (V * 1000) rem 1000000}, R};
		10 ->
			{null, Data};
		11 ->
			{RegexPattern, R1} = decode_cstring(Data, <<>>),
			{RegexOpts, R2} = decode_cstring(R1, <<>>),
			{{regex, RegexPattern, RegexOpts}, R2};
		12 ->
			{Collection, <<Id:96/bits, R/binary>>} = decode_cstring(Data, <<>>),
			{{pointer, Collection, Id}, R};
		13 ->
			{Code, R} = decode_cstring(Data, <<>>),
			{{javascript, [{}], Code}, R};
		14 ->
			{Symbol, R} = decode_cstring(Data, <<>>),
			{binary_to_atom(Symbol, utf8), R};
		15 ->
			<<?INT32(_), R1/binary>> = Data,
			{Code, R2} = decode_cstring(R1, <<>>),
			{Scope, R3} = decode(R2, Options),
			{{javascript, Scope, Code}, R3};
		16 ->
			<<?INT32(V), R/binary>> = Data,
			{V, R};
		17 ->
			<<?INT32(Inc), ?INT32(Time), R/binary>> = Data,
			{{timestamp, Inc, Time}, R};
		18 ->
			<<?INT64(V), R/binary>> = Data,
			{V, R};
		127 ->
			{max_key, Data};
		255 ->
			{min_key, Data}
	end,
	{Label, Value, Rest}.

%% @private
decode_array(<<>>, _Options) ->
	[];
decode_array(Data, Options) ->
	{_, Value, Rest} = decode_field(Data, Options),
	[Value | decode_array(Rest, Options)].

%% @private
decode_cstring(<<?NULL, Rest/binary>>, Acc) ->
	{Acc, Rest};
decode_cstring(<<C, Rest/binary>>, Acc) ->
	decode_cstring(Rest, <<Acc/binary, C>>).

%% @private
decode_label(Label, Options) ->
	case lists:keyfind(label, 1, Options) of
		{label, atom} -> binary_to_atom(Label, utf8);
		{label, existing_atom} -> existing_atom(Label);
		_ -> Label
	end.

%% @private
lookup_i(_, [{}]) ->
	undefined;
lookup_i(_, []) ->
	undefined;
lookup_i(Label, [{Label, Value} | _]) ->
	{Label, Value};
lookup_i(Label0, [{Label1, _} | _] = Document) when is_atom(Label0), is_binary(Label1) ->
	lookup_i(atom_to_binary(Label0, utf8), Document);
lookup_i(Label0, [{Label1, _} | _] = Document) when is_binary(Label0), is_atom(Label1) ->
	lookup_i(existing_atom(Label0), Document);
lookup_i(Label, [_ | Rest]) ->
	lookup_i(Label, Rest).

%% @private
existing_atom(Binary) ->
	try binary_to_existing_atom(Binary, utf8) of
		L -> L
	catch
		error:badarg -> Binary
	end.

-ifdef(TEST).

encode_test_() ->
	Tests = [
		{[{}], <<?INT32(5), ?NULL>>},
		{[{a, 1.0}], <<?INT32(16), ?INT8(1), "a", ?NULL, 1.0:64/float-little, ?NULL>>},
		{[{a, <<"a">>}], <<?INT32(14), ?INT8(2), "a", ?NULL, ?INT32(2), "a", ?NULL, ?NULL>>},
		{[{'BSON', [<<"awesome">>, 5.05, 1986]}], <<49,0,0,0,4,66,83,79,78,0,38,0,0,0,2,48,0,8,0,0,0,97,119,101,115,111,109,101,0,1,49,0,51,51,51,51,51,51,20,64,16,50,0,194,7,0,0,0,0>>}
	],
	[fun() -> Result = encode(Input) end || {Input, Result} <- Tests].

roundtrip_test() ->
	Document = test_document(),
	{Document, <<>>} = decode(encode(Document), [{label, existing_atom}]).

lookup_test_() ->
	Tests = [
		{a, {ok, -4.230845}},
		{<<"a">>, {ok, -4.230845}},
		{[<<"a">>], {ok, -4.230845}},
		{[c, x], {ok, -1}},
		{[c, z], undefined},
		{[c, z, y], undefined},
		{[d1, 2], {ok, 45}},
		{[d1, 10], undefined}
	],
	[fun() -> Result = lookup(Path, test_document()) end || {Path, Result} <- Tests].

update_test_() ->
	Tests = [
		{{a, 1}, [{}], [{a, 1}]},
		{{a, 1}, [{a, 0}], [{a, 1}]},
		{{a, 1}, [{<<"a">>, 0}], [{<<"a">>, 1}]},
		{{[a], 1}, [{<<"a">>, 0}], [{<<"a">>, 1}]},
		{{b, 1}, [{a, 0}], [{b, 1}, {a, 0}]}
	],
	[fun() -> Result = update(Key, Value, Doc) end || {{Key, Value}, Doc, Result} <- Tests].



test_document() ->
	Data = <<200,12,240,129,100,90,56,198,34,0,0>>,
	Time = os:timestamp(),
	[
		{a, -4.230845},
		{b, <<"hello">>},
		{c, [{x, -1}, {y, 2.2001}]},
		{d1, [23, 45, 200]},
		{d2, []},
		{eeeeeeeee, {data, binary, Data}},
		{f, {data, function, Data}},
		{g, {data, uuid, Data}},
		{h, {data, md5, Data}},
		{i, {data, user, Data}},
		{j, object_id(Time, 2, 3, 4)},
		{k1, false},
		{k2, true},
		{l, milliseconds_precision(Time)},
		{m, undefined},
		{n, {regex, <<"foo">>, <<"bar">>}},
		{o1, {javascript, [{}], <<"function(x) = x + 1;">>}},
		{o2, {javascript, [{x, 0}, {y, <<"foo">>}], <<"function(a) = a + x">>}},
		{p, atom},
		{q1, -2000444000},
		{q2, -8000111000222001},
		{r, {timestamp, 100022, 995332003}},
		{s1, min_key},
		{s2, max_key}
	].

milliseconds_precision({MegaSecs, Secs, MicroSecs}) ->
	{MegaSecs, Secs, MicroSecs div 1000 * 1000}.

-endif.