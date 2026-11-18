import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../services/api_service.dart';

/// Singleton Service handling live Google Play Billing for WrindhaOS
class BillingService extends ChangeNotifier {
  static final BillingService _instance = BillingService._internal();
  factory BillingService() => _instance;
  BillingService._internal();

  /// Must exactly match the Google Play Console subscription product ID and
  /// the productId sent to the backend for server-side verification.
  static const String proSubscriptionId = 'wrindha_pro_monthly';
  static const Set<String> allSubscriptionIds = {
    'wrindha_pro_monthly',
    'wrindhaos_premium_monthly',
  };

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;

  bool isAvailable = false;
  ProductDetails? proProduct;
  bool isProcessing = false;
  bool isVerifying = false;
  String? errorMessage;
  Function(bool)? _onProStatusChanged;

  /// Returns localized price string directly from Google Play Store or default fallback
  String get formattedPrice => proProduct?.price ?? '₹49 / month';

  /// Initialize early in app lifecycle (AppProvider / main)
  Future<void> initialize({Function(bool)? onProStatusChanged}) async {
    _onProStatusChanged = onProStatusChanged;

    try {
      isAvailable = await _iap.isAvailable();
    } catch (e) {
      isAvailable = false;
      if (kDebugMode) {
        print('[BILLING SERVICE] Play Billing check error: $e');
      }
    }

    if (!isAvailable) {
      if (kDebugMode) {
        print('[BILLING SERVICE] Google Play Store Billing is not available on this device/environment.');
      }
      notifyListeners();
      return;
    }

    // Subscribe to continuous purchase updates
    _purchaseSubscription?.cancel();
    _purchaseSubscription = _iap.purchaseStream.listen(
      _handlePurchaseUpdates,
      onDone: () => _purchaseSubscription?.cancel(),
      onError: (error) {
        errorMessage = error.toString();
        notifyListeners();
      },
    );

    // Load live Product Details from Google Play Store
    await queryProducts();
  }

  /// Query Google Play Store for active subscription products
  Future<void> queryProducts() async {
    try {
      isAvailable = await _iap.isAvailable().timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
    } catch (e) {
      isAvailable = false;
    }

    if (!isAvailable) {
      errorMessage = 'Google Play Store billing is unavailable on this device.';
      if (kDebugMode) {
        print('[BILLING SERVICE] Google Play Store Billing is not available on this device/environment.');
      }
      notifyListeners();
      return;
    }

    // Subscribe to continuous purchase updates if not already subscribed
    _purchaseSubscription ??= _iap.purchaseStream.listen(
      _handlePurchaseUpdates,
      onDone: () => _purchaseSubscription?.cancel(),
      onError: (error) {
        errorMessage = error.toString();
        notifyListeners();
      },
    );

    try {
      final ProductDetailsResponse response = await _iap.queryProductDetails(allSubscriptionIds).timeout(
        const Duration(seconds: 25),
        onTimeout: () => ProductDetailsResponse(
          productDetails: [],
          notFoundIDs: allSubscriptionIds.toList(),
        ),
      );
      if (response.error != null) {
        errorMessage = 'Play Store Error: ${response.error!.message} (${response.error!.code})';
        if (kDebugMode) {
          print('[BILLING SERVICE] Query Product Error: ${response.error!.code} - ${response.error!.message}');
        }
      } else if (response.productDetails.isNotEmpty) {
        // Find matching product or take first returned
        proProduct = response.productDetails.firstWhere(
          (p) => p.id == proSubscriptionId,
          orElse: () => response.productDetails.first,
        );
        errorMessage = null;
        if (kDebugMode) {
          print('[BILLING SERVICE] Found Product: ${proProduct!.id} - Price: ${proProduct!.price}');
        }
      } else {
        errorMessage = 'Product "$proSubscriptionId" pending Play Console activation or app download via Play Store link.';
        if (kDebugMode) {
          print('[BILLING SERVICE] Products not found: ${response.notFoundIDs}');
        }
      }
    } catch (e) {
      errorMessage = e.toString();
      if (kDebugMode) {
        print('[BILLING SERVICE] Exception querying products: $e');
      }
    }
    notifyListeners();
  }

