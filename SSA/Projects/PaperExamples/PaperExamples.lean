import Qq
import Lean
import Mathlib.Logic.Function.Iterate
import SSA.Core.Framework
import SSA.Core.Tactic
import SSA.Core.Util
import SSA.Core.MLIRSyntax.GenericParser
import SSA.Core.MLIRSyntax.EDSL
import Std.Data.BitVec
import Mathlib.Data.BitVec.Lemmas
import Mathlib.Tactic.Ring
-- import Mathlib.Data.StdBitVec.Lemmas

set_option pp.proofs false
set_option pp.proofs.withType false

open BitVec
open Ctxt(Var)

@[simp]
theorem BitVec.ofInt_zero (w : ℕ) :
    BitVec.ofInt w 0 = 0 :=
  rfl

namespace ToyNoRegion

inductive Ty
  | int
  deriving DecidableEq, Repr

@[reducible]
instance : TyDenote Ty where
  toType
    | .int => BitVec 32

inductive Op :  Type
  | add : Op
  | const : (val : ℤ) → Op
  deriving DecidableEq, Repr

instance : OpSignature Op Ty Id where
  signature
    | .const _ => ⟨[], [], .int, .pure⟩
    | .add   => ⟨[.int, .int], [], .int, .pure⟩

@[reducible]
instance : OpDenote Op Ty Id where
  denote
    | .const n, _, _ => BitVec.ofInt 32 n
    | .add, [(a : BitVec 32), (b : BitVec 32)]ₕ, _ => a + b

def cst {Γ : Ctxt _} (n : ℤ) : Expr Op Γ .pure .int  :=
  Expr.mk
    (op := .const n)
    (ty_eq := rfl)
    (eff_le := by constructor)
    (args := .nil)
    (regArgs := .nil)

def add {Γ : Ctxt _} (e₁ e₂ : Var Γ .int) : Expr Op Γ .pure .int :=
  Expr.mk
    (op := .add)
    (ty_eq := rfl)
(eff_le := by constructor)
    (args := .cons e₁ <| .cons e₂ .nil)
    (regArgs := .nil)

attribute [local simp] Ctxt.snoc

namespace MLIR2Simple

def mkTy : MLIR.AST.MLIRType φ → MLIR.AST.ExceptM Op Ty
  | MLIR.AST.MLIRType.int MLIR.AST.Signedness.Signless _ => do
    return .int
  | _ => throw .unsupportedType

instance instTransformTy : MLIR.AST.TransformTy Op Ty 0 where
  mkTy := mkTy

def mkExpr (Γ : Ctxt Ty) (opStx : MLIR.AST.Op 0) : MLIR.AST.ReaderM Op (Σ ty, Expr Op Γ .pure ty) := do
  match opStx.name with
  | "const" =>
    match opStx.attrs.find_int "value" with
    | .some (v, _ty) => return ⟨.int, cst v⟩
    | .none => throw <| .generic s!"expected 'const' to have int attr 'value', found: {repr opStx}"
  | "add" =>
    match opStx.args with
    | v₁Stx::v₂Stx::[] =>
      let ⟨.int, v₁⟩ ← MLIR.AST.TypedSSAVal.mkVal Γ v₁Stx
      let ⟨.int, v₂⟩ ← MLIR.AST.TypedSSAVal.mkVal Γ v₂Stx
      return ⟨.int, add v₁ v₂⟩
    | _ => throw <| .generic s!"expected two operands for `add`, found #'{opStx.args.length}' in '{repr opStx.args}'"
  | _ => throw <| .unsupportedOp s!"unsupported operation {repr opStx}"

instance : MLIR.AST.TransformExpr Op Ty 0 where
  mkExpr Γ opStx := do return ⟨_, ← mkExpr Γ opStx⟩

def mkReturn (Γ : Ctxt Ty) (opStx : MLIR.AST.Op 0) : MLIR.AST.ReaderM Op (Σ ty, Com Op Γ .pure ty) :=
  if opStx.name == "return"
  then match opStx.args with
  | vStx::[] => do
    let ⟨ty, v⟩ ← MLIR.AST.TypedSSAVal.mkVal Γ vStx
    return ⟨ty, Com.ret v⟩
  | _ => throw <| .generic s!"Ill-formed return statement (wrong arity, expected 1, got {opStx.args.length})"
  else throw <| .generic s!"Tried to build return out of non-return statement {opStx.name}"

