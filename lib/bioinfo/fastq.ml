open Bistro.Std
open Bistro.EDSL
open Types

type _ format =
  | Sanger  : [`sanger] format
  | Solexa  : [`solexa] format
  | Phred64 : [`phred64] format

let sanger_of_solexa fq = assert false

let sanger_of_phred64 fq = assert false

let to_sanger :
  type s. s format -> s fastq workflow -> [`sanger] fastq workflow
  = fun format fq ->
    match format with
    | Sanger -> fq
    | Solexa -> sanger_of_solexa fq
    | Phred64 -> sanger_of_phred64 fq

let concat = function
  | [] -> raise (Invalid_argument "fastq concat: empty list")
  | x :: [] -> x
  | fqs ->
    workflow ~descr:"fastq.concat" [
      cmd "cat" ~stdout:dest [ list dep ~sep:" " fqs ]
    ]
