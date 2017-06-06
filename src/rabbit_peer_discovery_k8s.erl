%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is AWeber Communications.
%% Copyright (c) 2015-2016 AWeber Communications
%% Copyright (c) 2016-2017 Pivotal Software, Inc. All rights reserved.
%%

-module(rabbit_peer_discovery_k8s).
-behaviour(rabbit_peer_discovery_backend).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbitmq_peer_discovery_common/include/rabbit_peer_discovery.hrl").

-export([list_nodes/0, supports_registration/0, register/0, unregister/0,
         post_registration/0]).

-ifdef(TEST).
-compile(export_all).
-endif.

-define(CONFIG_MODULE, rabbit_peer_discovery_config).
-define(UTIL_MODULE,   rabbit_peer_discovery_util).
-define(HTTPC_MODULE,  rabbit_peer_discovery_httpc).

-define(BACKEND_CONFIG_KEY, peer_discovery_k8s).

-define(CONFIG_MAPPING,
         #{
          k8s_scheme                         => #peer_discovery_config_entry_meta{
                                                   type          = string,
                                                   env_variable  = "K8S_SCHEME",
                                                   default_value = "https"
                                                  },
          k8s_host                           => #peer_discovery_config_entry_meta{
                                                   type          = string,
                                                   env_variable  = "K8S_HOST",
                                                   default_value = "kubernetes.default.svc.cluster.local"
                                                  },
          k8s_port                           => #peer_discovery_config_entry_meta{
                                                   type          = integer,
                                                   env_variable  = "K8S_PORT",
                                                   default_value = 443
                                                  },
          k8s_token_path                     => #peer_discovery_config_entry_meta{
                                                   type          = string,
                                                   env_variable  = "K8S_TOKEN_PATH",
                                                   default_value = "/var/run/secrets/kubernetes.io/serviceaccount/token"
                                                  },
          k8s_cert_path                      => #peer_discovery_config_entry_meta{
                                                   type          = string,
                                                   env_variable  = "K8S_CERT_PATH",
                                                   default_value = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
                                                  },
          k8s_namespace_path                 => #peer_discovery_config_entry_meta{
                                                   type          = string,
                                                   env_variable  = "K8S_NAMESPACE_PATH",
                                                   default_value = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"
                                                  },
          k8s_service_name                   => #peer_discovery_config_entry_meta{
                                                   type          = string,
                                                   env_variable  = "K8S_SERVICE_NAME",
                                                   default_value = "rabbitmq"
                                                  },
          k8s_address_type                   => #peer_discovery_config_entry_meta{
                                                   type          = string,
                                                   env_variable  = "K8S_ADDRESS_TYPE",
                                                   default_value = "ip"
                                                  },
          k8s_hostname_suffix                => #peer_discovery_config_entry_meta{
                                                   type          = string,
                                                   env_variable  = "K8S_HOSTNAME_SUFFIX",
                                                   default_value = ""
                                                  }
         }).

%%
%% API
%%

-spec list_nodes() -> {ok, {Nodes :: list(), NodeType :: rabbit_types:node_type()}}.

list_nodes() ->
    case make_request() of
	{ok, Response} ->
	    Addresses = extract_node_list(Response),
	    {ok, lists:map(fun node_name/1, Addresses)};
	{error, Reason} ->
	    rabbit_log:info(
	      "Failed to get nodes from k8s - ~s", [Reason]),
	    {error, Reason}
    end.

-spec supports_registration() -> boolean().

supports_registration() ->
    false.


-spec register() -> ok.
register() ->
    ok.

-spec unregister() -> ok.
unregister() ->
    ok.

-spec post_registration() -> ok | {error, Reason :: string()}.

post_registration() ->
    ok.

%%
%% Implementation
%%
-spec get_config_key(Key :: atom(), Map :: #{atom() => peer_discovery_config_value()})
                    -> peer_discovery_config_value().

get_config_key(Key, Map) ->
    ?CONFIG_MODULE:get(Key, ?CONFIG_MAPPING, Map).

%% @doc Perform a HTTP GET request to K8s
%% @end
%%
-spec make_request() -> {ok, term()} | {error, term()}.
make_request() ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    {ok, Token} = file:read_file(get_config_key(k8s_token_path, M)),
    Token1 = binary:replace(Token, <<"\n">>, <<>>),
    ?HTTPC_MODULE:get(
      get_config_key(k8s_scheme, M),
      get_config_key(k8s_host, M),
      get_config_key(k8s_port, M),
      base_path(),
      [],
      [{"Authorization", "Bearer " ++ binary_to_list(Token1)}],
      [{ssl, [{cacertfile, get_config_key(k8s_cert_path, M)}]}]).

%% @spec node_name(k8s_endpoint) -> list()  
%% @doc Return a full rabbit node name, appending hostname suffix
%% @end
%%
node_name(Address) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    ?UTIL_MODULE:node_name(
       ?UTIL_MODULE:as_string(Address) ++ get_config_key(k8s_hostname_suffix, M)).


%% @spec maybe_ready_address(k8s_subsets()) -> list()
%% @doc Return a list of ready nodes
%% SubSet can contain also "notReadyAddresses"  
%% @end
%%
maybe_ready_address(Subset) ->
    case maps:get(<<"notReadyAddresses">>, Subset, undefined) of
      undefined -> ok;
      NotReadyAddresses ->
            Formatted = string:join([binary_to_list(get_address(X))
                                     || X <- NotReadyAddresses], ", "),
            rabbit_log:info("k8s endpoint listing returned nodes not yet ready: ~s",
                            [Formatted])
    end,
    maps:get(<<"addresses">>, Subset, []).

%% @doc Return a list of nodes
%%    see http://kubernetes.io/docs/api-reference/v1/definitions/#_v1_endpoints
%% @end
%%
-spec extract_node_list(term()) -> [binary()].
extract_node_list(Response) ->
    IpLists = [[get_address(Address)
		|| Address <- maybe_ready_address(Subset)]
	       || Subset <- maps:get(<<"subsets">>, Response, [])],
    sets:to_list(sets:union(lists:map(fun sets:from_list/1, IpLists))).


%% @doc Return a list of path segments that are the base path for k8s key actions
%% @end
%%
-spec base_path() -> [?HTTPC_MODULE:path_component()].
base_path() ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    {ok, NameSpace} = file:read_file(
			get_config_key(k8s_namespace_path, M)),
    NameSpace1 = binary:replace(NameSpace, <<"\n">>, <<>>),
    [api, v1, namespaces, NameSpace1, endpoints,
     get_config_key(k8s_service_name, M)].

get_address(Address) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    maps:get(list_to_binary(get_config_key(k8s_address_type, M)), Address).