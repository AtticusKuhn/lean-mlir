import Mathlib.Logic.Function.Iterate
import SSA.Core.Framework
import SSA.Core.Util

set_option pp.proofs false
set_option pp.proofs.withType false

open Std (BitVec)
open Ctxt(Var)

namespace ToyNoRegion

inductive Ty
  | int
  deriving DecidableEq, Repr

@[reducible]
instance : Goedel Ty where
  toType
    | .int => BitVec 32

inductive Op :  Type
  | add : Op
  | const : (val : ℤ) → Op
  deriving DecidableEq, Repr

instance : OpSignature Op Ty where
  signature
    | .const _ => ⟨[], [], .int⟩
    | .add   => ⟨[.int, .int], [], .int⟩

@[reducible]
instance : OpDenote Op Ty where
  denote
    | .const n, _, _ => BitVec.ofInt 32 n
    | .add, .cons (a : BitVec 32) (.cons (b : BitVec 32) .nil), _ => a + b

def cst {Γ : Ctxt _} (n : ℤ) : IExpr Op Γ .int  :=
  IExpr.mk
    (op := .const n)
    (ty_eq := rfl)
    (args := .nil)
    (regArgs := .nil)

def add {Γ : Ctxt _} (e₁ e₂ : Var Γ .int) : IExpr Op Γ .int :=
  IExpr.mk
    (op := .add)
    (ty_eq := rfl)
    (args := .cons e₁ <| .cons e₂ .nil)
    (regArgs := .nil)

attribute [local simp] Ctxt.snoc

/-- x + 0 -/
def lhs : ICom Op (Ctxt.ofList [.int]) .int :=
   -- %c0 = 0
  ICom.lete (cst 0) <|
   -- %out = %x + %c0
  ICom.lete (add ⟨1, by simp [Ctxt.snoc]⟩ ⟨0, by simp [Ctxt.snoc]⟩ ) <|
  -- return %out
  ICom.ret ⟨0, by simp [Ctxt.snoc]⟩

/-- x -/
def rhs : ICom Op (Ctxt.ofList [.int]) .int :=
  ICom.ret ⟨0, by simp⟩

def p1 : PeepholeRewrite Op [.int] .int :=
  { lhs := lhs, rhs := rhs, correct :=
    by
      rw [lhs, rhs]
      /-
      ICom.denote
        (ICom.lete (cst 0)
        (ICom.lete (add { val := 1, property := _ } { val := 0, property := _ })
        (ICom.ret { val := 0, property := ex1.proof_3 }))) =
      ICom.denote (ICom.ret { val := 0, property := _ })
      -/
      funext Γv
      simp_peephole [add, cst] at Γv
      /- ⊢ ∀ (a : BitVec 32), a + BitVec.ofInt 32 0 = a -/
      intros a
      ring
      /- goals accomplished 🎉 -/
      sorry
    }

def ex1' : ICom Op  (Ctxt.ofList [.int]) .int := rewritePeepholeAt p1 1 lhs


theorem EX1' : ex1' = (
  -- %c0 = 0
  ICom.lete (cst 0) <|
  -- %out_dead = %x + %c0
  ICom.lete (add ⟨1, by simp [Ctxt.snoc]⟩ ⟨0, by simp [Ctxt.snoc]⟩ ) <| -- %out = %x + %c0
  -- ret %c0
  ICom.ret ⟨2, by simp [Ctxt.snoc]⟩)
  := by rfl

end ToyNoRegion

namespace ToyRegion

inductive Ty
  | int
  deriving DecidableEq, Repr

@[reducible]
instance : Goedel Ty where
  toType
    | .int => BitVec 32

inductive Op :  Type
  | add : Op
  | const : (val : ℤ) → Op
  | iterate (k : ℕ) : Op
  deriving DecidableEq, Repr

instance : OpSignature Op Ty where
  signature
    | .const _ => ⟨[], [], .int⟩
    | .add   => ⟨[.int, .int], [], .int⟩
    | .iterate _k => ⟨[.int], [([.int], .int)], .int⟩

