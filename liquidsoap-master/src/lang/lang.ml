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

module Term = Lang_values
include Term.V
module T = Lang_types
module Ground = Term.Ground
open Ground

type t = T.t
type scheme = T.scheme
type pos = T.pos

let log = Log.make ["lang"]

(** Type construction *)

let ground_t x = T.make (T.Ground x)
let int_t = ground_t T.Int
let unit_t = T.make T.unit
let float_t = ground_t T.Float
let bool_t = ground_t T.Bool
let string_t = ground_t T.String
let tuple_t l = T.make (T.Tuple l)
let product_t a b = tuple_t [a; b]

let rec record_t = function
  | [] -> unit_t
  | (l, t) :: r -> T.meth l ([], t) (record_t r)

let rec method_t t0 = function
  | [] -> t0
  | (l, t) :: r -> T.meth l t (method_t t0 r)

let of_tuple_t t =
  match (T.deref t).T.descr with T.Tuple l -> l | _ -> assert false

let of_product_t t =
  match of_tuple_t t with [a; b] -> (a, b) | _ -> assert false

let fun_t p b = T.make (T.Arrow (p, b))
let list_t t = T.make (T.List t)

let of_list_t t =
  match (T.deref t).T.descr with T.List t -> t | _ -> assert false

let nullable_t t = T.make (T.Nullable t)
let ref_t t = Term.ref_t t
let metadata_t = list_t (product_t string_t string_t)
let univ_t ?(constraints = []) () = T.fresh ~level:0 ~constraints ~pos:None
let getter_t a = univ_t ~constraints:[T.Getter a] ()
let string_getter_t () = getter_t T.String
let float_getter_t () = getter_t T.Float
let int_getter_t () = getter_t T.Int
let bool_getter_t () = getter_t T.Bool
let frame_kind_t ~audio ~video ~midi = Term.frame_kind_t audio video midi
let of_frame_kind_t t = Term.of_frame_kind_t t
let source_t t = Term.source_t t
let of_source_t t = Term.of_source_t t
let format_t t = Term.format_t t
let request_t = Term.request_t ()
let kind_t k = Term.kind_t k
let kind_none_t = Term.kind_t Frame.none
let empty = { Frame.audio = Frame.none; video = Frame.none; midi = Frame.none }
let any = { Frame.audio = `Any; video = `Any; midi = `Any }

let audio_video_internal =
  { Frame.audio = `Internal; video = `Internal; midi = Frame.none }

let audio_pcm = { Frame.audio = Frame.audio_pcm; video = `Any; midi = `Any }

let audio_params p =
  {
    Frame.audio = `Format (Frame_content.Audio.lift_params p);
    video = `Any;
    midi = `Any;
  }

let audio_n n = { Frame.audio = Frame.audio_n n; video = `Any; midi = `Any }
let audio_mono = audio_params { Frame_content.Contents.channel_layout = `Mono }

let audio_stereo =
  audio_params { Frame_content.Contents.channel_layout = `Stereo }

let video_yuv420p =
  { Frame.audio = `Any; video = Frame.video_yuv420p; midi = `Any }

let midi = { Frame.audio = `Any; video = `Any; midi = Frame.midi_native }

