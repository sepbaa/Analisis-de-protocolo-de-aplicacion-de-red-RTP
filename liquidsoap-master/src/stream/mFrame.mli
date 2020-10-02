(** MIDI frame manipulation *)

type t = Frame.t

(** Is it partially filled ? *)
val is_partial : t -> bool

(** Number size of a MIDI frame. *)
val size : unit -> int

(** Position of the first break. *)
val position : t -> int

(** Add a break. *)
val add_break : t -> int -> unit

type metadata = (string, string) Hashtbl.t

val set_metadata : t -> int -> metadata -> unit
val get_metadata : t -> int -> metadata option
val get_all_metadata : t -> (int * metadata) list

(** Get the MIDI content. Raises [Not_found] if frame has
    no midi content. *)
val content : t -> Frame_content.data

(** Get the MIDI content in [Midi] format. Raises [Frame_content.Invalid]
  * if content is not [Midi] and [Not_found] if frame has no midi content. *)
val midi : t -> Frame_content.Midi.data
