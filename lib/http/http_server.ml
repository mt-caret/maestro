open! Core
open! Async
open Maestro_observability
module Server = Cohttp_async.Server

module Refresh_result = struct
  type t =
    | Queued of { coalesced : bool }
    | Unavailable
end

type t = { server : (Socket.Address.Inet.t, int) Server.t }

let json_headers = Http.Header.of_list [ "content-type", "application/json" ]
let html_headers = Http.Header.of_list [ "content-type", "text/html; charset=utf-8" ]

let javascript_headers =
  Http.Header.of_list
    [ "content-type", "text/javascript; charset=utf-8"; "content-encoding", "gzip" ]
;;

let respond_json ?(status = `OK) json =
  Server.respond_string ~headers:json_headers ~status (Jsonaf.to_string json)
;;

let error_envelope ~code ~message : Jsonaf.t =
  `Object [ "error", `Object [ "code", `String code; "message", `String message ] ]
;;

let respond_error ~status ~code ~message =
  respond_json ~status (error_envelope ~code ~message)
;;

let method_not_allowed () =
  respond_error
    ~status:`Method_not_allowed
    ~code:"method_not_allowed"
    ~message:"Method not allowed"
;;

let handle ~snapshot ~request_refresh (request : Http.Request.t) =
  let meth = Http.Request.meth request in
  let path = Uri.path (Uri.of_string (Http.Request.resource request)) in
  match String.split path ~on:'/' |> List.filter ~f:(Fn.non String.is_empty) with
  | [] ->
    (match meth with
     | `GET -> Server.respond_string ~headers:html_headers Dashboard_page.html
     | _ -> method_not_allowed ())
  | [ "assets"; "dashboard.js" ] ->
    (match meth with
     | `GET ->
       Server.respond_string ~headers:javascript_headers Dashboard_page.javascript_gzip
     | _ -> method_not_allowed ())
  | [ "api"; "v1"; "state" ] ->
    (match meth with
     | `GET ->
       let%bind snapshot = snapshot () in
       respond_json (Presenter.state_payload snapshot ~generated_at:(Time_ns.now ()))
     | _ -> method_not_allowed ())
  | [ "api"; "v1"; "refresh" ] ->
    (match meth with
     | `POST ->
       (match%bind request_refresh () with
        | Refresh_result.Unavailable ->
          respond_error
            ~status:`Service_unavailable
            ~code:"orchestrator_unavailable"
            ~message:"Orchestrator is unavailable"
        | Queued { coalesced } ->
          respond_json
            ~status:`Accepted
            (Presenter.refresh_response
               ~queued:true
               ~coalesced
               ~requested_at:(Time_ns.now ())))
     | _ -> method_not_allowed ())
  | [ "api"; "v1"; issue_identifier ] ->
    (match meth with
     | `GET ->
       let%bind snapshot = snapshot () in
       (match Presenter.issue_payload snapshot ~issue_identifier with
        | Some json -> respond_json json
        | None ->
          respond_error
            ~status:`Not_found
            ~code:"issue_not_found"
            ~message:"Issue not found")
     | _ -> method_not_allowed ())
  | _ -> respond_error ~status:`Not_found ~code:"not_found" ~message:"Not found"
;;

let start ~host ~port ~snapshot ~request_refresh =
  let where_to_listen =
    Tcp.Where_to_listen.bind_to
      (match Unix.Inet_addr.of_string host with
       | address -> Tcp.Bind_to_address.Address address
       | exception (_ : exn) -> Tcp.Bind_to_address.Localhost)
      (match port with
       | 0 -> Tcp.Bind_to_port.On_port_chosen_by_os
       | port -> Tcp.Bind_to_port.On_port port)
  in
  match%map
    Monitor.try_with ~run:`Schedule (fun () ->
      Server.create
        ~on_handler_error:`Ignore
        where_to_listen
        (fun ~body:(_ : Cohttp_async.Body.t) (_ : Socket.Address.Inet.t) request ->
           handle ~snapshot ~request_refresh request))
  with
  | Ok server -> Ok { server }
  | Error exn -> Or_error.of_exn (Monitor.extract_exn exn)
;;

let bound_port t = Server.listening_on t.server
let close t = Server.close t.server
