(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Rawright 2003-2020 Savonet team

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

open Avutil

type 'a frame = { time_base : Avutil.rational; frame : 'a Avutil.frame }

module BaseSpecs = struct
  include Ffmpeg_content_base

  type kind = [ `Raw ]

  let kind = `Raw
end

module AudioSpecs = struct
  include BaseSpecs

  let string_of_kind = function `Raw -> "ffmpeg.audio.raw"
  let kind_of_string = function "ffmpeg.audio.raw" -> Some `Raw | _ -> None

  type params = {
    channel_layout : Channel_layout.t option;
    sample_format : Sample_format.t option;
    sample_rate : int option;
  }

  type data = (params, audio frame) content

  let frame_params { frame } =
    {
      channel_layout = Some (Audio.frame_get_channel_layout frame);
      sample_format = Some (Audio.frame_get_sample_format frame);
      sample_rate = Some (Audio.frame_get_sample_rate frame);
    }

  let mk_params p =
    {
      channel_layout = Some (Avcodec.Audio.get_channel_layout p);
      sample_format = Some (Avcodec.Audio.get_sample_format p);
      sample_rate = Some (Avcodec.Audio.get_sample_rate p);
    }

  let default_params _ =
    { channel_layout = None; sample_format = None; sample_rate = None }

  let string_of_params { channel_layout; sample_format; sample_rate } =
    Frame_content.print_optional
      [
        ( "channel_layout",
          Option.map
            (Channel_layout.get_description ?channels:None)
            channel_layout );
        ("sample_format", Option.map Sample_format.get_name sample_format);
        ("sample_rate", Option.map string_of_int sample_rate);
      ]

  let parse_param label value =
    match label with
      | "channel_layout" ->
          Some
            {
              channel_layout = Some (Avutil.Channel_layout.find value);
              sample_format = None;
              sample_rate = None;
            }
      | "sample_format" ->
          Some
            {
              channel_layout = None;
              sample_format = Some (Avutil.Sample_format.find value);
              sample_rate = None;
            }
      | "sample_rate" ->
          Some
            {
              channel_layout = None;
              sample_format = None;
              sample_rate = Some (int_of_string value);
            }
      | _ -> None

  let compatible p p' =
    let c = function None, _ | _, None -> true | Some p, Some p' -> p = p' in
    c (p.channel_layout, p'.channel_layout)
    && c (p.sample_format, p'.sample_format)
    && c (p.sample_rate, p'.sample_rate)

  let merge p p' =
    {
      channel_layout =
        Frame_content.merge_param ~name:"channel_layout"
          (p.channel_layout, p'.channel_layout);
      sample_format =
        Frame_content.merge_param ~name:"sample_format"
          (p.sample_format, p'.sample_format);
      sample_rate =
        Frame_content.merge_param ~name:"sample_rate"
          (p.sample_rate, p'.sample_rate);
    }
end

module Audio = struct
  include Frame_content.MkContent (AudioSpecs)

  let kind = lift_kind `Raw
end

module VideoSpecs = struct
  include BaseSpecs

  let string_of_kind = function `Raw -> "ffmpeg.video.raw"
  let kind_of_string = function "ffmpeg.video.raw" -> Some `Raw | _ -> None

  type params = {
    width : int option;
    height : int option;
    pixel_format : Avutil.Pixel_format.t option;
  }

  type data = (params, video frame) content

  let frame_params { frame } =
    {
      width = Some (Video.frame_get_width frame);
      height = Some (Video.frame_get_height frame);
      pixel_format = Some (Video.frame_get_pixel_format frame);
    }

  let mk_params p =
    {
      width = Some (Avcodec.Video.get_width p);
      height = Some (Avcodec.Video.get_height p);
      pixel_format = Avcodec.Video.get_pixel_format p;
    }

  let default_params _ = { width = None; height = None; pixel_format = None }

  let string_of_params { width; height; pixel_format } =
    Frame_content.print_optional
      [
        ("width", Option.map string_of_int width);
        ("height", Option.map string_of_int height);
        ("pixel_format", Option.map Avutil.Pixel_format.to_string pixel_format);
      ]

  let parse_param label value =
    match label with
      | "width" ->
          Some
            {
              width = Some (int_of_string value);
              height = None;
              pixel_format = None;
            }
      | "height" ->
          Some
            {
              width = None;
              height = Some (int_of_string value);
              pixel_format = None;
            }
      | "pixel_format" ->
          Some
            {
              width = None;
              height = None;
              pixel_format = Some (Avutil.Pixel_format.of_string value);
            }
      | _ -> None

  let compatible p p' =
    let c = function None, _ | _, None -> true | Some p, Some p' -> p = p' in
    c (p.width, p'.width)
    && c (p.height, p'.height)
    && c (p.pixel_format, p'.pixel_format)

  let merge p p' =
    {
      width = Frame_content.merge_param ~name:"width" (p.width, p'.width);
      height = Frame_content.merge_param ~name:"height" (p.height, p'.height);
      pixel_format =
        Frame_content.merge_param ~name:"pixel_format"
          (p.pixel_format, p'.pixel_format);
    }
end

module Video = struct
  include Frame_content.MkContent (VideoSpecs)

  let kind = lift_kind `Raw
end
