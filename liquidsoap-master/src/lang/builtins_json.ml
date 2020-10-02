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

let log = Log.make ["lang"; "json"]

let rec to_json_compact v =
  (* Utils.escape implements JSON's escaping RFC. *)
  let print_s s = Utils.escape_string (fun x -> Utils.escape_utf8 x) s in
  match v.Lang.value with
    (* JSON specs do not allow a trailing . *)
    | Lang.(Ground (Ground.Float n)) ->
        let s = string_of_float n in
        let s = Printf.sprintf "%s" s in
        if s.[String.length s - 1] = '.' then Printf.sprintf "%s0" s else s
    | Lang.Ground g -> Lang_values.Ground.to_string g
    | Lang.List l -> (
        try
          (* Convert (string*'a) list to object *)
          let l =
            List.map
              (fun x ->
                let x, y = Lang.to_product x in
                Printf.sprintf "%s:%s" (to_json_compact x) (to_json_compact y))
              l
          in
          Printf.sprintf "{%s}" (String.concat "," l)
        with _ ->
          Printf.sprintf "[%s]" (String.concat "," (List.map to_json_compact l))
        )
    | Lang.Null -> "null"
    | Lang.Tuple l -> "[" ^ String.concat "," (List.map to_json_compact l) ^ "]"
    | Lang.Meth _ -> failwith "TODO: JSON of field not yet implemented"
    | Lang.Source _ -> "\"<source>\""
    | Lang.Ref v -> Printf.sprintf "{\"reference\":%s}" (to_json_compact !v)
    | Lang.Encoder e -> print_s (Encoder.string_of_format e)
    | Lang.FFI _ | Lang.Fun _ -> "\"<fun>\""

let rec to_json_pp f v =
  match v.Lang.value with
    | Lang.List l -> (
        match l with
          | {
              Lang.value =
                Lang.Tuple
                  [{ Lang.value = Lang.Ground (Lang.Ground.String _) }; _];
            }
            :: _ ->
              (* Convert (string*'a) list to object *)
              let print f l =
                let len = List.length l in
                let f pos x =
                  let x, y = Lang.to_product x in
                  if pos != len - 1 then
                    Format.fprintf f "%a: %a,@;<1 0>" to_json_pp x to_json_pp y
                  else Format.fprintf f "%a: %a" to_json_pp x to_json_pp y;
                  pos + 1
                in
                ignore (List.fold_left f 0 l)
              in
              Format.fprintf f "@[{@;<1 1>@[%a@]@;<1 0>}@]" print l
          | _ ->
              let print f l =
                let len = List.length l in
                let f pos x =
                  if pos < len - 1 then
                    Format.fprintf f "%a,@;<1 0>" to_json_pp x
                  else Format.fprintf f "%a" to_json_pp x;
                  pos + 1
                in
                ignore (List.fold_left f 0 l)
              in
              Format.fprintf f "@[[@;<1 1>@[%a@]@;<1 0>]@]" print l )
    | Lang.Tuple l ->
        Format.fprintf f "@[[@;<1 1>@[";
        let rec aux = function
          | [] -> ()
          | [p] -> Format.fprintf f "%a" to_json_pp p
          | p :: l ->
              Format.fprintf f "%a,@;<1 0>" to_json_pp p;
              aux l
        in
        aux l;
        Format.fprintf f "@]@;<1 0>]@]"
    | Lang.Ref v ->
        Format.fprintf f "@[{@;<1 1>@[\"reference\":@;<0 1>%a@]@;<1 0>}@]"
          to_json_pp !v
    | _ -> Format.fprintf f "%s" (to_json_compact v)

let to_json_pp v =
  let b = Buffer.create 10 in
  let f = Format.formatter_of_buffer b in
  ignore (to_json_pp f v);
  Format.pp_print_flush f ();
  Buffer.contents b

let to_json ~compact v = if compact then to_json_compact v else to_json_pp v

let () =
  Lang_builtins.add_builtin "json_of" ~cat:Lang_builtins.String
    ~descr:"Convert a value to a json string."
    [
      ( "compact",
        Lang.bool_t,
        Some (Lang.bool false),
        Some "Output compact text." );
      ("", Lang.univ_t (), None, None);
    ]
    Lang.string_t
    (fun p ->
      let compact = Lang.to_bool (List.assoc "compact" p) in
      let v = to_json ~compact (List.assoc "" p) in
      Lang.string v)

exception Failed

let () =
  Printexc.register_printer (function
    | Failed -> Some "Liquidsoap count not parse JSON string"
    | _ -> None)

(* We compare the default's type with the parsed json value and return if they
   match. This comes with json_of in Lang_builtins. *)
let rec of_json d j =
  match (d.Lang.value, j) with
    | Lang.Tuple [], `Null -> Lang.unit
    | Lang.Ground (Lang.Ground.Bool _), `Bool b ->
        Lang.bool b
        (* JSON specs do not differenciate between ints
         * and floats. Therefore, we should parse int as
         * floats when required.. *)
    | Lang.Ground (Lang.Ground.Int _), `Int i -> Lang.int i
    | Lang.Ground (Lang.Ground.Float _), `Int i -> Lang.float (float_of_int i)
    | Lang.Ground (Lang.Ground.String _), `String s -> Lang.string s
    | Lang.Ground (Lang.Ground.Float _), `Float x -> Lang.float x
    | Lang.List [], `List [] -> Lang.list []
    | Lang.List (d :: _), `List l ->
        (* TODO: we could also try with other elements of the default list... *)
        let l = List.map (of_json d) l in
        Lang.list l
    | Lang.Tuple [d1; d2], `List [j1; j2] ->
        Lang.product (of_json d1 j1) (of_json d2 j2)
    | ( Lang.List
          ({
             Lang.value =
               Lang.Tuple
                 [{ Lang.value = Lang.Ground (Lang.Ground.String _) }; d];
           }
          :: _),
        `Assoc l ) ->
        (* Try to convert the object to a list of pairs, dropping fields that
           cannot be parsed.  This requires the target type to be [(string*'a)],
           currently it won't work if it is [?T] which would be obtained with
           of_json(default=[],...). *)
        let l =
          List.fold_left
            (fun cur (x, y) ->
              try Lang.product (Lang.string x) (of_json d y) :: cur
              with _ -> cur)
            [] l
        in
        Lang.list l
    | _ -> raise Failed

let () =
  let t = Lang.univ_t () in
  Lang_builtins.add_builtin ~cat:Lang_builtins.String
    ~descr:
      "Parse a json string into a liquidsoap value. The value provided in the \
       `default` parameter is quite important: only the part of the JSON data \
       which has the same type as the `default` parameter will be kept \
       (heterogeneous data cannot be represented in Liquidsoap because of \
       typing). For instance, if the JSON `j` is\n\
       ```\n\
       {\n\
      \ \"a\": \"test\",\n\
      \ \"b\": 5\n\
       }\n\
       ```\n\
       the value returned by `of_json(default=[(\"\",0)], j)` will be \
       `[(\"b\",5)]`: the pair `(\"a\",\"test\")` is not kept because it is \
       not of type `string * int`." "of_json"
    [
      ("default", t, None, Some "Default value if string cannot be parsed.");
      ("", Lang.string_t, None, None);
    ] t (fun p ->
      let default = List.assoc "default" p in
      let s = Lang.to_string (List.assoc "" p) in
      try
        let json = Configure.JSON.from_string s in
        of_json default json
      with e ->
        log#info "JSON parsing failed: %s" (Printexc.to_string e);
        default)
