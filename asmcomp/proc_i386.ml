(* Description of the Intel 386 processor *)

open Misc
open Arch
open Format
open Cmm
open Reg
open Mach

(* Registers available for register allocation *)

(* Register map:
    eax         0               eax - edx: function arguments and results
    ebx         1               eax: C function results
    ecx         2               ebx, esi, edi, ebp: preserved by C
    edx         3
    esi         4
    edi         5
    ebp         6

    f0 - f3     100-103         function arguments and results
                                f0: C function results
                                f1-f3: preserved by C *)

let int_reg_name =
  [| "%eax"; "%ebx"; "%ecx"; "%edx"; "%esi"; "%edi"; "%ebp" |]

let float_reg_name =
  [| "%st"; "%st(1)"; "%st(2)"; "%st(3)"; "%st(4)" |]

let num_register_classes = 2

let register_class r =
  match r.typ with
    Int -> 0
  | Addr -> 0
  | Float -> 1

let num_available_registers = [| 7; 4 |]

let first_available_register = [| 0; 100 |]

let register_name r =
  if r < 100 then int_reg_name.(r) else float_reg_name.(r - 100)

(* Representation of hard registers by pseudo-registers *)

let hard_int_reg =
  let v = Array.new 7 Reg.dummy in
  for i = 0 to 6 do v.(i) <- Reg.at_location Int (Reg i) done;
  v

let hard_float_reg =
  let v = Array.new 4 Reg.dummy in
  for i = 0 to 3 do v.(i) <- Reg.at_location Float (Reg(i + 100)) done;
  v

let all_phys_regs =
  Array.append hard_int_reg hard_float_reg

let phys_reg n =
  if n < 100 then hard_int_reg.(n) else hard_float_reg.(n - 100)

let stack_slot slot ty =
  Reg.at_location ty (Stack slot)

(* Exceptions raised to signal cases not handled here *)

exception Use_default

(* Instruction selection *)

(* Auxiliary for recognizing addressing modes *)

type addressing_expr =
    Asymbol of string
  | Alinear of expression
  | Aadd of expression * expression
  | Ascale of expression * int
  | Ascaledadd of expression * expression * int

let rec select_addr exp =
  match exp with
    Cconst(Const_symbol s) ->
      (Asymbol s, 0)
  | Cop((Caddi | Cadda), [arg; Cconst(Const_int m)]) ->
      let (a, n) = select_addr arg in (a, n + m)
  | Cop((Caddi | Cadda), [Cconst(Const_int m); arg]) ->
      let (a, n) = select_addr arg in (a, n + m)
  | Cop(Clsl, [arg; Cconst(Const_int(1|2|3 as shift))]) ->
      begin match select_addr arg with
        (Alinear e, n) -> (Ascale(e, 1 lsl shift), n lsl shift)
      | _ -> (Alinear exp, 0)
      end
  | Cop(Cmuli, [arg; Cconst(Const_int(2|4|8 as mult))]) ->
      begin match select_addr arg with
        (Alinear e, n) -> (Ascale(e, mult), n * mult)
      | _ -> (Alinear exp, 0)
      end
  | Cop(Cmuli, [Cconst(Const_int(2|4|8 as mult)); arg]) ->
      begin match select_addr arg with
        (Alinear e, n) -> (Ascale(e, mult), n * mult)
      | _ -> (Alinear exp, 0)
      end
  | Cop((Caddi | Cadda), [arg1; arg2]) ->
      begin match (select_addr arg1, select_addr arg2) with
          ((Alinear e1, n1), (Alinear e2, n2)) ->
              (Aadd(e1, e2), n1 + n2)
        | ((Alinear e1, n1), (Ascale(e2, scale), n2)) ->
              (Ascaledadd(e1, e2, scale), n1 + n2)
        | ((Ascale(e1, scale), n1), (Alinear e2, n2)) ->
              (Ascaledadd(e2, e1, scale), n1 + n2)
        | (_, (Ascale(e2, scale), n2)) ->
              (Ascaledadd(arg1, e2, scale), n2)
        | ((Ascale(e1, scale), n1), _) ->
              (Ascaledadd(arg2, e1, scale), n1)
        | _ ->
              (Aadd(arg1, arg2), 0)
      end
  | arg ->
      (Alinear arg, 0)
    
let select_addressing exp =
  match select_addr exp with
    (Asymbol s, d) ->
      (Ibased(s, d), Ctuple [])
  | (Alinear e, d) ->
      (Iindexed d, e)
  | (Aadd(e1, e2), d) ->
      (Iindexed2 d, Ctuple[e1; e2])
  | (Ascale(e, scale), d) ->
      (Iindexed 0, exp)
  | (Ascaledadd(e1, e2, scale), d) ->
      (Iindexed2scaled(scale, d), Ctuple[e1; e2])

exception Use_default

let select_oper op args =
  match op with
  (* Recognize the LEA instruction *)
    Caddi | Cadda ->
      begin match select_addressing (Cop(op, args)) with
        ((Iindexed2 n as addr), arg) when n <> 0 ->
          (Ispecific(Ilea addr), arg)
      | ((Iindexed2scaled(scale, n) as addr), arg) ->
          (Ispecific(Ilea addr), arg)
      | _ ->
          raise Use_default
      end
  (* Recognize the NEG instruction *)
  | Csubi ->
      begin match args with
        [Cconst(Const_int 0); arg] -> (Ispecific Ineg, arg)
      | _ -> raise Use_default
      end
  (* Prevent the recognition of (x / cst) and (x % cst),
     which do not correspond to an addressing mode. *)
  | Cdivi -> (Iintop Idiv, Ctuple args)
  | Cmodi -> (Iintop Imod, Ctuple args)
  | _ -> raise Use_default

