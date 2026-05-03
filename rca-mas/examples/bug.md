# Bug: Cart total shows wrong amount when discount code is applied

## Steps to reproduce
1. Add 3 items to the cart
2. Apply discount code "SAVE10"
3. Proceed to checkout

## Expected behaviour
Cart total reflects 10% discount applied to subtotal.

## Actual behaviour
Cart total shows original price with no discount applied.
Console shows: "TypeError: Cannot read properties of undefined (reading 'discount_value')"

## Environment
- Version: 2.3.1
- File: src/cart/pricing.py
- Introduced after recent merge to main

## Additional context
The discount feature was recently refactored. The error appears in `src/cart/pricing.py` around the `apply_discount` function.
