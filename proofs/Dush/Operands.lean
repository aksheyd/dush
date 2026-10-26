import Dush.Accounting

namespace Dush.Acct

theorem run_seen_indep (w : Entry → Nat) (es : List Entry) :
    ∀ s t t', (run w ⟨s, t⟩ es).seen = (run w ⟨s, t'⟩ es).seen := by
  induction es with
  | nil => intro s t t'; rfl
  | cons e es ih => intro s t t'; simp only [run_cons, step]; exact ih _ _ _

theorem run_total_shift (w : Entry → Nat) (es : List Entry) :
    ∀ s t, (run w ⟨s, t⟩ es).total = t + (run w ⟨s, 0⟩ es).total := by
  intro s t; rw [run_total_charges, run_total_charges]; omega

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

theorem grand_total_eq (w : Entry → Nat) (ops : List (List Entry)) :
    (opTotals w Seen.empty ops).sum = total w ops.flatten := opTotals_sum w ops _

def linkStep (live : Bool) (links nlink : Int) : Bool × Int × Bool :=
  if live then (true, links - 1, decide (0 < links - 1)) else (false, nlink - 1, true)

structure DuState where
  rem : Key → Nat
  total : Nat

def DuState.set (r : Key → Nat) (k : Key) (v : Nat) : Key → Nat :=
  fun k' => if k' = k then v else r k'

def duStep (w : Entry → Nat) (st : DuState) (e : Entry) : DuState :=
  if e.tracked then
    if 0 < st.rem e.key then ⟨DuState.set st.rem e.key (st.rem e.key - 1), st.total⟩
    else ⟨DuState.set st.rem e.key (e.nlink - 1), st.total + w e⟩
  else ⟨st.rem, st.total + w e⟩

theorem linkStep_eq_duStep (r nlink : Nat) (hn : 1 < nlink) :
    linkStep (decide (0 < r)) r nlink =
      (decide (0 < r), ((if 0 < r then r - 1 else nlink - 1 : Nat) : Int),
        decide (0 < (if 0 < r then r - 1 else nlink - 1 : Nat))) := by
  by_cases h : 0 < r <;> simp [linkStep, h] <;> omega

def duRun (w : Entry → Nat) (st : DuState) (es : List Entry) : DuState := es.foldl (duStep w) st

def duTotal (w : Entry → Nat) (es : List Entry) : Nat := (duRun w ⟨fun _ => 0, 0⟩ es).total

theorem duStep_congr (w : Entry → Nat) (st : DuState) {x y : Entry} (hk : x.key = y.key)
    (hn : x.nlink = y.nlink) (hw : w x = w y) : duStep w st x = duStep w st y := by
  simp only [duStep, tracked_of_key hk hn, hk, hn, hw]

theorem set_comm (r : Key → Nat) {a b : Key} (h : a ≠ b) (u v : Nat) :
    DuState.set (DuState.set r a u) b v = DuState.set (DuState.set r b v) a u := by
  funext k
  simp only [DuState.set]
  by_cases ha : k = a <;> by_cases hb : k = b <;> simp [ha, hb, h, Ne.symm h]

theorem set_other (r : Key → Nat) {a b : Key} (h : b ≠ a) (v : Nat) :
    DuState.set r a v b = r b := by
  simp [DuState.set, h]

theorem duStep_comm (w : Entry → Nat) (z : DuState) (x y : Entry)
    (hc : x.key = y.key → x.nlink = y.nlink ∧ w x = w y) :
    duStep w (duStep w z x) y = duStep w (duStep w z y) x := by
  by_cases hk : x.key = y.key
  · obtain ⟨hn, hw⟩ := hc hk
    rw [duStep_congr w z hk hn hw, duStep_congr w _ hk hn hw]
  · obtain ⟨r, t⟩ := z
    have hk' : y.key ≠ x.key := fun h => hk h.symm
    by_cases hx : x.tracked <;> by_cases hy : y.tracked <;>
      simp only [duStep, hx, hy, ↓reduceIte, Bool.false_eq_true]
    · by_cases px : 0 < r x.key <;> by_cases py : 0 < r y.key <;>
        simp only [px, py, set_other _ hk, set_other _ hk', ↓reduceIte, DuState.mk.injEq,
          set_comm r hk, true_and] <;> omega
    · by_cases px : 0 < r x.key <;> simp only [px, ↓reduceIte, DuState.mk.injEq, true_and] <;>
        omega
    · by_cases py : 0 < r y.key <;> simp only [py, ↓reduceIte, DuState.mk.injEq, true_and] <;>
        omega
    · simp only [DuState.mk.injEq, true_and]; omega

