import Dush.Accounting

/-!
# Operands, `-c`, and `du`'s own hard-link table

`dush` (`src/main.zig`, `src/walk.zig`): one `files` inode set is shared by every operand;
each operand prints its own total; `-c` prints `grand_total`, the sum of the printed totals.

Apple `du` (`file_cmds/du/du.c`): `linkchk` keeps one global table for the whole run, but an
entry expires: the first sighting of an inode with `nlink > 1` stores `nlink - 1`, every later
sighting decrements it and is skipped, and the entry is removed when it reaches 0. `-c` prints
`savednumber`, the sum of the root-level operand totals.
-/

namespace Dush.Acct

/-! ## `dush` operands -/

theorem run_seen_indep (w : Entry → Nat) (es : List Entry) :
    ∀ s t t', (run w ⟨s, t⟩ es).seen = (run w ⟨s, t'⟩ es).seen := by
  induction es with
  | nil => intro s t t'; rfl
  | cons e es ih => intro s t t'; simp only [run_cons, step]; exact ih _ _ _

theorem run_total_shift (w : Entry → Nat) (es : List Entry) :
    ∀ s t, (run w ⟨s, t⟩ es).total = t + (run w ⟨s, 0⟩ es).total := by
  intro s t; rw [run_total_charges, run_total_charges]; omega

/-- Per-operand totals; the inode set carries over from one operand to the next. -/
def opTotals (w : Entry → Nat) (s : Seen) : List (List Entry) → List Nat
  | [] => []
  | o :: os => (run w ⟨s, 0⟩ o).total :: opTotals w (run w ⟨s, 0⟩ o).seen os

theorem opTotals_sum (w : Entry → Nat) (ops : List (List Entry)) :
    ∀ s, (opTotals w s ops).sum = (run w ⟨s, 0⟩ ops.flatten).total := by
  induction ops with
  | nil => intro s; rfl
  | cons o os ih =>
    intro s
    simp only [opTotals, List.sum_cons, List.flatten_cons]
    rw [ih]
    have hap : run w ⟨s, 0⟩ (o ++ os.flatten) = run w (run w ⟨s, 0⟩ o) os.flatten :=
      List.foldl_append
    rw [hap]
    generalize run w ⟨s, 0⟩ o = R
    obtain ⟨S, T⟩ := R
    rw [run_total_shift w _ S T]

/-- (e) `dush -c`: the `total` line is the sum of the operand lines, and equals one pass over
all operands' entries. With `Consistent` it does not depend on the operand order either
(`total_perm`), although the split between operand lines does. -/
theorem grand_total_eq (w : Entry → Nat) (ops : List (List Entry)) :
    (opTotals w Seen.empty ops).sum = total w ops.flatten := opTotals_sum w ops _

/-! ## Apple `du`'s `linkchk` -/

structure DuState where
  rem : Key → Nat
  total : Nat

def DuState.set (r : Key → Nat) (k : Key) (v : Nat) : Key → Nat :=
  fun k' => if k' = k then v else r k'

/-- One entry through `du`'s `linkchk` and `curblocks` accumulation. -/
def duStep (w : Entry → Nat) (st : DuState) (e : Entry) : DuState :=
  if 1 < e.nlink then
    if 0 < st.rem e.key then ⟨DuState.set st.rem e.key (st.rem e.key - 1), st.total⟩
    else ⟨DuState.set st.rem e.key (e.nlink - 1), st.total + w e⟩
  else ⟨st.rem, st.total + w e⟩

def duRun (w : Entry → Nat) (st : DuState) (es : List Entry) : DuState := es.foldl (duStep w) st

def duTotal (w : Entry → Nat) (es : List Entry) : Nat := (duRun w ⟨fun _ => 0, 0⟩ es).total

def duOpTotals (w : Entry → Nat) (r : Key → Nat) : List (List Entry) → List Nat
  | [] => []
  | o :: os => (duRun w ⟨r, 0⟩ o).total :: duOpTotals w (duRun w ⟨r, 0⟩ o).rem os

