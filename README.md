# Parimutuel Prediction Market Smart Contract

A decentralized binary prediction market implemented in Clarity v2 for the Stacks blockchain.

## Features

- Create binary (YES/NO) prediction markets with configurable fees
- Place bets using STX tokens
- Oracle-based outcome resolution
- Pro-rata profit distribution
- Automatic refunds for invalid markets
- Security features including reentrancy protection

## Contract Overview

```clarity
;; Key functions:
create-market    ;; Create a new prediction market
bet-yes         ;; Place a bet on YES outcome
bet-no          ;; Place a bet on NO outcome
resolve         ;; Oracle resolves the market outcome
claim           ;; Claim winnings or refunds
withdraw-fee    ;; Creator withdraws market fees
```

## Parameters

- Minimum bet: 1 STX
- Maximum fee: 10% (1000 basis points)
- Question format: 160-byte buffer
- Resolution: Binary (YES/NO)

## Usage

### Creating a Market

```clarity
(contract-call? .parimutuel-prediction create-market 
    question: 0x... 
    close-height: u123456 
    fee-bps: u100)
```

### Placing Bets

```clarity
(contract-call? .parimutuel-prediction bet-yes u1 u1000000) ;; 1 STX on YES
(contract-call? .parimutuel-prediction bet-no u1 u1000000)  ;; 1 STX on NO
```

## Security Features

- Minimum bet amounts to prevent dust attacks
- Reentrancy protection on claims
- Oracle-controlled resolution
- Time-locked betting periods
- Safe math operations


### Testing

```bash
clarinet test
```

