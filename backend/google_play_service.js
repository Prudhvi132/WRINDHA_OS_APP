const crypto = require('crypto');

// -----------------------------------------------------------------------------
// GOOGLE PLAY DEVELOPER API - SERVER-SIDE PURCHASE VERIFICATION
// Zero external dependencies: raw REST + OAuth2 RS256 JWT via Node crypto
// -----------------------------------------------------------------------------

const PACKAGE_NAME = process.env.GOOGLE_PLAY_PACKAGE_NAME || 'com.wrindha.app';
const SERVICE_ACCOUNT_EMAIL = process.env.GOOGLE_PLAY_SERVICE_ACCOUNT_EMAIL || '';
const PRIVATE_KEY = (process.env.GOOGLE_PLAY_PRIVATE_KEY || '').replace(/\\n/g, '\n');

function isConfigured() {
  return Boolean(SERVICE_ACCOUNT_EMAIL && PRIVATE_KEY && PRIVATE_KEY.includes('PRIVATE KEY'));
}

// Cached OAuth2 access token: { token, expiresAtMs }
let cachedAccessToken = null;

/**
 * Exchange a signed service-account JWT for a Google OAuth2 access token.
 * Scopes: https://www.googleapis.com/auth/androidpublisher
 */
async function getAccessToken() {
  if (cachedAccessToken && cachedAccessToken.expiresAtMs > Date.now() + 60000) {
    return cachedAccessToken.token;
  }
  if (!isConfigured()) {
    throw new Error('Google Play service account not configured');
  }

  const nowSec = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const payload = {
    iss: SERVICE_ACCOUNT_EMAIL,
    scope: 'https://www.googleapis.com/auth/androidpublisher',
    aud: 'https://oauth2.googleapis.com/token',
    iat: nowSec,
    exp: nowSec + 3600,
  };

  const b64Header = Buffer.from(JSON.stringify(header)).toString('base64url');
  const b64Payload = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const signature = crypto
    .createSign('RSA-SHA256')
    .update(`${b64Header}.${b64Payload}`)
    .sign(PRIVATE_KEY)
    .toString('base64url');
  const assertion = `${b64Header}.${b64Payload}.${signature}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });

  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.access_token) {
    throw new Error(`Google OAuth2 token exchange failed (HTTP ${res.status}): ${data.error_description || data.error || 'unknown'}`);
  }

  cachedAccessToken = {
    token: data.access_token,
    expiresAtMs: Date.now() + (data.expires_in || 3600) * 1000,
  };
  return cachedAccessToken.token;
}

/**
 * Verify a Google Play subscription purchase token server-side.
 * Returns { verified, orderId, status, autoRenewing, startTimeMillis, expiryTimeMillis }
 * or throws { statusCode, code, message }.
 */
async function verifyPurchaseToken(purchaseToken, productId) {
  if (!isConfigured()) {
    // Explicit opt-in mock/test mode for internal testing prior to service account configuration
    if (process.env.ALLOW_MOCK_PURCHASES === 'true' || process.env.ALLOW_TEST_PURCHASES === 'true') {
      const now = Date.now();
      return {
        verified: true,
        orderId: `GPA.TEST.${now}`,
        status: 'ACTIVE',
        autoRenewing: true,
        startTimeMillis: now,
        expiryTimeMillis: now + 30 * 24 * 3600 * 1000,
        mock: true,
      };
    }
    throw {
      statusCode: 503,
      code: 'PLAY_VERIFICATION_NOT_CONFIGURED',
      message: 'Google Play Service Account credentials (GOOGLE_PLAY_SERVICE_ACCOUNT_EMAIL and GOOGLE_PLAY_PRIVATE_KEY) are not configured in environment variables.',
    };
  }

  const accessToken = await getAccessToken();

  // 1. Try modern subscriptionsv2 API (required for products configured with base plans)
  try {
    const v2Url = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${encodeURIComponent(PACKAGE_NAME)}/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`;
    const resV2 = await fetch(v2Url, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (resV2.ok) {
      const subDataV2 = await resV2.json().catch(() => ({}));
      const lineItem = subDataV2.lineItems?.[0] || {};
      const expiryTimeMillis = lineItem.expiryTime ? new Date(lineItem.expiryTime).getTime() : 0;
      const isExpired = expiryTimeMillis > 0 && Date.now() > expiryTimeMillis;
      const subState = subDataV2.subscriptionState;
      const isActive = (subState === 'SUBSCRIPTION_STATE_ACTIVE' || subState === 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD') && !isExpired;

      return {
        verified: isActive,
        orderId: subDataV2.latestOrderId || `GPA.${Date.now()}`,
        status: isActive ? 'ACTIVE' : 'EXPIRED',
        autoRenewing: lineItem.autoRenewingPlan != null,
        startTimeMillis: subDataV2.startTime ? new Date(subDataV2.startTime).getTime() : Date.now(),
        expiryTimeMillis,
      };
    }
  } catch (_) {}

  // 2. Fallback to legacy v1 subscription endpoint
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${encodeURIComponent(PACKAGE_NAME)}` +
    `/purchases/subscriptions/${encodeURIComponent(productId)}/tokens/${encodeURIComponent(purchaseToken)}`;

  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });

  const bodyText = await res.text();
  let subData = {};
  try { subData = JSON.parse(bodyText); } catch (_) {}

  if (!res.ok) {
    // 410 GONE = token consumed/expired/unknown -> invalid purchase
    throw {
      statusCode: 400,
      code: 'GOOGLE_PLAY_VERIFICATION_FAILED',
      message: `Google Play purchase verification failed (HTTP ${res.status}): ${subData.error?.message || bodyText.slice(0, 200)}`,
    };
  }

  const expiryTimeMillis = parseInt(subData.expiryTimeMillis || '0', 10);
  const isExpired = expiryTimeMillis > 0 && Date.now() > expiryTimeMillis;

  let status = 'ACTIVE';
  if (isExpired) {
    status = 'EXPIRED';
  } else if (subData.userCancellationTimeMillis) {
    // Cancelled but retains premium access until period ends
    status = 'CANCELLED';
  } else if (subData.paymentState === 0) {
    status = 'PENDING';
  } else if (subData.paymentState === -1) {
    status = 'EXPIRED';
  }

  return {
    verified: true,
    orderId: subData.orderId || `GPA.${Date.now()}`,
    status,
    autoRenewing: subData.autoRenewing ?? true,
    startTimeMillis: parseInt(subData.startTimeMillis || Date.now(), 10),
    expiryTimeMillis,
    cancelReason: subData.cancelReason,
  };
}

module.exports = {
  isConfigured,
  verifyPurchaseToken,
  PACKAGE_NAME,
};
