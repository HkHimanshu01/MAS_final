# Bug: TypeError when applying discount code

## Steps to reproduce
1. Add items to cart
2. Apply code "SAVE10"

## Expected
Discount applied correctly.

## Actual
"TypeError: Cannot read properties of undefined (reading 'discount_value')"

## File
src/cart/pricing.py
