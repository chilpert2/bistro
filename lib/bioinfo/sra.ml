open Core_kernel.Std
open Bistro
open Bistro.EDSL_sh
open Types

let input x = Workflow.input x

let fetch_srr id =
  if (String.length id > 6) then (
    let prefix = String.prefix id 6 in
    workflow ~descr:(sprintf "sra.fetch_srr(%s)" id) [
      wget ~dest (sprintf "ftp://ftp-trace.ncbi.nlm.nih.gov/sra/sra-instant/reads/ByRun/sra/SRR/%s/%s/%s.sra" prefix id id) ()
    ]
  )
  else failwithf "Guizmin_workflow.Sra.fetch_srr: id %s is invalid (should be longer than 6 characters long)" id ()
