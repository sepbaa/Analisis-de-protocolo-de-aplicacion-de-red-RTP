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

open Frame

type t = Frame.t

(* Samples of ticks, and vice versa. *)
let sot = audio_of_master
let tos = master_of_audio
let content b = b.content.audio
let pcm b = Frame_content.Audio.get_data (content b)

let to_s16le b =
  let fpcm = pcm b in
  assert (Audio.channels fpcm = 2);
  Audio.S16LE.make fpcm

let duration () = Lazy.force duration
let size () = sot (Lazy.force size)
let position t = sot (position t)
let breaks t = List.map sot (breaks t)
let add_break t i = add_break t (tos i)
let set_breaks t l = set_breaks t (List.map tos l)
let is_partial = is_partial
let advance = advance
let clear = clear

exception No_metadata

type metadata = (string, string) Hashtbl.t

let set_metadata t i m = set_metadata t (tos i) m
let get_metadata t i = get_metadata t (tos i)

let get_all_metadata t =
  List.map (fun (x, y) -> (sot x, y)) (get_all_metadata t)

let set_all_metadata t l =
  set_all_metadata t (List.map (fun (x, y) -> (tos x, y)) l)

let free_metadata = free_metadata
let free_all_metadata = free_all_metadata
let blankify b off len = Audio.clear (Audio.sub (pcm b) off len)
let multiply b off len c = Audio.amplify c (Audio.sub (pcm b) off len)

let add b1 off1 b2 off2 len =
  Audio.add (Audio.sub (pcm b1) off1 len) (Audio.sub (pcm b2) off2 len)

let rms b off len = Audio.Analyze.rms (Audio.sub (pcm b) off len)
