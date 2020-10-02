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

class bpm ~kind (source : source) cb every =
  let every = Frame.audio_of_seconds every in
  object (self)
    inherit operator ~name:"bpm" kind [source] as super

    method stype = source#stype

    method is_ready = source#is_ready

    method self_sync = source#self_sync

    method remaining = source#remaining

    method seek = source#seek

    method abort_track = source#abort_track

    val mutable bpm = None

    method wake_up a =
      super#wake_up a;
      bpm <-
        Some
          (Soundtouch.BPM.make
             (Frame_content.Audio.channels_of_format self#ctype.Frame.audio)
             (Lazy.force Frame.audio_rate))

    val mutable n = 0

    method private get_frame buf =
      let bpm = Option.get bpm in
      let offset = AFrame.position buf in
      source#get buf;
      let len = AFrame.position buf - offset in
      let buf = AFrame.pcm buf in
      let ibuf = Audio.interleave (Audio.sub buf offset len) in
      Soundtouch.BPM.put_samples_ba bpm ibuf;
      n <- n + len;
      if n >= every then (
        n <- 0;
        let bpm = Soundtouch.BPM.get_bpm bpm in
        ignore (cb [("", Lang.float bpm)]) )
  end

let () =
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "bpm"
    [
      ( "every",
        Lang.float_t,
        Some (Lang.float 1.),
        Some "Interval at which BPM is computed (in second)." );
      ( "",
        Lang.fun_t [(false, "", Lang.float_t)] Lang.unit_t,
        None,
        Some "Callback function." );
      ("", Lang.source_t k, None, None);
    ]
    ~return_t:k ~category:Lang.SoundProcessing ~descr:"Detect the BPM."
    ~flags:[]
    (fun p ->
      let f v = List.assoc v p in
      let every = Lang.to_float (f "every") in
      let cb = Lang.to_fun (Lang.assoc "" 1 p) in
      let s = Lang.to_source (Lang.assoc "" 2 p) in
      (new bpm ~kind s cb every :> Source.source))
