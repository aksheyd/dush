import Dush.Units

namespace Dush.Acct

open Dush

structure Entry where
  dev : Nat
  ino : Nat
  nlink : Nat
  blocks : Nat
  size : Nat
deriving DecidableEq, Repr

abbrev Key := Nat × Nat

def Entry.key (e : Entry) : Key := (e.dev, e.ino)

def Entry.tracked (e : Entry) : Bool := decide (1 < e.nlink) && decide (e.ino ≠ 0)

def Entry.bytes (apparent : Bool) (e : Entry) : Nat := entryBytes apparent e.size e.blocks

abbrev Seen := Key → Bool

def Seen.empty : Seen := fun _ => false

def Seen.add (s : Seen) (k k' : Key) : Bool := decide (k' = k) || s k'

structure State where
  seen : Seen
  total : Nat

def charge (w : Entry → Nat) (s : Seen) (e : Entry) : Nat :=
  if e.tracked && s e.key then 0 else w e

def mark (s : Seen) (e : Entry) : Seen := if e.tracked then s.add e.key else s

def step (w : Entry → Nat) (st : State) (e : Entry) : State :=
  ⟨mark st.seen e, st.total + charge w st.seen e⟩

def run (w : Entry → Nat) (st : State) (es : List Entry) : State := es.foldl (step w) st

def total (w : Entry → Nat) (es : List Entry) : Nat := (run w ⟨Seen.empty, 0⟩ es).total

def Consistent (w : Entry → Nat) (es : List Entry) : Prop :=
  ∀ e ∈ es, ∀ e' ∈ es, e.key = e'.key → e.nlink = e'.nlink ∧ w e = w e'

theorem tracked_of_key {x y : Entry} (hk : x.key = y.key) (hn : x.nlink = y.nlink) :
    x.tracked = y.tracked := by
  simp only [Entry.key, Prod.mk.injEq] at hk
  simp [Entry.tracked, hk.2, hn]

theorem run_cons (w : Entry → Nat) (st : State) (e : Entry) (es : List Entry) :
    run w st (e :: es) = run w (step w st e) es := rfl

