open! Core
open Bonsai_web
open Maestro_snapshot
open Maestro_web
module Handle = Bonsai_web_test.Handle
module Result_spec = Bonsai_web_test.Result_spec

let state =
  let tokens =
    { Snapshot.Tokens.input_tokens = 1200; output_tokens = 300; total_tokens = 1500 }
  in
  { Http_api.State.generated_at = Time_ns.epoch
  ; counts = { running = 1; retrying = 1; blocked = 1 }
  ; running =
      [ { issue_id = "mt-101"
        ; issue_identifier = "MT-101"
        ; issue_url = Some "https://tracker/MT-101"
        ; state = "In Progress"
        ; session_id = Some "thread-1-turn-2"
        ; turn_count = 2
        ; last_event = Some "Turn_completed"
        ; last_message = Some "dune build"
        ; started_at = Time_ns.epoch
        ; last_event_at = Some Time_ns.epoch
        ; workspace_path = Some "/tmp/ws/MT-101"
        ; tokens
        ; runtime_seconds = 125.
        }
      ]
  ; retrying =
      [ { issue_id = "mt-450"
        ; issue_identifier = "MT-450"
        ; issue_url = None
        ; attempt = 4
        ; due_in_ms = 1250
        ; error = Some "rate limit exhausted"
        ; workspace_path = None
        }
      ]
  ; blocked =
      [ { issue_id = "mt-333"
        ; issue_identifier = "MT-333"
        ; issue_url = None
        ; state = Some "In Progress"
        ; session_id = None
        ; error = Some "approval required"
        ; blocked_at = Time_ns.epoch
        ; last_event = None
        ; last_message = None
        }
      ]
  ; codex_totals =
      { input_tokens = 1200
      ; output_tokens = 300
      ; total_tokens = 1500
      ; seconds_running = 125.
      }
  ; rate_limits = None
  }
;;

let%expect_test "dashboard renders an API snapshot" =
  let encoded = state |> Http_api.State.jsonaf_of_t |> Jsonaf.to_string in
  print_s [%sexp (Http_api.decode_state encoded : Http_api.State.t Or_error.t)];
  let handle =
    Handle.create (Result_spec.vdom Fn.id) (fun graph ->
      Dashboard.component
        (Bonsai.return state)
        ~fetch_detail:(fun _ -> Effect.return (Or_error.error_string "unused"))
        graph)
  in
  Handle.show handle;
  [%expect
    {|
    (Ok
     ((generated_at (1970-01-01 00:00:00.000000000Z))
      (counts ((running 1) (retrying 1) (blocked 1)))
      (running
       (((issue_id mt-101) (issue_identifier MT-101)
         (issue_url (https://tracker/MT-101)) (state "In Progress")
         (session_id (thread-1-turn-2)) (turn_count 2)
         (last_event (Turn_completed)) (last_message ("dune build"))
         (started_at (1970-01-01 00:00:00.000000000Z))
         (last_event_at ((1970-01-01 00:00:00.000000000Z)))
         (workspace_path (/tmp/ws/MT-101))
         (tokens ((input_tokens 1200) (output_tokens 300) (total_tokens 1500)))
         (runtime_seconds 125))))
      (retrying
       (((issue_id mt-450) (issue_identifier MT-450) (issue_url ()) (attempt 4)
         (due_in_ms 1250) (error ("rate limit exhausted")) (workspace_path ()))))
      (blocked
       (((issue_id mt-333) (issue_identifier MT-333) (issue_url ())
         (state ("In Progress")) (session_id ()) (error ("approval required"))
         (blocked_at (1970-01-01 00:00:00.000000000Z)) (last_event ())
         (last_message ()))))
      (codex_totals
       ((input_tokens 1200) (output_tokens 300) (total_tokens 1500)
        (seconds_running 125)))
      (rate_limits ())))
    <main>
      <header>
        <h1> Maestro </h1>
        <p class="muted"> 1970-01-01 00:00:00.000000000Z </p>
        <div class="totals"> agents 1 backoff 1 blocked 1 tokens in 1,200 / out 300 runtime 2m 5s </div>
      </header>
      <div class="layout">
        <div>
          <section>
            <h2> Running (1) </h2>
            <table>
              <thead>
                <tr>
                  <th> ID </th>
                  <th> STATE </th>
                  <th> TURN </th>
                  <th> TOKENS </th>
                  <th> EVENT </th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td>
                    <button class="issue" @on_click> MT-101 </button>
                  </td>
                  <td> In Progress </td>
                  <td> 2 </td>
                  <td> 1,500 </td>
                  <td> dune build </td>
                </tr>
              </tbody>
            </table>
          </section>
          <section>
            <h2> Backoff queue (1) </h2>
            <table>
              <thead>
                <tr>
                  <th> ID </th>
                  <th> ATTEMPT </th>
                  <th> IN </th>
                  <th> ERROR </th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td>
                    <button class="issue" @on_click> MT-450 </button>
                  </td>
                  <td> 4 </td>
                  <td> 2s </td>
                  <td> rate limit exhausted </td>
                </tr>
              </tbody>
            </table>
          </section>
          <section>
            <h2> Blocked (1) </h2>
            <table>
              <thead>
                <tr>
                  <th> ID </th>
                  <th> STATE </th>
                  <th> ERROR </th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td>
                    <button class="issue" @on_click> MT-333 </button>
                  </td>
                  <td> In Progress </td>
                  <td> approval required </td>
                </tr>
              </tbody>
            </table>
          </section>
        </div>
        <aside>
          <h2> Detail </h2>
          <p> Select an issue. </p>
        </aside>
      </div>
    </main>
    |}]
;;
