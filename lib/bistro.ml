open Core_kernel.Std

type path = string list
with sexp

let string_of_path = function
  | []
  | "" :: _ -> failwith "string_of_path: wrong path"
  | p -> List.reduce_exn p ~f:Filename.concat

let path_of_string s = String.split ~on:'/' s

let digest x =
  Digest.to_hex (Digest.string (Marshal.to_string x []))

let ( % ) f g x = g (f x)

let ok = function
  | `Ok x -> x
  | `Error e -> raise e

module Utils = struct
  let python_version fmt =
    let regexp = match fmt with
      | `M_m -> "[0-9]\\.[0-9]"
    in
    let ic = Unix.open_process_in (sprintf "python --version 2>&1 | grep -o '%s'" regexp) in
    let r = In_channel.input_line ic in
    In_channel.close ic ;
    r
end

module T = struct
  type u =
    | Input of string * path
    | Extract of string * u * path
    | Step of step

  and step = {
    id : string ;
    descr : string ;
    deps : u list ;
    script : script ;
    np : int ; (** Required number of processors *)
    mem : int ; (** Required memory in MB *)
    timeout : int ; (** Maximum allowed running time in hours *)
    version : int option ; (** Version number of the wrapper *)
  }

  and script = {
    interpreter : interpreter ;
    tokens : token list ;
  }

  and token =
    | S of string
    | D of u
    | DEST
    | TMP

  and interpreter = [
    | `bash
    | `ocaml
    | `ocamlscript
    | `perl
    | `python
    | `R
    | `sh
  ]

  with sexp
end

include T

module Script = struct
  type t = script

  let make interpreter xs = {
    interpreter ;
    tokens = List.concat xs
  }

  let interpreter x = x.interpreter

  let deps s =
    List.filter_map s.tokens ~f:(function
        | D r -> Some (r :> u)
        | S _ | DEST | TMP -> None
      )
    |> List.dedup

  let string_of_token ~string_of_workflow ~tmp ~dest = function
    | S s -> s
    | D w -> string_of_workflow (w :> u)
    | DEST -> dest
    | TMP -> tmp

  let to_string ~string_of_workflow ~tmp ~dest script =
    List.map script.tokens ~f:(string_of_token ~string_of_workflow ~tmp ~dest)
    |> String.concat
end

module Workflow = struct
  include T
  type 'a t = u

  let id = function
    | Input (id, _)
    | Extract (id, _, _)
    | Step { id } -> id

  let id' = id

  let input ?(may_change = false) target =
    let hash = if may_change then Some (Digest.file target) else None in
    let id = digest ("input", target, hash) in
    Input (id, path_of_string target)


  let make
      ?(descr = "")
      ?(mem = 100)
      ?(np = 1)
      ?(timeout = 24)
      ?version
      script =
    let deps = Script.deps script in
    let id = digest ("step",
                     version,
                     Script.to_string
                       ~string_of_workflow:id
                       ~tmp:"TMP"
                       ~dest:"DEST"
                       script) in
    Step { descr ; deps ; script ; np ; mem ; timeout ; version ; id }

  let extract u path =
    let u, path =
      match u with
      | Extract (_, v, p) -> v, p @ path
      | Input _ | Step _ -> u, path
    in
    let id = digest ("extract", id u, path) in
    Extract (id, u, path)

  let rec collect accu u =
    let accu' = List.Assoc.add accu (id u) u in
    match u with
    | Input _ -> accu'
    | Extract (_, v, _) -> collect accu' v
    | Step { deps } ->
      List.fold deps ~init:accu' ~f:collect

  let descr = function
    | Input (_,p) -> (string_of_path p)
    | Extract (_, _, p) -> (string_of_path p)
    | Step { descr } -> descr


  let u x = x

  let to_dot u oc =
    let nodes = collect [] u in
    fprintf oc "digraph workflow {\n" ;
    List.iter nodes ~f:(fun (id_n, n) ->
        match n with
        | Step { deps } ->
          fprintf oc "n%s [shape=box,label = \"%s\"];\n" id_n (descr n) ;
          List.iter deps ~f:(fun m ->
              fprintf oc "n%s -> n%s;\n" id_n (id m)
            )
        | Extract (_,m,_) ->
          fprintf oc "n%s [shape=box,label = \"%s\",shape=plaintext];\n" id_n (descr n) ;
          fprintf oc "n%s -> n%s [style=dotted];\n" id_n (id m)
        | Input _ ->
          fprintf oc "n%s [label = \"%s\"];\n" id_n (descr n)
      ) ;
    fprintf oc "}\n"
