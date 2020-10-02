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

(** Decode and read metadata from flac files. *)

let log = Log.make ["decoder"; "flac"]

exception End_of_stream

let create_decoder input =
  let read = input.Decoder.read in
  let seek =
    match input.Decoder.lseek with
      | Some f -> Some (fun len -> ignore (f (Int64.to_int len)))
      | None -> None
  in
  let tell =
    match input.Decoder.tell with
      | Some f -> Some (fun () -> Int64.of_int (f ()))
      | None -> None
  in
  let length =
    match input.Decoder.length with
      | Some f -> Some (fun () -> Int64.of_int (f ()))
      | None -> None
  in
  let dummy_c =
    Flac.Decoder.get_callbacks ?seek ?tell ?length read (fun _ -> ())
  in
  let decoder = Flac.Decoder.create dummy_c in
  let decoder, info, _ = Flac.Decoder.init decoder dummy_c in
  let samplerate, _ =
    (info.Flac.Decoder.sample_rate, info.Flac.Decoder.channels)
  in
  let processed = ref Int64.zero in
  {
    Decoder.seek =
      (fun ticks ->
        let duration = Frame.seconds_of_master ticks in
        let samples = Int64.of_float (duration *. float samplerate) in
        let pos = Int64.add !processed samples in
        let c =
          Flac.Decoder.get_callbacks ?seek ?tell ?length read (fun _ -> ())
        in
        let ret = Flac.Decoder.seek decoder c pos in
        if ret = true then (
          processed := pos;
          ticks )
        else (
          match Flac.Decoder.state decoder c with
            | `Seek_error ->
                if Flac.Decoder.flush decoder c then 0
                else
                  (* Flushing failed, we are in an unknown state.. *)
                  raise End_of_stream
            | _ -> 0 ));
    decode =
      (fun buffer ->
        let c =
          Flac.Decoder.get_callbacks ?seek ?tell ?length read (fun data ->
              let data = Audio.of_array data in
              let len = try Audio.length data with _ -> 0 in
              processed := Int64.add !processed (Int64.of_int len);
              buffer.Decoder.put_pcm ~samplerate data)
        in
        match Flac.Decoder.state decoder c with
          | `Search_for_metadata | `Read_metadata | `Search_for_frame_sync
          | `Read_frame ->
              Flac.Decoder.process decoder c
          | _ -> raise End_of_stream);
  }

(** Configuration keys for flac. *)
let mime_types =
  Dtools.Conf.list
    ~p:(Decoder.conf_mime_types#plug "flac")
    "Mime-types used for guessing FLAC format"
    ~d:["audio/flac"; "audio/x-flac"]

let file_extensions =
  Dtools.Conf.list
    ~p:(Decoder.conf_file_extensions#plug "flac")
    "File extensions used for guessing FLAC format" ~d:["flac"]

let priority =
  Dtools.Conf.int
    ~p:(Decoder.conf_priorities#plug "flac")
    "Priority for the flac decoder" ~d:1

(* Get the number of channels of audio in an MP3 file.
 * This is done by decoding a first chunk of data, thus checking
 * that libmad can actually open the file -- which doesn't mean much. *)
let file_type filename =
  let fd = Unix.openfile filename [Unix.O_RDONLY; Unix.O_CLOEXEC] 0o640 in
  Tutils.finalize
    ~k:(fun () -> Unix.close fd)
    (fun () ->
      let write _ = () in
      let h = Flac.Decoder.File.create_from_fd write fd in
      let info = h.Flac.Decoder.File.info in
      let rate, channels =
        (info.Flac.Decoder.sample_rate, info.Flac.Decoder.channels)
      in
      log#info "Libflac recognizes %S as FLAC (%dHz,%d channels)." filename rate
        channels;
      Some
        {
          Frame.audio = Frame_content.Audio.format_of_channels channels;
          video = Frame_content.None.format;
          midi = Frame_content.None.format;
        })

let file_decoder ~metadata:_ ~ctype filename =
  Decoder.opaque_file_decoder ~filename ~ctype create_decoder

let () =
  Decoder.decoders#register "FLAC"
    ~sdoc:
      "Use libflac to decode any file or stream if its MIME type or file \
       extension is appropriate."
    {
      Decoder.media_type = `Audio;
      priority = (fun () -> priority#get);
      file_extensions = (fun () -> Some file_extensions#get);
      mime_types = (fun () -> Some mime_types#get);
      file_type = (fun ~ctype:_ filename -> file_type filename);
      file_decoder = Some file_decoder;
      stream_decoder = Some (fun ~ctype:_ _ -> create_decoder);
    }

let log = Log.make ["metadata"; "flac"]

let get_tags file =
  if
    not
      (Decoder.test_file ~log ~mimes:mime_types#get
         ~extensions:file_extensions#get file)
  then raise Not_found;
  let fd = Unix.openfile file [Unix.O_RDONLY; Unix.O_CLOEXEC] 0o640 in
  Tutils.finalize
    ~k:(fun () -> Unix.close fd)
    (fun () ->
      let write _ = () in
      let h = Flac.Decoder.File.create_from_fd write fd in
      match h.Flac.Decoder.File.comments with Some (_, m) -> m | None -> [])

let () = Request.mresolvers#register "FLAC" get_tags

let check filename =
  match Configure.file_mime with
    | Some f -> List.mem (f filename) mime_types#get
    | None -> (
        try
          ignore (file_type filename);
          true
        with _ -> false )

let duration file =
  if not (check file) then raise Not_found;
  let fd = Unix.openfile file [Unix.O_RDONLY; Unix.O_CLOEXEC] 0o640 in
  Tutils.finalize
    ~k:(fun () -> Unix.close fd)
    (fun () ->
      let write _ = () in
      let h = Flac.Decoder.File.create_from_fd write fd in
      let info = h.Flac.Decoder.File.info in
      match info.Flac.Decoder.total_samples with
        | x when x = Int64.zero -> raise Not_found
        | x -> Int64.to_float x /. float info.Flac.Decoder.sample_rate)

let () = Request.dresolvers#register "FLAC" duration