@[reducible]
instance : OpDenote Op Ty where
  denote
    | .const n, _, _ => BitVec.ofInt 32 n
    | .add, .cons (a : BitVec 32) (.cons (b : BitVec 32) .nil), _ => a + b
    | .iterate k, (.cons (x : BitVec 32) .nil), (.cons (f : _ → BitVec 32) .nil) =>
      let f' (v :  BitVec 32) : BitVec 32 := f  (Ctxt.Valuation.nil.snoc' v)
      k.iterate f' x
      -- let f_k := Nat.iterate f' k
      -- f_k x

def cst {Γ : Ctxt _} (n : ℤ) : IExpr Op Γ .int  :=
  IExpr.mk
    (op := .const n)
    (ty_eq := rfl)
    (args := .nil)
    (regArgs := .nil)

def add {Γ : Ctxt _} (e₁ e₂ : Var Γ .int) : IExpr Op Γ .int :=
  IExpr.mk
    (op := .add)
    (ty_eq := rfl)
    (args := .cons e₁ <| .cons e₂ .nil)
    (regArgs := .nil)

def iterate {Γ : Ctxt _} (k : Nat) (input : Var Γ Ty.int) (body : ICom Op [.int] .int) : IExpr Op Γ .int :=
  IExpr.mk
    (op := .iterate k)
    (ty_eq := rfl)
    (args := .cons input .nil)
    (regArgs := HVector.cons body HVector.nil)

attribute [local simp] Ctxt.snoc

/-- running `f(x) = x + x` 0 times is the identity. -/
def lhs : ICom Op [.int] .int :=
  ICom.lete (iterate (k := 0) ⟨0, by simp[Ctxt.snoc]⟩ (
      ICom.lete (add ⟨0, by simp[Ctxt.snoc]⟩ ⟨0, by simp[Ctxt.snoc]⟩) -- fun x => (x + x)
      <| ICom.ret ⟨0, by simp[Ctxt.snoc]⟩
  )) <|
  ICom.ret ⟨0, by simp[Ctxt.snoc]⟩

def rhs : ICom Op [.int] .int :=
  ICom.ret ⟨0, by simp[Ctxt.snoc]⟩

attribute [local simp] Ctxt.snoc

@[simp]
theorem Ctxt.Valuation.snoc_last [Goedel Ty] {ty : Ty} (Γ : Ctxt Ty) (V : Γ.Valuation) (v : Goedel.toType ty):
  (Ctxt.Valuation.snoc V v) (Ctxt.Var.last _ _) = v := rfl
set_option pp.proofs false in
set_option pp.proofs.withType false in
def p1 : PeepholeRewrite Op [.int] .int:=
  { lhs := lhs, rhs := rhs, correct := by
      rw [lhs, rhs]
      funext Γv
      /-
      ICom.denote
        (ICom.lete
          (iterate 0 { val := 0, property := lhs.proof_1 }
            (ICom.lete (add { val := 0, property := lhs.proof_1 } { val := 0, property := lhs.proof_1 })
              (ICom.ret { val := 0, property := lhs.proof_2 })))
          (ICom.ret { val := 0, property := lhs.proof_2 }))
        Γv =
      ICom.denote (ICom.ret { val := 0, property := rhs.proof_1 }) Γv
      -/
      simp_peephole [add, iterate] at Γv
      /-  ∀ (a : BitVec 32), (fun v => v + v)^[0] a = a -/
      simp [Function.iterate_zero]
      done
  }

/-
def ex1' : ICom Op  (Ctxt.ofList [.int]) .int := rewritePeepholeAt p1 1 lhs

theorem EX1' : ex1' = (
  -- %c0 = 0
  ICom.lete (cst 0) <|
  -- %out_dead = %x + %c0
  ICom.lete (add ⟨1, by simp [Ctxt.snoc]⟩ ⟨0, by simp [Ctxt.snoc]⟩ ) <| -- %out = %x + %c0
  -- ret %c0
  ICom.ret ⟨2, by simp [Ctxt.snoc]⟩)
  := by rfl
-/

end ToyRegion
