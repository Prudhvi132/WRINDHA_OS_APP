-- =============================================================================
-- WRINDHAOS MIGRATION: Payment Verification Hardening
-- Date: 2026-11-17
-- Purpose:
--   1. Add purchase tracking columns to subscriptions table
--   2. Clean up corrupted rows created by the old unverified upgrade endpoint
--      (users marked PRO without any Google Play purchase verification)
-- =============================================================================

-- 1. New columns for verified purchase tracking
ALTER TABLE public.subscriptions ADD COLUMN IF NOT EXISTS purchase_token TEXT;
ALTER TABLE public.subscriptions ADD COLUMN IF NOT EXISTS product_id VARCHAR(100);
ALTER TABLE public.subscriptions ADD COLUMN IF NOT EXISTS order_id VARCHAR(150);
ALTER TABLE public.subscriptions ADD COLUMN IF NOT EXISTS auto_renewing BOOLEAN DEFAULT TRUE;

-- 2. Hard-expire suspicious legacy upgrades.
--    Legacy rows were created by the blind upgrade endpoint with:
--      payment_provider = 'GOOGLE_PLAY' | 'LOCAL_SYNC' | 'NONE'
--      and NO purchase_token / order_id.
--    Real Google Play subscriptions ALWAYS have an order id and token
--    once this migration's verification flow has recorded them.
--    => Rows without a purchase token and older than this migration
--       cannot be trusted and are downgraded to expired/free.
UPDATE public.subscriptions
SET status = 'expired',
    plan = 'free',
    updated_at = NOW()
WHERE purchase_token IS NULL
  AND status = 'active';

-- 3. Reset profile flags for users whose ONLY subscription evidence was an
--    unverified legacy row (keeps genuinely verified users untouched).
UPDATE public.profiles p
SET is_premium = FALSE,
    subscription_plan = 'FREE',
    updated_at = NOW()
WHERE (p.is_premium = TRUE OR p.subscription_plan = 'PRO')
  AND NOT EXISTS (
    SELECT 1
    FROM public.subscriptions s
    WHERE s.user_id = p.id
      AND s.purchase_token IS NOT NULL
      AND s.plan IN ('pro', 'premium')
      AND s.status IN ('active', 'trial', 'cancelled')
  );

-- 4. One active subscription row per user: remove older duplicates.
--    Keeps the row with the most recent updated_at per user.
DELETE FROM public.subscriptions s
USING public.subscriptions newer
WHERE s.user_id = newer.user_id
  AND s.id <> newer.id
  AND COALESCE(newer.updated_at, newer.created_at) > COALESCE(s.updated_at, s.created_at);

-- 5. Expire subscriptions whose paid period has ended (safety net).
UPDATE public.subscriptions
SET status = 'expired',
    plan = 'free',
    updated_at = NOW()
WHERE expires_at IS NOT NULL
  AND expires_at < NOW()
  AND status IN ('active', 'trial');

-- 6. Indexes
CREATE UNIQUE INDEX IF NOT EXISTS idx_subscriptions_purchase_token ON public.subscriptions(purchase_token);
CREATE INDEX IF NOT EXISTS idx_subscriptions_user_status ON public.subscriptions(user_id, status);

-- =============================================================================
-- NOTE: After running this migration, affected users who genuinely purchased
-- via Google Play will regain Pro automatically on next app launch:
--   App startup -> restorePurchases() -> backend verifies the real Play token
--   -> subscriptions row updated with purchase_token -> Pro granted.
-- =============================================================================
