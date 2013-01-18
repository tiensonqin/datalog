(** The main datalog file. It provides a CLI tool to parse rule/fact files and compute
    their fixpoint *)

let progress = ref false
let print_input = ref false
let print_result = ref false
let print_saturated = ref false
let print_size = ref false
let sums = ref []
let patterns = ref []
let explains = ref []
let files = ref []

(** Parse file and returns the rules *)
let parse_file filename =
  Format.printf "%% parse file %s@." filename;
  let ic = open_in filename in
  let lexbuf = Lexing.from_channel ic in
  let rules = Datalog.Parser.parse_file Datalog.Lexer.token lexbuf in
  close_in ic;
  rules

(** Parse files *)
let parse_files () =
  let rules = List.fold_left
    (fun rules file ->
      List.rev_append (parse_file file) rules)
    [] !files
  in List.rev rules

let pp_progress i total =
  Format.printf "\r%% rule %-5d / %-5d  " i total;
  Format.print_flush ()

(** Compute fixpoint of rules *)
let process_rules rules =
  Format.printf "%% process %d rules@." (List.length rules);
  (if !print_input then
    List.iter (Format.printf "  rule @[<h>%a@]@." (Datalog.Logic.pp_rule ?to_s:None)) rules);
  Format.printf "%% computing fixpoint...@.";
  let db = Datalog.Logic.db_create () in
  (* handlers *)
  List.iter (fun (n,handler,_) -> Datalog.Logic.db_subscribe db n handler) !sums;
  (* add rules one by one *)
  let total = List.length rules in
  ignore (List.fold_left (fun i rule -> (if !progress then pp_progress i total);
                          Datalog.Logic.db_add db rule; i+1)
          1 rules);
  Format.printf "%% done.@.";
  (* print fixpoint of set after application of rules *)
  (if !print_size then
    Format.printf "%% size of saturated set: %d@." (Datalog.Logic.db_size db));
  (if !print_saturated then 
    Datalog.Logic.db_fold (fun () rule ->
      Format.printf "  @[<h>%a@]@." (Datalog.Logic.pp_rule ?to_s:None) rule) () db
  else if !print_result then 
    Datalog.Logic.db_fold (fun () rule ->
      if Datalog.Logic.is_fact rule then
        Format.printf "  @[<h>%a@]@." (Datalog.Logic.pp_rule ?to_s:None) rule) () db);
  (* print aggregates *)
  List.iter (fun (_,_,printer) -> printer ()) !sums;
  (* print patterns *)
  List.iter (fun pattern ->
    Format.printf "%% facts matching pattern %a:@." (Datalog.Logic.pp_term ?to_s:None) pattern;
    Datalog.Logic.db_match db pattern
      (fun fact subst -> Format.printf "  @[<h>%a.@]@." (Datalog.Logic.pp_term ?to_s:None) fact))
    !patterns;
  (* print explanations *)
  List.iter (fun pattern ->
    Datalog.Logic.db_match db pattern
      (fun fact subst ->
        (* premises *)
        Format.printf "  premises of @[<h>%a@]: @[<h>" (Datalog.Logic.pp_term ?to_s:None) fact;
        let premises = Datalog.Logic.db_premises db fact in
        List.iter (fun fact' -> Format.printf " %a"
          (Datalog.Logic.pp_term ?to_s:None) fact') premises;
        Format.printf "@]@.";
        (* explanation *)
        let explanation = Datalog.Logic.db_explain db fact in
        Format.printf "  explain @[<h>%a@] by: @[<h>" (Datalog.Logic.pp_term ?to_s:None) fact;
        List.iter (fun fact' -> Format.printf " %a"
          (Datalog.Logic.pp_term ?to_s:None) fact') explanation;
        Format.printf "@]@."))
    !explains;
  (* print memory usage *)
  let stat = Gc.quick_stat () in
  Format.printf "%% max_heap_size: %d; minor_collections: %d; major collections: %d@."
    stat.Gc.top_heap_words stat.Gc.minor_collections stat.Gc.major_collections;
  ()

(** Handler that aggregates the number of facts with this head symbol. It adds the
    handler to the global variable [sums] *)
let add_sum symbol =
  let n = Datalog.Symbols.mk_symbol symbol in
  let count = ref 0 in
  (* print result at exit *)
  let printer () = Format.printf "%% number of fact with head %s: %d@." symbol !count in
  let handler _ = incr count in
  sums := (n, handler, printer) :: !sums

(** Handler that prints facts that match the given [pattern] once the
    set is saturated *)
let add_pattern p =
  let lexbuf = Lexing.from_string p in
  let term = Datalog.Parser.term Datalog.Lexer.token lexbuf in
  patterns := term :: !patterns

(** Add the pattern to the list of patterns to explain *)
let add_explain p =
  let lexbuf = Lexing.from_string p in
  let term = Datalog.Parser.term Datalog.Lexer.token lexbuf in
  explains := term :: !explains

(** parse CLI arguments *)
let parse_args () =
  let options =
    [ ("-progress", Arg.Set progress, "print progress");
      ("-input", Arg.Set print_input, "print input rules");
      ("-output", Arg.Set print_result, "print facts after fixpoint");
      ("-saturated", Arg.Set print_saturated, "print facts and rules after fixpoint");
      ("-sum", Arg.String add_sum, "aggregate number of terms for the given symbol");
      ("-pattern", Arg.String add_pattern, "print facts matching this pattern");
      ("-explain", Arg.String add_explain, "explain facts matching this pattern");
      ("-size", Arg.Set print_size, "print number of rules after fixpoint");
    ]
  in
  Arg.parse options (fun f -> files := f :: !files) "compute fixpoint of given files"

let () =
  Format.printf "%% start datalog@.";
  parse_args ();
  let rules = parse_files () in
  process_rules rules