instance : MLIR.AST.TransformReturn Op Ty 0 where
  mkReturn Γ opStx := do return ⟨_, ← mkReturn Γ opStx⟩

open Qq in
elab "[simple_com| " reg:mlir_region "]" : term => SSA.elabIntoCom reg q(Op)

end MLIR2Simple

open MLIR AST MLIR2Simple in
def eg₀ : Com Op (Ctxt.ofList []) .pure .int :=
  [simple_com| {
    %c2= "const"() {value = 2} : () -> i32
    %c4 = "const"() {value = 4} : () -> i32
    %c6 = "add"(%c2, %c4) : (i32, i32) -> i32
    %c8 = "add"(%c6, %c2) : (i32, i32) -> i32
    "return"(%c8) : (i32) -> ()
  }]

def eg₀val := Com.denote eg₀ Ctxt.Valuation.nil
#eval eg₀val -- 0x00000008#32

open MLIR AST MLIR2Simple in
/-- x + 0 -/
def lhs : Com Op (Ctxt.ofList [.int]) .pure .int :=
  [simple_com| {
    ^bb0(%x : i32):
      %c0 = "const" () { value = 0 : i32 } : () -> i32
      %out = "add" (%x, %c0) : (i32, i32) -> i32
      "return" (%out) : (i32) -> (i32)
  }]

open MLIR AST MLIR2Simple in
/-- x -/
def rhs : Com Op (Ctxt.ofList [.int]) .pure .int :=
  [simple_com| {
    ^bb0(%x : i32):
      "return" (%x) : (i32) -> (i32)
  }]

open MLIR AST MLIR2Simple in
def p1 : PeepholeRewrite Op [.int] .int :=
  { lhs := lhs, rhs := rhs, correct :=
    by
      rw [lhs, rhs]
      /-:
      Com.denote
        (Com.lete (cst 0)
        (Com.lete (add { val := 1, property := _ } { val := 0, property := _ })
        (Com.ret { val := 0, property := ex1.proof_3 }))) =
      Com.denote (Com.ret { val := 0, property := _ })
      -/
      funext Γv
      simp_peephole [add, cst] at Γv
      /- ⊢ ∀ (a : BitVec 32), a + BitVec.ofInt 32 0 = a -/
      intros a
      rw [BitVec.ofInt_zero]
      ring_nf
      /- goals accomplished 🎉 -/
      done
    }

def ex1_rewritePeepholeAt : Com Op  (Ctxt.ofList [.int]) .pure .int := rewritePeepholeAt p1 1 lhs

theorem hex1_rewritePeephole : ex1_rewritePeepholeAt = (
  -- %c0 = 0
  Com.lete (cst 0) <|
  -- %out_dead = %x + %c0
  Com.lete (add ⟨1, by simp [Ctxt.snoc]⟩ ⟨0, by simp [Ctxt.snoc]⟩ ) <| -- %out = %x + %c0
  -- ret %c0
  Com.ret ⟨2, by simp [Ctxt.snoc]⟩)
  := by rfl

def ex1_rewritePeephole : Com Op  (Ctxt.ofList [.int]) .pure .int := rewritePeephole (fuel := 100) p1 lhs

theorem Hex1_rewritePeephole : ex1_rewritePeephole = (
  -- %c0 = 0
  Com.lete (cst 0) <|
  -- %out_dead = %x + %c0
  Com.lete (add ⟨1, by simp [Ctxt.snoc]⟩ ⟨0, by simp [Ctxt.snoc]⟩ ) <| -- %out = %x + %c0
  -- ret %c0
  Com.ret ⟨2, by simp [Ctxt.snoc]⟩)
  := by rfl


end ToyNoRegion

namespace ToyRegion

inductive Ty
  | int
  deriving DecidableEq, Repr

@[reducible]
instance : TyDenote Ty where
  toType
    | .int => BitVec 32

inductive Op :  Type
  | add : Op
  | const : (val : ℤ) → Op
  | iterate (k : ℕ) : Op
  deriving DecidableEq, Repr