theorem duTotal_perm (w : Entry → Nat) {l₁ l₂ : List Entry} (hp : l₁.Perm l₂)
    (hc : Consistent w l₁) : duTotal w l₁ = duTotal w l₂ := by
  unfold duTotal duRun
  rw [List.Perm.foldl_eq' hp (fun x hx y hy z => duStep_comm w z x y (hc x hx y hy))]

def duChargesAux (w : Entry → Nat) : (Key → Nat) → List Entry → List Nat
  | _, [] => []
  | r, e :: es => (duStep w ⟨r, 0⟩ e).total :: duChargesAux w (duStep w ⟨r, 0⟩ e).rem es

theorem duStep_total (w : Entry → Nat) (r : Key → Nat) (t : Nat) (e : Entry) :
    duStep w ⟨r, t⟩ e = ⟨(duStep w ⟨r, 0⟩ e).rem, t + (duStep w ⟨r, 0⟩ e).total⟩ := by
  simp only [duStep]
  split
  · split <;> simp
  · simp

theorem duRun_total_charges (w : Entry → Nat) (es : List Entry) :
    ∀ r t, (duRun w ⟨r, t⟩ es).total = t + (duChargesAux w r es).sum := by
  induction es with
  | nil => intro r t; simp [duRun, duChargesAux]
  | cons e es ih =>
    intro r t
    simp only [duRun, List.foldl_cons, duChargesAux, List.sum_cons] at *
    rw [duStep_total, ih]; omega

theorem length_duChargesAux (w : Entry → Nat) (r : Key → Nat) (es : List Entry) :
    (duChargesAux w r es).length = es.length := by
  induction es generalizing r with
  | nil => rfl
  | cons e es ih => simp [duChargesAux, ih]

def duTagCharges (w : Entry → Nat) (trace : List (Nat × Entry)) : List (Nat × Nat) :=
  (trace.map Prod.fst).zip (duChargesAux w (fun _ => 0) (trace.map Prod.snd))

theorem du_workers_sum (w : Entry → Nat) (n : Nat) (trace : List (Nat × Entry))
    (htag : ∀ p ∈ trace, p.1 < n) :
    rsum n (partialSum (duTagCharges w trace)) = duTotal w (trace.map Prod.snd) := by
  rw [rsum_partial]
  · unfold duTagCharges duTotal
    rw [duRun_total_charges, List.map_snd_zip]
    · omega
    · simp [length_duChargesAux]
  · intro p hp
    unfold duTagCharges at hp
    have := List.of_mem_zip hp
    obtain ⟨q, hq, hqe⟩ := List.mem_map.mp this.1
    rw [← hqe]; exact htag q hq

theorem du_parallel_eq_sequential (w : Entry → Nat) (n : Nat) (trace : List (Nat × Entry))
    (traversal : List Entry) (htag : ∀ p ∈ trace, p.1 < n)
    (hperm : (trace.map Prod.snd).Perm traversal) (hc : Consistent w traversal) :
    rsum n (partialSum (duTagCharges w trace)) = duTotal w traversal := by
  rw [du_workers_sum w n trace htag]
  exact duTotal_perm w hperm (fun e he e' he' => hc e (hperm.subset he) e' (hperm.subset he'))

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

theorem du_grand_total_eq (w : Entry → Nat) (ops : List (List Entry)) :
    (duOpTotals w (fun _ => 0) ops).sum = duTotal w ops.flatten := duOpTotals_sum w ops _

def LinkBounded (es : List Entry) : Prop :=
  ∀ e ∈ es, e.tracked → es.countP (isInode e.key) ≤ e.nlink

def Inv (s : Seen) (r : Key → Nat) (es : List Entry) : Prop :=
  ∀ k, (s k = false → r k = 0) ∧ (s k = true → es.countP (isInode k) ≤ r k)