theorem step_comm (w : Entry → Nat) (z : State) (x y : Entry)
    (hc : x.key = y.key → x.nlink = y.nlink ∧ w x = w y) :
    step w (step w z x) y = step w (step w z y) x := by
  obtain ⟨s, t⟩ := z
  simp only [step, State.mk.injEq]
  constructor
  · funext k
    simp only [mark]
    by_cases hx : x.tracked <;> by_cases hy : y.tracked <;> simp [hx, hy, Seen.add, Bool.or_left_comm]
  · by_cases hk : x.key = y.key
    · obtain ⟨hn, hw⟩ := hc hk
      have ht := tracked_of_key hk hn
      simp only [charge, mark, hk, ht, hw]
    · have hk' : y.key ≠ x.key := fun h => hk h.symm
      simp only [charge, mark]
      by_cases hx : x.tracked <;> by_cases hy : y.tracked <;> simp [hx, hy, Seen.add, hk, hk']
      all_goals omega

theorem total_perm (w : Entry → Nat) {l₁ l₂ : List Entry} (hp : l₁.Perm l₂)
    (hc : Consistent w l₁) : total w l₁ = total w l₂ := by
  unfold total run
  rw [List.Perm.foldl_eq' hp (fun x hx y hy z => step_comm w z x y (hc x hx y hy))]

theorem order_matters_without_consistency :
    let a : Entry := ⟨1, 7, 2, 8, 0⟩
    let b : Entry := ⟨1, 7, 2, 16, 0⟩
    total (Entry.bytes false) [a, b] ≠ total (Entry.bytes false) [b, a] := by
  decide

def countedAux (s : Seen) : List Entry → List Entry
  | [] => []
  | e :: es => if e.tracked && s e.key then countedAux s es else e :: countedAux (mark s e) es

def counted (es : List Entry) : List Entry := countedAux Seen.empty es

theorem run_total_aux (w : Entry → Nat) (es : List Entry) :
    ∀ s t, (run w ⟨s, t⟩ es).total = t + ((countedAux s es).map w).sum := by
  induction es with
  | nil => intro s t; simp [run, countedAux]
  | cons e es ih =>
    intro s t
    rw [run_cons]
    simp only [step, countedAux, charge]
    cases h : (e.tracked && s e.key)
    · simp only [ite_false, Bool.false_eq_true, List.map_cons, List.sum_cons]
      rw [ih]; omega
    · simp only [ite_true]
      have : mark s e = s := by
        funext k
        simp only [Bool.and_eq_true] at h
        simp only [mark, h.1, ite_true]
        by_cases hk : k = e.key
        · subst hk; simp [Seen.add, h.2]
        · simp [Seen.add, hk]
      rw [this, ih]; omega

theorem total_eq_counted (w : Entry → Nat) (es : List Entry) :
    total w es = ((counted es).map w).sum := by
  unfold total counted; rw [run_total_aux]; omega

theorem countedAux_sublist (s : Seen) (es : List Entry) : (countedAux s es).Sublist es := by
  induction es generalizing s with
  | nil => exact List.Sublist.slnil
  | cons e es ih =>
    unfold countedAux
    split
    · exact List.Sublist.cons e (ih s)
    · exact List.Sublist.cons_cons e (ih _)

theorem counted_sublist (es : List Entry) : (counted es).Sublist es := countedAux_sublist _ es

theorem countedAux_untracked (s : Seen) (es : List Entry) :
    (countedAux s es).filter (fun e => !e.tracked) = es.filter (fun e => !e.tracked) := by
  induction es generalizing s with
  | nil => rfl
  | cons e es ih =>
    unfold countedAux
    cases ht : e.tracked
    · simp [ht, mark, ih]
    · cases hs : s e.key
      · simp [ht, ih]
      · simp [ht, ih]

theorem counted_untracked (es : List Entry) :
    (counted es).filter (fun e => !e.tracked) = es.filter (fun e => !e.tracked) :=
  countedAux_untracked _ es

def isInode (k : Key) (e : Entry) : Bool := e.tracked && decide (e.key = k)

theorem countedAux_once (s : Seen) (k : Key) (es : List Entry) :
    (countedAux s es).countP (isInode k) =
      if s k then 0 else if es.any (isInode k) then 1 else 0 := by
  induction es generalizing s with
  | nil => simp [countedAux]
  | cons e es ih =>
    unfold countedAux
    by_cases hskip : (e.tracked && s e.key) = true
    · rw [ite_eq_left hskip, ih]
      simp only [Bool.and_eq_true] at hskip
      by_cases hk : e.key = k
      · subst hk; simp [hskip.2]
      · have : isInode k e = false := by simp [isInode, hk]
        simp [this]
    · rw [ite_eq_right hskip, List.countP_cons, ih]
      by_cases hm : isInode k e = true
      · have ht : e.tracked = true := by simp [isInode] at hm; exact hm.1
        have hk : e.key = k := by simp [isInode] at hm; exact hm.2
        have hsk : s k = false := by
          subst hk; simp [ht] at hskip; exact hskip
        have hmk : mark s e k = true := by simp [mark, ht, Seen.add, hk]
        simp [hm, hsk, hmk]
      · have hmk : mark s e k = s k := by
          simp only [mark]
          split
          · simp only [isInode, Bool.and_eq_true, decide_eq_true_eq, not_and] at hm
            rename_i ht
            have : k ≠ e.key := fun h => hm ht h.symm
            simp [Seen.add, this]
          · rfl
        have hf : isInode k e = false := by simpa using hm
        simp [hmk, hf]

theorem counted_once (k : Key) (es : List Entry) (h : es.any (isInode k)) :
    (counted es).countP (isInode k) = 1 := by
  unfold counted; rw [countedAux_once]; simp [Seen.empty, h]

def chargesAux (w : Entry → Nat) (s : Seen) : List Entry → List Nat
  | [] => []
  | e :: es => charge w s e :: chargesAux w (mark s e) es

theorem run_total_charges (w : Entry → Nat) (es : List Entry) :
    ∀ s t, (run w ⟨s, t⟩ es).total = t + (chargesAux w s es).sum := by
  induction es with
  | nil => intro s t; simp [run, chargesAux]
  | cons e es ih =>
    intro s t; rw [run_cons]; simp only [step, chargesAux, List.sum_cons]; rw [ih]; omega

def rsum : Nat → (Nat → Nat) → Nat
  | 0, _ => 0
  | n + 1, f => rsum n f + f n

theorem rsum_add (n : Nat) (f g : Nat → Nat) :
    rsum n (fun i => f i + g i) = rsum n f + rsum n g := by
  induction n with
  | zero => rfl
  | succ n ih => simp only [rsum, ih]; omega

theorem rsum_indicator (n t c : Nat) (h : t < n) :
    rsum n (fun i => if t = i then c else 0) = c := by
  induction n with
  | zero => omega
  | succ n ih =>
    simp only [rsum]
    by_cases ht : t = n
    · subst ht
      have : rsum t (fun i => if t = i then c else 0) = 0 := by
        clear ih h
        have : ∀ m, m ≤ t → rsum m (fun i => if t = i then c else 0) = 0 := by
          intro m; induction m with
          | zero => intro; rfl
          | succ m ihm => intro hm; simp only [rsum]; rw [ihm (by omega)]; simp; omega
        exact this t (Nat.le_refl t)
      simp [this]
    · rw [ih (by omega)]; simp [ht]

def partialSum (tagged : List (Nat × Nat)) (i : Nat) : Nat :=
  ((tagged.filter (fun p => p.1 = i)).map Prod.snd).sum

theorem rsum_partial (n : Nat) (tagged : List (Nat × Nat)) (h : ∀ p ∈ tagged, p.1 < n) :
    rsum n (partialSum tagged) = (tagged.map Prod.snd).sum := by
  induction tagged with
  | nil =>
    simp only [List.map_nil, List.sum_nil]
    clear h; induction n with
    | zero => rfl
    | succ n ih => simp [rsum, ih, partialSum]
  | cons p ps ih =>
    obtain ⟨t, c⟩ := p
    have hps : ∀ q ∈ ps, q.1 < n := fun q hq => h q (List.mem_cons_of_mem _ hq)
    have hsplit : partialSum ((t, c) :: ps) =
        fun i => (if t = i then c else 0) + partialSum ps i := by
      funext i; unfold partialSum
      by_cases hi : t = i
      · simp [hi]
      · simp [hi]
    rw [hsplit, rsum_add, rsum_indicator n t c (h _ List.mem_cons_self), ih hps]
    simp

def tagCharges (w : Entry → Nat) (trace : List (Nat × Entry)) : List (Nat × Nat) :=
  (trace.map Prod.fst).zip (chargesAux w Seen.empty (trace.map Prod.snd))

theorem length_chargesAux (w : Entry → Nat) (s : Seen) (es : List Entry) :
    (chargesAux w s es).length = es.length := by
  induction es generalizing s with
  | nil => rfl
  | cons e es ih => simp [chargesAux, ih]

theorem workers_sum (w : Entry → Nat) (n : Nat) (trace : List (Nat × Entry))
    (htag : ∀ p ∈ trace, p.1 < n) :
    rsum n (partialSum (tagCharges w trace)) = total w (trace.map Prod.snd) := by
  rw [rsum_partial]
  · unfold tagCharges total
    rw [run_total_charges, List.map_snd_zip]
    · omega
    · simp [length_chargesAux]
  · intro p hp
    unfold tagCharges at hp
    have := List.of_mem_zip hp
    obtain ⟨q, hq, hqe⟩ := List.mem_map.mp this.1
    rw [← hqe]; exact htag q hq

theorem parallel_eq_sequential (w : Entry → Nat) (n : Nat) (trace : List (Nat × Entry))
    (traversal : List Entry) (htag : ∀ p ∈ trace, p.1 < n)
    (hperm : (trace.map Prod.snd).Perm traversal) (hc : Consistent w traversal) :
    rsum n (partialSum (tagCharges w trace)) = total w traversal := by
  rw [workers_sum w n trace htag]
  exact total_perm w hperm (fun e he e' he' => hc e (hperm.subset he) e' (hperm.subset he'))

end Dush.Acct
