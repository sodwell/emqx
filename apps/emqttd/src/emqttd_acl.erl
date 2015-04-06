%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2015, Feng Lee <feng@emqtt.io>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% emqttd ACL.
%%%
%%% Two types of authorization:
%%% 
%%% subscribe topic
%%% publish to topic
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(emqttd_acl).

-author('feng@emqtt.io').

-include("emqttd.hrl").

-callback check_acl(PubSub, User, Topic) -> {ok, allow | deny} | ignore | {error, any()} when
    PubSub   :: pubsub(),
    User     :: mqtt_user(),
    Topic    :: binary().

-callback reload_acl() -> ok | {error, any()}.

-behaviour(gen_server).

-define(SERVER, ?MODULE).

%% API Function Exports
-export([start_link/1, check/3, reload/0, register_mod/1, unregister_mod/1]).

%% ACL Callback
-export([check_acl/3, reload_acl/0]).

-define(ACL_TAB, mqtt_acl).

-record(state, {acl_file, raw_rules = []}).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Start ACL Server.
%%
%% @end
%%------------------------------------------------------------------------------
-spec start_link(AclOpts) -> {ok, pid()} | ignore | {error, any()} when
    AclOpts     :: [{file, list()}].
start_link(AclOpts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [AclOpts], []).

-spec check(PubSub, User, Topic) -> allow | deny when
      PubSub :: pubsub(),
      User   :: mqtt_user(),
      Topic  :: binary().
check(PubSub, User, Topic) ->
    case ets:lookup(?ACL_TAB, acl_mods) of
        [] -> {error, "No ACL mod!"};
        [{_, Mods}] -> check(PubSub, User, Topic, Mods)
    end.
check(_PubSub, _User, _Topic, []) ->
    {error, "All ACL mods ignored!"};
check(PubSub, User, Topic, [Mod|Mods]) ->
    case Mod:check_acl(PubSub, User, Topic) of
        {ok, AllowDeny} -> AllowDeny;
        ignore -> check(PubSub, User, Topic, Mods)
    end.

%%TODO: 
reload() ->
    case ets:lookup(?ACL_TAB, acl_mods) of
        [] -> {error, "No ACL mod!"};
        [{_, Mods}] -> [M:reload() || M <- Mods]
    end.

register_mod(Mod) ->
    gen_server:call(?MODULE, {register_mod, Mod}).

unregister_mod(Mod) ->
    gen_server:call(?MODULE, {unregister_mod, Mod}).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([AclOpts]) ->
    ets:new(?ACL_TAB, [set, protected, named_table]),
    ets:insert(?ACL_TAB, {acl_mods, [?MODULE]}),
    AclFile = proplists:get_value(file, AclOpts),
    load_rules(#state{acl_file = AclFile}).

load_rules(State = #state{acl_file = AclFile}) ->
    {ok, Terms} = file:consult(AclFile),
    Rules = [compile(Term) || Term <- Terms],
    lists:foreach(fun(PubSub) ->
        ets:insert(?ACL_TAB, {PubSub, 
            lists:filter(fun(Rule) -> filter(PubSub, Rule) end, Rules)})
        end, [publish, subscribe]),
    {ok, State#state{raw_rules = Terms}}.

filter(_PubSub, {allow, all}) ->
    true;
filter(_PubSub, {deny, all}) ->
    true;
filter(publish, {_AllowDeny, _Who, publish, _Topics}) ->
    true;
filter(_PubSub, {_AllowDeny, _Who, pubsub, _Topics}) ->
    true;
filter(subscribe, {_AllowDeny, _Who, subscribe, _Topics}) ->
    true;
filter(_PubSub, {_AllowDeny, _Who, _, _Topics}) ->
    false.

handle_call(reload, _From, State) ->
    case catch load_rules(State) of
        {ok, NewState} -> 
            {reply, ok, NewState};
        {'EXIT', Error} -> 
            {reply, {error, Error}, State}
    end;

handle_call({register_mod, Mod}, _From, State) ->
    [{_, Mods}] = ets:lookup(?ACL_TAB, acl_mods), 
    case lists:member(Mod, Mods) of
        true -> 
            {reply, {error, registered}, State};
        false -> 
            ets:insert(?ACL_TAB, {acl_mods, [Mod|Mods]}),
            {reply, ok, State}
    end;

handle_call({unregister_mod, Mod}, _From, State) ->
    [{_, Mods}] = ets:lookup(?ACL_TAB, acl_mods), 
    case lists:member(Mod, Mods) of
        true ->
            ets:insert(?ACL_TAB, lists:delete(Mod, Mods)),
            {reply, ok, State};
        false -> 
            {reply, {error, not_found}, State}
    end;

handle_call(Req, _From, State) ->
    lager:error("Bad Request: ~p", [Req]),
    {reply, {error, badreq}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