theorem du_eq_dush_aux (w : Entry → Nat) (es : List Entry) :
    ∀ s r t, LinkBounded es → Inv s r es →
      (duRun w ⟨r, t⟩ es).total = (run w ⟨s, t⟩ es).total := by
  induction es with
  | nil => intro s r t _ _; rfl
  | cons e es ih =>
    intro s r t hb hinv
    have hb' : LinkBounded es := by
      intro e' he' hn
      refine Nat.le_trans ?_ (hb e' (List.mem_cons_of_mem _ he') hn)
      rw [List.countP_cons]; omega
    have hcl : ∀ k, es.countP (isInode k) ≤ (e :: es).countP (isInode k) := by
      intro k; rw [List.countP_cons]; omega
    simp only [duRun, run, List.foldl_cons, duStep, step] at *
    by_cases htr : e.tracked = true
    · have hcnt := hb e List.mem_cons_self htr
      have hself : isInode e.key e = true := by simp [isInode, htr]
      rw [ite_eq_left htr]
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
          have := List.countP_cons (p := isInode e.key) (a := e) (l := es)
          rw [hself] at this; simp at this; omega
        · have hm : mark s e k = s k := by simp [mark, htr, Seen.add, hk]
          simp only [hm, DuState.set, ite_eq_right hk]
          exact ⟨(hinv k).1, fun h => Nat.le_trans (hcl k) ((hinv k).2 h)⟩
      · have hge := (hinv e.key).2 hs
        have hpos : 0 < (e :: es).countP (isInode e.key) := by
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
          have := List.countP_cons (p := isInode e.key) (a := e) (l := es)
          rw [hself] at this; simp at this; omega
        · simp only [DuState.set, ite_eq_right hk]
          exact ⟨(hinv k).1, fun h => Nat.le_trans (hcl k) ((hinv k).2 h)⟩
    · have htr' : e.tracked = false := by simpa using htr
      rw [ite_eq_right htr]
      have hch : charge w s e = w e := by simp [charge, htr']
      have hm : mark s e = s := by simp [mark, htr']
      rw [hch, hm]
      apply ih _ _ _ hb'
      intro k
      exact ⟨(hinv k).1, fun h => Nat.le_trans (hcl k) ((hinv k).2 h)⟩

theorem du_eq_dush (w : Entry → Nat) (es : List Entry) (hb : LinkBounded es) :
    duTotal w es = total w es :=
  du_eq_dush_aux w es _ _ 0 hb (fun k => ⟨fun _ => rfl, fun h => by simp [Seen.empty] at h⟩)

theorem sum_indicator (k : Key) (l : List Entry) :
    (l.map (fun e => if isInode k e then 1 else 0)).sum = l.countP (isInode k) := by
  induction l with
  | nil => rfl
  | cons e l ih =>
    simp only [List.map_cons, List.sum_cons, List.countP_cons, ih]
    cases isInode k e <;> simp <;> omega

theorem du_counted_once (k : Key) (es : List Entry) (hb : LinkBounded es)
    (h : es.any (isInode k)) :
    duTotal (fun e => if isInode k e then 1 else 0) es = 1 := by
  rw [du_eq_dush _ es hb, total_eq_counted, sum_indicator, counted_once k es h]

theorem duStep_scale (w : Entry → Nat) (c : Nat) (r : Key → Nat) (e : Entry) :
    duStep (fun e => c * w e) ⟨r, 0⟩ e =
      ⟨(duStep w ⟨r, 0⟩ e).rem, c * (duStep w ⟨r, 0⟩ e).total⟩ := by
  simp only [duStep]
  split
  · split <;> simp
  · simp

theorem duChargesAux_scale (w : Entry → Nat) (c : Nat) (r : Key → Nat) (es : List Entry) :
    (duChargesAux (fun e => c * w e) r es).sum = c * (duChargesAux w r es).sum := by
  induction es generalizing r with
  | nil => simp [duChargesAux]
  | cons e es ih =>
    simp only [duChargesAux, List.sum_cons, duStep_scale, ih, Nat.mul_add]

theorem dush_bytes_eq_du_units (apparent : Bool) (es : List Entry) :
    duTotal (Entry.bytes apparent) es =
      512 * duTotal (fun e => duUnits apparent e.size e.blocks) es := by
  have hw : Entry.bytes apparent = fun e => 512 * duUnits apparent e.size e.blocks := by
    funext e; simp [Entry.bytes, entryBytes_eq_duUnits]
  unfold duTotal
  rw [duRun_total_charges, duRun_total_charges, hw, duChargesAux_scale]
  omega

theorem du_expiry_counterexample :
    let a : Entry := ⟨1, 42, 2, 16, 5000⟩
    let w := fun e : Entry => duUnits false e.size e.blocks
    duOpTotals w (fun _ => 0) [[a], [a], [a]] = [16, 0, 16] ∧
    opTotals w Seen.empty [[a], [a], [a]] = [16, 0, 0] := by
  decide

theorem total_line_not_sum_of_lines :
    dushBlocks 1024 512 + dushBlocks 1024 512 = 2 ∧ dushBlocks 1024 (512 + 512) = 1 := by
  decide

end Dush.Acct