let midi_n n =
  {
    Frame.audio = `Any;
    video = `Any;
    midi =
      `Format
        (Frame_content.Midi.lift_params { Frame_content.Contents.channels = n });
  }

let kind_type_of_kind_format fields =
  let audio = Term.kind_t fields.Frame.audio in
  let video = Term.kind_t fields.Frame.video in
  let midi = Term.kind_t fields.Frame.midi in
  frame_kind_t ~audio ~video ~midi

(** Value construction *)

let mk ?pos value = { pos; value }
let unit = mk unit
let int i = mk (Ground (Int i))
let bool i = mk (Ground (Bool i))
let float i = mk (Ground (Float i))
let string i = mk (Ground (String i))
let tuple l = mk (Tuple l)
let product a b = tuple [a; b]
let list l = mk (List l)
let null = mk Null

let rec meth v0 = function
  | [] -> v0
  | (l, v) :: r -> mk (Meth (l, v, meth v0 r))

let record = meth unit
let source s = mk (Source s)
let request r = mk (Ground (Request r))
let reference x = mk (Ref x)
let val_fun p f = mk (FFI (p, [], f))

let val_cst_fun p c =
  let p' = List.map (fun (l, d) -> (l, l, d)) p in
  let f t tm = mk (Fun (p', [], [], { Term.t; Term.term = tm })) in
  let mkg t = T.make (T.Ground t) in
  (* Convert the value into a term if possible, to enable introspection, mostly
     for printing. *)
  match c.value with
    | Tuple [] -> f (T.make T.unit) Term.unit
    | Ground (Int i) -> f (mkg T.Int) (Term.Ground (Term.Ground.Int i))
    | Ground (Bool i) -> f (mkg T.Bool) (Term.Ground (Term.Ground.Bool i))
    | Ground (Float i) -> f (mkg T.Float) (Term.Ground (Term.Ground.Float i))
    | Ground (String i) -> f (mkg T.String) (Term.Ground (Term.Ground.String i))
    | _ -> mk (FFI (p', [], fun _ -> c))

let metadata m =
  list (Hashtbl.fold (fun k v l -> product (string k) (string v) :: l) m [])

let compare_values a b =
  let rec aux = function
    | Ground a, Ground b -> Ground.compare a b
    | Tuple l, Tuple m ->
        List.fold_left2
          (fun cmp a b -> if cmp <> 0 then cmp else aux (a.value, b.value))
          0 l m
    | List l1, List l2 ->
        let rec cmp = function
          | [], [] -> 0
          | [], _ -> -1
          | _, [] -> 1
          | h1 :: l1, h2 :: l2 ->
              let c = aux (h1.value, h2.value) in
              if c = 0 then cmp (l1, l2) else c
        in
        cmp (l1, l2)
    | Null, Null -> 0
    | Null, _ -> -1
    | _, Null -> 1
    | _ -> assert false
  in
  aux (a.value, b.value)

(** Helpers for defining protocols. *)

let to_proto_doc ~syntax ~static doc =
  let item = new Doc.item ~sort:false doc in
  item#add_subsection "syntax" (Doc.trivial syntax);
  item#add_subsection "static" (Doc.trivial (string_of_bool static));
  item

let add_protocol ~syntax ~doc ~static name resolver =
  let doc = to_proto_doc ~syntax ~static doc in
  let spec = { Request.static; resolve = resolver } in
  Request.protocols#register ~doc name spec

(** Helpers for defining builtin functions. *)

type proto = (string * t * value option * string option) list

let doc_of_prototype_item ~generalized t d doc =
  let doc = match doc with None -> "(no doc)" | Some d -> d in
  let item = new Doc.item doc in
  item#add_subsection "type" (T.doc_of_type ~generalized t);
  item#add_subsection "default"
    ( match d with
      | None -> Doc.trivial "None"
      | Some d -> Doc.trivial (print_value d) );
  item

type doc_flag = Hidden | Deprecated | Experimental | Extra

let string_of_flag = function
  | Hidden -> "hidden"
  | Deprecated -> "deprecated"
  | Experimental -> "experimental"
  | Extra -> "extra"

let builtin_type p t =
  T.make
    (T.Arrow (List.map (fun (lbl, t, opt, _) -> (opt <> None, lbl, t)) p, t))

let to_plugin_doc category flags main_doc proto return_t =
  let item = new Doc.item ~sort:false main_doc in
  let t = builtin_type proto return_t in
  let generalized = T.filter_vars (fun _ -> true) t in
  item#add_subsection "_category" (Doc.trivial category);
  item#add_subsection "_type" (T.doc_of_type ~generalized t);
  List.iter
    (fun f -> item#add_subsection "_flag" (Doc.trivial (string_of_flag f)))
    flags;
  List.iter
    (fun (l, t, d, doc) ->
      item#add_subsection
        (if l = "" then "(unlabeled)" else l)
        (doc_of_prototype_item ~generalized t d doc))
    proto;
  item

let add_builtin ~category ~descr ?(flags = []) name proto return_t f =
  let t = builtin_type proto return_t in
  let value =
    {
      pos = None;
      value =
        FFI (List.map (fun (lbl, _, opt, _) -> (lbl, lbl, opt)) proto, [], f);
    }
  in
  let generalized = T.filter_vars (fun _ -> true) t in
  Term.add_builtin
    ~doc:(to_plugin_doc category flags descr proto return_t)
    (String.split_on_char '.' name)
    ((generalized, t), value)

let add_builtin_base ~category ~descr ?(flags = []) name value t =
  let doc = new Doc.item ~sort:false descr in
  let value = { pos = t.T.pos; value } in
  let generalized = T.filter_vars (fun _ -> true) t in
  doc#add_subsection "_category" (Doc.trivial category);
  doc#add_subsection "_type" (T.doc_of_type ~generalized t);
  List.iter
    (fun f -> doc#add_subsection "_flag" (Doc.trivial (string_of_flag f)))
    flags;
  Term.add_builtin ~doc (String.split_on_char '.' name) ((generalized, t), value)

let add_module name = Term.add_module (String.split_on_char '.' name)

(** Specialized version for operators, that is builtins returning sources. *)

type category =
  | Input
  | Output
  | Conversions
  | TrackProcessing
  | SoundProcessing
  | VideoProcessing
  | MIDIProcessing
  | Visualization
  | SoundSynthesis
  | Liquidsoap

let string_of_category x =
  "Source / "
  ^
  match x with
    | Input -> "Input"
    | Output -> "Output"
    | Conversions -> "Conversions"
    | TrackProcessing -> "Track Processing"
    | SoundProcessing -> "Sound Processing"
    | VideoProcessing -> "Video Processing"
    | MIDIProcessing -> "MIDI Processing"
    | SoundSynthesis -> "Sound Synthesis"
    | Visualization -> "Visualization"
    | Liquidsoap -> "Liquidsoap"

(** An operator is a builtin function that builds a source.
  * It is registered using the wrapper [add_operator].
  * Creating the associated function type (and function) requires some work:
  *  - Specify which content_kind the source will carry:
  *    a given fixed number of channels, any fixed, a variable number?
  *  - The content_kind can also be linked to a type variable,
  *    e.g. the parameter of a format type.
  * From this high-level description a type is created. Often it will
  * carry a type constraint.
  * Once the type has been inferred, the function might be executed,
  * and at this point the type might still not be known completely
  * so we have to force its value withing the acceptable range. *)

let add_operator ~category ~descr ?(flags = []) ?(active = false) name proto
    ~return_t f =
  let compare (x, _, _, _) (y, _, _, _) =
    match (x, y) with
      | "", "" -> 0
      | _, "" -> -1
      | "", _ -> 1
      | x, y -> Stdlib.compare x y
  in
  let proto =
    let t = T.make (T.Ground T.String) in
    ( "id",
      t,
      Some { pos = t.T.pos; value = Ground (String "") },
      Some "Force the value of the source ID." )
    :: List.stable_sort compare proto
  in
  let f env =
    let src : Source.source = f env in
    let id =
      match (List.assoc "id" env).value with
        | Ground (String s) -> s
        | _ -> assert false
    in
    if id <> "" then src#set_id id;
    { pos = None; value = Source src }
  in
  let f env =
    let pos = None in
    try f env with
      | Source.Clock_conflict (a, b) ->
          raise (Lang_errors.Clock_conflict (pos, a, b))
      | Source.Clock_loop (a, b) -> raise (Lang_errors.Clock_loop (pos, a, b))
      | Source.Kind.Conflict (a, b) ->
          raise (Lang_errors.Kind_conflict (pos, a, b))
  in
  let return_t = Term.source_t ~active return_t in
  let category = string_of_category category in
  add_builtin ~category ~descr ~flags name proto return_t f

(** List of references for which iter_sources had to give up --- see below. *)
let static_analysis_failed = ref []

let iter_sources f v =
  let itered_values = ref [] in
  let rec iter_term env v =
    match v.Term.term with
      | Term.Ground _ | Term.Encoder _ -> ()
      | Term.List l -> List.iter (iter_term env) l
      | Term.Tuple l -> List.iter (iter_term env) l
      | Term.Null -> ()
      | Term.Meth (_, a, b) ->
          iter_term env a;
          iter_term env b
      | Term.Invoke (a, _) -> iter_term env a
      | Term.Open (a, b) ->
          iter_term env a;
          iter_term env b
      | Term.Let { Term.def = a; body = b; _ } | Term.Seq (a, b) ->
          iter_term env a;
          iter_term env b
      | Term.Var v -> (
          try
            (* If it's locally bound it won't be in [env]. *)
            (* TODO since inner-bound variables don't mask outer ones in [env],
             *   we are actually checking values that may be out of reach. *)
            let v = List.assoc v env in
            if Lazy.is_val v then (
              let v = Lazy.force v in
              iter_value v )
            else ()
          with Not_found -> () )
      | Term.App (a, l) ->
          iter_term env a;
          List.iter (fun (_, v) -> iter_term env v) l
      | Term.Fun (_, proto, body) | Term.RFun (_, _, proto, body) ->
          iter_term env body;
          List.iter
            (fun (_, _, _, v) ->
              match v with Some v -> iter_term env v | None -> ())
            proto
  and iter_value v =
    if not (List.memq v !itered_values) then (
      (* We need to avoid checking the same value multiple times, otherwise we
         get an exponential blowup, see #1247. *)
      itered_values := v :: !itered_values;
      match v.value with
        | Source s -> f s
        | Ground _ | Encoder _ -> ()
        | List l -> List.iter iter_value l
        | Tuple l -> List.iter iter_value l
        | Null -> ()
        | Meth (_, a, b) ->
            iter_value a;
            iter_value b
        | Fun (proto, pe, env, body) ->
            (* The following is necessarily imprecise: we might see sources that
               will be unused in the execution of the function. *)
            iter_term env body;
            List.iter (fun (_, v) -> iter_value v) pe;
            List.iter (function _, _, Some v -> iter_value v | _ -> ()) proto
        | FFI (proto, pe, _) ->
            List.iter (fun (_, v) -> iter_value v) pe;
            List.iter (function _, _, Some v -> iter_value v | _ -> ()) proto
        | Ref r ->
            if List.memq r !static_analysis_failed then ()
            else (
              (* Do not walk inside references, otherwise the list of "contained"
                 sources may change from one time to the next, which makes it
                 impossible to avoid ill-balanced activations. Not walking inside
                 references does not break things more than they are already:
                 detecting sharing in presence of references to sources cannot be
                 done statically anyway. We display a fat log message to warn
                 about this risky situation. *)
              let may_have_source =
                let rec aux v =
                  match v.value with
                    | Source _ -> true
                    | Ground _ | Encoder _ | Null -> false
                    | List l -> List.exists aux l
                    | Tuple l -> List.exists aux l
                    | Ref r -> aux !r
                    | Fun _ | FFI _ -> true
                    | Meth (_, v, t) -> aux v || aux t
                in
                aux v
              in
              static_analysis_failed := r :: !static_analysis_failed;
              if may_have_source then
                log#severe
                  "WARNING! Found a reference, potentially containing sources, \
                   inside a dynamic source-producing function. Static analysis \
                   cannot be performed: make sure you are not sharing sources \
                   contained in references!" ) )
  in
  iter_value v

let apply f p = Clock.collect_after (fun () -> Term.apply f p)

(** {1 High-level manipulation of values} *)

let to_unit t = match (demeth t).value with Tuple [] -> () | _ -> assert false

let to_bool t =
  match (demeth t).value with Ground (Bool b) -> b | _ -> assert false

let to_bool_getter t =
  match (demeth t).value with
    | Ground (Bool b) -> fun () -> b
    | Fun _ | FFI _ -> (
        fun () ->
          match (apply t []).value with
            | Ground (Bool b) -> b
            | _ -> assert false )
    | _ -> assert false

let to_fun f =
  match (demeth f).value with
    | Fun _ | FFI _ -> fun args -> apply f args
    | _ -> assert false

let to_string t =
  match (demeth t).value with Ground (String s) -> s | _ -> assert false

let to_string_getter t =
  match (demeth t).value with
    | Ground (String s) -> fun () -> s
    | Fun _ | FFI _ -> (
        fun () ->
          match (apply t []).value with
            | Ground (String s) -> s
            | _ -> assert false )
    | _ -> assert false

let to_float t =
  match (demeth t).value with Ground (Float s) -> s | _ -> assert false

let to_float_getter t =
  match (demeth t).value with
    | Ground (Float s) -> fun () -> s
    | Fun _ | FFI _ -> (
        fun () ->
          match (apply t []).value with
            | Ground (Float s) -> s
            | _ -> assert false )
    | _ -> assert false

let to_source t =
  match (demeth t).value with Source s -> s | _ -> assert false

let to_format t =
  match (demeth t).value with Encoder f -> f | _ -> assert false

let to_request t =
  match (demeth t).value with Ground (Request r) -> r | _ -> assert false

let to_int t =
  match (demeth t).value with Ground (Int s) -> s | _ -> assert false

let to_int_getter t =
  match (demeth t).value with
    | Ground (Int n) -> fun () -> n
    | Fun _ | FFI _ -> (
        fun () ->
          match (apply t []).value with
            | Ground (Int n) -> n
            | _ -> assert false )
    | _ -> assert false

let to_num t =
  match (demeth t).value with
    | Ground (Int n) -> `Int n
    | Ground (Float x) -> `Float x
    | _ -> assert false

let to_list t = match (demeth t).value with List l -> l | _ -> assert false
let to_tuple t = match (demeth t).value with Tuple l -> l | _ -> assert false
let to_option t = match (demeth t).value with Null -> None | _ -> Some t

let to_product t =
  match (demeth t).value with Tuple [a; b] -> (a, b) | _ -> assert false

let to_ref t = match t.value with Ref r -> r | _ -> assert false

let to_metadata_list t =
  let pop v =
    let f (a, b) = (to_string a, to_string b) in
    f (to_product v)
  in
  List.map pop (to_list t)

let to_metadata t =
  let t = to_metadata_list t in
  let metas = Hashtbl.create 10 in
  List.iter (fun (a, b) -> Hashtbl.add metas a b) t;
  metas

let to_string_list l = List.map to_string (to_list l)
let to_int_list l = List.map to_int (to_list l)
let to_source_list l = List.map to_source (to_list l)

(** [assoc lbl n l] returns the [n]th element in [l]
  * of which the first component is [lbl]. *)
let rec assoc label n = function
  | [] -> raise Not_found
  | (l, e) :: tl ->
      if l = label then if n = 1 then e else assoc label (n - 1) tl
      else assoc label n tl

let error ?(pos = []) ?message kind =
  raise (Lang_values.Runtime_error { Lang_values.kind; msg = message; pos })

(** {1 Parsing} *)

let type_and_run ~throw ~lib ast =
  Clock.collect_after (fun () ->
      if Lazy.force Term.debug then Printf.eprintf "Type checking...\n%!";
      (* Type checking *)
      Term.check ~throw ~ignored:true ast;

      if Lazy.force Term.debug then
        Printf.eprintf "Checking for unused variables...\n%!";
      (* Check for unused variables, relies on types *)
      Term.check_unused ~throw ~lib ast;
      if Lazy.force Term.debug then Printf.eprintf "Evaluating...\n%!";
      ignore (Term.eval_toplevel ast))

let mk_expr ~pwd processor lexbuf =
  let processor = MenhirLib.Convert.Simplified.traditional2revised processor in
  let tokenizer = Lang_pp.mk_tokenizer ~pwd lexbuf in
  let tokenizer () =
    let token, (startp, endp) = tokenizer () in
    (token, startp, endp)
  in
  processor tokenizer

let from_in_channel ?(dir = Unix.getcwd ()) ?(parse_only = false) ~ns ~lib
    in_chan =
  let lexbuf = Sedlexing.Utf8.from_channel in_chan in
  begin
    match ns with
    | Some ns -> Sedlexing.set_filename lexbuf ns
    | None -> ()
  end;
  try
    Lang_errors.report lexbuf (fun ~throw () ->
        let expr = mk_expr ~pwd:dir Lang_parser.program lexbuf in
        if not parse_only then type_and_run ~throw ~lib expr)
  with Lang_errors.Error -> exit 1

let from_file ?parse_only ~ns ~lib filename =
  let ic = open_in filename in
  from_in_channel ~dir:(Filename.dirname filename) ?parse_only ~ns ~lib ic;
  close_in ic

let load_libs ?parse_only () =
  let dir = Configure.liq_libs_dir in
  let file = Filename.concat dir "pervasives.liq" in
  if Sys.file_exists file then
    from_file ?parse_only ~ns:(Some file) ~lib:true file

let from_file = from_file ~ns:None

let from_string ?parse_only ~lib expr =
  let i, o = Unix.pipe ~cloexec:true () in
  let i = Unix.in_channel_of_descr i in
  let o = Unix.out_channel_of_descr o in
  output_string o expr;
  close_out o;
  from_in_channel ?parse_only ~ns:None ~lib i;
  close_in i

let eval s =
  try
    let lexbuf = Sedlexing.Utf8.from_string s in
    let expr = mk_expr ~pwd:"/nonexistent" Lang_parser.program lexbuf in
    Clock.collect_after (fun () ->
        Lang_errors.report lexbuf (fun ~throw () ->
            Term.check ~throw ~ignored:false expr);
        Some (Term.eval expr))
  with e ->
    Printf.eprintf "Evaluating %S failed: %s!" s (Printexc.to_string e);
    None

let from_in_channel ?parse_only ~lib x =
  from_in_channel ?parse_only ~ns:None ~lib x

let interactive () =
  Format.printf
    "\n\
     Welcome to the liquidsoap interactive loop.\n\n\
     You may enter any sequence of expressions, terminated by \";;\".\n\
     Each input will be fully processed: parsing, type-checking,\n\
     evaluation (forces default types), output startup (forces default clock).\n\
     @.";
  if Dtools.Log.conf_file#get then
    Format.printf "Logs can be found in %S.\n@." Dtools.Log.conf_file_path#get;
  let lexbuf =
    (* See ocaml-community/sedlex#45 *)
    let chunk_size = 512 in
    let buf = Bytes.create chunk_size in
    let cached = ref (-1) in
    let position = ref (-1) in
    let rec gen () =
      match (!position, !cached) with
        | _, 0 -> None
        | -1, _ ->
            position := 0;
            cached := input stdin buf 0 chunk_size;
            gen ()
        | len, c when len = c ->
            position := -1;

            (* This means that the last read was a full chunk. Safe to try a new
               one right away. *)
            if len = chunk_size then gen () else None
        | len, _ ->
            position := len + 1;
            Some (Bytes.get buf len)
    in
    Sedlexing.Utf8.from_gen gen
  in
  let rec loop () =
    Format.printf "# %!";
    if
      try
        Lang_errors.report lexbuf (fun ~throw () ->
            let expr =
              mk_expr ~pwd:(Unix.getcwd ()) Lang_parser.interactive lexbuf
            in
            Term.check ~throw ~ignored:false expr;
            Term.check_unused ~throw ~lib:true expr;
            Clock.collect_after (fun () ->
                ignore (Term.eval_toplevel ~interactive:true expr)));
        true
      with
        | End_of_file ->
            Format.printf "Bye bye!@.";
            false
        | Lang_errors.Error -> true
        | e ->
            let e = Console.colorize [`white; `bold] (Printexc.to_string e) in
            Format.printf "Exception: %s!@." e;
            true
    then loop ()
  in
  loop ();
  Tutils.shutdown 0

(* Abstract types. *)

module type Abstract = sig
  type content

  val t : t
  val to_value : content -> value
  val of_value : value -> content
end

module type AbstractDef = sig
  type content

  val name : string
  val descr : content -> string
  val compare : content -> content -> int
end

module L = Lang_values
module G = L.Ground

module MkAbstract (Def : AbstractDef) = struct
  type T.ground += Type
  type G.t += Value of Def.content

  let () =
    G.register (function
      | Value v ->
          let compare = function
            | Value v' -> Def.compare v v'
            | _ -> assert false
          in
          Some { G.descr = (fun () -> Def.descr v); compare; typ = Type }
      | _ -> None);

    Lang_types.register_ground_printer (function
      | Type -> Some Def.name
      | _ -> None)

  let t = ground_t Type
  let to_value c = mk (L.V.Ground (Value c))

  let of_value t =
    match t.value with L.V.Ground (Value c) -> c | _ -> assert false
end
