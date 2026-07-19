open! Core
open! Async

(* A scripted fake Codex app-server: replies by matching method names in received lines
   (so multi-turn sessions work), records everything it receives in a trace file, and can
   inject extra behavior per case. Shared by the app-server and agent-runner tests. *)
let write
  ~dir
  ~trace
  ?(on_turn_start = {|printf '%s\n' '{"method":"turn/completed"}'|})
  ?(extra_cases = "")
  ()
  =
  let script = dir ^/ "fake-codex.sh" in
  let contents =
    [%string
      {|T=0
while IFS= read -r line; do
  printf '%s\n' "$line" >> "%{trace}"
  case "$line" in
    *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *'"method":"initialized"'*) : ;;
    *'"method":"thread/start"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"th-1"}}}' ;;
    *'"method":"turn/start"'*) T=$((T+1)); printf '{"id":3,"result":{"turn":{"id":"tu-%d"}}}\n' "$T"; %{on_turn_start} ;;
%{extra_cases}
  esac
done|}]
  in
  let%map () = Writer.save script ~contents in
  script
;;
