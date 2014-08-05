open Packet
open OpenFlow0x05_Core

type msg_code =  | HELLO | ERROR | ECHO_REQ | ECHO_RESP | EXPERIMENTER | FEATURES_REQ
                 | FEATURES_RESP | GET_CONFIG_REQ | GET_CONFIG_RESP 
                 | SET_CONFIG | PACKET_IN | FLOW_REMOVED | PORT_STATUS | PACKET_OUT
                 | FLOW_MOD | GROUP_MOD | PORT_MOD | TABLE_MOD | MULTIPART_REQ
                 | MULTIPART_RESP | BARRIER_REQ | BARRIER_RESP | ROLE_REQ 
                 | ROLE_RESP | GET_ASYNC_REQ | GET_ASYNC_REP | SET_ASYNC 
                 | METER_MOD | ROLE_STATUS | TABLE_STATUS | REQUEST_FORWARD 
                 | BUNDLE_CONTROL | BUNDLE_ADD_MESSAGE

module PortDesc : sig

  module Config : sig

    type t = portConfig

    val marshal : t -> int32

    val parse : int32 -> t

    val to_string : t -> string

  end

  module State : sig

    type t = portState

    val marshal : t -> int32

    val parse : int32 -> t

    val to_string : t -> string

  end

  module Properties : sig

   type t = portProp

   val sizeof : t -> int

   val to_string : t -> string

   val marshal : Cstruct.t -> t -> int

   val parse : Cstruct.t -> t

  end

  type t = portDesc

  val sizeof : t -> int

  val to_string : t -> string

  val marshal : Cstruct.t -> t -> int

  val parse : Cstruct.t -> t

end

module Oxm : sig

  type t = oxm

  val field_name : t -> string

  val sizeof : t -> int 

  val sizeof_headers : t list -> int

  val to_string : t -> string

  val marshal : Cstruct.t -> t -> int

  val marshal_header : Cstruct.t -> t -> int

  val parse : Cstruct.t -> t * Cstruct.t

  val parse_header : Cstruct.t -> t * Cstruct.t

end

module OfpMatch : sig

  type t = oxmMatch

  val sizeof : t -> int

  val to_string : t -> string 

  val marshal : Cstruct.t -> t -> int

  val parse : Cstruct.t -> t * Cstruct.t

end

module PseudoPort : sig

  type t = pseudoPort

  val size_of : t -> int

  val to_string : t -> string

  val marshal : t -> int32

  val make : int32 -> int16 -> t

end

module Action : sig

  type sequence = OpenFlow0x05_Core.actionSequence

  type t = action

  val sizeof : t -> int

  val marshal : Cstruct.t -> t -> int

  val parse : Cstruct.t -> t

  val parse_sequence : Cstruct.t -> sequence

  val to_string :  t -> string
    
end

module Instruction : sig

  type t = instruction

  val to_string : t -> string

  val sizeof : t -> int

  val marshal : Cstruct.t -> t -> int

  val parse : Cstruct.t ->  t

end

module Instructions : sig

  type t = instruction list

  val sizeof : t -> int

  val marshal : Cstruct.t -> t -> int

  val to_string : t -> string

  val parse : Cstruct.t -> t

end

module Experimenter : sig

  type t = experimenter

  val sizeof : t -> int

  val marshal : Cstruct.t -> t -> int

  val to_string : t -> string

  val parse : Cstruct.t -> t

end

module SwitchFeatures : sig

  type t = { datapath_id : int64; num_buffers : int32;
             num_tables : int8; aux_id : int8;
             supported_capabilities : switchCapabilities }

  val sizeof : t -> int

  val to_string : t -> string

  val marshal : Cstruct.t -> t -> int

  val parse : Cstruct.t -> t

end

module SwitchConfig : sig

  type t = switchConfig

  val sizeof : t -> int

  val to_string : t -> string

  val marshal : Cstruct.t -> t -> int

  val parse : Cstruct.t -> t

end

module Message : sig

  type t =
    | Hello
    | EchoRequest of bytes
    | EchoReply of bytes
    | Experimenter of Experimenter.t
    | FeaturesRequest
    | FeaturesReply of SwitchFeatures.t
    | GetConfigRequestMsg of SwitchConfig.t
    | GetConfigReplyMsg of SwitchConfig.t
    | SetConfigMsg of SwitchConfig.t

  val sizeof : t -> int

  val to_string : t -> string

  val blit_message : t -> Cstruct.t -> int
  
  val header_of : xid -> t -> OpenFlow_Header.t

  val marshal : xid -> t -> string

  val parse : OpenFlow_Header.t -> string -> (xid * t)
  
  val marshal_body : t -> Cstruct.t -> unit
   
end