  /// Trigger live Google Play purchase flow
  Future<bool> buyProSubscription() async {
    if (!isAvailable) {
      errorMessage = 'Google Play Store billing is not available on this device.';
      notifyListeners();
      return false;
    }

    // Only query if not already cached in memory
    if (proProduct == null) {
      await queryProducts();
    }

    if (proProduct == null) {
      if (errorMessage == null || errorMessage!.isEmpty) {
        errorMessage = 'Subscription product "$proSubscriptionId" details not returned by Google Play.';
      }
      notifyListeners();
      return false;
    }

    isProcessing = true;
    errorMessage = null;
    notifyListeners();

    try {
      final PurchaseParam purchaseParam = PurchaseParam(productDetails: proProduct!);
      final bool success = await _iap.buyNonConsumable(purchaseParam: purchaseParam);
      if (!success) {
        isProcessing = false;
        errorMessage = 'Google Play Store did not launch purchase sheet.';
        notifyListeners();
      }
      return success;
    } catch (e) {
      isProcessing = false;
      errorMessage = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Handle incoming transactions from Google Play.
  /// NOTE: pending & restored purchases are also delivered on this stream at
  /// app startup, which is how existing subscriptions are re-recognized.
  Future<void> _handlePurchaseUpdates(List<PurchaseDetails> purchaseDetailsList) async {
    for (var purchase in purchaseDetailsList) {
      if (purchase.productID != proSubscriptionId) continue;
      switch (purchase.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // Verify with backend BEFORE granting Pro access.
          await _verifyPurchaseWithBackend(purchase);
          // Mandatory: acknowledge with Google Play to finalize transaction.
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }
          break;
        case PurchaseStatus.error:
          isProcessing = false;
          errorMessage = purchase.error?.message ?? 'Purchase failed or was canceled.';
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }
          break;
        case PurchaseStatus.pending:
          isProcessing = true;
          break;
        case PurchaseStatus.canceled:
          isProcessing = false;
          errorMessage = 'Purchase was canceled.';
          break;
      }
    }
    notifyListeners();
  }

  /// Ask Google Play to re-deliver past purchases (fires purchaseStream with
  /// PurchaseStatus.restored entries, which we then verify with the backend).
  Future<void> restorePurchases() async {
    if (!isAvailable) return;
    try {
      if (kDebugMode) {
        print('[BILLING SERVICE] Requesting purchase restore from Google Play...');
      }
      await _iap.restorePurchases();
      // Restored purchases arrive asynchronously via _handlePurchaseUpdates.
      // Also confirm with the backend in case Play has nothing to restore but
      // the server already holds a verified subscription for this user.
      await checkBackendSubscriptionStatus();
    } catch (e) {
      if (kDebugMode) {
        print('[BILLING SERVICE] Restore purchases error: $e');
      }
    }
  }

