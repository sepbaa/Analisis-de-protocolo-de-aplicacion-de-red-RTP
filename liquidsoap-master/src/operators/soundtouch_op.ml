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
module Generator = Generator.From_audio_video

class soundtouch ~kind (source : source) rate tempo pitch =
  let abg = Generator.create `Audio in
  object (self)
    inherit operator ~name:"soundtouch" kind [source] as super

    val mutable st = None

    val mutable databuf = Frame.dummy

    method wake_up a =
      super#wake_up a;
      databuf <- Frame.create self#ctype;
      st <-
        Some (Soundtouch.make self#audio_channels (Lazy.force Frame.audio_rate));
      self#log#important "Using soundtouch %s."
        (Soundtouch.get_version_string (Option.get st))

    method private set_clock =
      let slave_clock = Clock.create_known (new Clock.clock self#id) in
      (* Our external clock should stricly contain the slave clock. *)
      Clock.unify self#clock
        (Clock.create_unknown ~sources:[] ~sub_clocks:[slave_clock]);
      Clock.unify slave_clock source#clock;

      (* Make sure the slave clock can be garbage collected, cf. cue_cut(). *)
      Gc.finalise (fun self -> Clock.forget self#clock slave_clock) self

    method private slave_tick =
      (Clock.get source#clock)#end_tick;
      source#after_output;
      Frame.advance databuf

    method stype = source#stype

    method self_sync = false

    method is_ready = Generator.length abg > 0 || source#is_ready

    method remaining = Generator.remaining abg

    method abort_track =
      Generator.clear abg;
      source#abort_track

    method private feed =
      let st = Option.get st in
      Soundtouch.set_rate st (rate ());
      Soundtouch.set_tempo st (tempo ());
      Soundtouch.set_pitch st (pitch ());
      AFrame.clear databuf;
      source#get databuf;
      let db = AFrame.pcm databuf in
      let db = Audio.interleave db in
      Soundtouch.put_samples_ba st db;
      let available = Soundtouch.get_available_samples st in
      if available > 0 then (
        let tmp =
          Bigarray.Array1.create Bigarray.float32 Bigarray.c_layout
            (self#audio_channels * available)
        in
        ignore (Soundtouch.get_samples_ba st tmp);
        let tmp = Audio.deinterleave self#audio_channels tmp in
        Generator.put_audio abg
          (Frame_content.Audio.lift_data tmp)
          0
          (Frame.master_of_audio available) );
      if AFrame.is_partial databuf then Generator.add_break abg;

      (* It's almost impossible to know where to add metadata,
       * b/c of tempo so we add then right here. *)
      List.iter
        (fun (_, m) -> Generator.add_metadata abg m)
        (AFrame.get_all_metadata databuf);
      self#slave_tick

    method private get_frame buf =
      let need = AFrame.size () - AFrame.position buf in
      while Generator.length abg < need && source#is_ready do
        self#feed
      done;
      Generator.fill abg buf
  end

let () =
  (* TODO: could we keep the video in some cases? *)
  let kind = Lang.audio_pcm in
  let return_t = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "soundtouch"
    [
      ("rate", Lang.float_getter_t (), Some (Lang.float 1.0), None);
      ("tempo", Lang.float_getter_t (), Some (Lang.float 1.0), None);
      ("pitch", Lang.float_getter_t (), Some (Lang.float 1.0), None);
      ("", Lang.source_t return_t, None, None);
    ]
    ~category:Lang.SoundProcessing ~return_t
    ~descr:"Change the rate, the tempo or the pitch of the sound."
    ~flags:[Lang.Experimental]
    (fun p ->
      let f v = List.assoc v p in
      let rate = Lang.to_float_getter (f "rate") in
      let tempo = Lang.to_float_getter (f "tempo") in
      let pitch = Lang.to_float_getter (f "pitch") in
      let s = Lang.to_source (f "") in
      (new soundtouch ~kind s rate tempo pitch :> Source.source))
