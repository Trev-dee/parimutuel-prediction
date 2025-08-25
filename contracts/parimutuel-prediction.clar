;; ------------------------------------------------------------
;; Parimutuel Prediction Market (Binary YES/NO) - Clarity v2
;; ------------------------------------------------------------
;; - Anyone can create a market (creator receives fees).
;; - Bets in STX until the close block.
;; - Oracle resolves outcome (YES=true / NO=false).
;; - Winners share the losing pool pro-rata (after fee).
;; - If no winners exist, all bettors get refunds (invalid).
;; ------------------------------------------------------------

(define-constant ERR-UNAUTHORIZED (err u401))
(define-constant ERR-BAD-ARGS     (err u400))
(define-constant ERR-NOT-FOUND    (err u404))
(define-constant ERR-TOO-EARLY    (err u425))
(define-constant ERR-TOO-LATE     (err u426))
(define-constant ERR-ALREADY      (err u409))
(define-constant ERR-NOTHING      (err u204))
(define-constant MAX-FEE-BPS u1000) ;; creator fee cap: 10%
(define-constant MIN-BET u1000000) ;; minimum bet amount: 1 STX

(define-data-var global-oracle principal tx-sender)
(define-data-var next-market-id uint u1)

;; Market storage
(define-map markets
  { id: uint }
  {
    creator: principal,
    fee-bps: uint,                ;; fee on total pool (to creator)
    question: (buff 160),
    close-height: uint,           ;; last block to place bets
    resolved: bool,
    outcome: bool,                ;; true=YES wins, false=NO wins
    total-yes: uint,
    total-no: uint,
    fee-paid: bool                ;; prevents double fee-withdraw
  })

;; Per-user positions and claim status (one row per market per user)
(define-map positions
  { id: uint, user: principal }
  {
    yes: uint,      ;; total STX staked on YES
    no: uint,       ;; total STX staked on NO
    claimed: bool   ;; set after claim to prevent double-claim
  })

;; ----------------- helpers -----------------

(define-read-only (now)
  burn-block-height)

(define-read-only (mul-div (x uint) (num uint) (den uint))
  (if (is-eq den u0) u0 (/ (* x num) den)))

(define-read-only (get-market (id uint))
  (ok (unwrap! (map-get? markets { id: id }) ERR-NOT-FOUND)))

(define-read-only (get-position (id uint) (who principal))
  (default-to { yes: u0, no: u0, claimed: false }
    (map-get? positions { id: id, user: who })))

;; ----------------- admin/oracle -----------------

(define-public (set-oracle (who principal))
  (begin
    (asserts! (is-eq tx-sender (var-get global-oracle)) ERR-UNAUTHORIZED)
    (ok (var-set global-oracle who))
    ))

;; ----------------- create market -----------------

(define-public (create-market (question (buff 160)) (close-height uint) (fee-bps uint))
  (let ((id (var-get next-market-id)))
    (begin
      (asserts! (> close-height (now)) ERR-BAD-ARGS)
      (asserts! (<= fee-bps MAX-FEE-BPS) ERR-BAD-ARGS)

      (map-set markets { id: id }
        {
          creator: tx-sender,
          fee-bps: fee-bps,
          question: question,
          close-height: close-height,
          resolved: false,
          outcome: true,           ;; placeholder; valid only when resolved=true
          total-yes: u0,
          total-no: u0,
          fee-paid: false
        })
      (var-set next-market-id (+ id u1))
      (ok id)
    )))

;; ----------------- betting -----------------

(define-public (bet-yes (id uint) (amount uint))
  (place-bet id amount true))

(define-public (bet-no (id uint) (amount uint))
  (place-bet id amount false))

(define-private (place-bet (id uint) (amount uint) (is-yes bool))
  (let ((m? (map-get? markets { id: id })))
    (match m? m
      (begin
        (asserts! (not (get resolved m)) ERR-ALREADY)
        (asserts! (>= amount MIN-BET) ERR-BAD-ARGS)
        (asserts! (<= (now) (get close-height m)) ERR-TOO-LATE)

        (asserts! (is-ok (stx-transfer? amount tx-sender (as-contract tx-sender))) ERR-BAD-ARGS)

        (let ((pos (get-position id tx-sender)))
          (if is-yes
            (begin
              (map-set positions { id: id, user: tx-sender }
                { yes: (+ (get yes pos) amount), no: (get no pos), claimed: false })
              (map-set markets { id: id } (merge m { total-yes: (+ (get total-yes m) amount) }))
            )
            (begin
              (map-set positions { id: id, user: tx-sender }
                { yes: (get yes pos), no: (+ (get no pos) amount), claimed: false })
              (map-set markets { id: id } (merge m { total-no: (+ (get total-no m) amount) }))
            ))
          (ok true)
        ))
      ERR-NOT-FOUND)))

