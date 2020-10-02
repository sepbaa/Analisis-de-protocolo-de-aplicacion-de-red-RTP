module G = Generator.From_audio_video

let () =
  Frame.allow_lazy_config_eval ();
  let frame_size = Lazy.force Frame.size in
  let gen = G.create `Both in
  let data = Frame_content.None.data in
  (* Set this:
     0----1----2--> audio
     0----1----2----3----4----> video *)
  G.put_audio ~pts:0L gen data 0 frame_size;
  G.put_audio ~pts:1L gen data 0 frame_size;
  G.put_audio ~pts:2L gen data 0 (frame_size / 2);
  assert (G.video_length gen = 0);
  assert (G.audio_length gen = (2 * frame_size) + (frame_size / 2));
  assert (G.length gen = 0);

  G.put_video ~pts:0L gen data 0 frame_size;
  G.put_video ~pts:1L gen data 0 frame_size;
  G.put_video ~pts:2L gen data 0 frame_size;
  G.put_video ~pts:3L gen data 0 (2 * frame_size);
  assert (G.video_length gen = 5 * frame_size);
  assert (G.audio_length gen = (2 * frame_size) + (frame_size / 2));
  assert (G.length gen = 2 * frame_size);

  (* Add 2--(3)----(4)-- audio *)
  G.put_audio ~pts:2L gen data 0 (2 * frame_size);
  (* Get:
     0----1----2----3----4--> audio
     0----1----2----3----4----> video *)
  assert (G.video_length gen = 5 * frame_size);
  assert (G.audio_length gen = (4 * frame_size) + (frame_size / 2));
  assert (G.length gen = 4 * frame_size);

  (* Add 1---- video (non-monotonic PTS) *)
  G.put_video ~pts:1L gen data 0 frame_size;
  (* Get:
     0----1----2----3----4--> audio
     0----1----2----3----4----> video *)
  assert (G.video_length gen = 5 * frame_size);
  assert (G.audio_length gen = (4 * frame_size) + (frame_size / 2));
  assert (G.length gen = 4 * frame_size);

  (* Add 4--(5)-- audio *)
  G.put_audio ~pts:4L gen data 0 frame_size;
  (* Get:
     0----1----2----3----4----5--> audio
     0----1----2----3----4----> video *)
  assert (G.video_length gen = 5 * frame_size);
  assert (G.audio_length gen = (5 * frame_size) + (frame_size / 2));
  assert (G.length gen = 5 * frame_size);

  (* Add 6---- video (discontinuity) *)
  G.put_video ~pts:6L gen data 0 frame_size;
  (* Get:
     0----1----2----3----4----> audio
     0----1----2----3----4----6----> video *)
  assert (G.video_length gen = 6 * frame_size);
  assert (G.audio_length gen = 5 * frame_size);
  assert (G.length gen = 5 * frame_size);

  (* Add 5----(6)-- audio (partial out-of-sync) *)
  G.put_audio ~pts:5L gen data 0 (3 * frame_size / 2);
  (* Get:
     0----1----2----3----4----6--> audio
     0----1----2----3----4----6----> video *)
  assert (G.video_length gen = 6 * frame_size);
  assert (G.audio_length gen = (5 * frame_size) + (frame_size / 2));
  assert (G.length gen = 5 * frame_size);

  (* Add 7----(8)-- audio *)
  G.put_audio ~pts:7L gen data 0 (3 * frame_size / 2);
  (* Get:
     0----1----2----3----4----7----8--> audio
     0----1----2----3----4----> video *)
  assert (G.video_length gen = 5 * frame_size);
  assert (G.audio_length gen = (6 * frame_size) + (frame_size / 2));
  assert (G.length gen = 5 * frame_size);

  (* Add 9-- audio (discontinuity) *)
  G.put_audio ~pts:9L gen data 0 (frame_size / 2);
  (* Get:
       0----1----2----3----4----7----8--9--> audio
       0----1----2----3----4----> video
     Partial audio frame will be removed in a future cleanup. *)
  assert (G.video_length gen = 5 * frame_size);
  assert (G.audio_length gen = 7 * frame_size);
  assert (G.length gen = 5 * frame_size);

  (* Add 5----6----7----8----9---- video *)
  G.put_video ~pts:5L gen data 0 (5 * frame_size);
  (* Get:
       0----1----2----3----4----7----9--> audio
       0----1----2----3----4----7----9----> video
     Partial audio frame will be removed in a future cleanup. *)
  assert (G.video_length gen = 7 * frame_size);
  assert (G.audio_length gen = (6 * frame_size) + (frame_size / 2));
  assert (G.length gen = 6 * frame_size);

  (* Add 10-- audio (partial out-of-sync) *)
  G.put_audio ~pts:10L gen data 0 (frame_size / 2);
  (* Get:
     0----1----2----3----4----7----10--> audio
     0----1----2----3----4----7----> video *)
  assert (G.video_length gen = 6 * frame_size);
  assert (G.audio_length gen = (6 * frame_size) + (frame_size / 2))
