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

(** FFMPEG encoder *)

let log = Ffmpeg_utils.log

type encoder = {
  mk_stream : Frame.t -> unit;
  encode : Frame.t -> int -> int -> unit;
}

type handler = {
  output : Avutil.output Avutil.container;
  audio_stream : encoder option;
  video_stream : encoder option;
  mutable started : bool;
}

let mk_format ffmpeg =
  match (ffmpeg.Ffmpeg_format.format, ffmpeg.Ffmpeg_format.output) with
    | short_name, `Url filename ->
        Av.Format.guess_output_format ~filename ?short_name ()
    | Some short_name, _ -> Av.Format.guess_output_format ~short_name ()
    | _ -> None

let encode ~encoder frame start len =
  if not encoder.started then (
    ignore
      (Option.map (fun { mk_stream } -> mk_stream frame) encoder.audio_stream);
    ignore
      (Option.map (fun { mk_stream } -> mk_stream frame) encoder.video_stream) );
  encoder.started <- true;
  ignore
    (Option.map (fun { encode } -> encode frame start len) encoder.audio_stream);
  ignore
    (Option.map (fun { encode } -> encode frame start len) encoder.video_stream)

let insert_metadata ~encoder m =
  let m =
    Hashtbl.fold (fun lbl v l -> (lbl, v) :: l) (Meta_format.to_metadata m) []
  in
  if not (Av.output_started encoder.output) then
    Av.set_output_metadata encoder.output m

(* Convert ffmpeg-specific options. *)
let convert_options opts =
  let convert name fn =
    match Hashtbl.find_opt opts name with
      | None -> ()
      | Some v -> Hashtbl.replace opts name (fn v)
  in
  convert "sample_fmt" (function
    | `String fmt -> `Int Avutil.Sample_format.(get_id (find fmt))
    | _ -> assert false);
  convert "channel_layout" (function
    | `String layout -> `Int64 Avutil.Channel_layout.(get_id (find layout))
    | _ -> assert false)

let encoder ~mk_audio ~mk_video ffmpeg meta =
  let buf = Strings.Mutable.empty () in
  let make () =
    let options = Hashtbl.copy ffmpeg.Ffmpeg_format.other_opts in
    convert_options options;
    let write str ofs len =
      Strings.Mutable.add_subbytes buf str ofs len;
      len
    in
    let format = mk_format ffmpeg in
    let output =
      match ffmpeg.Ffmpeg_format.output with
        | `Stream ->
            if format = None then failwith "format is required!";
            Av.open_output_stream ~opts:options write (Option.get format)
        | `Url url -> Av.open_output ?format ~opts:options url
    in
    let audio_stream =
      Option.map
        (fun _ -> mk_audio ~ffmpeg ~options output)
        ffmpeg.Ffmpeg_format.audio_codec
    in
    let video_stream =
      Option.map
        (fun _ -> mk_video ~ffmpeg ~options output)
        ffmpeg.Ffmpeg_format.video_codec
    in
    if Hashtbl.length options > 0 then
      failwith
        (Printf.sprintf "Unrecognized options: %s"
           (Ffmpeg_format.string_of_options options));
    { output; audio_stream; video_stream; started = false }
  in
  let encoder = ref (make ()) in
  let encode frame start len =
    encode ~encoder:!encoder frame start len;
    Strings.Mutable.flush buf
  in
  let insert_metadata m = insert_metadata ~encoder:!encoder m in
  insert_metadata meta;
  let stop () =
    Av.close !encoder.output;
    Strings.Mutable.flush buf
  in
  { Encoder.insert_metadata; header = Strings.empty; encode; stop }
