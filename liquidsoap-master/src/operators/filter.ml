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

type mode = Low_pass | High_pass | Band_pass | Notch

class filter ~kind (source : source) freq q wet mode =
  let rate = float (Lazy.force Frame.audio_rate) in
  object (self)
    inherit operator ~name:"filter" kind [source] as super

    method stype = source#stype

    method remaining = source#remaining

    method seek = source#seek

    method is_ready = source#is_ready

    method abort_track = source#abort_track

    method self_sync = source#self_sync

    val mutable low = [||]

    val mutable high = [||]

    val mutable band = [||]

    val mutable notch = [||]

    method wake_up a =
      super#wake_up a;
      let channels = self#audio_channels in
      low <- Array.make channels 0.;
      high <- Array.make channels 0.;
      band <- Array.make channels 0.;
      notch <- Array.make channels 0.

    (* State vartiable filter, see
       http://www.musicdsp.org/archive.php?classid=3#23

       TODO: the problem with this filter is that it only handles freq <= rate/4,
       we have to find something better. See
       http://www.musicdsp.org/showArchiveComment.php?ArchiveID=23

       Maybe should we implement Chamberlin's version instead, which handles freq
       <= rate/2. See http://www.musicdsp.org/archive.php?classid=3#142 *)
    method private get_frame buf =
      let offset = AFrame.position buf in
      source#get buf;
      let b = AFrame.pcm buf in
      let position = AFrame.position buf in
      let freq = freq () in
      let q = q () in
      let wet = wet () in
      let f = 2. *. sin (Float.pi *. freq /. rate) in
      for c = 0 to Array.length b - 1 do
        let b_c = b.(c) in
        for i = offset to position - 1 do
          low.(c) <- low.(c) +. (f *. band.(c));
          high.(c) <- (q *. b_c.{i}) -. low.(c) -. (q *. band.(c));
          band.(c) <- (f *. high.(c)) +. band.(c);
          notch.(c) <- high.(c) +. low.(c);
          b_c.{i} <-
            ( wet
            *.
            match mode with
              | Low_pass -> low.(c)
              | High_pass -> high.(c)
              | Band_pass -> band.(c)
              | Notch -> notch.(c) )
            +. ((1. -. wet) *. b_c.{i})
        done
      done
  end

let () =
  let kind = Lang.any in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "filter"
    [
      ("freq", Lang.float_getter_t (), None, None);
      ("q", Lang.float_getter_t (), Some (Lang.float 1.), None);
      ( "mode",
        Lang.string_t,
        None,
        Some
          "Available modes are 'low' (for low-pass filter), 'high' (for \
           high-pass filter), 'band' (for band-pass filter) and 'notch' (for \
           notch / band-stop / band-rejection filter)." );
      ( "wetness",
        Lang.float_getter_t (),
        Some (Lang.float 1.),
        Some
          "How much of the original signal should be added (1. means only \
           filtered and 0. means only original signal)." );
      ("", Lang.source_t k, None, None);
    ]
    ~return_t:k ~category:Lang.SoundProcessing
    ~descr:"Perform several kinds of filtering on the signal"
    (fun p ->
      let f v = List.assoc v p in
      let freq, q, wet, mode, src =
        ( Lang.to_float_getter (f "freq"),
          Lang.to_float_getter (f "q"),
          Lang.to_float_getter (f "wetness"),
          f "mode",
          Lang.to_source (f "") )
      in
      let mode =
        match Lang.to_string mode with
          | "low" -> Low_pass
          | "high" -> High_pass
          | "band" -> Band_pass
          | "notch" -> Notch
          | _ ->
              raise
                (Lang_errors.Invalid_value
                   (mode, "valid values are low|high|band|notch"))
      in
      (new filter ~kind src freq q wet mode :> Source.source))