end

type 'a directory = [`directory of 'a]
type package = [`package] directory


module EDSL = struct
  type expr = token list

  let workflow ?descr ?mem ?np ?timeout ?version ?(interpreter = `sh) expr =
    Workflow.make ?descr ?mem ?timeout ?version (Script.make interpreter expr)

  let dest = [ DEST ]
  let tmp = [ TMP ]
  let string s = [ S s ]
  let int i = [ S (string_of_int i) ]
  let float f = [ S (Float.to_string f) ]
  let path p = [ S (string_of_path p) ]
  let dep w = [ D w ]

  let option f = function
    | None -> []
    | Some x -> f x

  let list f ?(sep = ",") l =
    List.map l ~f
    |> List.intersperse ~sep:[ S sep ]
    |> List.concat

  let seq ?(sep = "") xs = List.concat (List.intersperse ~sep:(string sep) xs)

  let enum dic x = [ S (List.Assoc.find_exn dic x) ]

  let use s = s.tokens
end

module EDSL_sh = struct
  include EDSL

  type cmd = token list

  let script cmds =
    Script.make
      `sh
      (List.intersperse ~sep:[S "\n"] cmds)

  let workflow ?descr ?mem ?np ?timeout ?version cmds =
    Workflow.make ?descr ?mem ?timeout ?version (script cmds)


  let cmd ?path ?pythonpath p ?stdin ?stdout ?stderr args =
    let add_path =
      match path with
      | None | Some [] -> ident
      | Some pkgs ->
        fun cmd ->
          S "(export PATH="
          :: (
            List.map pkgs ~f:(fun p -> [ D p ; S "/bin" ])
            |> List.intersperse ~sep:[S ":"]
            |> List.concat
          )
          @ [ S ":$PATH ; " ]
          @ cmd
          @ [ S ")" ]
    in
    let add_pythonpath = match pythonpath with
      | None | Some [] -> ident
      | Some pkgs ->
        fun cmd ->
          S "(export PYTHONPATH="
          :: (
            List.map pkgs ~f:(fun p -> [ D p ; S "/lib/python2.7/site-packages" ])
            (* FIXME: this won't work with other versions of python
               than 2.7 ; we should introduce execution-time variables
               -- here PYTHON_VERSION -- and the corresponding
               constructor in the API *)
            |> List.intersperse ~sep:[S ":"]
            |> List.concat
          )
          @ [ S ":$PYTHONPATH ; " ]
          @ cmd
          @ [ S ")" ]
    in
    let prog_expr = [ S p ] in
    let stdout_expr =
      match stdout with
      | None -> []
      | Some e -> S " > " :: e
    in
    let stdin_expr =
      match stdin with
      | None -> []
      | Some e -> S " < " :: e
    in
    let stderr_expr =
      match stderr with
      | None -> []
      | Some e -> S " 2> " :: e
    in
    [ prog_expr ] @ args @ [ stdin_expr ; stdout_expr ; stderr_expr ]
    |> List.filter ~f:(( <> ) [])
    |> List.intersperse ~sep:[S " "]
    |> List.concat
    |> add_pythonpath
    |> add_path


  let opt o f x = S o :: S " " :: f x

  let opt' o f x = S o :: S "=" :: f x

  let flag f x b = if b then f x else []

  let mkdir d = cmd "mkdir" [ d ]

  let mkdir_p d = cmd "mkdir" [ string "-p" ; d ]

  let cd p = cmd "cd" [ p ]

  let rm_rf x = cmd "rm" [ string "-rf" ; x ]

  let mv x y = cmd "mv" [ x ; y ]

  let wget url ?dest () = cmd "wget" [
      option (opt "-O" ident) dest ;
      string url
    ]

  let ( // ) x y = x @ [ S "/" ; S y ]

  let par cmd =
    S "( " :: (cmd @ [ S " )" ])

  let cmd_list op cmds =
    List.intersperse ~sep:[ S " " ; S op ; S " " ] cmds
    |> List.concat
    |> par

  let or_list = cmd_list "||"
  let and_list = cmd_list "&&"
  let pipe = cmd_list "|"

  let with_env vars cmd =
    (
      List.map vars ~f:(fun (var, value) -> [ S var ; S "=" ] @ value)
      |> List.intersperse ~sep:[ S " " ]
      |> List.concat
    )
    @ (S " " :: cmd)
end