instance : OpSignature Op Ty Id where
  signature
    | .const _ => ⟨[], [], .int, .pure⟩
    | .add   => ⟨[.int, .int], [], .int, .pure⟩
    | .iterate _k => ⟨[.int], [([.int], .int)], .int, .pure⟩

@[reducible]
instance : OpDenote Op Ty Id where
  denote
    | .const n, _, _ => BitVec.ofInt 32 n
    | .add, [(a : BitVec 32), (b : BitVec 32)]ₕ , _ => a + b
    | .iterate k, [(x : BitVec 32)]ₕ, [(f : _ → BitVec 32)]ₕ =>
      let f' (v :  BitVec 32) : BitVec 32 := f  (Ctxt.Valuation.nil.snoc v)
      k.iterate f' x
      -- let f_k := Nat.iterate f' k
      -- f_k x

def cst {Γ : Ctxt _} (n : ℤ) : Expr Op Γ .pure .int  :=
  Expr.mk
    (op := .const n)
    (ty_eq := rfl)
    (eff_le := by constructor)
    (args := .nil)
    (regArgs := .nil)

def add {Γ : Ctxt _} (e₁ e₂ : Var Γ .int) : Expr Op Γ .pure .int :=
  Expr.mk
    (op := .add)
    (ty_eq := rfl)
(eff_le := by constructor)
    (args := .cons e₁ <| .cons e₂ .nil)
    (regArgs := .nil)

def iterate {Γ : Ctxt _} (k : Nat) (input : Var Γ Ty.int) (body : Com Op [.int] .impure .int) :
    Expr Op Γ .pure .int :=
  Expr.mk
    (op := .iterate k)
    (ty_eq := rfl)
(eff_le := by constructor)
    (args := .cons input .nil)
    (regArgs := HVector.cons body HVector.nil)

attribute [local simp] Ctxt.snoc

/-- running `f(x) = x + x` 0 times is the identity. -/
def lhs : Com Op [.int] .pure .int :=
  Com.lete (iterate (k := 0) ⟨0, by simp[Ctxt.snoc]⟩ (
      Com.letPure (add ⟨0, by simp[Ctxt.snoc]⟩ ⟨0, by simp[Ctxt.snoc]⟩) -- fun x => (x + x)
      <| Com.ret ⟨0, by simp[Ctxt.snoc]⟩
  )) <|
  Com.ret ⟨0, by simp[Ctxt.snoc]⟩

def rhs : Com Op [.int] .pure .int :=
  Com.ret ⟨0, by simp[Ctxt.snoc]⟩

attribute [local simp] Ctxt.snoc

set_option pp.proofs false in
set_option pp.proofs.withType false in
def p1 : PeepholeRewrite Op [.int] .int:=
  { lhs := lhs, rhs := rhs, correct := by
      rw [lhs, rhs]
      funext Γv
      /-
      Com.denote
        (Com.lete
          (iterate 0 { val := 0, property := lhs.proof_1 }
            (Com.lete (add { val := 0, property := lhs.proof_1 } { val := 0, property := lhs.proof_1 })
              (Com.ret { val := 0, property := lhs.proof_2 })))
          (Com.ret { val := 0, property := lhs.proof_2 }))
        Γv =
      Com.denote (Com.ret { val := 0, property := rhs.proof_1 }) Γv
      -/
      simp_peephole [add, iterate] at Γv
      /-  ∀ (a : BitVec 32), (fun v => v + v)^[0] a = a -/
      simp [Function.iterate_zero]
      done
  }

/-
def ex1' : Com Op  (Ctxt.ofList [.int]) .int := rewritePeepholeAt p1 1 lhs

theorem EX1' : ex1' = (
  -- %c0 = 0
  Com.lete (cst 0) <|
  -- %out_dead = %x + %c0
  Com.lete (add ⟨1, by simp [Ctxt.snoc]⟩ ⟨0, by simp [Ctxt.snoc]⟩ ) <| -- %out = %x + %c0
  -- ret %c0
  Com.ret ⟨2, by simp [Ctxt.snoc]⟩)
  := by rfl
-/

end ToyRegion