let pseudoregs_for_operation op arg res =
  match op with
    (* Two-address binary operations *)
    Iintop(Iadd|Isub|Imul|Iand|Ior|Ixor) ->
      ([|res.(0); arg.(1)|], res)
    (* Two-address unary operations *)
  | Iintop_imm((Iadd|Isub|Imul|Iand|Ior|Ixor|Ilsl|Ilsr|Iasr), _) |
    Ispecific Ineg -> 
      (res, res)
    (* For shifts with variable shift count, second arg must be in ecx *)
  | Iintop(Ilsl|Ilsr|Iasr) ->
      ([|res.(0); phys_reg 2|], res)
    (* For div and mod, first arg must be in eax, result is in eax or edx *)
  | Iintop(Idiv) ->
      ([|phys_reg 0; arg.(1)|], [|phys_reg 0|])
  | Iintop(Imod) ->
      ([|phys_reg 0; arg.(1)|], [|phys_reg 3|])
    (* For storing a byte, the argument must be in eax...edx.
       For storing a word, any reg is ok.
       Keep it simple, just force it to be in edx in both cases. *)
  | Istore(Word, addr) -> raise Use_default
  | Istore(chunk, addr) ->
      let newarg = Array.copy arg in
      newarg.(0) <- phys_reg 3;
      (newarg, res)
    (* For modify, the argument must be in eax *)
  | Imodify ->
      ([|phys_reg 0|], [||])
    (* Other instructions are more or less regular *)
  | _ -> raise Use_default

let is_immediate (n: int) = true

(* Calling conventions *)

let calling_conventions first_int last_int first_float last_float make_stack
                        arg =
  let loc = Array.new (Array.length arg) Reg.dummy in
  let int = ref first_int in
  let float = ref first_float in
  let ofs = ref 0 in
  for i = 0 to Array.length arg - 1 do
    match arg.(i).typ with
      Int | Addr as ty ->
        if !int <= last_int then begin
          loc.(i) <- phys_reg !int;
          incr int
        end else begin
          loc.(i) <- stack_slot (make_stack !ofs) ty;
          ofs := !ofs + size_int
        end
    | Float ->
        if !float <= last_float then begin
          loc.(i) <- phys_reg !float;
          incr float
        end else begin
          loc.(i) <- stack_slot (make_stack !ofs) Float;
          ofs := !ofs + size_float
        end
  done;
  (loc, !ofs)

let incoming ofs = Incoming ofs
let outgoing ofs = Outgoing ofs
let not_supported ofs = fatal_error "Proc.loc_results: cannot call"

let loc_arguments arg =
  calling_conventions 0 3 100 103 outgoing arg
let loc_parameters arg =
  let (loc, ofs) = calling_conventions 0 3 100 103 incoming arg in loc
let loc_results res =
  let (loc, ofs) = calling_conventions 0 3 100 103 not_supported res in loc
let loc_external_arguments arg =
  calling_conventions 0 (-1) 100 99 outgoing arg
let loc_external_results res =
  let (loc, ofs) = calling_conventions 0 0 100 100 not_supported res in loc

let loc_exn_bucket = phys_reg 0         (* eax *)

(* Registers destroyed by operations *)

let destroyed_at_oper = function
    Iop(Iintop(Idiv | Imod)) -> [| phys_reg 0; phys_reg 3 |] (* eax, edx *)
  | Iop(Ialloc _) -> [| phys_reg 0|] (* eax *)
  | Iop(Imodify) -> [| phys_reg 0 |] (* eax *)
  | Iop(Iintop(Icomp _) | Iintop_imm(Icomp _, _)) -> [| phys_reg 0 |] (* eax *)
  | Iop(Iintoffloat) -> [| phys_reg 0 |] (* eax *)
  | Iifthenelse(Ifloattest _, _, _) -> [| phys_reg 0 |] (* eax *)
  | _ -> [||]

let destroyed_at_call = all_phys_regs
let destroyed_at_extcall = [| phys_reg 0; phys_reg 2; phys_reg 3 |]
                           (* eax, ecx, edx *)
let destroyed_at_raise = all_phys_regs

(* Reloading of instruction arguments, storing of instruction results *)

let stackp r =
  match r.loc with
    Stack _ -> true
  | _ -> false

let reload_test makereg tst arg =
  match tst with
    Iinttest cmp ->
      if stackp arg.(0) & stackp arg.(1)
      then [| makereg arg.(0); arg.(1) |]
      else arg
  | _ -> arg

let reload_operation makereg op arg res =
  match op with
    Iintop(Iadd|Isub|Imul|Iand|Ior|Ixor|Icomp _) ->
      (* One of the two arguments can reside in the stack *)
      if stackp arg.(0) & stackp arg.(1)
      then ([|arg.(0); makereg arg.(1)|], res)
      else (arg, res)
  | Iintop(Ilsl|Ilsr|Iasr) | Iintop_imm(_, _) | Ispecific Ineg |
    Iaddf | Isubf | Imulf | Idivf | Ifloatofint | Iintoffloat ->
      (* The argument(s) can be either in register or on stack *)
      (arg, res)
  | _ -> (* Other operations: all args and results in registers *)
      raise Use_default

(* Layout of the stack frame *)

let num_stack_slots = [| 0; 0 |]
let stack_offset = ref 0
let contains_calls = ref false

let frame_size () =                     (* includes return address *)
  !stack_offset + 4 * num_stack_slots.(0) + 8 * num_stack_slots.(1) + 4

let slot_offset loc class =
  match loc with
    Incoming n -> frame_size() + n
  | Local n ->
      if class = 0
      then !stack_offset + n * 4
      else !stack_offset + num_stack_slots.(0) * 4 + n * 8
  | Outgoing n -> n