  /// Extract the raw Google Play purchase token from purchase verification data.
  /// On Android, serverVerificationData IS the raw purchase token string.
  String? _extractPurchaseToken(PurchaseDetails purchase) {
    final data = purchase.verificationData;
    final server = data.serverVerificationData;
    if (server.isNotEmpty) {
      // serverVerificationData is the raw purchase token on Android.
      // Guard against any platform that returns JSON instead.
      final trimmed = server.trim();
      if (trimmed.startsWith('{')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map) {
            return (decoded['purchaseToken'] ?? decoded['token'])?.toString();
          }
        } catch (_) {
          return trimmed;
        }
      }
      return trimmed;
    }
    final local = data.localVerificationData;
    return (local.isNotEmpty) ? local.trim() : null;
  }

  /// Verify purchase token with backend server. Pro is granted ONLY on success.
  Future<void> _verifyPurchaseWithBackend(PurchaseDetails purchase) async {
    final purchaseToken = _extractPurchaseToken(purchase);
    if (purchaseToken == null || purchaseToken.isEmpty) {
      if (kDebugMode) {
        print('[BILLING SERVICE] No purchase token available for verification');
      }
      errorMessage = 'Purchase verification failed: Missing purchase token';
      isProcessing = false;
      notifyListeners();
      return;
    }
    await verifyPurchaseToken(purchaseToken);
  }

  /// Send a purchase token to the backend for server-side verification.
  /// There is NO fallback that activates Pro without verification.
  Future<bool> verifyPurchaseToken(String purchaseToken) async {
    isVerifying = true;
    isProcessing = true;
    notifyListeners();
    try {
      if (kDebugMode) {
        print('[BILLING SERVICE] Verifying purchase token with backend...');
      }

      final headers = await ApiService.getAuthHeaders();
      if (headers == null) {
        errorMessage = 'Authentication required for purchase verification. Please log in again.';
        if (kDebugMode) {
          print('[BILLING SERVICE] No auth session for verification');
        }
        return false;
      }

      // Matches deployed Vercel routing: /api/subscription/verify-play-purchase
      final endpoints = [
        '/subscription/verify-play-purchase',
        '/subscription/verify',
        '/subscription/upgrade', // secure legacy route, also verifies tokens
      ];

      http.Response? response;
      for (final ep in endpoints) {
        try {
          response = await http.post(
            Uri.parse('${ApiService.baseUrl}$ep'),
            headers: headers,
            body: jsonEncode({
              'purchaseToken': purchaseToken,
              'productId': proSubscriptionId,
            }),
          ).timeout(const Duration(seconds: 20));
          if (kDebugMode) {
            print('[BILLING SERVICE] Verify $ep -> HTTP ${response.statusCode}');
          }
          if (response.statusCode != 404 && response.statusCode != 405) break;
        } catch (_) {}
      }

      if (response == null) {
        errorMessage = 'Unable to reach the verification server. Check your connection.';
        return false;
      }

      Map<String, dynamic> data = {};
      try {
        data = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {}

      if (response.statusCode == 200 && data['success'] == true) {
        if (data['isPro'] == true || (data['subscription']?['isPro'] == true)) {
          if (kDebugMode) {
            print('[BILLING SERVICE] Purchase verified. Pro granted by backend.');
          }
          errorMessage = null;
          if (_onProStatusChanged != null) {
            _onProStatusChanged!(true);
          }
          return true;
        }
        errorMessage = data['message'] ?? 'Purchase is not active.';
        return false;
      }

      errorMessage = data['message'] ?? 'Purchase verification failed (HTTP ${response.statusCode}).';
      if (kDebugMode) {
        print('[BILLING SERVICE] Backend verification failed: $errorMessage');
      }
      return false;
    } catch (e) {
      errorMessage = 'Purchase verification error: $e';
      if (kDebugMode) {
        print('[BILLING SERVICE] Verification exception: $e');
      }
      return false;
    } finally {
      isVerifying = false;
      isProcessing = false;
      notifyListeners();
    }
  }

  /// Check with backend if this user already has a verified active subscription.
  Future<void> checkBackendSubscriptionStatus() async {
    try {
      final headers = await ApiService.getAuthHeaders();
      if (headers == null) {
        if (kDebugMode) {
          print('[BILLING SERVICE] No auth session for subscription check');
        }
        return;
      }

      // Deployed Vercel routes first.
      final endpoints = ['/subscription/me', '/subscription', '/subscription-me'];
      for (final ep in endpoints) {
        http.Response? response;
        try {
          response = await http.get(
            Uri.parse('${ApiService.baseUrl}$ep'),
            headers: headers,
          ).timeout(const Duration(seconds: 10));
        } catch (_) {}

        if (response != null && response.statusCode == 200) {
          Map<String, dynamic> data = {};
          try {
            data = jsonDecode(response.body) as Map<String, dynamic>;
          } catch (_) {}
          final subscription = (data['subscription'] is Map) ? data['subscription'] : data;
          final isPro = data['isPro'] == true ||
              data['isPremium'] == true ||
              subscription?['isPro'] == true ||
              subscription?['isPremium'] == true;
          if (isPro) {
            if (kDebugMode) {
              print('[BILLING SERVICE] Backend shows an active Pro subscription');
            }
            if (_onProStatusChanged != null) {
              _onProStatusChanged!(true);
            }
          }
          return;
        }
      }

      // Secondary check through ApiService (owns its own fallback routing).
      final sub = await ApiService.fetchUserSubscription();
      if (sub != null && sub.isActive && sub.isPro) {
        if (kDebugMode) {
          print('[BILLING SERVICE] ApiService confirmed active Pro subscription');
        }
        if (_onProStatusChanged != null) {
          _onProStatusChanged!(true);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('[BILLING SERVICE] Backend subscription check failed: $e');
      }
    }
  }

  @override
  void dispose() {
    _purchaseSubscription?.cancel();
    super.dispose();
  }
}
