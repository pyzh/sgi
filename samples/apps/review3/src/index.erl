-module(index).
-compile(export_all).
-include_lib("n2o/include/wf.hrl").

main() ->
    {Ret, _Status, _Headers} = sgi_n2o_uwsgi_handler:send(),
    Ret.
