(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2020 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

open Source

class echo ~kind (source : source) delay feedback ping_pong =
  object (self)
    inherit operator ~name:"echo" kind [source] as super

    method stype = source#stype

    method remaining = source#remaining

    method seek = source#seek

    method self_sync = source#self_sync

    method is_ready = source#is_ready

    method abort_track = source#abort_track

    val mutable effect = None

    method private wake_up a =
      super#wake_up a;
      effect <-
        Some
          (Audio.Effect.delay self#audio_channels
             (Lazy.force Frame.audio_rate)
             ~ping_pong (delay ()) (feedback ()))

    val mutable past_pos = 0

    method private get_frame buf =
      let offset = AFrame.position buf in
      source#get buf;
      let b = AFrame.pcm buf in
      let position = AFrame.position buf in
      let effect = Option.get effect in
      effect#set_delay (delay ());
      effect#set_feedback (feedback ());
      effect#process (Audio.sub b offset (position - offset))
  end

let () =
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "echo"
    [
      ( "delay",
        Lang.float_getter_t (),
        Some (Lang.float 0.5),
        Some "Delay in seconds." );
      ( "feedback",
        Lang.float_getter_t (),
        Some (Lang.float (-6.)),
        Some "Feedback coefficient in dB (negative)." );
      ( "ping_pong",
        Lang.bool_t,
        Some (Lang.bool false),
        Some "Use ping-pong delay." );
      ("", Lang.source_t k, None, None);
    ]
    ~return_t:k ~category:Lang.SoundProcessing ~descr:"Add echo."
    (fun p ->
      let f v = List.assoc v p in
      let duration, feedback, pp, src =
        ( Lang.to_float_getter (f "delay"),
          Lang.to_float_getter (f "feedback"),
          Lang.to_bool (f "ping_pong"),
          Lang.to_source (f "") )
      in
      let feedback =
        (* Check the initial value, wrap the getter with a converter. *)
        if feedback () > 0. then
          raise
            (Lang_errors.Invalid_value
               (f "feedback", "feedback should be negative"));
        fun () -> Audio.lin_of_dB (feedback ())
      in
      new echo ~kind src duration feedback pp)
