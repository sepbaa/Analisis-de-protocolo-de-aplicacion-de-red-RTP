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

exception Incorrect_stream_type

module type S = sig
  type t

  val length : t -> int (* ticks *)

  val remaining : t -> int (* ticks *)

  val clear : t -> unit
  val fill : t -> Frame.t -> unit
  val remove : t -> int -> unit
  val add_metadata : t -> Frame.metadata -> unit
end

module type S_Asio = sig
  type t

  val length : t -> int (* ticks *)

  val audio_length : t -> int
  val video_length : t -> int
  val remaining : t -> int (* ticks *)

  val clear : t -> unit
  val fill : t -> Frame.t -> unit
  val add_metadata : t -> Frame.metadata -> unit
  val add_break : ?sync:bool -> t -> unit
  val put_audio : ?pts:int64 -> t -> Frame_content.data -> int -> int -> unit
  val put_video : ?pts:int64 -> t -> Frame_content.data -> int -> int -> unit
  val set_mode : t -> [ `Audio | `Video | `Both | `Undefined ] -> unit
end

(** The base module doesn't even know what kind of data it is buffering. *)
module Generator = struct
  (** A chunk with given offset and length. *)
  type 'a chunk = 'a * int * int

  (** A buffer is a queue of chunks. *)
  type 'a buffer = 'a chunk Queue.t

  (** All positions and lengths are in ticks. *)
  type 'a t = {
    mutable length : int;
    mutable offset : int;
    mutable buffers : 'a buffer;
  }

  let create () = { length = 0; offset = 0; buffers = Queue.create () }

  let clear g =
    g.length <- 0;
    g.offset <- 0;
    g.buffers <- Queue.create ()

  let length b = b.length

  (** Remove [len] ticks of data. *)
  let rec remove g len =
    assert (g.length >= len);
    if len > 0 then (
      let _, _, b_len = Queue.peek g.buffers in
      (* Is it enough to advance in the first buffer?
       * Or do we need to consume it completely and go farther in the queue? *)
      if g.offset + len < b_len then (
        g.length <- g.length - len;
        g.offset <- g.offset + len )
      else (
        let removed = b_len - g.offset in
        ignore (Queue.take g.buffers);
        g.length <- g.length - removed;
        g.offset <- 0;
        remove g (len - removed) ) )

  (* Feed an item into a generator.
     The item is put as such, not copied. *)
  let put g content ofs len =
    g.length <- g.length + len;
    Queue.add (content, ofs, len) g.buffers

  (* Get [size] amount of data from [g].
     Returns a list where each element will typically be passed to a blit:
     its elements are of the form [b,o,o',l] where [o] is the offset of data
     in the block [b], [o'] is the position at which it should be written
     (the first position [o'] will always be [0]), and [l] is the length
     of data to be taken from that block. *)
  let get g size =
    (* The main loop takes the current offset in the output buffer,
     * and iterates on input buffer chunks. *)
    let rec aux chunks offset =
      (* How much (more) data should be output? *)
      let needed = size - offset in
      assert (needed > 0);
      let block, block_ofs, block_len = Queue.peek g.buffers in
      let block_len = block_len - g.offset in
      let copied = min needed block_len in
      let chunks = (block, block_ofs + g.offset, offset, copied) :: chunks in
      (* Update buffer data -- did we consume a full block? *)
      if block_len <= needed then (
        ignore (Queue.take g.buffers);
        g.length <- g.length - block_len;
        g.offset <- 0 )
      else (
        g.length <- g.length - needed;
        g.offset <- g.offset + needed );

      (* Add more data by recursing on the next block, or finish. *)
      if block_len < needed then aux chunks (offset + block_len)
      else List.rev chunks
    in
    if size = 0 then [] else aux [] 0
end

(* TODO: use this in the following modules instead of copying the code... *)
module Metadata = struct
  type t = {
    mutable metadata : (int * Frame.metadata) list;
    mutable breaks : int list;
    mutable length : int;
  }

  let create () = { metadata = []; breaks = []; length = 0 }

  let clear g =
    g.metadata <- [];
    g.breaks <- [];
    g.length <- 0

  let advance g len =
    g.metadata <- List.map (fun (t, m) -> (t - len, m)) g.metadata;
    g.metadata <- List.filter (fun (t, _) -> t >= 0) g.metadata;
    g.breaks <- List.map (fun t -> t - len) g.breaks;
    g.breaks <- List.filter (fun t -> t >= 0) g.breaks;
    g.length <- g.length - len;
    assert (g.length >= 0)

  let length g = g.length
  let remaining g = match g.breaks with a :: _ -> a | _ -> -1
  let metadata g len = List.filter (fun (t, _) -> t < len) g.metadata

  let feed_from_frame g frame =
    let size = Lazy.force Frame.size in
    let length = length g in
    g.metadata <-
      g.metadata
      @ List.map (fun (t, m) -> (length + t, m)) (Frame.get_all_metadata frame);
    g.breaks <-
      g.breaks
      @ List.map
          (fun t -> length + t)
          (* Filter out the last break, which only marks the end of frame, not a
           * track limit (doesn't mean is_partial). *)
          (List.filter (fun x -> x < size) (Frame.breaks frame));
    let frame_length =
      let rec aux = function [t] -> t | _ :: tl -> aux tl | [] -> size in
      aux (Frame.breaks frame)
    in
    g.length <- g.length + frame_length

  let drop_initial_break g =
    match g.breaks with
      | 0 :: tl -> g.breaks <- tl
      | [] -> () (* end of stream / underrun... *)
      | _ -> assert false

  let fill g frame =
    let offset = Frame.position frame in
    let needed =
      let size = Lazy.force Frame.size in
      let remaining = remaining g in
      let remaining = if remaining = -1 then length g else remaining in
      min (size - offset) remaining
    in
    List.iter
      (fun (p, m) -> if p < needed then Frame.set_metadata frame (offset + p) m)
      g.metadata;
    advance g needed;

    (* Mark the end of this filling. If the frame is partial it must be because
     * of a break in the generator, or because the generator is emptying.
     * Conversely, each break in the generator must cause a partial frame, so
     * don't remove any if it isn't partial. *)
    Frame.add_break frame (offset + needed);
    if Frame.is_partial frame then drop_initial_break g
end

(** Generate a stream, including metadata and breaks.
  * The API is based on feeding from frames, and filling frames. *)
module From_frames = struct
  type t = {
    mutable metadata : (int * Frame.metadata) list;
    mutable breaks : int list;
    generator : Frame.content Generator.t;
  }

  let create () =
    { metadata = []; breaks = []; generator = Generator.create () }

  let clear fg =
    fg.metadata <- [];
    fg.breaks <- [];
    Generator.clear fg.generator

  (** Total length. *)
  let length fg = Generator.length fg.generator

  (** Duration of data (in ticks) before the next break, -1 if there's none. *)
  let remaining fg = match fg.breaks with a :: _ -> a | _ -> -1

  let add_metadata fg m = fg.metadata <- fg.metadata @ [(length fg, m)]
  let add_break fg = fg.breaks <- fg.breaks @ [length fg]

  (* Advance metadata and breaks by [len] ticks. *)
  let advance fg len =
    let meta = List.map (fun (x, y) -> (x - len, y)) fg.metadata in
    let breaks = List.map (fun x -> x - len) fg.breaks in
    fg.metadata <- List.filter (fun x -> fst x >= 0) meta;
    fg.breaks <- List.filter (fun x -> x >= 0) breaks

  let remove fg len =
    Generator.remove fg.generator len;
    advance fg len

  (** Only the breaks and metadata in the considered portion of the
    * content will be taken into account. This includes position
    * ofs but excludes ofs+len for metadata and the opposite for breaks. *)
  let feed fg ?(copy = true) ?(breaks = []) ?(metadata = []) content ofs len =
    let breaks = List.filter (fun p -> ofs < p && p <= ofs + len) breaks in
    let metadata =
      List.filter (fun (p, _) -> ofs <= p && p < ofs + len) metadata
    in
    let content = if copy then Frame.copy content else content in
    fg.breaks <- fg.breaks @ List.map (fun p -> length fg + p - ofs) breaks;
    fg.metadata <-
      fg.metadata @ List.map (fun (p, m) -> (length fg + p - ofs, m)) metadata;
    Generator.put fg.generator content ofs len

  (** Take all data from a frame: breaks, metadata and available content. *)
  let feed_from_frame fg frame =
    let size = Lazy.force Frame.size in
    fg.metadata <-
      fg.metadata
      @ List.map
          (fun (p, m) -> (length fg + p, m))
          (Frame.get_all_metadata frame);
    fg.breaks <-
      fg.breaks
      @ List.map
          (fun p -> length fg + p)
          (* Filter out the last break, which only marks the end
           * of frame, not a track limit (doesn't mean is_partial). *)
          (List.filter (fun x -> x < size) (Frame.breaks frame));

    (* Feed all content layers into the generator. *)
    Generator.put fg.generator (Frame.copy frame.Frame.content) 0 size

  (* Fill a frame from the generator's data. *)
  let fill fg frame =
    let offset = Frame.position frame in
    let buffer_size = Lazy.force Frame.size in
    let remaining =
      let l = remaining fg in
      if l = -1 then length fg else l
    in
    let needed = min (buffer_size - offset) remaining in
    let blocks = Generator.get fg.generator needed in
    List.iter
      (fun (block, o, o', size) ->
        let dst = frame.Frame.content in
        Frame.blit_content block o dst (offset + o') size)
      blocks;
    List.iter
      (fun (p, m) -> if p < needed then Frame.set_metadata frame (offset + p) m)
      fg.metadata;
    advance fg needed;

    (* Mark the end of this filling.
     * If the frame is partial it must be because of a break in the
     * generator, or because the generator is emptying.
     * Conversely, each break in the generator must cause a partial frame,
     * so don't remove any if it isn't partial. *)
    Frame.add_break frame (offset + needed);
    if Frame.is_partial frame then (
      match fg.breaks with
        | 0 :: tl -> fg.breaks <- tl
        | [] -> () (* end of stream / underrun ... *)
        | _ -> assert false )
end

(** In [`Both] mode, the buffer is always kept in sync as follows:
    - PTS in audio and video is expected to be tracked when submitting
      data. User with no knowledge of PTS (typically all decoders except
      ffmpeg) should be able to submit without having to deal with PTS.
    - The buffer is always in sync except for potentially one type of
      data and always at the end of the buffer. Typically:
         0----1----2--> audio
         0----1----2----3----4----> video
    - When a new chunk is added, any gap in data from the other type
      is removed. So, for instance, when adding an audio chunk of type
      4--(5)----(6)- one gets:
         0----1----4----5----6-> audio
         0----1----4----> video
      Note: video frame being usually one frame long, we unfortunately cannot
      keep partially filled frames.
    - Current chunk length and PTS are tracked so that new chunk are split
      by increment of frame size. Typically, if we have:
         0----1----2--> audio
         0----1----2----3----4----5> video
      Adding a chunk of audio of type: 2--(3)----(4)- should
      result in  adding a first chunk of 4-- then a chunk of 3----
      and, finally, a chunk of 4-. *)
module From_audio_video = struct
  type mode = [ `Audio | `Video | `Both | `Undefined ]
  type 'a content = { pts : int64; data : 'a }

  type t = {
    mutable mode : mode;
    mutable current_audio_pts : int64;
    current_audio : Frame_content.data content Generator.t;
    audio : Frame_content.data content Generator.t;
    mutable current_video_pts : int64;
    current_video : Frame_content.data content Generator.t;
    video : Frame_content.data content Generator.t;
    mutable metadata : (int * Frame.metadata) list;
    mutable breaks : int list;
  }

  let create m =
    {
      mode = m;
      current_audio_pts = 0L;
      current_audio = Generator.create ();
      audio = Generator.create ();
      current_video_pts = 0L;
      current_video = Generator.create ();
      video = Generator.create ();
      metadata = [];
      breaks = [];
    }

  (** Audio length, in ticks. *)
  let audio_length t =
    Generator.length t.audio + Generator.length t.current_audio

  (** Video length, in ticks. *)
  let video_length t =
    Generator.length t.video + Generator.length t.current_video

  (** Total length. *)
  let length t = min (Generator.length t.audio) (Generator.length t.video)

  (** Total buffered length. *)
  let buffered_length t = max (audio_length t) (video_length t)

  (** Duration of data (in ticks) before the next break, -1 if there's none. *)
  let remaining t = match t.breaks with a :: _ -> a | _ -> -1

  (** Add metadata at the minimum position of audio and video.
    * You probably want to call this when there is as much
    * audio as video. *)
  let add_metadata t m = t.metadata <- t.metadata @ [(length t, m)]

  (** Add a track limit. Audio and video length should be equal. *)
  let add_break ?(sync = false) t =
    if sync then (
      Generator.clear t.current_audio;
      Generator.clear t.current_video );
    t.breaks <- t.breaks @ [length t]

  let clear t =
    t.metadata <- [];
    t.breaks <- [];
    Generator.clear t.audio;
    Generator.clear t.video

  (** Current mode:
    * in Audio mode (resp. Video), only audio (resp. Audio) can be fed,
    * otherwise both have to be fed. *)
  let mode t = t.mode

  (** Change the generator mode. Only allowed when there is as much audio as video.  *)
  let set_mode t m =
    if t.mode <> m then (
      assert (audio_length t = video_length t);
      t.mode <- m )

  (** Check for pending synced A/V content *)
  let sync_content t =
    let s = Lazy.force Frame.size in

    let audio = Queue.copy t.current_audio.Generator.buffers in
    let video = Queue.copy t.current_video.Generator.buffers in

    let rec pick ~picked ~pos ~chunks pts =
      match Queue.peek_opt chunks with
        | Some (chunk, _, l) when chunk.pts = pts ->
            Queue.add (Queue.take chunks) picked;
            pick ~picked ~pos:(pos + l) ~chunks pts
        | Some (chunk, _, _) when pts < chunk.pts -> (pos, true)
        (* Prevent user from submitting non-monotonic PTS. *)
        | Some (chunk, _, _) when chunk.pts < pts ->
            pick ~picked ~pos ~chunks pts
        | None -> (pos, false)
        | _ -> assert false
    in

    let add_audio ~picked ~pos () =
      Queue.iter (fun (chunk, o, l) -> Generator.put t.audio chunk o l) picked;
      Generator.remove t.current_audio pos
    in

    let add_video ~picked ~pos () =
      Queue.iter (fun (chunk, o, l) -> Generator.put t.video chunk o l) picked;
      Generator.remove t.current_video pos
    in

    let rec f () =
      match (Queue.peek_opt audio, Queue.peek_opt video) with
        | Some ({ pts = audio_pts }, _, _), Some ({ pts = video_pts }, _, _)
          when audio_pts < video_pts ->
            let picked_audio = Queue.create () in
            let audio_len, _ =
              pick ~picked:picked_audio ~pos:0 ~chunks:audio audio_pts
            in
            Generator.remove t.current_audio audio_len;
            f ()
        | Some ({ pts = audio_pts }, _, _), Some ({ pts = video_pts }, _, _)
          when video_pts < audio_pts ->
            let picked_video = Queue.create () in
            let video_len, _ =
              pick ~picked:picked_video ~pos:0 ~chunks:video video_pts
            in
            Generator.remove t.current_video video_len;
            f ()
        | Some ({ pts }, _, _), Some _ ->
            let picked_audio = Queue.create () in
            let picked_video = Queue.create () in
            let audio_len, more_audio =
              pick ~picked:picked_audio ~pos:0 ~chunks:audio pts
            in
            let video_len, more_video =
              pick ~picked:picked_video ~pos:0 ~chunks:video pts
            in
            ( match (audio_len, video_len) with
              (* Full frame sync. Take it! *)
              | _ when audio_len = video_len && video_len = s ->
                  add_audio ~picked:picked_audio ~pos:audio_len ();
                  add_video ~picked:picked_video ~pos:video_len ()
              (* Partial audio or video frame. Can it! *)
              | _
                when (audio_len < s && more_audio)
                     || (video_len < s && more_video) ->
                  Generator.remove t.current_audio audio_len;
                  Generator.remove t.current_video video_len
              | _ -> () );
            f ()
        | _ -> ()
    in

    f ()

  let put_frames ~pts ~current_pts gen data o l =
    let s = Lazy.force Frame.size in

    let current_chunk = Generator.length gen mod s in

    let put ~pts o l =
      if current_pts <= pts && 0 < l then Generator.put gen { pts; data } o l
    in

    (* First complete the previous chunk. *)
    let r = min l (s - current_chunk) in
    put ~pts o r;

    let pts = if r + current_chunk = s then Int64.succ pts else pts in
    let l = l - r in
    let o = o + r in

    (* Now fill out the rest of the frames in [l] *)
    let frames = l / s in
    let rem = l mod s in

    (* Add data by increment one one pts/frame.size *)
    for i = 0 to frames - 1 do
      let pts = Int64.add pts (Int64.of_int i) in
      put ~pts (o + (i * s)) s
    done;

    let pts = Int64.add pts (Int64.of_int frames) in

    put ~pts (o + (frames * s)) rem;

    pts

  (** Add some audio content. Offset and length are given in master ticks. *)
  let put_audio ?pts t data o l =
    let pts = match pts with Some pts -> pts | None -> t.current_audio_pts in
    t.current_audio_pts <-
      put_frames ~pts ~current_pts:t.current_audio_pts t.current_audio data o l;
    begin
      match t.mode with
      (* The buffer's logic is all synchronous so we keep
         constant empty content for the other type when using
         the buffer with one single type. *)
      | `Audio ->
          t.current_video_pts <-
            put_frames ~pts ~current_pts:t.current_video_pts t.current_video
              Frame_content.None.data 0 l
      | `Both -> ()
      | _ -> assert false
    end;
    sync_content t

  (** Add some video content. Offset and length are given in master ticks. *)
  let put_video ?pts t data o l =
    let pts = match pts with Some pts -> pts | None -> t.current_video_pts in
    t.current_video_pts <-
      put_frames ~pts ~current_pts:t.current_video_pts t.current_video data o l;
    begin
      match t.mode with
      (* The buffer's logic is all synchronous so we keep
         constant empty content for the other type when using
         the buffer with one single type. *)
      | `Video ->
          t.current_audio_pts <-
            put_frames ~pts ~current_pts:t.current_audio_pts t.current_audio
              Frame_content.None.data 0 l
      | _ -> ()
    end;
    sync_content t

  (** Take all data from a frame: breaks, metadata and available content. *)
  let feed_from_frame ?mode t frame =
    let size = Lazy.force Frame.size in
    t.metadata <-
      t.metadata
      @ List.map
          (fun (p, m) -> (length t + p, m))
          (Frame.get_all_metadata frame);
    t.breaks <-
      t.breaks
      @ List.map
          (fun p -> length t + p)
          (* Filter out the last break, which only marks the end
           * of frame, not a track limit (doesn't mean is_partial). *)
          (List.filter (fun x -> x < size) (Frame.breaks frame));

    (* Feed all content layers into the generator. *)
    let pts = Frame.pts frame in
    let mode = match mode with Some mode -> mode | None -> t.mode in

    match mode with
      | `Audio ->
          put_audio ~pts t
            (Frame_content.copy (AFrame.content frame))
            0 (Lazy.force Frame.size)
      | `Video ->
          put_video ~pts t (VFrame.content frame) 0 (Lazy.force Frame.size)
      | `Both ->
          put_audio ~pts t
            (Frame_content.copy (AFrame.content frame))
            0 (Lazy.force Frame.size);
          put_video ~pts t (VFrame.content frame) 0 (Lazy.force Frame.size)
      | `Undefined -> ()

  (* Advance metadata and breaks by [len] ticks. *)
  let advance t len =
    let meta = List.map (fun (x, y) -> (x - len, y)) t.metadata in
    let breaks = List.map (fun x -> x - len) t.breaks in
    t.metadata <- List.filter (fun x -> fst x >= 0) meta;
    t.breaks <- List.filter (fun x -> x >= 0) breaks

  let remove t len =
    let audio_len = Generator.length t.audio in
    Generator.remove t.audio len;
    Generator.remove t.current_audio (len - audio_len);
    let video_len = Generator.length t.video in
    Generator.remove t.video len;
    Generator.remove t.current_video (len - video_len);
    advance t len

  let fill t frame =
    let mode = mode t in
    let fpos = Frame.position frame in
    let size = Lazy.force Frame.size in

    let remaining =
      let l = remaining t in
      if l = -1 then length t else l
    in

    let l = min (size - fpos) remaining in

    let audio = Generator.get t.audio l in
    let video = Generator.get t.video l in

    if mode = `Both || mode = `Audio then
      List.iter
        (fun ({ data }, apos, apos', al) ->
          Frame_content.blit data apos (AFrame.content frame) (fpos + apos') al)
        audio;

    if mode = `Both || mode = `Video then
      List.iter
        (fun ({ data }, vpos, vpos', vl) ->
          Frame_content.blit data vpos (VFrame.content frame) (fpos + vpos') vl)
        video;

    Frame.add_break frame (fpos + l);

    List.iter
      (fun (p, m) -> if p < l then Frame.set_metadata frame (fpos + p) m)
      t.metadata;

    advance t l;

    (* If the frame is partial it must be because of a break in the
     * generator, or because the generator is emptying.
     * Conversely, each break in the generator must cause a partial frame,
     * so don't remove any if it isn't partial. *)
    if Frame.is_partial frame then (
      match t.breaks with
        | 0 :: tl -> t.breaks <- tl
        | [] -> () (* end of stream / underrun ... *)
        | _ -> assert false )
end

module From_audio_video_plus = struct
  module Super = From_audio_video

  type mode = [ `Audio | `Video | `Both | `Undefined ]

  (** There are different ways of handling an overful generator:
    * (1) when streaming, one should just stop the decoder for a while;
    * (2) when not streaming, one should throw some data.
    * Doing 1 instead of 2 can lead to deconnections.
    * Doing 2 instead of 1 leads to ugly sound.
    * Currently the only possibility is to drop data, since we want to remain
    * connected to the client. This behaves well in most cases, since clients
    * generally don't not go faster than stream-time. *)
  type overfull = [ `Drop_old of int ]

  type t = {
    lock : Mutex.t;
    (* The type of fed data must always be the same. This is fixed by the first
       filled frame. *)
    mutable ctype : Frame.content_type option;
    mutable error : bool;
    overfull : overfull option;
    gen : Super.t;
    log : string -> unit;
    log_overfull : bool;
    (* Metadata rewriting, in place modification allowed *)
    mutable map_meta : Frame.metadata -> Frame.metadata;
  }

  let create ?(lock = Mutex.create ()) ?overfull ~log ~log_overfull mode =
    {
      lock;
      ctype = None;
      error = false;
      overfull;
      log;
      log_overfull;
      gen = Super.create mode;
      map_meta = (fun x -> x);
    }

  let content_type t = Tutils.mutexify t.lock (fun () -> Option.get t.ctype) ()

  let set_content_type t =
    Tutils.mutexify t.lock (fun ctype ->
        assert (t.ctype = None);
        t.ctype <- Some ctype)

  let mode t = Tutils.mutexify t.lock Super.mode t.gen
  let set_mode t mode = Tutils.mutexify t.lock (Super.set_mode t.gen) mode
  let audio_length t = Tutils.mutexify t.lock Super.audio_length t.gen
  let video_length t = Tutils.mutexify t.lock Super.video_length t.gen
  let length t = Tutils.mutexify t.lock Super.length t.gen
  let remaining t = Tutils.mutexify t.lock Super.remaining t.gen
  let set_rewrite_metadata t f = t.map_meta <- f

  let add_metadata t m =
    Tutils.mutexify t.lock (fun m -> Super.add_metadata t.gen (t.map_meta m)) m

  let add_break ?sync t = Tutils.mutexify t.lock (Super.add_break ?sync) t.gen
  let clear t = Tutils.mutexify t.lock Super.clear t.gen

  let fill t frame =
    Tutils.mutexify t.lock
      (fun () ->
        let p = Frame.position frame in
        let breaks = Frame.breaks frame in
        Super.fill t.gen frame;
        let c = frame.Frame.content in
        match t.ctype with
          | None -> t.ctype <- Some (Frame.type_of_content c)
          | Some ctype ->
              if not (Frame.compatible (Frame.type_of_content c) ctype) then (
                t.log "Incorrect stream type!";
                t.error <- true;
                Super.clear t.gen;
                Frame.clear_from frame p;
                Frame.set_breaks frame (p :: breaks) ))
      ()

  let remove t len = Tutils.mutexify t.lock (Super.remove t.gen) len

  let check_overfull t extra =
    assert (Tutils.seems_locked t.lock);
    match t.overfull with
      | Some (`Drop_old len) when Super.buffered_length t.gen + extra > len ->
          let len = Super.buffered_length t.gen + extra - len in
          let len_time = Frame.seconds_of_master len in
          if t.log_overfull then
            t.log
              (Printf.sprintf
                 "Buffer overrun: Dropping %.2fs. Consider increasing the max \
                  buffer size!"
                 len_time);
          Super.remove t.gen len
      | _ -> ()

  let put_audio ?pts t buf off len =
    Tutils.mutexify t.lock
      (fun () ->
        if t.error then (
          Super.clear t.gen;
          t.error <- false;
          raise Incorrect_stream_type )
        else (
          check_overfull t len;
          Super.put_audio ?pts t.gen buf off len ))
      ()

  let put_video ?pts t buf off len =
    Tutils.mutexify t.lock
      (fun () ->
        if t.error then (
          Super.clear t.gen;
          t.error <- false;
          raise Incorrect_stream_type )
        else (
          check_overfull t len;
          Super.put_video ?pts t.gen buf off len ))
      ()

  let feed_from_frame ?mode t frame =
    Tutils.mutexify t.lock
      (fun () ->
        ( match t.ctype with
          | None -> t.ctype <- Some (Frame.content_type frame)
          | Some ctype ->
              if Frame.content_type frame <> ctype then (
                t.log "Incorrect stream type!";
                t.error <- true ) );
        if t.error then (
          Super.clear t.gen;
          t.error <- false;
          raise Incorrect_stream_type )
        else (
          check_overfull t (Lazy.force Frame.size);
          Super.feed_from_frame ?mode t.gen frame ))
      ()
end
