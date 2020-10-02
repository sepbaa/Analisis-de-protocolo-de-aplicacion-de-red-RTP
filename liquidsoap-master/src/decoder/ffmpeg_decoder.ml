(*****************************************************************************

   Liquidsoap, a programmable audio stream generator.
   Copyright 2003-2017 Savonet team

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

(** Decode and read metadata using ffmpeg. *)

exception End_of_file
exception No_stream

module Generator = Decoder.G

let log = Log.make ["decoder"; "ffmpeg"]

(** Configuration keys for ffmpeg. *)
let mime_types =
  Dtools.Conf.list
    ~p:(Decoder.conf_mime_types#plug "ffmpeg")
    "Mime-types used for decoding with ffmpeg"
    ~d:
      [
        "audio/vnd.wave";
        "audio/wav";
        "audio/wave";
        "audio/x-wav";
        "audio/aac";
        "audio/aacp";
        "audio/x-hx-aac-adts";
        "audio/flac";
        "audio/x-flac";
        "audio/mpeg";
        "audio/MPA";
        "video/x-ms-asf";
        "video/x-msvideo";
        "audio/mp4";
        "application/mp4";
        "video/mp4";
        "video/3gpp";
        "video/webm";
        "video/x-matroska";
        "video/mp2t";
        "video/MP2T";
        "application/ogg";
        "application/x-ogg";
        "audio/x-ogg";
        "audio/ogg";
        "video/ogg";
        "video/webm";
        "application/ffmpeg";
      ]

let file_extensions =
  Dtools.Conf.list
    ~p:(Decoder.conf_file_extensions#plug "ffmpeg")
    "File extensions used for decoding with ffmpeg"
    ~d:
      [
        "mp1";
        "mp2";
        "mp3";
        "m4a";
        "m4b";
        "m4p";
        "m4v";
        "m4r";
        "3gp";
        "mp4";
        "wav";
        "flac";
        "ogv";
        "oga";
        "ogx";
        "ogg";
        "opus";
        "wma";
        "webm";
        "wmv";
        "avi";
        "mkv";
        "aac";
        "osb";
      ]

let priority =
  Dtools.Conf.int
    ~p:(Decoder.conf_priorities#plug "ffmpeg")
    "Priority for the ffmpeg decoder" ~d:10

let duration file =
  let container = Av.open_input file in
  Tutils.finalize
    ~k:(fun () -> Av.close container)
    (fun () ->
      let duration = Av.get_input_duration container ~format:`Millisecond in
      Option.map (fun d -> Int64.to_float d /. 1000.) duration)

let () =
  Request.dresolvers#register "FFMPEG" (fun fname ->
      match duration fname with None -> raise Not_found | Some d -> d)

let get_tags file =
  let container = Av.open_input file in
  Tutils.finalize
    ~k:(fun () -> Av.close container)
    (fun () -> Av.get_input_metadata container)

let () = Request.mresolvers#register "FFMPEG" get_tags

(* Get the type of an input container. *)
let get_type ~ctype ~url container =
  let audio_params, descr =
    try
      let _, _, params = Av.find_best_audio_stream container in
      let channels = Avcodec.Audio.get_nb_channels params in
      let samplerate = Avcodec.Audio.get_sample_rate params in
      let codec_name =
        Avcodec.Audio.string_of_id (Avcodec.Audio.get_params_id params)
      in
      ( Some params,
        [
          Printf.sprintf "audio: {codec: %s, %dHz, %d channel(s)}" codec_name
            samplerate channels;
        ] )
    with Avutil.Error _ -> (None, [])
  in
  let video_params, descr =
    try
      let _, _, params = Av.find_best_video_stream container in
      let width = Avcodec.Video.get_width params in
      let height = Avcodec.Video.get_height params in
      let pixel_format =
        match Avcodec.Video.get_pixel_format params with
          | None -> "unknown"
          | Some f -> Avutil.Pixel_format.to_string f
      in
      let codec_name =
        Avcodec.Video.string_of_id (Avcodec.Video.get_params_id params)
      in
      ( Some params,
        Printf.sprintf "video: {codec: %s, %dx%d, %s}" codec_name width height
          pixel_format
        :: descr )
    with Avutil.Error _ -> (None, descr)
  in
  if audio_params = None && video_params = None then
    failwith "No valid stream found in file.";
  let audio =
    match (audio_params, ctype.Frame.audio) with
      | None, _ -> Frame_content.None.format
      | Some p, format when Ffmpeg_copy_content.Audio.is_format format ->
          ignore
            (Frame_content.merge format
               Ffmpeg_copy_content.(Audio.lift_params (Some p)));
          format
      | Some p, format when Ffmpeg_raw_content.Audio.is_format format ->
          ignore
            (Frame_content.merge format
               Ffmpeg_raw_content.(Audio.lift_params (AudioSpecs.mk_params p)));
          format
      | Some p, _ ->
          Frame_content.(
            Audio.lift_params
              {
                Contents.channel_layout =
                  Audio_converter.Channel_layout.layout_of_channels
                    (Avcodec.Audio.get_nb_channels p);
              })
  in
  let video =
    match (video_params, ctype.Frame.video) with
      | None, _ -> Frame_content.None.format
      | Some p, format when Ffmpeg_copy_content.Video.is_format format ->
          ignore
            (Frame_content.merge format
               Ffmpeg_copy_content.(Video.lift_params (Some p)));
          format
      | Some p, format when Ffmpeg_raw_content.Video.is_format format ->
          ignore
            (Frame_content.merge format
               Ffmpeg_raw_content.(Video.lift_params (VideoSpecs.mk_params p)));
          format
      | _ -> Frame_content.(default_format Video.kind)
  in
  let ctype = { Frame.audio; video; midi = Frame_content.None.format } in
  log#info "ffmpeg recognizes %S as: %s and content-type: %s." url
    (String.concat ", " (List.rev descr))
    (Frame.string_of_content_type ctype);
  ctype

let seek ~audio ~video ~target_position ticks =
  let tpos = Frame.seconds_of_master ticks in
  log#debug "Setting target position to %f" tpos;
  target_position := Some tpos;
  let position = Int64.of_float (tpos *. 1000.) in
  let seek stream =
    try
      Av.seek stream `Millisecond position [| Av.Seek_flag_backward |];
      ticks
    with Avutil.Error _ -> 0
  in
  match (audio, video) with
    | Some (`Packet (_, s, _)), _ -> seek s
    | _, Some (`Packet (_, s, _)) -> seek s
    | Some (`Frame (_, s, _)), _ -> seek s
    | _, Some (`Frame (_, s, _)) -> seek s
    | _ -> raise No_stream

let mk_decoder ?audio ?video ~target_position container =
  let no_decoder = (-1, [], fun ~buffer:_ _ -> assert false) in
  let pack (idx, stream, decoder) = (idx, [stream], decoder) in
  let ( (audio_frame_idx, audio_frame, audio_frame_decoder),
        (audio_packet_idx, audio_packet, audio_packet_decoder) ) =
    match audio with
      | None -> (no_decoder, no_decoder)
      | Some (`Packet packet) -> (no_decoder, pack packet)
      | Some (`Frame frame) -> (pack frame, no_decoder)
  in
  let ( (video_frame_idx, video_frame, video_frame_decoder),
        (video_packet_idx, video_packet, video_packet_decoder) ) =
    match video with
      | None -> (no_decoder, no_decoder)
      | Some (`Packet packet) -> (no_decoder, pack packet)
      | Some (`Frame frame) -> (pack frame, no_decoder)
  in
  let check_pts stream pts =
    match (pts, !target_position) with
      | Some pts, Some target_position ->
          let { Avutil.num; den } = Av.get_time_base stream in
          let position = Int64.to_float pts *. float num /. float den in
          if position < target_position then
            log#debug
              "Current position: %f is less than target position: %f, \
               skipping.."
              position target_position;
          position <= target_position
      | _ -> true
  in
  fun buffer ->
    let rec f () =
      match
        Av.read_input ~audio_frame ~audio_packet ~video_frame ~video_packet
          container
      with
        | `Audio_frame (i, frame) when i = audio_frame_idx ->
            if check_pts (List.hd audio_frame) (Avutil.frame_pts frame) then
              audio_frame_decoder ~buffer frame
            else f ()
        | `Audio_packet (i, packet) when i = audio_packet_idx ->
            if check_pts (List.hd audio_packet) (Avcodec.Packet.get_pts packet)
            then audio_packet_decoder ~buffer packet
            else f ()
        | `Video_frame (i, frame) when i = video_frame_idx ->
            if check_pts (List.hd video_frame) (Avutil.frame_pts frame) then
              video_frame_decoder ~buffer frame
            else f ()
        | `Video_packet (i, packet) when i = video_packet_idx ->
            if check_pts (List.hd video_packet) (Avcodec.Packet.get_pts packet)
            then video_packet_decoder ~buffer packet
            else f ()
        | _ -> ()
        | exception Avutil.Error `Eof ->
            Generator.add_break ?sync:(Some true) buffer.Decoder.generator;
            raise End_of_file
    in
    f ()

let mk_streams ~ctype container =
  let audio =
    try
      match ctype.Frame.audio with
        | f when Frame_content.None.is_format f -> None
        | f when Ffmpeg_copy_content.Audio.is_format f ->
            Some (`Packet (Ffmpeg_copy_decoder.mk_audio_decoder container))
        | f when Ffmpeg_raw_content.Audio.is_format f ->
            Some (`Frame (Ffmpeg_raw_decoder.mk_audio_decoder container))
        | f ->
            let channels = Frame_content.Audio.channels_of_format f in
            Some
              (`Frame
                (Ffmpeg_internal_decoder.mk_audio_decoder ~channels container))
    with Avutil.Error _ -> None
  in
  let video =
    try
      match ctype.Frame.video with
        | f when Frame_content.None.is_format f -> None
        | f when Ffmpeg_copy_content.Video.is_format f ->
            Some (`Packet (Ffmpeg_copy_decoder.mk_video_decoder container))
        | f when Ffmpeg_raw_content.Video.is_format f ->
            Some (`Frame (Ffmpeg_raw_decoder.mk_video_decoder container))
        | _ ->
            Some (`Frame (Ffmpeg_internal_decoder.mk_video_decoder container))
    with Avutil.Error _ -> None
  in
  (audio, video)

let create_decoder ~ctype fname =
  let duration = duration fname in
  let remaining = ref duration in
  let m = Mutex.create () in
  let set_remaining stream pts =
    Tutils.mutexify m
      (fun () ->
        match (duration, pts) with
          | None, _ | Some _, None -> ()
          | Some d, Some pts ->
              let { Avutil.num; den } = Av.get_time_base stream in
              let position =
                Int64.to_float (Int64.mul (Int64.of_int num) pts) /. float den
              in
              remaining := Some (d -. position))
      ()
  in
  let get_remaining =
    Tutils.mutexify m (fun () ->
        match !remaining with None -> -1 | Some r -> Frame.master_of_seconds r)
  in
  let container = Av.open_input fname in
  let audio, video = mk_streams ~ctype container in
  let audio =
    match audio with
      | Some (`Packet (idx, stream, decoder)) ->
          let decoder ~buffer packet =
            set_remaining stream (Avcodec.Packet.get_pts packet);
            decoder ~buffer packet
          in
          Some (`Packet (idx, stream, decoder))
      | Some (`Frame (idx, stream, decoder)) ->
          let decoder ~buffer frame =
            set_remaining stream (Avutil.frame_pts frame);
            decoder ~buffer frame
          in
          Some (`Frame (idx, stream, decoder))
      | None -> None
  in
  let video =
    match video with
      | Some (`Packet (idx, stream, decoder)) ->
          let decoder ~buffer packet =
            set_remaining stream (Avcodec.Packet.get_pts packet);
            decoder ~buffer packet
          in
          Some (`Packet (idx, stream, decoder))
      | Some (`Frame (idx, stream, decoder)) ->
          let decoder ~buffer frame =
            set_remaining stream (Avutil.frame_pts frame);
            decoder ~buffer frame
          in
          Some (`Frame (idx, stream, decoder))
      | None -> None
  in
  let close () = Av.close container in
  let target_position = ref None in
  ( {
      Decoder.seek =
        (fun ticks ->
          match duration with
            | None -> -1
            | Some d ->
                let ticks =
                  ticks + Frame.master_of_seconds d - get_remaining ()
                in
                seek ~audio ~video ~target_position ticks);
      decode = mk_decoder ?audio ?video ~target_position container;
    },
    close,
    get_remaining )

let create_file_decoder ~metadata:_ ~ctype filename =
  let decoder, close, remaining = create_decoder ~ctype filename in
  Decoder.file_decoder ~filename ~close ~remaining ~ctype decoder

let create_stream_decoder ~ctype _ input =
  let seek_input =
    match input.Decoder.lseek with
      | None -> None
      | Some fn -> Some (fun len _ -> fn len)
  in
  let container = Av.open_input_stream ?seek:seek_input input.Decoder.read in
  let audio, video = mk_streams ~ctype container in
  let target_position = ref None in
  {
    Decoder.seek = seek ~audio ~video ~target_position;
    decode = mk_decoder ?audio ?video ~target_position container;
  }

let get_file_type ~ctype filename =
  let container = Av.open_input filename in
  Tutils.finalize
    ~k:(fun () -> Av.close container)
    (fun () -> get_type ~ctype ~url:filename container)

let () =
  Decoder.decoders#register "FFMPEG"
    ~sdoc:
      "Use libffmpeg to decode any file or stream if its MIME type or file \
       extension is appropriate."
    {
      Decoder.media_type = `Audio_video;
      priority = (fun () -> priority#get);
      file_extensions = (fun () -> Some file_extensions#get);
      mime_types = (fun () -> Some mime_types#get);
      file_type = (fun ~ctype filename -> Some (get_file_type ~ctype filename));
      file_decoder = Some create_file_decoder;
      stream_decoder = Some create_stream_decoder;
    }