theorem duRun_total_shift (w : Entry → Nat) (es : List Entry) :
    ∀ r t, (duRun w ⟨r, t⟩ es).total = t + (duRun w ⟨r, 0⟩ es).total ∧
      (duRun w ⟨r, t⟩ es).rem = (duRun w ⟨r, 0⟩ es).rem := by
  induction es with
  | nil => intro r t; simp [duRun]
  | cons e es ih =>
    intro r t
    simp only [duRun, List.foldl_cons, duStep] at *
    split
    · split
      · have h1 := ih (DuState.set r e.key (r e.key - 1)) t
        have h2 := ih (DuState.set r e.key (r e.key - 1)) 0
        omega
      · have h1 := ih (DuState.set r e.key (e.nlink - 1)) (t + w e)
        have h2 := ih (DuState.set r e.key (e.nlink - 1)) (0 + w e)
        constructor
        · omega
        · rw [h1.2, h2.2]
    · have h1 := ih r (t + w e)
      have h2 := ih r (0 + w e)
      constructor
      · omega
      · rw [h1.2, h2.2]

theorem duOpTotals_sum (w : Entry → Nat) (ops : List (List Entry)) :
    ∀ r, (duOpTotals w r ops).sum = (duRun w ⟨r, 0⟩ ops.flatten).total := by
  induction ops with
  | nil => intro r; rfl
  | cons o os ih =>
    intro r
    simp only [duOpTotals, List.sum_cons, List.flatten_cons]
    rw [ih]
    have hap : duRun w ⟨r, 0⟩ (o ++ os.flatten) = duRun w (duRun w ⟨r, 0⟩ o) os.flatten :=
      List.foldl_append
    rw [hap]
    generalize duRun w ⟨r, 0⟩ o = R
    obtain ⟨S, T⟩ := R
    rw [(duRun_total_shift w _ S T).1]

/-- (e) `du -c`: `savednumber` is the sum of the operand totals, one pass over all operands. -/
theorem du_grand_total_eq (w : Entry → Nat) (ops : List (List Entry)) :
    (duOpTotals w (fun _ => 0) ops).sum = duTotal w ops.flatten := duOpTotals_sum w ops _

/-! ## When `du` and `dush` agree -/

def linkTo (k : Key) (e : Entry) : Bool := decide (1 < e.nlink) && decide (e.key = k)

/-- Within the walk, no inode with `nlink > 1` is met more often than its link count, and
such inodes have nonzero inode numbers. Both always hold for one `du` run over a file
system that is not changing, unless the same file is reached through several operands. -/
def LinkBounded (es : List Entry) : Prop :=
  ∀ e ∈ es, 1 < e.nlink → e.ino ≠ 0 ∧ es.countP (linkTo e.key) ≤ e.nlink

def Inv (s : Seen) (r : Key → Nat) (es : List Entry) : Prop :=
  ∀ k, (s k = false → r k = 0) ∧ (s k = true → es.countP (linkTo k) ≤ r k)

