open Core.Std

module Platform = Async_OpenFlow_Platform
module Header = OpenFlow_Header
module M = OpenFlow0x04.Message
module C = OpenFlow0x04_Core

module Message : Platform.Message with type t = (Header.xid * M.t) = struct

  type t = (Header.xid * M.t) sexp_opaque with sexp

  let header_of (xid, m)= M.header_of xid m
  let parse hdr buf = M.parse hdr (Cstruct.to_string buf)
  let marshal (xid, m) buf = M.marshal_body m buf
  let to_string (_, m) = M.to_string m

  let marshal' msg =
    let hdr = header_of msg in
    let body_len = hdr.Header.length - Header.size in
    let body_buf = Cstruct.create body_len in
    marshal msg body_buf;
    (hdr, body_buf)
end

include Async_OpenFlow_Message.MakeSerializers (Message)

module Controller = struct
  open Async.Std

  module Log = Async_OpenFlow_Log
  let tags = [("openflow", "openflow0x04")]

  module ChunkController = Async_OpenFlowChunk.Controller
  module Client_id = struct
    module T = struct
      type t = SDN_Types.switchId with sexp
      let compare = compare
      let hash = Hashtbl.hash
    end
    include T
    include Hashable.Make(T)
  end

  module ClientMap = ChunkController.Client_id.Table
  module ClientSet = ChunkController.Client_id.Hash_set
  module SwitchMap = Client_id.Table

  module OF0x04 = OpenFlow0x04

  type state
    = Initialized
    | AwaitingPorts of OF0x04.SwitchFeatures.t * C.xid option * C.portDesc list

  type m = Message.t
  type c = OpenFlow0x04.SwitchFeatures.t * (C.portDesc list)
  type t =
    { sub : ChunkController.t
    ; shakes : state ClientMap.t
    ; c2s : SDN_Types.switchId ClientMap.t
    ; s2c : ChunkController.Client_id.t SwitchMap.t
    }

  type e = (Client_id.t, c, m) Platform.event


  let set_monitor_interval (t:t) (s:Time.Span.t) : unit =
    ChunkController.set_monitor_interval t.sub s

  let set_idle_wait (t:t) (s:Time.Span.t) : unit =
    ChunkController.set_idle_wait t.sub s

  let set_kill_wait (t:t) (s:Time.Span.t) : unit =
    ChunkController.set_kill_wait t.sub s


  let openflow0x04 t evt =
    match evt with
      | `Message (s_id, (hdr, bits)) ->
        return [`Message (s_id, Message.parse hdr bits)]
      | `Connect (c_id, version) ->
        if version = 0x04 then
          return [`Connect(c_id, ())]
        else begin
          ChunkController.close t.sub c_id;
          raise (ChunkController.Handshake (c_id, Printf.sprintf
                    "Negotiated switch version mismatch: expected %d but got %d%!"
                    0x04 version))
        end
      | `Disconnect e -> return [`Disconnect e]

  let create_from_chunk t =
    { sub = t
    ; shakes = ClientMap.create ()
    ; c2s = ClientMap.create ()
    ; s2c = SwitchMap.create ()
    }

  let create ?max_pending_connections
      ?verbose
      ?log_disconnects
      ?buffer_age_limit
      ?monitor_connections ~port () =
    ChunkController.create ?max_pending_connections ?verbose ?log_disconnects
      ?buffer_age_limit ?monitor_connections ~port ()
    >>| create_from_chunk

  (* XXX(seliopou): Raises `Not_found` if the client is no longer connected. *)
  let switch_id_of_client_exn t c_id = ClientMap.find_exn t.c2s c_id
  let client_id_of_switch_exn t sw_id = SwitchMap.find_exn t.s2c sw_id

  let switch_id_of_client t c_id = ClientMap.find t.c2s c_id
  let client_id_of_switch t sw_id = SwitchMap.find t.s2c sw_id

  let close t sw_id =
    let c_id = client_id_of_switch_exn t sw_id in
    ChunkController.close t.sub c_id

  let has_client_id t sw_id =
    let c_id = client_id_of_switch_exn t sw_id in
    ChunkController.has_client_id t.sub c_id

  let send t sw_id msg =
    let c_id = client_id_of_switch_exn t sw_id in
    ChunkController.send t.sub c_id (Message.marshal' msg)

  let send_result t sw_id msg =
    send t sw_id msg
    >>| function
      | `Sent t   -> Result.Ok ()
      | `Drop exn -> Result.Error exn

  let send_txn t sw_id msg =
    let c_id = client_id_of_switch_exn t sw_id in
    let xid  = ChunkController.client_next_xid t.sub c_id in
    ChunkController.send_txn t.sub c_id (Message.marshal' (xid, msg))

  let send_txn_with t sw_id msg f =
    try begin
      send_txn t sw_id msg
      >>= function
        | `Sent def -> def >>| f
        | `Drop exn -> return (Result.Error exn)
    end with Not_found -> return (Result.Error Not_found)

  let send_ignore_errors t sw_id msg =
    let c_id = client_id_of_switch_exn t sw_id in
    ChunkController.send_ignore_errors t.sub c_id (Message.marshal' msg)

  let send_to_all t msg = ChunkController.send_to_all t.sub (Message.marshal' msg)

  let client_addr_port t sw_id =
    let c_id = client_id_of_switch_exn t sw_id in
    ChunkController.client_addr_port t.sub c_id

  let listening_port t =
    ChunkController.listening_port t.sub

  let features t evt =
    match evt with
    | `Connect(c_id, ()) ->
      begin match ClientMap.add t.shakes c_id Initialized with
      | `Duplicate -> assert false
      | `Ok -> ()
      end;
      let req = (0l, M.FeaturesRequest) in
      ChunkController.send t.sub c_id (Message.marshal' req)
      (* XXX(seliopou): This swallows any errors that might have occurred
       * while attemping the handshake. Any such error should not be raised,
       * since as far as the user is concerned the connection never existed.
       * At the very least, the exception should be logged, which it will be
       * as long as the log_disconnects option is not disabled when creating
       * the controller.
       * *)
      >>| (function _ -> [])
    | `Message (c_id, (xid, msg)) when ClientMap.mem t.shakes c_id ->
      begin match ClientMap.find_exn t.shakes c_id, msg with
      | Initialized, M.FeaturesReply fs ->
        ClientMap.replace t.shakes c_id (AwaitingPorts(fs, None, []));
        let req = (0l, M.MultipartReq C.portDescReq) in
        ChunkController.send t.sub c_id (Message.marshal' req)
        (* XXX(seliopou): This swallows any errors that might have occurred
         * while attemping the handshake. Any such error should not be raised,
         * since as far as the user is concerned the connection never existed.
         * At the very least, the exception should be logged, which it will be
         * as long as the log_disconnects option is not disabled when creating
         * the controller.
         * *)
        >>| (function _ -> [])
      | AwaitingPorts(fs, m_xid, ps), M.MultipartReply {
          C.mpreply_typ = C.PortsDescReply pds;
          C.mpreply_flags = more } ->
        let m_xid', ps' = match m_xid with
          | Some(xid') -> m_xid, if xid = xid' then pds @ ps else ps
          | None       -> Some(xid), pds @ ps
        in
        if more then begin
          let state' = AwaitingPorts(fs, m_xid', ps') in
          ClientMap.replace t.shakes c_id state';
          return []
        end else begin
          let sw_id = fs.OpenFlow0x04.SwitchFeatures.datapath_id in
          ClientMap.add_exn t.c2s c_id sw_id;
          SwitchMap.add_exn t.s2c sw_id c_id;
          ClientMap.remove t.shakes c_id;
          return [`Connect(sw_id, (fs, ps'))]
        end
      | _, _ ->
        Log.printf ~tags ~level:`Debug
          "Dropped message during handshake: %s"
            (Message.to_string (xid, msg));
        return []
      end
    | `Message (c_id, msg) ->
      return [`Message(switch_id_of_client_exn t c_id, msg)]
    | `Disconnect(c_id, exn) ->
      match switch_id_of_client t c_id with
        | None -> (* features request did not complete *)
          begin match ClientMap.find_and_remove t.shakes c_id with
          | None   -> return []
          | Some _ -> assert false
          end
        | Some(sw_id) -> (* features request did complete *)
          ClientMap.remove t.c2s c_id;
          SwitchMap.remove t.s2c sw_id;
          return [`Disconnect(sw_id, exn)]

  let listen_pipe t p =
    let open Async_OpenFlow_Stage in
    run (openflow0x04 >=> features) t p

  let listen t =
    let open Async_OpenFlow_Stage in
    let open ChunkController in
    listen_pipe t (run (handshake 0x04) t.sub (listen t.sub))

  let clear_flows ?(pattern=C.match_all) (t:t) (sw_id:Client_id.t) =
    send_result t sw_id (0l, M.FlowModMsg
      { C.delete_all_flows with C.mfOfp_match = pattern })

  let clear_groups ?(pattern=C.(All,0xfffffffcl)) (t:t) (sw_id:Client_id.t) =
    let typ, id = pattern in
    send_result t sw_id (0l, M.GroupModMsg (C.DeleteGroup(typ, id)))

  let send_flow_mods ?(clear=true) (t : t) (sw_id : Client_id.t) flow_mods =
    let open Deferred.Result in
    begin if clear then clear_flows t sw_id else return () end
    >>= fun () ->
      let sends = List.map flow_mods
        ~f:(fun f -> send_result t sw_id (0l, M.FlowModMsg f))
      in
      all_ignore sends

  let send_pkt_out (t : t) (sw_id : Client_id.t) pkt_out =
    send_result t sw_id (0l, M.PacketOutMsg pkt_out)

  let barrier t sw_id =
    send_txn_with t sw_id M.BarrierRequest (function
      | `Result (hdr, body) ->
       (match M.parse hdr (Cstruct.to_string body) with
        | (_, M.BarrierReply) -> Result.Ok ()
        | _ -> assert false)
      | _              -> assert false)

end