;; ----------------- resolve -----------------

(define-public (resolve (id uint) (outcome-yes bool))
  (let ((m? (map-get? markets { id: id })))
    (match m? m
      (begin
        (asserts! (not (get resolved m)) ERR-ALREADY)
        (asserts! (> (now) (get close-height m)) ERR-TOO-EARLY)
        (asserts! (is-eq tx-sender (var-get global-oracle)) ERR-UNAUTHORIZED)

        (map-set markets { id: id } (merge m { resolved: true, outcome: outcome-yes }))
        (print { type: "market-resolved", id: id, outcome: outcome-yes })
        (ok { id: id, outcome-yes: outcome-yes })
      )
      ERR-NOT-FOUND)))

;; ----------------- claiming -----------------

;; Claim winnings or refunds after resolution.
(define-public (claim (id uint))
  (let ((m? (map-get? markets { id: id }))
        (pos (get-position id tx-sender)))
    (match m? m
      (begin
        (asserts! (get resolved m) ERR-TOO-EARLY)
        (asserts! (not (get claimed pos)) ERR-ALREADY)

        (let (
              (ty (get total-yes m))
              (tn (get total-no m))
              (pool (+ ty tn))
              (fee (mul-div pool (get fee-bps m) u10000))
              (dist (- pool fee))                 ;; distributable to winners
              (is-yes (get outcome m))
              (winners-total (if is-yes ty tn))
              (user-win (if is-yes (get yes pos) (get no pos)))
              (user-lose (if is-yes (get no pos) (get yes pos)))
             )
          (let (
                ;; invalid case: no winners -> refund both sides
                (payout (if (is-eq winners-total u0)
                            (+ (get yes pos) (get no pos))
                            (+ user-win (mul-div user-win (if is-yes tn ty) winners-total))))
               )
            (asserts! (> payout u0) ERR-NOTHING)

            ;; mark claimed first (reentrancy guard)
            (map-set positions { id: id, user: tx-sender }
              { yes: (get yes pos), no: (get no pos), claimed: true })

            ;; transfer payout
            (asserts! (is-ok (stx-transfer? payout (as-contract tx-sender) tx-sender)) ERR-BAD-ARGS)
            (ok { claimed: payout })
          )))
      ERR-NOT-FOUND)))

;; Creator withdraws the market fee (once) after resolution.
(define-public (withdraw-fee (id uint))
  (let ((m? (map-get? markets { id: id })))
    (match m? m
      (begin
        (asserts! (get resolved m) ERR-TOO-EARLY)
        (asserts! (is-eq (get creator m) tx-sender) ERR-UNAUTHORIZED)
        (asserts! (not (get fee-paid m)) ERR-ALREADY)

        (let ((pool (+ (get total-yes m) (get total-no m)))
              (fee (mul-div (+ (get total-yes m) (get total-no m)) (get fee-bps m) u10000))
              (ty (get total-yes m))
              (tn (get total-no m))
              (winners-total (if (get outcome m) ty tn)))
          ;; if invalid (no winners), fee is zero (refunds only)
          (let ((effective-fee (if (is-eq winners-total u0) u0 fee)))
            (asserts! (> effective-fee u0) ERR-NOTHING)
            (map-set markets { id: id } (merge m { fee-paid: true }))
            (asserts! (is-ok (stx-transfer? effective-fee (as-contract tx-sender) tx-sender)) ERR-BAD-ARGS)
            (ok { fee: effective-fee })
          )))
      ERR-NOT-FOUND)))

;; ----------------- views -----------------

(define-read-only (market-stats (id uint))
  (ok (unwrap! (map-get? markets { id: id })
    ERR-NOT-FOUND)))

(define-read-only (user-position (id uint) (who principal))
  (get-position id who))