open Core.Std
open Printf
open Workflow

let rec task i =
  let deps =
    List.init (i - 1) succ
    |> List.filter_map ~f:(
      fun j ->
	if i mod j = 0 then Some (task j)
	else None
    )
  in
  make [
    S [ A"echo" ; A(string_of_int i) ; A">" ; D ]
  ]
  |> fun init ->
    List.fold_left deps
      ~init
      ~f:(fun accu dep -> depends ~on:dep accu)

let () = Export.to_script ~cache_dir:"_bistro" (task 20) stdout