theorem du_eq_dush_aux (w : Entry → Nat) (es : List Entry) :
    ∀ s r t, LinkBounded es → Inv s r es →
      (duRun w ⟨r, t⟩ es).total = (run w ⟨s, t⟩ es).total := by
  induction es with
  | nil => intro s r t _ _; rfl
  | cons e es ih =>
    intro s r t hb hinv
    have hb' : LinkBounded es := by
      intro e' he' hn
      obtain ⟨h0, hc⟩ := hb e' (List.mem_cons_of_mem _ he') hn
      refine ⟨h0, Nat.le_trans ?_ hc⟩
      rw [List.countP_cons]; omega
    have hcl : ∀ k, es.countP (linkTo k) ≤ (e :: es).countP (linkTo k) := by
      intro k; rw [List.countP_cons]; omega
    simp only [duRun, run, List.foldl_cons, duStep, step] at *
    by_cases hn : 1 < e.nlink
    · obtain ⟨h0, hcnt⟩ := hb e List.mem_cons_self hn
      have htr : e.tracked = true := by simp [Entry.tracked, hn, h0]
      have hself : linkTo e.key e = true := by simp [linkTo, hn]
      rw [ite_eq_left hn]
      cases hs : s e.key
      · have hr0 : r e.key = 0 := (hinv e.key).1 hs
        rw [ite_eq_right (by omega)]
        have hch : charge w s e = w e := by simp [charge, htr, hs]
        rw [hch]
        apply ih _ _ _ hb'
        intro k
        by_cases hk : k = e.key
        · subst hk
          have hm : mark s e e.key = true := by simp [mark, htr, Seen.add]
          simp only [hm, DuState.set, ↓reduceIte]
          refine ⟨by simp, fun _ => ?_⟩
          have := List.countP_cons (p := linkTo e.key) (a := e) (l := es)
          rw [hself] at this; simp at this; omega
        · have hm : mark s e k = s k := by simp [mark, htr, Seen.add, hk]
          simp only [hm, DuState.set, ite_eq_right hk]
          exact ⟨(hinv k).1, fun h => Nat.le_trans (hcl k) ((hinv k).2 h)⟩
      · have hge := (hinv e.key).2 hs
        have hpos : 0 < (e :: es).countP (linkTo e.key) := by
          rw [List.countP_cons, hself]; simp
        rw [ite_eq_left (by omega)]
        have hch : charge w s e = 0 := by simp [charge, htr, hs]
        have hm : mark s e = s := by
          funext k; by_cases hk : k = e.key
          · subst hk; simp [mark, htr, Seen.add, hs]
          · simp [mark, htr, Seen.add, hk]
        rw [hch, hm, Nat.add_zero]
        apply ih _ _ _ hb'
        intro k
        by_cases hk : k = e.key
        · subst hk
          simp only [DuState.set, ↓reduceIte, hs]
          refine ⟨by simp, fun _ => ?_⟩
          have := List.countP_cons (p := linkTo e.key) (a := e) (l := es)
          rw [hself] at this; simp at this; omega
        · simp only [DuState.set, ite_eq_right hk]
          exact ⟨(hinv k).1, fun h => Nat.le_trans (hcl k) ((hinv k).2 h)⟩
    · rw [ite_eq_right hn]
      have htr : e.tracked = false := by simp [Entry.tracked, hn]
      have hch : charge w s e = w e := by simp [charge, htr]
      have hm : mark s e = s := by simp [mark, htr]
      rw [hch, hm]
      apply ih _ _ _ hb'
      intro k
      exact ⟨(hinv k).1, fun h => Nat.le_trans (hcl k) ((hinv k).2 h)⟩

/-- `du`'s expiring table and `dush`'s permanent set give the same total whenever no inode is
met more often than its link count. -/
theorem du_eq_dush (w : Entry → Nat) (es : List Entry) (hb : LinkBounded es) :
    duTotal w es = total w es :=
  du_eq_dush_aux w es _ _ 0 hb (fun k => ⟨fun _ => rfl, fun h => by simp [Seen.empty] at h⟩)

/-- With the unit weights, `dush`'s byte total is exactly 512 times `du`'s unit total. -/
theorem dush_bytes_eq_du_units (apparent : Bool) (es : List Entry) (hb : LinkBounded es) :
    total (Entry.bytes apparent) es = 512 * duTotal (fun e => duUnits apparent e.size e.blocks) es := by
  rw [du_eq_dush _ es hb, total_eq_counted, total_eq_counted]
  induction (counted es) with
  | nil => rfl
  | cons e es ih =>
    simp only [List.map_cons, List.sum_cons, Entry.bytes, entryBytes_eq_duUnits] at *
    rw [ih]; omega

/-- `du -c a a a` with `a` a 16-block file with 2 links: `du` prints `16 a`, `16 a`, and
`32 total` (the table entry expired after 2 sightings); `dush` charges the inode once. -/
theorem du_expiry_counterexample :
    let a : Entry := ⟨1, 42, 2, 16, 5000⟩
    let w := fun e : Entry => duUnits false e.size e.blocks
    duOpTotals w (fun _ => 0) [[a], [a], [a]] = [16, 0, 16] ∧
    opTotals w Seen.empty [[a], [a], [a]] = [16, 0, 0] := by
  decide

/-- `-c` rounds once: two 512-byte operands with `-k` print `1`, `1` and `1 total`. -/
theorem total_line_not_sum_of_lines :
    dushBlocks 1024 512 + dushBlocks 1024 512 = 2 ∧ dushBlocks 1024 (512 + 512) = 1 := by
  decide

end Dush.Acct
